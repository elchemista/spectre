defmodule SpectreInferenceInstanceLifecycleContractTest.SuccessModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:cognitive_model, :completed, self()})
    end

    {:ok,
     %Spectre.Inference.Response{
       text: "cognitive response",
       usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
       metadata: %{provider: :fixture}
     }}
  end
end

defmodule SpectreInferenceInstanceLifecycleContractTest.FailingModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:error, {:provider_failure, "private detail"}}
end

defmodule SpectreInferenceInstanceLifecycleContractTest.BlockingModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:cognitive_model, :blocked, self()})

    receive do
      :complete_cognitive_inference -> {:ok, "released response"}
      :fail_cognitive_inference -> {:error, :released_failure}
    end
  end
end

defmodule SpectreInferenceInstanceLifecycleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreInferenceInstanceLifecycleContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Instance
  alias Spectre.Prompt.Plan
  alias Spectre.Subject

  @agent SpectreInferenceInstanceLifecycleContractTest.Agent
  @success_model SpectreInferenceInstanceLifecycleContractTest.SuccessModel
  @failing_model SpectreInferenceInstanceLifecycleContractTest.FailingModel
  @blocking_model SpectreInferenceInstanceLifecycleContractTest.BlockingModel

  test "cognitive inference is a state-neutral Run and terminal results are idempotently attachable" do
    instance = start_instance()
    request = request("cognitive-success", @success_model)
    state_revision = :sys.get_state(instance).state.revision

    assert {:ok, %Response{text: "cognitive response"} = response} =
             Instance.infer(instance, request,
               run_id: "cognitive-run",
               test_pid: self(),
               operation_attempt_id: "attempt-one",
               operation_loop_id: "loop-one"
             )

    assert response.usage.input_tokens >= 2
    assert response.usage.output_tokens >= 3
    assert response.usage.total_tokens >= 5

    assert_receive {:cognitive_model, :completed, _worker}

    # Re-attaching to the deterministic Run returns the canonical response and
    # must not execute the nondeterministic provider boundary a second time.
    assert {:ok, ^response} =
             Instance.infer(instance, request,
               run_id: "cognitive-run",
               test_pid: self()
             )

    refute_receive {:cognitive_model, :completed, _worker}
    assert {:ok, %{status: :complete}} = Instance.run(instance, "cognitive-run")
    assert :sys.get_state(instance).state.revision == state_revision
  end

  test "failed cognitive Runs are retained and a conflicting request cannot claim their identity" do
    instance = start_instance()
    request = request("cognitive-failure", @failing_model, strict: true)

    assert {:error, reason} =
             Instance.infer(instance, request, run_id: "failed-cognitive-run")

    assert inspect(reason) =~ "provider_failure"
    refute inspect(reason) =~ "private detail"

    assert {:error, ^reason} =
             Instance.infer(instance, request, run_id: "failed-cognitive-run")

    conflicting = %{request | purpose: :different_cognitive_purpose}

    assert {:error, :cognitive_inference_run_conflict} =
             Instance.infer(instance, conflicting, run_id: "failed-cognitive-run")

    assert {:ok, %{status: :failed}} = Instance.run(instance, "failed-cognitive-run")
  end

  test "only one live caller owns an active cognitive Run and Run capacity remains bounded" do
    instance = start_instance(max_runs: 1)
    request = request("cognitive-blocked", @blocking_model, strict: true)
    parent = self()

    owner =
      Task.async(fn ->
        Instance.infer(instance, request,
          run_id: "blocked-cognitive-run",
          test_pid: parent
        )
      end)

    assert_receive {:cognitive_model, :blocked, worker}

    assert {:error, :cognitive_inference_already_attached} =
             Instance.infer(instance, request,
               run_id: "blocked-cognitive-run",
               test_pid: self()
             )

    second = request("second-cognitive", @success_model)

    assert {:error, :instance_run_capacity_reached} =
             Instance.infer(instance, second,
               run_id: "second-cognitive-run",
               test_pid: self()
             )

    send(worker, :complete_cognitive_inference)
    assert {:ok, %Response{text: "released response"}} = Task.await(owner, 1_000)
  end

  test "a replacement caller may attach after the original caller dies" do
    instance = start_instance()
    request = request("cognitive-dead-caller", @blocking_model, strict: true)
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        send(parent, :cognitive_caller_started)

        Instance.infer(instance, request,
          run_id: "dead-caller-run",
          test_pid: parent
        )
      end)

    assert_receive :cognitive_caller_started
    assert_receive {:cognitive_model, :blocked, worker}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}

    replacement =
      Task.async(fn ->
        Instance.infer(instance, request,
          run_id: "dead-caller-run",
          test_pid: parent
        )
      end)

    assert_eventually(fn -> task_waiting?(replacement.pid) end)
    send(worker, :complete_cognitive_inference)

    assert {:ok, %Response{text: "released response"}} = Task.await(replacement, 1_000)
  end

  test "the internal admission boundary rejects malformed requests and Run ids" do
    instance = start_instance()
    request = request("invalid-run-id", @success_model)

    assert {:error, :invalid_cognitive_inference_run_id} =
             Instance.infer(instance, request, run_id: "")

    assert {:error, {:invalid_cognitive_request, :atom}} =
             GenServer.call(instance, {:cognitive_inference, :invalid, []})
  end

  test "one-shot receipts enforce hard usage and explicitly configured cost accounting" do
    instance = start_instance()

    overrun =
      request("one-shot-overrun", @success_model, maximum_output_tokens: 2)

    assert {:error, overrun_reason} =
             Instance.infer(instance, overrun,
               run_id: "one-shot-overrun",
               inference_budget: [output_tokens: 2]
             )

    assert inspect(overrun_reason) =~ "inference_budget_exceeded"
    assert inspect(overrun_reason) =~ "output_tokens"

    priced = request("one-shot-priced", @success_model)

    assert {:ok, %Response{text: "cognitive response"}} =
             Instance.infer(instance, priced,
               run_id: "one-shot-priced",
               inference_budget: [cost: 1.0],
               inference_pricing_ref: "pricing:test:v1",
               inference_cost_usage?: true
             )
  end

  defp request(id, model, constraint_opts \\ []) do
    Request.new(
      id: id,
      purpose: :cognitive_operation,
      plan: %Plan{rendered: "perform a cognitive operation"},
      constraints: Constraints.new(constraint_opts),
      metadata: %{
        model: model,
        llm_opts: [model: model, test_pid: self()],
        explicit_model_override?: true
      }
    )
  end

  defp start_instance(extra \\ []) do
    opts =
      [
        agent: @agent,
        subject:
          Subject.new("cognitive-instance-#{System.unique_integer([:positive, :monotonic])}"),
        idle: false
      ]
      |> Keyword.merge(extra)

    start_supervised!({Instance, opts})
  end

  defp task_waiting?(pid) do
    case Process.info(pid, :status) do
      {:status, status} when status in [:waiting, :suspended] -> true
      _other -> false
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
