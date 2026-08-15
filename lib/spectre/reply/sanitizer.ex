defmodule Spectre.Reply.Sanitizer do
  @moduledoc """
  Strips Spectre control tokens from model output before it becomes a
  user-visible reply.

  Prompts teach the model Spectre's routing and planning markup — `<al>`,
  `<intent>`, `<reply>` wrappers, `INTENT:`/`AL:` control lines — and models
  also emit reasoning wrappers (`<think>`, HTML comments). None of that may
  reach the user, and without a core scrubber every host rewrites the same
  cleanup. This sanitizer is the runtime default wherever LLM text becomes
  `reply_text`; pass `sanitize_reply: false` to opt out. An action planner may
  perform its own cleanup first, but its visible reply still crosses this
  structural boundary unless sanitization is explicitly disabled.

  Host-specific cleanup (localized model preambles, channel formatting) stays
  in the host. It can be supplied through `:reply_sanitizer` as a module, or
  `{module, options}`, implementing this module's callbacks. The configured
  sanitizer is an additive layer: Spectre removes its own control tokens
  first, then invokes the extension. This keeps the core security boundary in
  place while allowing a package such as Pulse to own model-specific cleanup.

  Streaming extensions must implement all three streaming callbacks as well
  as `sanitize/2`. They receive only text already accepted by the core
  incremental sanitizer. A sanitizer may suppress text but must not synthesize
  or expand it. Its provisional output must also be monotonic with
  `sanitize/2`: concatenated deltas must not contain text that the terminal
  callback would remove.
  """

  alias Spectre.Reply.Sanitizer.Runtime

  @type stream_state :: term()

  @callback sanitize(String.t(), keyword()) :: String.t()
  @callback init_stream(keyword()) :: {:ok, stream_state()} | {:error, term()}
  @callback sanitize_chunk(String.t(), stream_state()) ::
              {:ok, String.t(), stream_state()} | {:error, term()}
  @callback finish_stream(stream_state()) :: {:ok, String.t()} | {:error, term()}

  @optional_callbacks init_stream: 1, sanitize_chunk: 2, finish_stream: 1

  @stripped_blocks [
    {"<!--", "-->"},
    {"<think", "</think>"},
    {"<al", "</al>"},
    {"<intent", "</intent>"}
  ]

  @stripped_tags ["reply"]

  @control_line_prefixes ["INTENT:", "AL:"]

  @doc """
  Removes Spectre control tokens and reasoning wrappers, then trims.

      iex> Spectre.Reply.Sanitizer.sanitize("<think>hmm</think>Hello <al>a1</al>there")
      "Hello there"

  Honors `sanitize_reply: false` in `opts` by returning the text trimmed but
  otherwise untouched. `:reply_sanitizer` accepts a callback module or
  `{module, options}` for additional cleanup after Spectre's built-in pass.
  """
  @spec sanitize(String.t(), keyword()) :: String.t()
  def sanitize(text, opts \\ []) when is_binary(text) and is_list(opts) do
    text
    |> sanitize_core(opts)
    |> Runtime.sanitize(opts)
  end

  defp sanitize_core(text, opts) do
    if Keyword.get(opts, :sanitize_reply, true) do
      @stripped_blocks
      |> Enum.reduce(text, fn {open, close}, acc -> strip_between(acc, open, close) end)
      |> strip_tags(@stripped_tags)
      |> strip_control_lines(@control_line_prefixes)
      |> String.trim()
    else
      String.trim(text)
    end
  end

  # Removes every case-insensitive `open…close` block, including nested
  # repetitions, without regex backtracking on adversarial input.
  @spec strip_between(String.t(), String.t(), String.t()) :: String.t()
  defp strip_between(text, open, close) do
    # Regex indexes refer to the original binary. Searching a downcased copy
    # and slicing the original is unsafe because Unicode case folding can
    # change byte length (for example, "İ" becomes "i̇"). The patterns are
    # escaped literals, so this remains a bounded, non-backtracking search.
    with {start, open_size} <- literal_match(text, open),
         search_from = start + open_size,
         {close_start, close_size} <- literal_match(text, close, search_from) do
      stop = close_start + close_size
      before_part = binary_part(text, 0, start)
      after_part = binary_part(text, stop, byte_size(text) - stop)
      strip_between(before_part <> after_part, open, close)
    else
      :nomatch -> text
    end
  end

  @spec strip_tags(String.t(), [String.t()]) :: String.t()
  defp strip_tags(text, tags) do
    Enum.reduce(tags, text, fn tag, acc ->
      Regex.replace(Regex.compile!("</?#{Regex.escape(tag)}\\s*>", "iu"), acc, "")
    end)
  end

  @spec literal_match(String.t(), String.t(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | :nomatch
  defp literal_match(text, literal, offset \\ 0) do
    regex = Regex.compile!(Regex.escape(literal), "iu")

    case Regex.run(regex, text, return: :index, offset: offset) do
      [{start, size}] -> {start, size}
      nil -> :nomatch
    end
  end

  @spec strip_control_lines(String.t(), [String.t()]) :: String.t()
  defp strip_control_lines(text, prefixes) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      normalized = line |> String.trim() |> String.upcase()
      Enum.any?(prefixes, &String.starts_with?(normalized, &1))
    end)
    |> Enum.join("\n")
  end
end
