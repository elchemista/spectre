defmodule SpectreEvalTest.LocalClassifier do
  @moduledoc false

  def classify(text, opts) do
    notify(opts, {:eval_local_called, text})

    case text do
      "local request" ->
        {:ok,
         %{
           label: :LOCAL,
           accepted?: true,
           confidence: 0.99,
           margin: 0.4,
           strategy: :local_classifier
         }}

      _text ->
        {:error, :no_local_match}
    end
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, message)
    :ok
  end
end

defmodule SpectreEvalTest.ClassifierLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:eval_llm_called, prompt})

    if String.contains?(prompt, "needs llm") do
      {:ok, "LLM_ROUTE"}
    else
      {:ok, "LOCAL"}
    end
  end
end

defmodule SpectreEvalTest.InputPlug do
  @moduledoc false
  @behaviour Spectre.Input.Plug

  @impl Spectre.Input.Plug
  def init(opts), do: opts

  @impl Spectre.Input.Plug
  def call(input, _context, _opts) do
    normalized = input.text |> String.trim() |> String.downcase()
    {:cont, %{input | text: normalized}}
  end
end

defmodule SpectreEvalTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(_record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, :eval_journal_written)
    :ok
  end
end

defmodule SpectreEvalTest.SemanticStore do
  @moduledoc false
  @behaviour Spectre.Router.SemanticCache

  @impl Spectre.Router.SemanticCache
  def lookup(_text, _opts), do: {:error, :miss}

  @impl Spectre.Router.SemanticCache
  def put(_text, _result, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, :eval_semantic_written)
    :ok
  end
end

defmodule SpectreEvalTest.Agent do
  @moduledoc false

  use Spectre.Agent

  classifier(SpectreEvalTest.ClassifierLLM, local: SpectreEvalTest.LocalClassifier)
  input_pipeline([{SpectreEvalTest.InputPlug, []}])
  router(via: [:regex, :classifier, :llm_classifier], semantic_cache?: false)

  interrupt :HELP, regex: ~r/^help$/ do
    run(:must_not_execute)
  end

  flow :evaluation do
    on :LOCAL, via: [:classifier, :llm_classifier] do
      run(:must_not_execute)
    end

    on :LLM_ROUTE, via: [:llm_classifier], learn: true do
      run(:must_not_execute)
    end
  end

  def must_not_execute(_input, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, :eval_handler_executed)
    {:ok, :unexpected}
  end
end

defmodule SpectreEvalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Spectre.Eval
  alias Spectre.Eval.Case
  alias Spectre.Eval.Report
  alias Spectre.Eval.Result
  alias Spectre.Router
  alias Spectre.Router.Receipt

  @fixture "test/fixtures/routing_eval.jsonl"

  test "router evaluation returns a privacy-safe receipt without executing the handler" do
    secret_input = "  HELP  "

    assert {:ok, receipt} =
             Router.evaluate(SpectreEvalTest.Agent, secret_input,
               test_pid: self(),
               journal: {SpectreEvalTest.JournalStore, pid: self()}
             )

    assert receipt.outcome == :route
    assert receipt.label == :HELP
    assert receipt.strategy == :regex
    refute receipt.llm_called?
    assert %{provider: :regex, result: :accepted} = List.first(receipt.attempts)

    serialized = inspect(receipt)
    refute serialized =~ secret_input
    refute serialized =~ "must_not_execute"
    refute_received :eval_handler_executed
    refute_received :eval_journal_written
  end

  test "receipt sanitizes arbitrary custom trace values" do
    context = %Spectre.Router.Context{
      route: Spectre.Route.new(%{strategy: :unknown, accepted?: false}),
      traces: [{"private trace value", %{prompt: "private prompt value"}}]
    }

    receipt = Receipt.from_context(context, 1)

    assert receipt.trace_codes == [:unknown_trace]
    refute inspect(receipt) =~ "private trace value"
    refute inspect(receipt) =~ "private prompt value"

    assert Receipt.from_context(%Spectre.Router.Context{traces: [{}]}, 1).trace_codes == [
             :unknown_trace
           ]
  end

  test "receipt sanitizes malformed route, candidate, and provider-call fields" do
    private = "private model output"
    private_atom = :"private model output"

    context = %Spectre.Router.Context{
      labels: [:SAFE],
      route:
        Spectre.Route.new(%{
          label: private_atom,
          strategy: private,
          accepted?: true,
          handler: {:run, :safe_handler}
        }),
      candidates: [
        %Spectre.Router.Candidate{
          provider: private,
          label: private_atom,
          score: private,
          margin: private,
          strength: private,
          accepted?: true
        }
      ]
    }

    receipt =
      Receipt.from_context(context, 1, [
        %{
          provider: private,
          outcome: private,
          duration_us: private,
          invoked?: private,
          purpose: private
        }
      ])

    assert receipt.label == nil
    assert receipt.strategy == nil

    assert receipt.candidates == [
             %{
               provider: :unknown,
               label: nil,
               accepted?: true,
               score: nil,
               margin: nil,
               strength: :unknown
             }
           ]

    refute inspect(receipt) =~ private

    malformed_context = %{
      context
      | route: %{label: private},
        candidates: [private],
        traces: private,
        errors: private
    }

    malformed_receipt = Receipt.from_context(malformed_context, private)
    assert malformed_receipt.outcome == :unknown
    assert malformed_receipt.duration_us == 0
    refute inspect(malformed_receipt) =~ private
  end

  test "receipt distinguishes local success from actual LLM fallback" do
    assert {:ok, local} =
             Router.evaluate(SpectreEvalTest.Agent, "local request", test_pid: self())

    assert local.label == :LOCAL
    assert local.strategy == :local_classifier
    refute local.llm_called?
    assert [local_call] = local.provider_calls
    assert local_call.provider == :local_classifier
    assert local_call.outcome == :ok
    assert local_call.invoked?
    assert is_integer(local_call.duration_us) and local_call.duration_us >= 0
    assert_receive {:eval_local_called, "local request"}
    refute_received {:eval_llm_called, _prompt}

    assert {:ok, llm} = Router.evaluate(SpectreEvalTest.Agent, "needs llm", test_pid: self())
    assert llm.label == :LLM_ROUTE
    assert llm.strategy == :llm_classifier
    assert llm.llm_called?

    assert Enum.any?(llm.provider_calls, fn call ->
             call.provider == :llm and call.purpose == :classifier and call.outcome == :ok and
               call.invoked?
           end)

    assert_receive {:eval_local_called, "needs llm"}
    assert_receive {:eval_llm_called, prompt}

    assert prompt =~
             "Latest message:\n<spectre-data trust=\"data\">needs llm</spectre-data>"
  end

  test "LLM policy records a call only after prompt construction succeeds" do
    invalid_prompt = fn _assigns -> {:ok, %{private: "prompt was not renderable"}} end

    assert {:ok, receipt} =
             Router.evaluate(SpectreEvalTest.Agent, "needs llm",
               classifier: [
                 adapter: SpectreEvalTest.ClassifierLLM,
                 local: SpectreEvalTest.LocalClassifier,
                 prompt: invalid_prompt
               ]
             )

    assert :llm_arbitration_started in receipt.trace_codes
    refute receipt.llm_called?
    refute Enum.any?(receipt.provider_calls, &(&1.provider == :llm))
    refute_received {:eval_llm_called, _prompt}
  end

  test "evaluation disables semantic learning even for learnable LLM routes" do
    assert {:ok, receipt} =
             Router.evaluate(SpectreEvalTest.Agent, "needs llm",
               test_pid: self(),
               semantic_cache: SpectreEvalTest.SemanticStore
             )

    assert receipt.label == :LLM_ROUTE
    assert :semantic_learn_skipped in receipt.trace_codes
    refute_received :eval_semantic_written
  end

  test "JSON state uses existing flow atoms and recent chat without creating corpus atoms" do
    state = %{
      "current_flow" => "evaluation",
      "data" => %{
        "chat_history" => [
          %{"user" => "earlier", "assistant" => "answer"}
        ]
      }
    }

    assert {:ok, receipt} =
             Router.evaluate(SpectreEvalTest.Agent, "needs llm",
               state: state,
               test_pid: self()
             )

    assert receipt.outcome == :route
    assert_receive {:eval_llm_called, prompt}
    assert prompt =~ "User: earlier"
    assert prompt =~ "Assistant: answer"
  end

  test "corpus runner reports route accuracy and LLM policy compliance" do
    assert {:ok, report} =
             Eval.run(SpectreEvalTest.Agent, @fixture, router_opts: [test_pid: self()])

    assert report.total == 3
    assert report.passed == 3
    assert report.failed == 0
    assert report.route_accuracy == 1.0
    assert report.llm_calls == 1
    assert report.unnecessary_llm_calls == 0
    assert report.missing_required_llm_calls == 0
    assert report.strategies == %{llm_classifier: 1, local_classifier: 1, regex: 1}
    assert report.tags["english"] == %{total: 3, passed: 3}
    assert Report.acceptable?(report)
  end

  test "a correct route still fails when the LLM call was forbidden" do
    cases = [
      %{
        id: "correct-but-expensive",
        input: "needs llm",
        expected_route: "LLM_ROUTE",
        llm: :forbidden
      }
    ]

    assert {:ok, report} = Eval.run(SpectreEvalTest.Agent, cases)
    assert report.correct_routes == 1
    assert report.route_accuracy == 1.0
    assert report.failed == 1
    assert report.unnecessary_llm_calls == 1
    refute Report.acceptable?(report)
  end

  test "case comparison catches missing LLM calls and duration regressions" do
    assert {:ok, evaluation_case} =
             Case.new(%{
               id: "slow-local",
               input: "local request",
               expected_route: "LOCAL",
               llm: "required",
               max_duration_us: 10
             })

    receipt = %Receipt{
      outcome: :route,
      label: :LOCAL,
      strategy: :local_classifier,
      accepted?: true,
      llm_called?: false,
      duration_us: 11
    }

    result = Result.new(evaluation_case, receipt)
    refute result.passed?

    assert Enum.map(result.violations, & &1.type) == [
             :missing_required_llm_call,
             :duration_exceeded
           ]
  end

  test "loader reports the exact invalid JSONL line" do
    path = Path.join(System.tmp_dir!(), "spectre-invalid-eval-#{System.unique_integer()}.jsonl")
    File.write!(path, "\n{\"id\":\"valid\",\"input\":\"help\"}\nnot-json\n")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_eval_case, 3, %Jason.DecodeError{}}} = Eval.load(path)
  end

  test "mix task writes a JSON artifact and enforces thresholds" do
    path = Path.join(System.tmp_dir!(), "spectre-eval-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)

    output =
      capture_io(fn ->
        assert :ok =
                 Mix.Tasks.Spectre.Eval.run([
                   "SpectreEvalTest.Agent",
                   @fixture,
                   "--json",
                   path
                 ])
      end)

    assert output =~ "Cases:                    3"
    assert output =~ "Unnecessary LLM calls:    0"
    assert {:ok, artifact} = path |> File.read!() |> Jason.decode()
    assert artifact["total"] == 3
    assert length(artifact["results"]) == 3
    assert is_list(get_in(artifact, ["results", Access.at(0), "actual", "provider_calls"]))
  end

  test "mix task exits unsuccessfully when a regression threshold fails" do
    assert_raise Mix.Error, ~r/did not meet its regression thresholds/, fn ->
      capture_io(fn ->
        Mix.Tasks.Spectre.Eval.run([
          "SpectreEvalTest.Agent",
          @fixture,
          "--min-pass-rate",
          "1.1"
        ])
      end)
    end
  end
end
