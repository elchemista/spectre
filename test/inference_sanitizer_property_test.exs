defmodule SpectreInferenceSanitizerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Inference.IncrementalSanitizer
  alias Spectre.Reply.Sanitizer

  @fragments [
    "",
    "plain text",
    "é🙂",
    " ",
    "\t",
    "\r",
    "\n",
    "\u00A0",
    "\u2003",
    "INTENT: route",
    "IN",
    "TENT: route",
    "intent: route",
    "AL: action",
    "A",
    "L: action",
    "<think>",
    "<thinkX>",
    "<THINK private>",
    "</think>",
    "<al>",
    "<alpine>",
    "</al>",
    "<intent>",
    "<intentional>",
    "</intent>",
    "<reply>",
    "<reply\u00A0>",
    "</reply>",
    "<!--",
    "-->",
    "<unknown>",
    "</unknown>"
  ]

  @dangerous_constructs [
    "<!--hidden-->",
    "<think>hidden</think>",
    "<al>hidden</al>",
    "<intent>hidden</intent>",
    "<reply>visible</reply>"
  ]

  @removed_seams ["<reply>", "</reply>", "<!--seam-->", "<think>seam</think>"]

  property "provisional output never contains content removed by the terminal sanitizer" do
    check all(
            fragments <-
              list_of(
                one_of([member_of(@fragments), string(:utf8, max_length: 12)]),
                max_length: 24
              ),
            widths <- list_of(integer(1..9), min_length: 1, max_length: 16),
            max_runs: 250
          ) do
      input = Enum.join(fragments)
      emitted = sanitize_incrementally(input, widths)

      assert Sanitizer.sanitize(emitted) == String.trim(emitted)
    end
  end

  property "removing markup cannot splice visible fragments into control syntax" do
    check all(
            construct <- member_of(@dangerous_constructs),
            split <- integer(1..(byte_size(construct) - 1)),
            seam <- member_of(@removed_seams),
            widths <- list_of(integer(1..7), min_length: 1, max_length: 12),
            max_runs: 200
          ) do
      <<left::binary-size(^split), right::binary>> = construct
      input = left <> seam <> right
      emitted = sanitize_incrementally(input, widths)

      assert Sanitizer.sanitize(emitted) == String.trim(emitted)
    end
  end

  test "prefix tags, Unicode indentation, and stripped joins never leak control content" do
    fully_suppressed = [
      "<thinkX>ragiono</think>",
      "\u00A0INTENT: fai X",
      "IN<reply>TENT: fai X",
      "A<!-- hidden -->L: fai X",
      "IN<think>hidden</think>TENT: fai X"
    ]

    for input <- fully_suppressed do
      for split <- 0..byte_size(input) do
        <<left::binary-size(^split), right::binary>> = input
        emitted = sanitize_chunks(input, [left, right])

        assert emitted == ""
        assert Sanitizer.sanitize(emitted) == String.trim(emitted)
      end
    end

    synthesized_comment = "<!<reply>--hidden-->"

    for split <- 0..byte_size(synthesized_comment) do
      <<left::binary-size(^split), right::binary>> = synthesized_comment
      emitted = sanitize_chunks(synthesized_comment, [left, right])

      assert Sanitizer.sanitize(emitted) == String.trim(emitted)
    end
  end

  defp sanitize_incrementally(input, widths) do
    input
    |> split_chunks(widths)
    |> then(&sanitize_chunks(input, &1))
  end

  defp sanitize_chunks(input, chunks) do
    lookahead = max(16, byte_size(input) + 1)
    state = IncrementalSanitizer.new(max_sanitizer_lookahead_bytes: lookahead)

    {parts, state} =
      Enum.reduce(chunks, {[], state}, fn chunk, {parts, current} ->
        assert {:ok, emitted, next} = IncrementalSanitizer.push(current, chunk)
        {[emitted | parts], next}
      end)

    assert {:ok, trailing, _state} = IncrementalSanitizer.finish(state)
    parts |> Enum.reverse() |> Enum.join() |> Kernel.<>(trailing)
  end

  defp split_chunks("", _widths), do: [""]
  defp split_chunks(input, widths), do: do_split_chunks(input, widths, widths, [])

  defp do_split_chunks("", _remaining, _all, chunks), do: Enum.reverse(chunks)

  defp do_split_chunks(input, [], all, chunks),
    do: do_split_chunks(input, all, all, chunks)

  defp do_split_chunks(input, [width | rest], all, chunks) do
    size = min(width, byte_size(input))
    <<chunk::binary-size(^size), remaining::binary>> = input
    do_split_chunks(remaining, rest, all, [chunk | chunks])
  end
end
