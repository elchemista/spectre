defmodule Spectre.Core.InputPipelineTest do
  use ExUnit.Case, async: true

  alias Spectre.Canonical.Value
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText

  defmodule Probe do
    @behaviour Spectre.Input.Plug

    @impl true
    def init(opts) do
      send(opts[:observer], {:initialized, opts[:name]})
      Keyword.get(opts, :init_result, {:ok, opts})
    end

    @impl true
    def call(input, opts) do
      send(opts[:observer], {:called, opts[:name], input, self()})

      case Keyword.get(opts, :mode, :echo) do
        :echo -> {:cont, input}
        :append -> {:cont, input <> opts[:suffix]}
        :return -> opts[:result]
        :raise -> raise "private payload and exception details"
        :throw -> throw({:private_payload, input})
        :exit -> exit({:private_payload, input})
      end
    end
  end

  defmodule Envelope do
    @behaviour Spectre.Input.Plug
    @impl true
    def call(%{"transcript" => text}, _opts), do: {:cont, text}
    def call(_input, _opts), do: {:error, :missing_transcript}
  end

  test "initialization happens once and stages observe the previous stage's output" do
    assert {:ok, pipeline} =
             Pipeline.new([
               probe("first", mode: :append, suffix: "a"),
               probe("second", mode: :append, suffix: "b")
             ])

    assert_receive {:initialized, "first"}
    assert_receive {:initialized, "second"}
    caller = self()

    for original <- ["one-", "two-"] do
      assert {:ok, result} = Pipeline.run(pipeline, original)
      assert result == original <> "ab"
      assert_receive {:called, "first", ^original, ^caller}
      second_input = original <> "a"
      assert_receive {:called, "second", ^second_input, ^caller}
    end

    refute_receive {:initialized, _}
  end

  test "an adapter without init can unpack application-defined media data" do
    assert {:ok, pipeline} = Pipeline.new([Envelope, {NormalizeText, case: :downcase}])

    assert {:ok, "hello"} =
             Pipeline.run(pipeline, %{"transcript" => "  HELLO  ", "media_ref" => "audio:123"})
  end

  test "empty pipelines preserve exact values including distinct numeric representations" do
    assert {:ok, pipeline} = Pipeline.new([])

    for input <- [nil, "", <<0, 255, 17>>, %{"amount" => 1.0}, [1, 1.0], {:event, "x"}] do
      assert {:ok, result} = Pipeline.run(pipeline, input)
      assert result === input
    end
  end

  test "halt is explicit and does not invoke later stages" do
    assert {:ok, pipeline} =
             Pipeline.new([
               probe("stop", mode: :return, result: {:halt, "review-required"}),
               probe("unreachable")
             ])

    assert {:halt, "review-required"} = Pipeline.run(pipeline, "original")
    assert_receive {:called, "stop", "original", _}
    refute_receive {:called, "unreachable", _, _}
  end

  test "a plug rejection neither retries nor runs later stages" do
    assert {:ok, pipeline} =
             Pipeline.new([
               probe("reject", mode: :return, result: {:error, :invalid_envelope}),
               probe("unreachable")
             ])

    assert {:error, {:input_plug_failed, Probe, :invalid_envelope}} =
             Pipeline.run(pipeline, "original")

    assert_receive {:called, "reject", _, _}
    refute_receive {:called, _, _, _}
  end

  test "callback exceptions are compact and never leak exception payloads" do
    assert {:ok, pipeline} = Pipeline.new([probe("failure", mode: :raise)])

    assert {:error,
            {:input_plug_failed, Probe, {:adapter_callback_exception, Probe, :call, RuntimeError}}} =
             Pipeline.run(pipeline, "secret")

    assert_receive {:called, "failure", _, _}
    refute_receive {:called, _, _, _}
  end

  test "throws and exits stop normalization without killing the caller" do
    for kind <- [:throw, :exit] do
      assert {:ok, pipeline} = Pipeline.new([probe("failure", mode: kind)])

      assert {:error,
              {:input_plug_failed, Probe, {:adapter_callback_failure, Probe, :call, ^kind}}} =
               Pipeline.run(pipeline, "secret")
    end
  end

  test "an untagged reply or authority-shaped result cannot be interpreted as normalization" do
    for reply <- [:ok, {:ok, "text"}, {:admitted, %{}}, %{grant: "claim"}] do
      assert {:ok, pipeline} = Pipeline.new([probe("invalid", mode: :return, result: reply)])

      assert {:error, {:input_plug_failed, Probe, :invalid_input_plug_result}} =
               Pipeline.run(pipeline, "text")
    end
  end

  test "capabilities and improper input are rejected before any callback runs" do
    assert {:ok, pipeline} = Pipeline.new([probe("never")])

    for input <- [self(), make_ref(), fn -> :ok end, [1 | :invalid], %{scope: %URI{}}] do
      assert {:error, _reason} = Pipeline.run(pipeline, input)
    end

    refute_receive {:called, _, _, _}
  end

  test "nonportable intermediate values cannot reach the next plug, even via halt" do
    for status <- [:cont, :halt] do
      assert {:ok, pipeline} =
               Pipeline.new([
                 probe("invalid", mode: :return, result: {status, self()}),
                 probe("unreachable")
               ])

      assert {:error, {:input_plug_failed, Probe, _reason}} = Pipeline.run(pipeline, "text")
      refute_receive {:called, "unreachable", _, _}
    end
  end

  test "encoded-byte limits are exact and reject oversized input before callbacks" do
    size = byte_size(Value.encode!("text"))
    assert {:ok, exact} = Pipeline.new([probe("exact")], max_bytes: size)
    assert {:ok, "text"} = Pipeline.run(exact, "text")
    assert_receive {:called, "exact", "text", _}
    assert {:ok, smaller} = Pipeline.new([probe("smaller")], max_bytes: size - 1)

    assert {:error, {:canonical_value_too_large, ^size, limit}} = Pipeline.run(smaller, "text")
    assert limit == size - 1
    refute_receive {:called, "smaller", _, _}
  end

  test "an expanding callback cannot hand an oversized value to downstream stages" do
    assert {:ok, pipeline} =
             Pipeline.new(
               [
                 probe("expand", mode: :return, result: {:cont, String.duplicate("x", 1024)}),
                 probe("unreachable")
               ],
               max_bytes: 64
             )

    assert {:error, {:input_plug_failed, Probe, {:canonical_value_too_large, _, 64}}} =
             Pipeline.run(pipeline, "small")

    refute_receive {:called, "unreachable", _, _}
  end

  test "depth and collection limits remain active independently of the byte budget" do
    assert {:ok, pipeline} =
             Pipeline.new([probe("bounded")], max_depth: 2, max_collection_size: 3)

    assert {:ok, [[1]]} = Pipeline.run(pipeline, [[1]])
    assert_receive {:called, "bounded", [[1]], _}
    assert {:error, _} = Pipeline.run(pipeline, [[[1]]])
    assert {:error, _} = Pipeline.run(pipeline, [1, 2, 3, 4])
    refute_receive {:called, _, _, _}
  end

  test "pipeline declarations reject malformed options and cannot enable runtime structs" do
    for opts <- [
          [max_bytes: 1.0],
          [max_depth: -1],
          [max_collection_size: -1],
          [allowed_structs: [URI]],
          [max_bytes: 64, max_bytes: 128],
          [max_bytes: 64] ++ [:not_a_keyword]
        ] do
      assert {:error, _} = Pipeline.new([probe("never")], opts)
    end

    refute_receive {:initialized, _}
  end

  test "invalid, oversized and improper plug lists cannot start callbacks" do
    for specs <- [:invalid, [Envelope | :invalid], List.duplicate(probe("never"), 65)] do
      assert {:error, :invalid_input_plugs} = Pipeline.new(specs)
    end

    assert {:error, :invalid_input_plug_options} = Pipeline.new([{Probe, [:invalid]}])
    assert {:error, _} = Pipeline.new([Spectre.Input.Nonexistent])
    assert {:error, _} = Pipeline.new([String])
    refute_receive {:initialized, _}
  end

  test "initialization failures remain errors, not prepared state" do
    assert {:error, :unsupported_version} =
             Pipeline.new([probe("bad", init_result: {:error, :unsupported_version})])

    assert {:error, :invalid_input_plug_init_result} =
             Pipeline.new([probe("bad", init_result: %{secret: "not-a-result"})])
  end

  test "text normalization composes Unicode, case and whitespace in documented order" do
    assert {:ok, pipeline} = Pipeline.new([{NormalizeText, case: :downcase}])
    assert {:ok, "café déjà vu"} = Pipeline.run(pipeline, "  CAFE\u0301\tDÉJÀ\nVU  ")
    assert {:ok, pipeline} = Pipeline.new([{NormalizeText, unicode: :nfkc, case: :upcase}])
    assert {:ok, "REFUND 42"} = Pipeline.run(pipeline, "Ｒｅｆｕｎｄ　４２")
  end

  test "disabled normalizations preserve exact whitespace, casing and combining marks" do
    assert {:ok, pipeline} =
             Pipeline.new([
               {NormalizeText, unicode: false, trim: false, collapse_whitespace: false}
             ])

    original = "  CAFE\u0301\n\t"
    assert {:ok, ^original} = Pipeline.run(pipeline, original)
  end

  test "text normalization rejects non-UTF8 or non-text instead of guessing a media format" do
    assert {:ok, pipeline} = Pipeline.new([NormalizeText])

    for input <- [<<255, 192, 128>>, %{"audio_ref" => "blob:one"}, nil, ["text"]] do
      assert {:error, {:input_plug_failed, NormalizeText, :invalid_input_text}} =
               Pipeline.run(pipeline, input)
    end
  end

  test "invalid normalization policy fails at preparation rather than changing semantics silently" do
    for opts <- [
          [trim: :yes],
          [case: :fold],
          [unicode: nil],
          [collapse_whitespace: 1],
          [typo: true]
        ] do
      assert {:error, _} = Pipeline.new([{NormalizeText, opts}])
    end
  end

  defp probe(name, opts \\ []),
    do: {Probe, Keyword.merge([observer: self(), name: name], opts)}
end
