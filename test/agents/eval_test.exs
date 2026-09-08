defmodule Spectre.Agents.EvalTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Spectre.Eval, as: EvalTask
  alias Spectre.Agent.Classification
  alias Spectre.Eval
  alias Spectre.Input.{Pipeline, Plugs.NormalizeText}
  alias Spectre.Router

  defmodule Faq do
    use Spectre.Skill, namespace: "eval", name: "faq"

    flow :questions do
      router(via: [:string_bag])
      route(:hours, match: [string_bag: ["when are you open"]])
    end
  end

  defmodule Support do
    use Spectre.Agent, namespace: "eval", name: "support"
    skill(Faq, as: :faq)

    flow :orders do
      router(via: [:regex, :string_bag])
      route(:lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u])
      route(:help, match: [string_bag: ["help with my order"]])
      route(:first, match: [regex: ~r/^both$/])
      route(:second, match: [regex: ~r/^both$/])
    end

    flow :normalized do
      pipe_through(:normalize)
      router(via: [:regex])
      route(:hello, match: [regex: ~r/^hello$/])
    end

    flow :plain do
    end
  end

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous) end)
    {:ok, flow} = Eval.prepare(Support, "orders")
    %{flow: flow}
  end

  test "regex, phrase matching, ambiguity and no-match use their actual routing semantics", c do
    cases = [
      sample("order 2041", %{"status" => "matched", "rule" => "orders/lookup", "via" => "regex"}),
      sample("help with my order", %{
        "status" => "matched",
        "rule" => "orders/help",
        "via" => "string_bag"
      }),
      sample("both", %{"status" => "ambiguous", "rules" => ["orders/second", "orders/first"]}),
      sample("weather tomorrow", %{"status" => "no_match"})
    ]

    assert {:ok, %{total: 4, passed: 4, failed: 0, failures: []}} = Eval.run(c.flow, cases)
  end

  test "mounts keep qualified rule identities without publishing a Definition" do
    assert {:ok, flow} = Eval.prepare(Support, "faq/questions")

    assert {:ok, %{passed: 1}} =
             Eval.run(flow, [
               sample("when are you open", %{
                 "status" => "matched",
                 "rule" => "faq/questions/hours"
               })
             ])

    assert {:error, :unknown_eval_flow} = Eval.prepare(Support, "missing/questions")
    assert {:error, :unknown_eval_flow} = Eval.prepare(Support, "orders/missing")
    assert {:error, :unknown_eval_flow} = Eval.prepare(Support, "missing")
    assert {:error, :invalid_eval_flow} = Eval.prepare(Support, :orders)
    assert {:error, _} = Eval.prepare(String, "orders")
  end

  test "pipelines remain explicit and unrouted input is not a miss" do
    assert {:error, {:unwired_flow_pipeline, "normalize"}} = Eval.prepare(Support, "normalized")
    {:ok, normalize} = Pipeline.new([{NormalizeText, case: :downcase}])
    {:ok, flow} = Eval.prepare(Support, "normalized", pipelines: %{"normalize" => normalize})

    assert {:ok, %{passed: 1}} =
             Eval.run(flow, [
               sample(" HELLO ", %{"status" => "matched", "rule" => "normalized/hello"})
             ])

    {:ok, plain} = Eval.prepare(Support, "plain")
    assert {:ok, %{passed: 1}} = Eval.run(plain, [sample("anything", %{"status" => "unrouted"})])
  end

  test "retained failures show behavioral differences but never private input or captures", c do
    cases =
      Stream.repeatedly(fn ->
        sample("order 987654321", %{"status" => "matched", "rule" => "orders/help"})
      end)
      |> Stream.take(30)

    assert {:ok, report} = Eval.run(c.flow, cases, max_failures: 2)
    assert %{total: 30, failed: 30, passed: 0} = report
    assert Enum.map(report.failures, & &1.case) == [1, 2]
    assert hd(report.failures).actual["rule"] == "orders/lookup"
    refute inspect(report) =~ "987654321"
  end

  test "case limits reject truncation and empty evaluation cannot claim success", c do
    input = sample("none", %{"status" => "no_match"})

    assert {:error, :eval_case_limit_exceeded} =
             Eval.run(c.flow, Stream.repeatedly(fn -> input end), max_cases: 2)

    assert {:ok, %{total: 2}} = Eval.run(c.flow, [input, input], max_cases: 2)
    assert {:error, :empty_eval_dataset} = Eval.run(c.flow, [])

    for opts <- [[max_cases: 0], [max_failures: -1], [max_cases: 2.0], [max_case: 1]] do
      assert {:error, _} = Eval.run(c.flow, [input], opts)
    end

    assert {:error, :invalid_eval_target} = Eval.run(:invented, [input])
  end

  test "malformed expectations fail before invoking application callbacks" do
    for value <- [
          nil,
          %{},
          %{"input" => "x"},
          sample("x", %{"status" => "matched"}),
          sample("x", %{"status" => "matched", "rule" => "r", "via" => nil}),
          sample("x", %{"status" => "no_match", "extra" => true}),
          sample("x", %{"status" => "ambiguous", "rules" => ["r", "r"]}),
          sample("x", %{"status" => "ambiguous", "rules" => ["r"]})
        ] do
      assert {:error, {:eval_case, 1, _}} =
               Eval.run(fn _ -> flunk("invalid case was routed") end, [value])
    end
  end

  test "application routing errors and halts stay distinct; programmer exceptions are not hidden" do
    route = fn
      "stop" -> {:halt, "PRIVATE_HALTED_INPUT"}
      "broken" -> {:error, "PRIVATE_ADAPTER_ERROR"}
    end

    assert {:ok, %{passed: 2}} =
             Eval.run(route, [
               sample("stop", %{"status" => "halted"}),
               sample("broken", %{"status" => "error"})
             ])

    assert {:ok, report} = Eval.run(route, [sample("broken", %{"status" => "no_match"})])
    refute inspect(report) =~ "PRIVATE"

    for result <- [:invalid, {:ambiguous, nil}, {:ambiguous, ["only-one"]}] do
      assert {:error, {:eval_case, 1, :invalid_eval_result}} =
               Eval.run(fn _ -> result end, [sample("x", %{"status" => "no_match"})])
    end

    assert_raise ArgumentError, "broken fixture", fn ->
      Eval.run(fn _ -> raise ArgumentError, "broken fixture" end, [
        sample("x", %{"status" => "no_match"})
      ])
    end
  end

  test "recorded classifier labels reuse the real classifier bridge, with no provider call" do
    rules = %{"support/refund" => %{to: "refund", match: %{llm_classifier: true}}}

    route = fn labels ->
      {:ok, router} =
        Router.new(rules,
          via: [:llm_classifier],
          adapters: [llm_classifier: {Classification, observed: labels}]
        )

      Router.route(router, nil)
    end

    cases = [
      sample([%{"label" => "support/refund", "score" => 0.98}], %{
        "status" => "matched",
        "rule" => "support/refund"
      }),
      sample([%{"label" => "support/refund", "score" => 0.2}], %{"status" => "no_match"}),
      sample([%{"label" => "undeclared", "score" => 1.0}], %{"status" => "error"})
    ]

    assert {:ok, %{passed: 3}} = Eval.run(route, cases)

    {:ok, router} =
      Router.new(rules, via: [:llm_classifier], adapters: [llm_classifier: Classification])

    assert {:ok, %{passed: 1}} =
             Eval.run(router, [sample("no observation", %{"status" => "no_match"})])
  end

  @tag :tmp_dir
  test "JSONL is line-addressable, strict, streamed and closes files on callback failures", c do
    path = Path.join(c.tmp_dir, "cases.jsonl")

    File.write!(
      path,
      "\n" <>
        JSON.encode!(sample("private", %{"status" => "matched", "rule" => "orders/lookup"})) <>
        "\n"
    )

    assert {:ok, %{failures: [%{case: 2}]}} = Eval.run_file(c.flow, path)
    File.write!(path, "\nnot JSON PRIVATE\n")
    assert {:error, {:eval_case, 2, :invalid_json}} = Eval.run_file(c.flow, path)
    File.write!(path, String.duplicate("x", 1_048_577))
    assert {:error, {:eval_case, 1, :eval_line_too_large}} = Eval.run_file(c.flow, path)
    File.write!(path, "  \n")
    assert {:error, :empty_eval_dataset} = Eval.run_file(c.flow, path)
    assert {:error, {:eval_file, :enoent}} = Eval.run_file(c.flow, path <> ".missing")
    File.write!(path, JSON.encode!(sample("x", %{"status" => "no_match"})))

    assert_raise File.Error, fn ->
      Eval.run_file(fn _ -> File.read!(path <> ".callback_failure") end, path)
    end

    assert {:ok, %{passed: 1}} = Eval.run_file(c.flow, path)
  end

  @tag :tmp_dir
  test "CLI succeeds on exact expectations and fails CI on a behavioral regression", c do
    path = Path.join(c.tmp_dir, "cases.jsonl")

    File.write!(
      path,
      JSON.encode!(sample("order 42", %{"status" => "matched", "rule" => "orders/lookup"}))
    )

    args = [inspect(Support), path, "--flow", "orders"]
    assert capture_io(fn -> EvalTask.run(args) end) =~ "Routing: 1/1 passed; 0 failed"

    File.write!(
      path,
      JSON.encode!(sample("PRIVATE", %{"status" => "matched", "rule" => "orders/lookup"}))
    )

    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert_raise Mix.Error, ~r/routing regression/, fn -> EvalTask.run(args) end
        end)
      end)

    assert output =~ "line 1"
    refute output =~ "PRIVATE"
    assert_raise Mix.Error, ~r/usage/, fn -> EvalTask.run([inspect(Support), path]) end

    assert_raise Mix.Error, ~r/unknown compiled/, fn ->
      EvalTask.run(["Uncompiled.EvalExample", path, "--flow", "orders"])
    end
  end

  defp sample(input, expected), do: %{"input" => input, "expected" => expected}
end
