defmodule SpectreRuntimeInferenceEdgeContractTest.Model do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:ok, "runtime inference"}
end

defmodule SpectreRuntimeInferenceEdgeContractTest.StreamAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts), do: MapSet.new([:stream, :pull_transport])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, _opts), do: {:error, :not_opened_by_runtime_test}

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(state), do: {:ok, state}

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(_state, _reason), do: :ok
end

defmodule SpectreRuntimeInferenceEdgeContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :runtime_edges do
    on :PING, regex: ~r/^ping$/ do
      run(:pong)
    end

    on :ASK, regex: ~r/^ask$/ do
      ask(:base)
    end
  end

  def pong(_input, _context), do: "pong"
end

defmodule SpectreRuntimeInferenceEdgeContractTest.DefinitionBoundary do
  @moduledoc false

  def __spectre_definition__ do
    case Process.get({__MODULE__, :failure}) do
      :raise -> raise "definition lookup failed"
      :throw -> throw(:definition_lookup_failed)
      nil -> SpectreRuntimeInferenceEdgeContractTest.Agent.__spectre_definition__()
    end
  end
end

defmodule SpectreRuntimeInferenceEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request
  alias Spectre.Input
  alias Spectre.Invocation
  alias Spectre.Prompt.Plan
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Runtime
  alias Spectre.State

  @agent SpectreRuntimeInferenceEdgeContractTest.Agent
  @definition_boundary SpectreRuntimeInferenceEdgeContractTest.DefinitionBoundary
  @model SpectreRuntimeInferenceEdgeContractTest.Model
  @stream_adapter SpectreRuntimeInferenceEdgeContractTest.StreamAdapter

  test "admission converts raised and thrown definition boundaries into stable failures" do
    request = request("admission")

    Enum.each([:raise, :throw], fn failure ->
      Process.put({@definition_boundary, :failure}, failure)

      assert {:error, admission_reason} =
               Runtime.admit(@definition_boundary, "logical", %State{})

      assert {:error, inference_reason} =
               Runtime.admit_inference(
                 @definition_boundary,
                 request,
                 "logical",
                 %State{}
               )

      # Definition.fetch/1 itself contains callback throws and presents the
      # Runtime with the same stable invalid-definition exception class.
      assert_failure_suffix(admission_reason, :run_admission_failed, ArgumentError)

      assert_failure_suffix(
        inference_reason,
        :inference_run_admission_failed,
        ArgumentError
      )
    end)

    Process.delete({@definition_boundary, :failure})
  end

  test "prepare, advance, and resume contain definition callback failures" do
    request = request("prepare")
    {:ok, inference_run} = Runtime.admit_inference(@agent, request, "logical", %State{})
    {:continue, conversational_run} = Runtime.start(@agent, "ping")
    stream_opts = stream_opts()
    {:continue, inference_started} = Runtime.start(@agent, "ask", stream_opts)

    {:dispatch, %Invocation{} = invocation, inference_awaiting, _prepared} =
      Runtime.advance(inference_started, stream_opts)

    Enum.each([:raise, :throw], fn failure ->
      Process.put({@definition_boundary, :failure}, failure)

      prepare_failure =
        Runtime.prepare_inference(%{inference_run | agent: @definition_boundary}, request, [])

      advance_failure = Runtime.advance(%{conversational_run | agent: @definition_boundary})

      resume_failure =
        Runtime.resume(
          %{inference_awaiting | agent: @definition_boundary},
          {:inference, invocation, Spectre.Inference.Response.new("ignored")}
        )

      assert {:error, prepare_reason, %Run{status: :failed}} = prepare_failure
      assert {:error, advance_reason, %Run{status: :failed}} = advance_failure
      assert {:error, resume_reason, %Run{status: :failed}} = resume_failure

      expected_suffix = ArgumentError

      assert_failure_suffix(prepare_reason, :inference_run_prepare_failed, expected_suffix)
      assert_failure_suffix(advance_reason, :run_advance_failed, expected_suffix)
      assert_failure_suffix(resume_reason, :run_resume_failed, expected_suffix)
    end)

    Process.delete({@definition_boundary, :failure})

    # The boundary id is a supported compact fence in addition to the full Ref.
    ref = Ref.new("policy-run", 0, :policy, "policy-boundary")
    boundary = %Boundary{id: "policy-boundary", kind: :needs, ref: ref}
    result = %Result{input: Input.new("yes"), state: %State{}}

    policy_run = %{
      Run.new(@agent, Input.new("yes"), %State{}, run_id: "policy-run")
      | status: :boundary,
        cursor: :policy,
        waiting: boundary,
        result: result
    }

    assert {:error, reason, %Run{}} =
             Runtime.resume(policy_run, {:policy, boundary.id, {:accept, :approved}})

    refute match?({:invalid_run_reference, _, _}, reason)
  end

  test "ordinary validation failures stay inside their Run step boundaries" do
    valid_request = request("invalid-prepare")
    {:ok, inference_run} = Runtime.admit_inference(@agent, valid_request, "logical", %State{})
    invalid_request = %{valid_request | metadata: []}

    assert {:error, :invalid_inference_request_metadata, %Run{status: :failed}} =
             Runtime.prepare_inference(inference_run, invalid_request, [])

    assert {:error, {:invalid_input_pipeline, :invalid}, %Run{status: :failed}} =
             Runtime.start(@agent, "ping", input_pipeline: :invalid)

    assert {:ok, %Result{reply_text: "pong"}} =
             Runtime.handle(
               @agent,
               Input.new("ping"),
               chat_history_limit: false
             )
  end

  test "inference resume contains memory and postprocessor validation failures" do
    opts = stream_opts()
    {:continue, started} = Runtime.start(@agent, "ask", opts)

    {:dispatch, %Invocation{} = invocation, awaiting, _prepared} =
      Runtime.advance(started, opts)

    assert {:error, {:payload_too_large, :memory_recall, _size, 1}, %Run{status: :failed}} =
             Runtime.resume(
               awaiting,
               {:inference, invocation, Spectre.Inference.Response.new("ignored")},
               Keyword.merge(opts, memory: String.duplicate("x", 20), memory_max_bytes: 1)
             )

    bounded_opts = Keyword.put(opts, :model_reply_max_bytes, 1)
    {:continue, bounded_started} = Runtime.start(@agent, "ask", bounded_opts)

    {:dispatch, %Invocation{} = bounded_invocation, bounded_awaiting, _prepared} =
      Runtime.advance(bounded_started, bounded_opts)

    assert {:error, _reason, %Run{status: :failed}} =
             Runtime.resume(
               bounded_awaiting,
               {:inference, bounded_invocation, Spectre.Inference.Response.new("too long")},
               bounded_opts
             )
  end

  test "legacy Runtime.handle refuses inference dispatch outside an Instance" do
    assert {:error, :inference_dispatch_requires_agent_instance} =
             Runtime.handle(
               @agent,
               Input.new("ask"),
               model: @model,
               plan_actions?: false,
               instance_run_lifecycle?: true,
               streaming?: true,
               stream_adapter: @stream_adapter
             )
  end

  test "revision fences reject stale invocation structs without mutating the Run" do
    opts = stream_opts()

    {:continue, started} = Runtime.start(@agent, "ask", opts)
    {:dispatch, %Invocation{} = invocation, awaiting, _prepared} = Runtime.advance(started, opts)
    stale = %{invocation | run_revision: invocation.run_revision + 1}

    assert {:error, {:stale_invocation, supplied, expected}, ^awaiting} =
             Runtime.resume(
               awaiting,
               {:inference, stale, Spectre.Inference.Response.new("ignored")}
             )

    assert supplied == stale.id
    assert expected == invocation.id
  end

  test "classifier inference continuations re-enter routing and policy without leaking classifier opts" do
    response = Spectre.Inference.Response.new("PING")

    route_request =
      Request.new(
        id: "route-classifier-resume",
        purpose: :route_classification,
        plan: plan("classify a route"),
        constraints: Constraints.new([]),
        metadata: %{
          model: @model,
          llm_opts: [model: @model],
          explicit_model_override?: true
        }
      )

    assert {:ok, route_run} =
             Runtime.admit_inference(@agent, route_request, "ping", %State{})

    assert {:dispatch, %Invocation{} = route_invocation, route_awaiting, _prepared} =
             Runtime.prepare_inference(route_run, route_request, model: @model)

    route_awaiting =
      put_in(
        route_awaiting.inference_continuation.postprocessor,
        :route_classification
      )

    assert {:boundary, %Boundary{kind: :reply}, routed} =
             Runtime.resume(
               route_awaiting,
               {:inference, route_invocation, response},
               model: @model
             )

    assert routed.inference_continuation == nil

    policy_request =
      Request.new(
        id: "policy-classifier-resume",
        purpose: :policy_interrupt_classification,
        plan: plan("classify a policy interrupt"),
        constraints: Constraints.new([]),
        metadata: %{
          model: @model,
          llm_opts: [model: @model],
          explicit_model_override?: true
        }
      )

    assert {:ok, policy_run} =
             Runtime.admit_inference(@agent, policy_request, "ping", %State{})

    assert {:dispatch, %Invocation{} = policy_invocation, policy_awaiting, _prepared} =
             Runtime.prepare_inference(policy_run, policy_request, model: @model)

    policy_awaiting =
      put_in(
        policy_awaiting.inference_continuation.postprocessor,
        :policy_interrupt_classification
      )

    assert {:error, _reason, %Run{status: :failed}} =
             Runtime.resume(
               policy_awaiting,
               {:inference, policy_invocation, response},
               model: @model,
               policy_global_interrupts?: true
             )
  end

  defp request(id) do
    Request.new(
      id: id,
      purpose: :cognitive_operation,
      plan: plan("runtime inference edge"),
      constraints: Constraints.new([]),
      metadata: %{
        model: @model,
        llm_opts: [model: @model],
        explicit_model_override?: true
      }
    )
  end

  defp plan(text) do
    {:ok, plan} = Plan.compose(text, [], [:agent])
    plan
  end

  defp stream_opts do
    [
      model: @model,
      plan_actions?: false,
      instance_run_lifecycle?: true,
      streaming?: true,
      stream_adapter: @stream_adapter
    ]
  end

  defp assert_failure_suffix({kind, module}, kind, module) when is_atom(module), do: :ok
end
