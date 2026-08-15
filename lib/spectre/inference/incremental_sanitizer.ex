defmodule Spectre.Inference.IncrementalSanitizer do
  @moduledoc """
  Bounded finite-state sanitizer for provisional streamed text.

  A marker may be split across arbitrary provider chunks, so sanitizing each
  delta independently is unsafe. This module retains only a possible marker
  prefix or tag header. Bodies of control blocks and rejected control lines
  are discarded incrementally and never accumulate in memory.

  The complete response still passes through Spectre's ordinary reply
  sanitizer and guards before it becomes a committed `Spectre.Result`.

  UTF-8 codepoints may also cross normalized provider-delta boundaries. The
  sanitizer retains their bounded trailing bytes before its text state
  machine sees the chunk.
  """

  alias Spectre.Inference.Utf8Buffer

  @control_tags ["think", "al", "intent"]
  @reply_tag "reply"
  @known_tags @control_tags ++ [@reply_tag]
  @control_prefixes ["intent:", "al:"]
  @comment_open "<!--"
  @comment_close "-->"
  @default_max_lookahead_bytes 128
  @minimum_lookahead_bytes 16

  defstruct buffer: "",
            utf8: %Utf8Buffer{},
            mode: :visible,
            line_start?: true,
            sanitize?: true,
            max_lookahead_bytes: @default_max_lookahead_bytes

  @type block :: :comment | {:tag, binary()}
  @type mode :: :visible | :drop_line | {:block, block()}
  @type t :: %__MODULE__{
          buffer: binary(),
          utf8: Utf8Buffer.t(),
          mode: mode(),
          line_start?: boolean(),
          sanitize?: boolean(),
          max_lookahead_bytes: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max =
      Keyword.get(
        opts,
        :max_sanitizer_lookahead_bytes,
        @default_max_lookahead_bytes
      )

    if is_integer(max) and max >= @minimum_lookahead_bytes do
      %__MODULE__{
        sanitize?: Keyword.get(opts, :sanitize_reply, true),
        max_lookahead_bytes: max
      }
    else
      raise ArgumentError,
            "sanitizer lookahead must be at least #{@minimum_lookahead_bytes} bytes"
    end
  end

  @spec push(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def push(%__MODULE__{sanitize?: false} = state, chunk) when is_binary(chunk) do
    with {:ok, valid, utf8} <- Utf8Buffer.push(state.utf8, chunk) do
      {:ok, valid, %{state | utf8: utf8}}
    end
  end

  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    with {:ok, valid, utf8} <- Utf8Buffer.push(state.utf8, chunk) do
      state
      |> Map.put(:utf8, utf8)
      |> Map.update!(:buffer, &(&1 <> valid))
      |> drain(false, [])
    end
  end

  @spec finish(t()) :: {:ok, binary(), t()} | {:error, term()}
  def finish(%__MODULE__{sanitize?: false} = state) do
    with :ok <- Utf8Buffer.finish(state.utf8) do
      {:ok, state.buffer, %{state | buffer: ""}}
    end
  end

  def finish(%__MODULE__{} = state) do
    with :ok <- Utf8Buffer.finish(state.utf8) do
      drain(state, true, [])
    end
  end

  defp drain(%{mode: {:block, :comment}} = state, finish?, output) do
    case :binary.match(state.buffer, @comment_close) do
      {position, length} ->
        rest = drop_prefix(state.buffer, position + length)
        drain(%{state | buffer: rest, mode: :visible}, finish?, output)

      :nomatch when finish? ->
        finished(output, %{state | buffer: ""})

      :nomatch ->
        retained = possible_suffix(state.buffer, [@comment_close])
        finished(output, %{state | buffer: retained})
    end
  end

  # Each branch is a transition in the bounded tag-parser state machine. The
  # complete transition table stays local so partial tags cannot leak.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp drain(%{mode: {:block, {:tag, tag}}} = state, finish?, output) do
    case :binary.match(state.buffer, "<") do
      :nomatch when finish? ->
        finished(output, %{state | buffer: ""})

      :nomatch ->
        # Control-block content is never retained. Only a possible '<' tag
        # prefix can be relevant to the next provider chunk.
        finished(output, %{state | buffer: ""})

      {position, 1} ->
        candidate = binary_part(state.buffer, position, byte_size(state.buffer) - position)

        case parse_tag(candidate, finish?, state.max_lookahead_bytes) do
          {:ok, ^tag, true, consumed} ->
            rest = drop_prefix(candidate, consumed)
            drain(%{state | buffer: rest, mode: :visible}, finish?, output)

          {:ok, _name, _closing?, consumed} ->
            drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

          {:comment, consumed} ->
            drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

          {:drop_fragment, consumed} ->
            drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

          :literal ->
            drain(%{state | buffer: drop_prefix(candidate, 1)}, finish?, output)

          :pending ->
            finished(output, %{state | buffer: candidate})

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp drain(%{mode: :drop_line} = state, finish?, output) do
    case :binary.match(state.buffer, "\n") do
      {position, 1} ->
        rest = drop_prefix(state.buffer, position + 1)
        drain(%{state | buffer: rest, mode: :visible, line_start?: true}, finish?, output)

      :nomatch ->
        # Once classified as a control line, its body can be discarded without
        # waiting for the newline.
        finished(output, %{state | buffer: ""})
    end
  end

  defp drain(%{mode: :visible, line_start?: true} = state, finish?, output) do
    case classify_line_start(state.buffer, finish?, state.max_lookahead_bytes) do
      :control ->
        drain(%{state | mode: :drop_line}, finish?, output)

      :visible ->
        drain(%{state | line_start?: false}, finish?, output)

      :pending ->
        finished(output, state)

      {:error, _reason} = error ->
        error
    end
  end

  # Visible-mode branches are the parser's transition table for text, newline,
  # tag, comment, and bounded partial-input handling.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp drain(%{mode: :visible} = state, finish?, output) do
    case next_visible_special(state.buffer) do
      nil when finish? ->
        finished(push_output(state.buffer, output), %{state | buffer: ""})

      nil ->
        finished(push_output(state.buffer, output), %{state | buffer: ""})

      {:newline, position} ->
        emitted_length = position + 1
        emitted = binary_part(state.buffer, 0, emitted_length)
        rest = drop_prefix(state.buffer, emitted_length)

        drain(
          %{state | buffer: rest, line_start?: true},
          finish?,
          push_output(emitted, output)
        )

      {:tag, position} ->
        before = binary_part(state.buffer, 0, position)
        candidate = binary_part(state.buffer, position, byte_size(state.buffer) - position)
        output = push_output(before, output)

        case parse_tag(candidate, finish?, state.max_lookahead_bytes) do
          {:ok, tag, false, consumed} when tag in @control_tags ->
            rest = drop_prefix(candidate, consumed)
            drain(%{state | buffer: rest, mode: {:block, {:tag, tag}}}, finish?, output)

          {:ok, _tag, _closing?, consumed} ->
            drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

          {:comment, consumed} ->
            rest = drop_prefix(candidate, consumed)
            drain(%{state | buffer: rest, mode: {:block, :comment}}, finish?, output)

          {:drop_fragment, consumed} ->
            drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

          :literal ->
            drain(
              %{state | buffer: drop_prefix(candidate, 1)},
              finish?,
              push_output("<", output)
            )

          :pending ->
            finished(output, %{state | buffer: candidate})

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp parse_tag(buffer, finish?, max) do
    lower = ascii_downcase(buffer)

    cond do
      String.starts_with?(lower, @comment_open) ->
        {:comment, byte_size(@comment_open)}

      not finish? and String.starts_with?(@comment_open, lower) ->
        bounded_pending(buffer, max)

      true ->
        parse_named_tag(buffer, lower, finish?, max)
    end
  end

  defp parse_named_tag(buffer, <<"</", rest::binary>>, finish?, max),
    do: parse_tag_name(buffer, rest, true, 2, finish?, max)

  defp parse_named_tag(buffer, <<"<", rest::binary>>, finish?, max),
    do: parse_tag_name(buffer, rest, false, 1, finish?, max)

  defp parse_named_tag(_buffer, _lower, _finish?, _max), do: :literal

  defp parse_tag_name(buffer, name_source, closing?, prefix_size, finish?, max) do
    case tag_name_length(name_source, 0) do
      {:delimiter, name_length} ->
        name = binary_part(name_source, 0, name_length)

        if name in @known_tags do
          complete_known_tag(buffer, name, closing?, finish?, max)
        else
          :literal
        end

      :exhausted ->
        name = name_source

        cond do
          possible_tag_name?(name) and not finish? ->
            bounded_pending(buffer, max)

          possible_tag_name?(name) and finish? ->
            {:drop_fragment, prefix_size + byte_size(name)}

          true ->
            :literal
        end
    end
  end

  defp complete_known_tag(buffer, name, closing?, finish?, max) do
    case :binary.match(buffer, ">") do
      {position, 1} ->
        {:ok, name, closing?, position + 1}

      :nomatch when finish? ->
        {:drop_fragment, byte_size(buffer)}

      :nomatch ->
        bounded_pending(buffer, max)
    end
  end

  defp tag_name_length(<<>>, _length), do: :exhausted

  defp tag_name_length(<<char, _rest::binary>>, length)
       when char in [32, 9, 10, 13, ?>, ?/],
       do: {:delimiter, length}

  defp tag_name_length(<<_char, rest::binary>>, length),
    do: tag_name_length(rest, length + 1)

  defp possible_tag_name?(name),
    do: name == "" or Enum.any?(@known_tags, &String.starts_with?(&1, name))

  defp bounded_pending(buffer, max) do
    if byte_size(buffer) <= max,
      do: :pending,
      else: {:error, :sanitizer_lookahead_exceeded}
  end

  defp classify_line_start(buffer, finish?, max) do
    lower = ascii_downcase(buffer)
    trimmed = trim_ascii_line_start(lower)

    cond do
      Enum.any?(@control_prefixes, &String.starts_with?(trimmed, &1)) ->
        :control

      not finish? and
          (trimmed == "" or Enum.any?(@control_prefixes, &String.starts_with?(&1, trimmed))) ->
        bounded_line_start(buffer, max)

      true ->
        :visible
    end
  end

  defp bounded_line_start(buffer, max) do
    if byte_size(buffer) <= max,
      do: :pending,
      else: {:error, :sanitizer_lookahead_exceeded}
  end

  defp next_visible_special(buffer) do
    tag = match_position(buffer, "<", :tag)
    newline = match_position(buffer, "\n", :newline)

    [tag, newline]
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&elem(&1, 1), fn -> nil end)
  end

  defp match_position(binary, literal, kind) do
    case :binary.match(binary, literal) do
      {position, _length} -> {kind, position}
      :nomatch -> nil
    end
  end

  defp possible_suffix(buffer, markers) do
    maximum =
      min(
        byte_size(buffer),
        Enum.max(Enum.map(markers, &byte_size/1), fn -> 0 end)
      )

    lower = ascii_downcase(buffer)

    Enum.find_value(maximum..1//-1, "", fn size ->
      suffix = binary_part(lower, byte_size(lower) - size, size)

      if Enum.any?(markers, &String.starts_with?(&1, suffix)) do
        binary_part(buffer, byte_size(buffer) - size, size)
      end
    end)
  end

  defp trim_ascii_line_start(<<char, rest::binary>>) when char in [32, 9, 13],
    do: trim_ascii_line_start(rest)

  defp trim_ascii_line_start(binary), do: binary

  defp ascii_downcase(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp drop_prefix(binary, size),
    do: binary_part(binary, size, byte_size(binary) - size)

  defp finished(output, state),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(output)), state}

  defp push_output("", output), do: output
  defp push_output(binary, output), do: [binary | output]
end
