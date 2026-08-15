defmodule Spectre.Inference.IncrementalSanitizer do
  @moduledoc false

  alias Spectre.Inference.Utf8Buffer

  @control_tags ["think", "al", "intent"]
  @reply_tag "reply"
  @known_tags @control_tags ++ [@reply_tag]
  @control_prefixes ["INTENT:", "AL:"]
  @comment_open "<!--"
  @comment_close "-->"
  @output_control_markers [
    @comment_open,
    "<think",
    "<al",
    "<intent",
    "<reply",
    "</reply"
  ]
  @default_max_lookahead_bytes 128
  @minimum_lookahead_bytes 16

  @control_open_patterns Enum.map(@control_tags, fn tag ->
                           {tag, Regex.compile!("\\A#{Regex.escape("<" <> tag)}", "iu")}
                         end)
  @reply_prefix_pattern Regex.compile!("\\A</?#{@reply_tag}", "iu")

  defstruct buffer: "",
            utf8: %Utf8Buffer{},
            mode: :visible,
            line_start?: true,
            line_buffer: "",
            syntax_buffer: "",
            sanitize?: true,
            max_lookahead_bytes: @default_max_lookahead_bytes

  @type block :: :comment | {:tag, binary()}
  @type mode :: :visible | :drop_line | {:block, block()}
  @type t :: %__MODULE__{
          buffer: binary(),
          utf8: Utf8Buffer.t(),
          mode: mode(),
          line_start?: boolean(),
          line_buffer: binary(),
          syntax_buffer: binary(),
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

  # Visible-mode branches are the parser's transition table for text, newline,
  # tag, comment, and bounded partial-input handling.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp drain(%{mode: :visible} = state, finish?, output) do
    drain_visible(state, finish?, output)
  end

  defp drain_visible(state, finish?, output) do
    case next_visible_special(state.buffer) do
      nil when finish? ->
        finish_visible(state.buffer, state, output)

      nil ->
        continue_visible(state.buffer, state, output)

      {:newline, position} ->
        emitted_length = position + 1
        emitted = binary_part(state.buffer, 0, emitted_length)
        rest = drop_prefix(state.buffer, emitted_length)

        with {:ok, state, output} <- collect_visible(emitted, state, output, finish?) do
          drain(%{state | buffer: rest}, finish?, output)
        end

      {:tag, position} ->
        before = binary_part(state.buffer, 0, position)
        candidate = binary_part(state.buffer, position, byte_size(state.buffer) - position)

        with {:ok, state, output} <- collect_visible(before, state, output, false) do
          continue_before_tag(candidate, state, finish?, output)
        end
    end
  end

  defp continue_before_tag(candidate, %{mode: :drop_line} = state, finish?, output),
    do: drain(%{state | buffer: candidate}, finish?, output)

  defp continue_before_tag(candidate, state, finish?, output),
    do: drain_visible_tag(candidate, state, finish?, output)

  defp drain_visible_tag(candidate, state, finish?, output) do
    case parse_tag(candidate, finish?, state.max_lookahead_bytes) do
      {:ok, tag, false, consumed} when tag in @control_tags ->
        rest = drop_prefix(candidate, consumed)
        state = discard_syntax_join(state)
        drain(%{state | buffer: rest, mode: {:block, {:tag, tag}}}, finish?, output)

      {:ok, _tag, _closing?, consumed} ->
        state = discard_syntax_join(state)
        drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

      {:comment, consumed} ->
        rest = drop_prefix(candidate, consumed)
        state = discard_syntax_join(state)
        drain(%{state | buffer: rest, mode: {:block, :comment}}, finish?, output)

      {:drop_fragment, consumed} ->
        state = discard_syntax_join(state)
        drain(%{state | buffer: drop_prefix(candidate, consumed)}, finish?, output)

      :literal ->
        with {:ok, state, output} <- collect_visible("<", state, output, false) do
          drain(%{state | buffer: drop_prefix(candidate, 1)}, finish?, output)
        end

      :pending ->
        finished(output, %{state | buffer: candidate})

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_tag(buffer, finish?, max) do
    lower = ascii_downcase(buffer)

    cond do
      String.starts_with?(lower, @comment_open) ->
        {:comment, byte_size(@comment_open)}

      not finish? and String.starts_with?(@comment_open, lower) ->
        bounded_pending(buffer, max)

      tag = control_open_prefix(buffer) ->
        complete_prefixed_control_tag(buffer, tag, finish?, max)

      reply_tag_prefix?(buffer) ->
        complete_prefixed_reply_tag(buffer, finish?, max)

      true ->
        parse_named_tag(buffer, lower, finish?, max)
    end
  end

  # The terminal sanitizer treats `<think`, `<al`, and `<intent` as block
  # prefixes, not exact tag names. Match the same prefix here before the
  # stricter tag parser so provisional output can never expose a block that
  # the authoritative terminal path would later remove.
  defp control_open_prefix(buffer) do
    Enum.find_value(@control_open_patterns, fn {tag, pattern} ->
      if Regex.match?(pattern, buffer), do: tag
    end)
  end

  defp reply_tag_prefix?(buffer), do: Regex.match?(@reply_prefix_pattern, buffer)

  defp complete_prefixed_control_tag(buffer, tag, finish?, max) do
    case :binary.match(buffer, ">") do
      {position, 1} -> {:ok, tag, false, position + 1}
      :nomatch when finish? -> {:drop_fragment, byte_size(buffer)}
      :nomatch -> bounded_pending(buffer, max)
    end
  end

  defp complete_prefixed_reply_tag(buffer, finish?, max) do
    case :binary.match(buffer, ">") do
      {position, 1} -> {:drop_fragment, position + 1}
      :nomatch when finish? -> {:drop_fragment, byte_size(buffer)}
      :nomatch -> bounded_pending(buffer, max)
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

  defp finish_visible(binary, state, output) do
    with {:ok, state, output} <- collect_visible(binary, state, output, true) do
      finished(output, %{state | buffer: ""})
    end
  end

  defp continue_visible(binary, state, output) do
    with {:ok, state, output} <- collect_visible(binary, state, output, false) do
      finished(output, %{state | buffer: ""})
    end
  end

  # The structural parser removes direct control tags before this point. Keep
  # a possible marker suffix until the next visible bytes arrive so removing a
  # tag or comment cannot splice two fragments into a fresh control opener.
  defp collect_visible(binary, state, output, finish?) do
    combined = state.syntax_buffer <> binary

    if finish? do
      collect_line_visible(combined, %{state | syntax_buffer: ""}, output, true)
    else
      retained = possible_suffix(combined, @output_control_markers)
      stable_size = byte_size(combined) - byte_size(retained)
      stable = binary_part(combined, 0, stable_size)
      state = %{state | syntax_buffer: retained}
      collect_line_visible(stable, state, output, false)
    end
  end

  defp collect_line_visible("", state, output, _finish?), do: {:ok, state, output}

  defp collect_line_visible(binary, %{line_start?: false} = state, output, finish?) do
    case :binary.match(binary, "\n") do
      :nomatch ->
        {:ok, state, push_output(binary, output)}

      {position, 1} ->
        length = position + 1
        emitted = binary_part(binary, 0, length)
        rest = drop_prefix(binary, length)
        state = %{state | line_start?: true, line_buffer: ""}
        collect_line_visible(rest, state, push_output(emitted, output), finish?)
    end
  end

  # Markup and comments are removed before bytes reach this small line-prefix
  # buffer. Holding only a possible control prefix prevents removed markup from
  # joining visible fragments into `INTENT:` or `AL:` after earlier bytes have
  # already escaped to the consumer.
  defp collect_line_visible(binary, %{line_start?: true} = state, output, finish?) do
    combined = state.line_buffer <> binary

    case :binary.match(combined, "\n") do
      {position, 1} ->
        length = position + 1
        line = binary_part(combined, 0, position)
        rest = drop_prefix(combined, length)
        state = %{state | line_buffer: "", line_start?: true, mode: :visible}

        output =
          if control_line?(line),
            do: output,
            else: push_output(binary_part(combined, 0, length), output)

        collect_line_visible(rest, state, output, finish?)

      :nomatch ->
        classify_visible_prefix(combined, state, output, finish?)
    end
  end

  defp classify_visible_prefix(combined, state, output, finish?) do
    normalized = normalize_line_start(combined)

    cond do
      control_prefix?(normalized) ->
        {:ok, %{state | line_buffer: "", mode: :drop_line}, output}

      not finish? and possible_control_prefix?(normalized) ->
        if byte_size(combined) <= state.max_lookahead_bytes,
          do: {:ok, %{state | line_buffer: combined}, output},
          else: {:error, :sanitizer_lookahead_exceeded}

      true ->
        {:ok, %{state | line_buffer: "", line_start?: false}, push_output(combined, output)}
    end
  end

  defp control_line?(line) do
    line
    |> String.trim()
    |> String.upcase()
    |> control_prefix?()
  end

  defp normalize_line_start(line), do: line |> String.trim_leading() |> String.upcase()

  defp control_prefix?(normalized),
    do: Enum.any?(@control_prefixes, &String.starts_with?(normalized, &1))

  defp possible_control_prefix?(normalized) do
    normalized == "" or Enum.any?(@control_prefixes, &String.starts_with?(&1, normalized))
  end

  defp discard_syntax_join(state), do: %{state | syntax_buffer: ""}
end
