defmodule Spectre.Reply.Sanitizer do
  @moduledoc """
  Strips Spectre control tokens from model output before it becomes a
  user-visible reply.

  Prompts teach the model Spectre's routing and planning markup — `<al>`,
  `<intent>`, `<reply>` wrappers, `INTENT:`/`AL:` control lines — and models
  also emit reasoning wrappers (`<think>`, HTML comments). None of that may
  reach the user, and without a core scrubber every host rewrites the same
  cleanup. This sanitizer is the runtime default wherever LLM text becomes
  `reply_text`; pass `sanitize_reply: false` to opt out, or configure an
  action planner with a `clean_reply/3` callback to take full ownership.

  Host-specific cleanup (localized model preambles, channel formatting) stays
  in the host — this module removes only tokens Spectre itself introduces plus
  universal reasoning wrappers.
  """

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
  otherwise untouched.
  """
  @spec sanitize(String.t(), keyword()) :: String.t()
  def sanitize(text, opts \\ []) when is_binary(text) and is_list(opts) do
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
    lower = String.downcase(text)

    with {start, _open_size} <- :binary.match(lower, open),
         search_from = start + byte_size(open),
         {relative_stop, close_size} <-
           :binary.match(binary_part(lower, search_from, byte_size(lower) - search_from), close) do
      stop = search_from + relative_stop + close_size
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
      acc
      |> String.replace("<#{tag}>", "")
      |> String.replace("</#{tag}>", "")
      |> String.replace("<#{String.upcase(tag)}>", "")
      |> String.replace("</#{String.upcase(tag)}>", "")
    end)
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
