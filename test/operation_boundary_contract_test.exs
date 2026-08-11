defmodule SpectreOperationBoundaryContractTest.Executors do
  @moduledoc false

  alias Spectre.Operation.Execution
  alias Spectre.Operation.ExecutionContext

  def with_progress(input, context) do
    :ok = ExecutionContext.progress(context, :half, %{stage: 1})
    :ok = ExecutionContext.progress(context, :suppressed, %{stage: 2})

    Execution.new(input,
      receipt: %{id: "receipt"},
      usage: %{cost: 2},
      artifacts: [%{kind: :record}],
      metadata: %{executor: :function}
    )
  end

  def one_arity(input), do: {:ok, input}
  def proposal(input, _context), do: input
  def cognitive(input, _context), do: input
  def fallback(_input, _context), do: :inside
  def invalid_fallback(_input, _context), do: :outside
  def failed_fallback(_input, _context), do: {:error, :fallback_unavailable}
  def reconcile(receipt, _context), do: {:ok, receipt}
  def invalid_effect(_input, _context), do: :not_an_effect

  def effect(input, _context) do
    Spectre.Effect.restore(%{
      id: "boundary-effect",
      kind: :observation,
      name: :observe,
      payload: input
    })
  end

  def declared_action_ambiguity(_input, _context),
    do: {:error, {:action_outcome_ambiguous, :provider_unknown}}

  def declared_effect_ambiguity(_input, _context),
    do: {:error, {:effect_outcome_ambiguous, :observation, :provider_unknown}}

  def block(input, context) do
    send(Keyword.fetch!(context.opts, :test_pid), {:operation_blocked, self(), input})

    receive do
      :continue -> {:ok, input}
    end
  end

  def raise_error(_input, _context), do: raise("executor failed")
end

defmodule SpectreOperationBoundaryContractTest.Actions do
  @moduledoc false

  def deliver(args, context) do
    {:ok,
     %{
       args: args,
       input: context.input.text,
       operation_id: context.opts[:operation_id],
       attempt_id: context.opts[:operation_attempt_id],
       idempotency_key: context.opts[:idempotency_key]
     }}
  end
end

defmodule SpectreOperationBoundaryContractTest.EffectExecutor do
  @moduledoc false
  @behaviour Spectre.Effect.Executor

  @impl true
  def execute(effect, context, opts) do
    {:ok,
     %{
       payload: effect.payload,
       input: context.input.text,
       operation_id: opts[:operation_id],
       attempt_id: opts[:operation_attempt_id],
       idempotency_key: opts[:idempotency_key]
     }}
  end
end

defmodule SpectreOperationBoundaryContractTest.EffectExtension do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def id, do: :operation_boundary_effects

  @impl true
  def api_version, do: 1

  @impl true
  def compile(_owner, opts), do: {:ok, opts}

  @impl true
  def effect_executors(_opts) do
    [{:observation, SpectreOperationBoundaryContractTest.EffectExecutor}]
  end
end

defmodule SpectreOperationBoundaryContractTest.RuntimeAgent do
  @moduledoc false
  use Spectre.Agent

  actions(SpectreOperationBoundaryContractTest.Actions)

  Spectre.Extension.register!(
    __MODULE__,
    SpectreOperationBoundaryContractTest.EffectExtension
  )
end

defmodule SpectreOperationBoundaryContractTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(_ref, opts) do
    case Keyword.fetch!(opts, :reply) do
      :not_found -> :not_found
      :binary -> {:ok, "checkpoint"}
      :map -> {:ok, %{revision: 1}}
      :error -> {:error, :load_failed}
      :invalid -> :unexpected
      :raise -> raise "load failed"
      :throw -> throw(:load_failed)
    end
  end

  @impl true
  def compare_and_swap(_ref, _checkpoint, _expected, _revision, opts) do
    case Keyword.fetch!(opts, :reply) do
      :ok -> :ok
      :receipt -> {:ok, %{etag: "next"}}
      :error -> {:error, :conflict}
      :invalid -> :unexpected
      :raise -> raise "persist failed"
      :throw -> throw(:persist_failed)
    end
  end
end

defmodule SpectreOperationBoundaryContractTest.Validator do
  @moduledoc false

  def validate(:ok), do: :ok
  def validate(true), do: true
  def validate(:normalized), do: {:ok, :normalized}
  def validate(false), do: false
  def validate(:error), do: {:error, :invalid}
  def validate(:invalid_reply), do: {:unexpected, :reply}
  def validate(:raise), do: raise("validator failed")
  def validate(:throw), do: throw(:validator_failed)

  def accept(value) when is_integer(value), do: :ok
  def accept(_value), do: {:error, :not_integer}
end

defmodule SpectreOperationBoundaryContractTest.Policy do
  @moduledoc false

  def authorize(_spec, request, _context), do: reply(request.input)
  def two_arity(request, _context), do: reply(request.input)

  defp reply(:ok), do: :ok
  defp reply(true), do: true
  defp reply(:authorized), do: {:ok, %{scope: :operation}}
  defp reply(false), do: false
  defp reply(:error), do: {:error, :forbidden}
  defp reply(:invalid), do: :maybe
  defp reply(:raise), do: raise("policy failed")
  defp reply(:throw), do: throw(:policy_failed)
end

defmodule SpectreOperationBoundaryContractTest.MemoryAdapter do
  @moduledoc false

  def remember_operation(%{reply: :ok}, _opts), do: :ok
  def remember_operation(%{reply: :receipt}, _opts), do: {:ok, %{id: "memory"}}
  def remember_operation(%{reply: :error}, _opts), do: {:error, :unavailable}
  def remember_operation(%{reply: :invalid}, _opts), do: :unexpected
  def remember_operation(%{reply: :raise}, _opts), do: raise("memory failed")
  def remember_operation(%{reply: :throw}, _opts), do: throw(:memory_failed)
end

defmodule SpectreOperationBoundaryContractTest.LegacyMemoryAdapter do
  @moduledoc false
  def remember(_payload, _opts), do: :ok
end

defmodule SpectreOperationBoundaryContractTest.EmptyAdapter do
  @moduledoc false
end

defmodule SpectreOperationBoundaryContractTest.MemoryAgent do
  @moduledoc false
  def __spectre_config__, do: [memory: SpectreOperationBoundaryContractTest.MemoryAdapter]
end

defmodule SpectreOperationBoundaryContractTest.LegacyMemoryAgent do
  @moduledoc false
  def __spectre_config__, do: [memory: SpectreOperationBoundaryContractTest.LegacyMemoryAdapter]
end

defmodule SpectreOperationBoundaryContractTest.EmptyMemoryAgent do
  @moduledoc false
  def __spectre_config__, do: [memory: SpectreOperationBoundaryContractTest.EmptyAdapter]
end

defmodule SpectreOperationBoundaryContractTest.NoMemoryAgent do
  @moduledoc false
  def __spectre_config__, do: []
end

defmodule SpectreOperationBoundaryContractTest.CatalogAgent do
  @moduledoc false

  alias Spectre.Operation.Spec

  def __spectre_config__ do
    [
      operations: [
        Spec.new(
          id: :imported_echo,
          executor: {SpectreOperationBoundaryContractTest.Executors, :one_arity},
          input: :map,
          output: :map
        )
      ]
    ]
  end
end

defmodule SpectreOperationBoundaryContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Action
  alias Spectre.Effect
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Operation.Artifact
  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Delivery
  alias Spectre.Operation.Delivery.Consent
  alias Spectre.Operation.Delivery.Policy, as: DeliveryPolicy
  alias Spectre.Operation.Event
  alias Spectre.Operation.Events
  alias Spectre.Operation.Execution
  alias Spectre.Operation.ExecutionContext
  alias Spectre.Operation.Executor
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Memory
  alias Spectre.Operation.Monitor
  alias Spectre.Operation.Policy
  alias Spectre.Operation.Progress
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Retry
  alias Spectre.Operation.Runner
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Subject

  @executors SpectreOperationBoundaryContractTest.Executors
  @validator SpectreOperationBoundaryContractTest.Validator
  @policy SpectreOperationBoundaryContractTest.Policy
  @agent SpectreOperationBoundaryContractTest.CatalogAgent
  @runtime_agent SpectreOperationBoundaryContractTest.RuntimeAgent
  @checkpoint_store SpectreOperationBoundaryContractTest.CheckpointStore

  test "artifacts, executions and progress reject malformed or nonportable envelopes" do
    artifact =
      Artifact.new(
        kind: :report,
        uri: "memory://report",
        digest: "sha256:123",
        media_type: "application/json",
        metadata: %{public: true}
      )

    assert :ok = Artifact.validate(artifact)
    assert artifact == Artifact.validate!(artifact)
    assert_raise ArgumentError, fn -> Artifact.new(%{}) end

    assert {:error, :invalid_operation_artifact_id} =
             Artifact.validate(%{artifact | id: ""})

    assert {:error, :invalid_operation_artifact_kind} =
             Artifact.validate(%{artifact | kind: nil})

    assert {:error, :invalid_operation_artifact_uri} =
             Artifact.validate(%{artifact | uri: ""})

    assert {:error, :invalid_operation_artifact_digest} =
             Artifact.validate(%{artifact | digest: 1})

    assert {:error, :invalid_operation_artifact_media_type} =
             Artifact.validate(%{artifact | media_type: ""})

    assert {:error, :invalid_operation_artifact_timestamp} =
             Artifact.validate(%{artifact | created_at: -1})

    assert {:error, :invalid_operation_artifact_metadata} =
             Artifact.validate(%{artifact | metadata: []})

    assert {:error, {:nonportable_operation_artifact, _reason}} =
             Artifact.validate(%{artifact | metadata: %{pid: self()}})

    execution =
      Execution.new(%{ok: true},
        receipt: %{id: "receipt"},
        usage: %{cost: 1.5},
        artifacts: [artifact],
        metadata: %{source: :test}
      )

    assert :ok = Execution.validate(execution)
    assert Execution.normalize(execution) == execution
    assert Execution.normalize(:plain).value == :plain

    assert {:error, :invalid_operation_execution_usage} =
             Execution.validate(%{execution | usage: []})

    assert {:error, :invalid_operation_execution_cost} =
             Execution.validate(%{execution | usage: %{cost: -1}})

    assert {:error, :invalid_operation_execution_artifacts} =
             Execution.validate(%{execution | artifacts: %{}})

    assert {:error, :invalid_operation_execution_metadata} =
             Execution.validate(%{execution | metadata: []})

    assert {:error, {:nonportable_operation_execution, _reason}} =
             Execution.validate(%{execution | value: self()})

    progress = progress_fixture()
    assert :ok = Progress.validate(progress)

    invalid_progress = [
      {%{progress | id: ""}, :invalid_operation_progress_identity},
      {%{progress | context_revision: -1}, :invalid_operation_progress_context_revision},
      {%{progress | control_generation: -1}, :invalid_operation_progress_control_generation},
      {%{progress | trigger_generation: -1}, :invalid_operation_progress_trigger_generation},
      {%{progress | sequence: 0}, :invalid_operation_progress_sequence},
      {%{progress | at: -1}, :invalid_operation_progress_timestamp},
      {%{progress | metadata: []}, :invalid_operation_progress_metadata}
    ]

    Enum.each(invalid_progress, fn {value, reason} ->
      assert {:error, ^reason} = Progress.validate(value)
    end)

    assert {:error, {:nonportable_operation_progress, _reason}} =
             Progress.validate(%{progress | value: self()})
  end

  test "validators and policy callbacks fail closed across every callback shape" do
    Enum.each(
      [
        {nil, self()},
        {:any, self()},
        {:map, %{}},
        {:list, []},
        {:binary, "value"},
        {:integer, 1},
        {:number, 1.5},
        {:atom, :value},
        {:boolean, true}
      ],
      fn {validator, value} -> assert :ok = Validator.validate(validator, value, :field) end
    )

    assert {:error, {:invalid_operation_value, :field, :map, :list}} =
             Validator.validate(:map, [], :field)

    assert :ok = Validator.validate(@validator, :ok, :field)
    assert :ok = Validator.validate({@validator, :accept}, 1, :field)
    assert :ok = Validator.validate(@validator, true, :field)
    assert :ok = Validator.validate(@validator, :normalized, :field)

    assert {:error, {:operation_validation_failed, :field}} =
             Validator.validate(@validator, false, :field)

    assert {:error, {:operation_validation_failed, :field, :invalid}} =
             Validator.validate(@validator, :error, :field)

    assert {:error, {:invalid_operation_validation_reply, :field, {:tuple, 2}}} =
             Validator.validate(@validator, :invalid_reply, :field)

    assert {:error, {:operation_validator_exception, :field, @validator, :validate, RuntimeError}} =
             Validator.validate(@validator, :raise, :field)

    assert {:error,
            {:operation_validator_failure, :field, @validator, :validate, :throw,
             :validator_failed}} = Validator.validate(@validator, :throw, :field)

    assert {:error, {:operation_validator_missing, :field, @validator, :missing}} =
             Validator.validate({@validator, :missing}, :ok, :field)

    assert {:error, {:operation_validator_not_loaded, :field, _module}} =
             Validator.validate(
               {SpectreOperationBoundaryContractTest.MissingValidator, :validate},
               :ok,
               :field
             )

    assert {:error, {:invalid_operation_validator, :field, []}} =
             Validator.validate([], :ok, :field)

    assert :ok = Validator.domain(nil, :anything, :domain)
    assert :ok = Validator.domain([:a, :b], :b, :domain)

    assert {:error, {:operation_value_outside_domain, :domain, :c}} =
             Validator.domain([:a, :b], :c, :domain)

    context = execution_context(attempt_fixture())
    request = Request.new(:policy_operation, :ok)
    registered = spec_fixture(policy: :registered)
    assert :ok = Policy.authorize(registered, request, context)

    Enum.each([:ok, true, :authorized], fn reply ->
      spec = spec_fixture(policy: @policy)
      assert :ok = Policy.authorize(spec, %{request | input: reply}, context)
    end)

    assert {:error, {:operation_not_authorized, :operation}} =
             Policy.authorize(
               spec_fixture(policy: {@policy, :two_arity}),
               %{request | input: false},
               context
             )

    assert {:error, {:operation_not_authorized, :operation, :forbidden}} =
             Policy.authorize(spec_fixture(policy: @policy), %{request | input: :error}, context)

    assert {:error, {:invalid_operation_policy_reply, :operation, :maybe}} =
             Policy.authorize(
               spec_fixture(policy: @policy),
               %{request | input: :invalid},
               context
             )

    assert {:error, {:operation_policy_exception, :operation, RuntimeError}} =
             Policy.authorize(spec_fixture(policy: @policy), %{request | input: :raise}, context)

    assert {:error, {:operation_policy_failure, :operation, :throw, :policy_failed}} =
             Policy.authorize(spec_fixture(policy: @policy), %{request | input: :throw}, context)

    missing = %{registered | policy: SpectreOperationBoundaryContractTest.MissingPolicy}

    assert {:error, {:operation_policy_not_loaded, :operation, _module}} =
             Policy.authorize(missing, request, context)

    callback_missing = %{registered | policy: SpectreOperationBoundaryContractTest.EmptyAdapter}

    assert {:error,
            {:operation_policy_callback_missing, :operation,
             SpectreOperationBoundaryContractTest.EmptyAdapter, :authorize}} =
             Policy.authorize(callback_missing, request, context)
  end

  test "the executor enforces catalog, policy, domain, fallback and reconciliation boundaries" do
    attempt = attempt_fixture()
    context = execution_context(attempt)

    function_spec =
      spec_fixture(
        executor: {@executors, :with_progress},
        input: :map,
        output: :map
      )

    assert {:ok, execution} =
             Executor.execute(function_spec, Request.new(:operation, %{value: 1}), context)

    assert execution.value == %{value: 1}
    assert execution.receipt == %{id: "receipt"}
    assert execution.usage == %{cost: 2}

    assert {:error, {:invalid_operation_value, {:operation_input, :operation}, :map, :list}} =
             Executor.execute(function_spec, Request.new(:operation, []), context)

    one_arity = spec_fixture(executor: @executors, input: :map, output: :map)

    assert {:error, {:operation_executor_missing, :operation, @executors, :execute}} =
             Executor.execute(one_arity, Request.new(:operation, %{}), context)

    one_arity = %{one_arity | executor: {@executors, :one_arity}}

    assert {:ok, %Execution{value: %{ok: true}}} =
             Executor.execute(one_arity, Request.new(:operation, %{ok: true}), context)

    missing = %{one_arity | executor: SpectreOperationBoundaryContractTest.MissingExecutor}

    assert {:error, {:operation_executor_not_loaded, :operation, _module}} =
             Executor.execute(missing, Request.new(:operation, %{}), context)

    planner =
      Spec.new(
        id: :planner,
        kind: :planner,
        executor: {@executors, :proposal},
        input: :any,
        output: :any,
        catalog: [:read, :write]
      )

    assert {:ok, %Execution{value: %{operation: :read}}} =
             Executor.execute(planner, Request.new(:planner, %{operation: :read}), context)

    assert {:ok, %Execution{value: %{"operation" => :write}}} =
             Executor.execute(planner, Request.new(:planner, %{"operation" => :write}), context)

    action_proposal = Action.new(:read)

    assert {:ok, %Execution{value: ^action_proposal}} =
             Executor.execute(planner, Request.new(:planner, action_proposal), context)

    assert {:error, {:planner_operation_outside_catalog, :planner}} =
             Executor.execute(planner, Request.new(:planner, :outside), context)

    assert {:error, {:invalid_planner_proposal, :list}} =
             Executor.execute(planner, Request.new(:planner, []), context)

    assert {:error, :planner_failed} =
             Executor.execute(planner, Request.new(:planner, {:error, :planner_failed}), context)

    cognitive =
      Spec.new(
        id: :cognitive,
        kind: :cognitive,
        executor: {@executors, :cognitive},
        fallback: {@executors, :fallback},
        input: :atom,
        output: :atom,
        domain: [:inside],
        retry: [max_attempts: 1]
      )

    cognitive_context = execution_context(%{attempt | operation: :cognitive})

    assert {:ok, fallback} =
             Executor.execute(cognitive, Request.new(:cognitive, :outside), cognitive_context)

    assert fallback.value == :inside
    assert fallback.metadata.cognitive_fallback

    invalid_fallback = %{cognitive | fallback: {@executors, :invalid_fallback}}

    assert {:error, {:cognitive_fallback_invalid, :cognitive, _, _}} =
             Executor.execute(
               invalid_fallback,
               Request.new(:cognitive, :outside),
               cognitive_context
             )

    failed_fallback = %{cognitive | fallback: {@executors, :failed_fallback}}

    assert {:error, {:cognitive_fallback_failed, :cognitive, _, :fallback_unavailable}} =
             Executor.execute(
               failed_fallback,
               Request.new(:cognitive, :outside),
               cognitive_context
             )

    no_fallback = %{cognitive | fallback: nil, retry: Retry.new(max_attempts: 2)}

    assert {:error, {:operation_value_outside_domain, {:operation_domain, :cognitive}, :outside}} =
             Executor.execute(no_fallback, Request.new(:cognitive, :outside), cognitive_context)

    reconcilable =
      Spec.new(
        id: :reconcile,
        executor: {@executors, :one_arity},
        reconcile: {@executors, :reconcile},
        side_effect: :reconcilable,
        output: :map
      )

    assert {:ok, %Execution{value: %{receipt: 1}}} =
             Executor.reconcile(reconcilable, %{receipt: 1}, context)

    assert {:error, {:operation_not_reconcilable, :operation}} =
             Executor.reconcile(function_spec, %{receipt: 1}, context)

    invalid_reconciliation = %{reconcilable | output: :map}

    assert {:error, {:invalid_operation_value, {:operation_output, :reconcile}, :map, :atom}} =
             Executor.reconcile(invalid_reconciliation, :invalid, context)

    response_spec =
      spec_fixture(input: :any, output: :any, domain: ["inside"])

    response = InferenceResponse.new("inside")

    assert {:ok, %Execution{value: ^response}} =
             Executor.execute(response_spec, Request.new(:operation, response), context)

    inference =
      Spec.new(
        id: :inference,
        kind: :cognitive,
        executor: :inference,
        input: :any,
        output: :any
      )

    for {value, shape} <- [
          {"invalid", :binary},
          {%{invalid: true}, :map},
          {{:invalid, :request}, {:tuple, 2}},
          {42, :other}
        ] do
      assert {:error, {:invalid_cognitive_request, ^shape}} =
               Executor.execute(inference, Request.new(:inference, value), context)
    end

    assert {:error, {:nonportable_operation_value, _reason}} =
             Executor.execute(
               %{function_spec | input: :any},
               %{Request.new(:operation, %{}) | input: %{pid: self()}},
               context
             )

    runtime_context = %{context | agent: @runtime_agent}

    action =
      Spec.new(
        id: :deliver,
        kind: :action,
        executor: [name: :deliver, via: :local, mode: :write, metadata: %{source: :test}],
        input: :any,
        output: :map
      )

    action_cases = [
      {%{item: 1}, %{runtime_context | input: Spectre.Input.new("typed")}, %{item: 1}, "typed"},
      {nil, %{runtime_context | input: "binary"}, %{}, "binary"},
      {:scalar, %{runtime_context | input: :unsupported}, %{value: :scalar}, ""}
    ]

    Enum.each(action_cases, fn {input, action_context, expected_args, expected_input} ->
      assert {:ok, %Execution{value: value}} =
               Executor.execute(action, Request.new(:deliver, input), action_context)

      assert value.args == expected_args
      assert value.input == expected_input
      assert value.operation_id == :deliver
      assert value.attempt_id == attempt.id
      assert value.idempotency_key == attempt.idempotency_key
    end)

    string_keyed_action = %{
      action
      | executor: %{
          "name" => :deliver,
          "via" => :local,
          "owner" => @runtime_agent,
          "scope" => :agent,
          "mode" => :read,
          "metadata" => %{source: :string_keys}
        }
    }

    assert {:ok, %Execution{value: %{args: %{map: true}}}} =
             Executor.execute(
               string_keyed_action,
               Request.new(:deliver, %{map: true}),
               %{runtime_context | input: %{source: :map}}
             )

    effect =
      Spec.new(
        id: :observe,
        kind: :effect,
        executor: {@executors, :effect},
        input: :any,
        output: :map
      )

    assert {:ok, %Execution{value: observed}} =
             Executor.execute(
               effect,
               Request.new(:observe, %{page: 1}),
               %{runtime_context | input: "effect input"}
             )

    assert %{page: 1} = observed.payload
    assert observed.input == "effect input"
    assert observed.operation_id == :observe
    assert observed.attempt_id == attempt.id
    assert observed.idempotency_key == attempt.idempotency_key

    direct_effect = %{effect | executor: nil}
    staged_effect = @executors.effect(%{page: 2}, runtime_context)

    assert {:ok, %Execution{value: %{payload: %{page: 2}}}} =
             Executor.execute(
               direct_effect,
               Request.new(:observe, staged_effect),
               runtime_context
             )

    action_effect =
      :deliver
      |> Action.new(args: %{effect: true})
      |> Action.to_effect_attrs()
      |> Effect.stage_action(@runtime_agent, :agent)

    assert {:ok, %Execution{value: %{args: %{effect: true}}}} =
             Executor.execute(
               direct_effect,
               Request.new(:observe, action_effect),
               runtime_context
             )

    invalid_effect_shapes = [
      {"invalid", :binary},
      {%{invalid: true}, :map},
      {{:invalid, :effect}, {:tuple, 2}},
      {42, :other}
    ]

    Enum.each(invalid_effect_shapes, fn {value, shape} ->
      assert {:error, {:invalid_operation_effect, :observe, ^shape}} =
               Executor.execute(
                 %{effect | executor: {@executors, :proposal}},
                 Request.new(:observe, value),
                 runtime_context
               )
    end)

    effect =
      Spec.new(
        id: :effect,
        kind: :effect,
        executor: {@executors, :invalid_effect},
        input: :map,
        output: :any
      )

    assert {:error, {:invalid_operation_effect, :effect, :atom}} =
             Executor.execute(effect, Request.new(:effect, %{}), context)

    crashing = spec_fixture(executor: {@executors, :raise_error})

    assert {:error, %Spectre.Provider.Failure{kind: :exception}} =
             Executor.execute(crashing, Request.new(:operation, %{}), context)

    ambiguous = %{crashing | side_effect: :idempotent}

    assert {:ambiguous, %Spectre.Provider.Failure{kind: :exception}} =
             Executor.execute(ambiguous, Request.new(:operation, %{}), context)

    assert {:ambiguous, {:action_outcome_ambiguous, :provider_unknown}} =
             Executor.execute(
               %{crashing | executor: {@executors, :declared_action_ambiguity}},
               Request.new(:operation, %{}),
               context
             )

    assert {:ambiguous, {:effect_outcome_ambiguous, :observation, :provider_unknown}} =
             Executor.execute(
               %{crashing | executor: {@executors, :declared_effect_ambiguity}},
               Request.new(:operation, %{}),
               context
             )
  end

  test "a temporary Runner emits fenced throttled progress and one terminal Result" do
    attempt = attempt_fixture()
    assert :ok = ExecutionContext.progress(execution_context(attempt), :default_metadata)

    spec =
      spec_fixture(
        executor: {@executors, :with_progress},
        input: :map,
        output: :map
      )

    request = Request.new(:operation, %{value: 1})

    child_spec = Runner.child_spec(attempt: attempt)
    assert child_spec.restart == :temporary
    assert child_spec.id == {Runner, attempt.id}

    {:ok, runner} =
      Runner.start_link(
        owner: self(),
        attempt: attempt,
        spec: spec,
        request: request,
        agent: @agent,
        subject: Subject.new("runner-subject"),
        controller: __MODULE__,
        input: %{},
        agent_state: %{},
        cognitive: %{},
        opts: [operation_progress_interval: 10_000]
      )

    monitor = Process.monitor(runner)

    assert_receive {:spectre, :operation_progress, %Progress{} = progress}, 1_000
    assert progress.sequence == 1
    assert progress.value == :half
    assert progress.context_revision == attempt.context_revision
    assert progress.control_generation == attempt.control_generation
    assert progress.trigger_generation == attempt.trigger_generation
    assert :ok = Progress.validate(progress)

    refute_receive {:spectre, :operation_progress, _second}, 25

    assert_receive {:spectre, :operation_result, result}, 1_000
    assert result.status == :ok
    assert result.value == %{value: 1}
    assert result.receipt == %{id: "receipt"}
    assert result.usage == %{cost: 2}
    assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 1_000

    trapped? = Process.flag(:trap_exit, true)

    assert {:error, :invalid_operation_runner_arguments} =
             Runner.start_link(owner: self(), attempt: :invalid, spec: spec, request: request)

    Process.flag(:trap_exit, trapped?)
  end

  test "the Runner supervisor starts and terminates temporary attempts" do
    assert {:error, {:already_started, _pid}} = RunnerSupervisor.start_link()

    attempt = attempt_fixture(id: "supervised-attempt")

    spec =
      spec_fixture(
        executor: {@executors, :block},
        input: :map,
        output: :map,
        timeout: 1_000
      )

    opts = [
      owner: self(),
      attempt: attempt,
      spec: spec,
      request: Request.new(:operation, %{value: 1}),
      agent: @agent,
      subject: Subject.new("supervised-runner-subject"),
      controller: __MODULE__,
      input: %{},
      agent_state: %{},
      cognitive: %{},
      opts: [test_pid: self()]
    ]

    assert {:ok, runner} = RunnerSupervisor.start_runner(opts)
    assert_receive {:operation_blocked, executor, %{value: 1}}, 1_000
    assert is_pid(executor)
    monitor = Process.monitor(runner)
    assert :ok = RunnerSupervisor.stop_runner(runner)
    assert_receive {:DOWN, ^monitor, :process, ^runner, :shutdown}, 1_000
  end

  test "checkpoint stores normalize configuration and fail closed at adapter boundaries" do
    ref = InstanceRef.new(@agent, Subject.new("checkpoint-store-subject"))

    assert {:ok, nil} = CheckpointStore.normalize(nil)
    assert {:ok, nil} = CheckpointStore.normalize(false)
    assert {:ok, {@checkpoint_store, []}} = CheckpointStore.normalize(@checkpoint_store)

    assert {:ok, {@checkpoint_store, [reply: :map]}} =
             CheckpointStore.normalize({@checkpoint_store, reply: :map})

    assert {:error, {:invalid_checkpoint_store, "invalid"}} =
             CheckpointStore.normalize("invalid")

    assert :not_found = CheckpointStore.load(nil, ref, [])

    assert {:error, {:checkpoint_store_not_loaded, _module}} =
             CheckpointStore.load(
               {SpectreOperationBoundaryContractTest.MissingCheckpointStore, []},
               ref,
               []
             )

    assert :not_found =
             CheckpointStore.load(
               {SpectreOperationBoundaryContractTest.EmptyAdapter, []},
               ref,
               []
             )

    assert :not_found = CheckpointStore.load({@checkpoint_store, [reply: :not_found]}, ref, [])

    assert {:ok, "checkpoint"} =
             CheckpointStore.load({@checkpoint_store, []}, ref, reply: :binary)

    assert {:ok, %{revision: 1}} =
             CheckpointStore.load({@checkpoint_store, [reply: :binary]}, ref, reply: :map)

    assert {:error, :load_failed} =
             CheckpointStore.load({@checkpoint_store, []}, ref, reply: :error)

    assert {:error, {:invalid_checkpoint_load_reply, @checkpoint_store, :unexpected}} =
             CheckpointStore.load({@checkpoint_store, []}, ref, reply: :invalid)

    assert {:error, {:checkpoint_load_exception, @checkpoint_store, RuntimeError}} =
             CheckpointStore.load({@checkpoint_store, []}, ref, reply: :raise)

    assert {:error, {:checkpoint_load_failure, @checkpoint_store, :throw, :load_failed}} =
             CheckpointStore.load({@checkpoint_store, []}, ref, reply: :throw)

    missing = SpectreOperationBoundaryContractTest.MissingCheckpointStore

    assert {:error, {:checkpoint_store_not_loaded, ^missing}} =
             CheckpointStore.persist({missing, []}, ref, "checkpoint", 0, 1, [])

    assert {:error,
            {:checkpoint_store_callback_missing,
             SpectreOperationBoundaryContractTest.EmptyAdapter, :compare_and_swap, 5}} =
             CheckpointStore.persist(
               {SpectreOperationBoundaryContractTest.EmptyAdapter, []},
               ref,
               "checkpoint",
               0,
               1,
               []
             )

    assert :ok =
             CheckpointStore.persist(
               {@checkpoint_store, [reply: :error]},
               ref,
               "checkpoint",
               0,
               1,
               reply: :ok
             )

    assert :ok =
             CheckpointStore.persist(
               {@checkpoint_store, []},
               ref,
               "checkpoint",
               1,
               2,
               reply: :receipt
             )

    assert {:error, :conflict} =
             CheckpointStore.persist(
               {@checkpoint_store, []},
               ref,
               "checkpoint",
               2,
               3,
               reply: :error
             )

    assert {:error,
            {:ambiguous, {:invalid_checkpoint_persist_reply, @checkpoint_store, :unexpected}}} =
             CheckpointStore.persist(
               {@checkpoint_store, []},
               ref,
               "checkpoint",
               3,
               4,
               reply: :invalid
             )

    assert {:error,
            {:ambiguous, {:checkpoint_persist_exception, @checkpoint_store, RuntimeError}}} =
             CheckpointStore.persist(
               {@checkpoint_store, []},
               ref,
               "checkpoint",
               4,
               5,
               reply: :raise
             )

    assert {:error,
            {:ambiguous,
             {:checkpoint_persist_failure, @checkpoint_store, :throw, :persist_failed}}} =
             CheckpointStore.persist(
               {@checkpoint_store, []},
               ref,
               "checkpoint",
               5,
               6,
               reply: :throw
             )
  end

  test "memory and local committed-event subscriptions remain optional, filtered ports" do
    assert :ok =
             Memory.persist(SpectreOperationBoundaryContractTest.MemoryAgent, %{reply: :ok}, [])

    assert :ok =
             Memory.persist(
               SpectreOperationBoundaryContractTest.MemoryAgent,
               %{reply: :receipt},
               []
             )

    assert {:error, :unavailable} =
             Memory.persist(
               SpectreOperationBoundaryContractTest.MemoryAgent,
               %{reply: :error},
               []
             )

    assert {:error, {:invalid_operation_memory_reply, :unexpected}} =
             Memory.persist(
               SpectreOperationBoundaryContractTest.MemoryAgent,
               %{reply: :invalid},
               []
             )

    assert {:error, {:operation_memory_exception, RuntimeError}} =
             Memory.persist(
               SpectreOperationBoundaryContractTest.MemoryAgent,
               %{reply: :raise},
               []
             )

    assert {:error, {:operation_memory_failure, :throw, :memory_failed}} =
             Memory.persist(
               SpectreOperationBoundaryContractTest.MemoryAgent,
               %{reply: :throw},
               []
             )

    assert :ok =
             Memory.persist(SpectreOperationBoundaryContractTest.LegacyMemoryAgent, %{}, [])

    assert {:error, :operation_memory_not_configured} =
             Memory.persist(SpectreOperationBoundaryContractTest.NoMemoryAgent, %{}, [])

    assert {:error,
            {:operation_memory_callback_missing,
             SpectreOperationBoundaryContractTest.EmptyAdapter}} =
             Memory.persist(SpectreOperationBoundaryContractTest.EmptyMemoryAgent, %{}, [])

    ref = InstanceRef.new(@agent, Subject.new("event-subject"))
    loop = loop_fixture(id: "subscribed-loop")
    matching = Event.new(loop, :completed, agent_id: "agent")
    ignored = Event.new(loop, :progressed, agent_id: "agent")

    assert {:ok, _owner} = Events.subscribe(ref, types: :completed, kinds: :work)
    assert :ok = Events.publish(ref, ignored)
    refute_receive {:spectre, :operation_event, ^ignored}, 25
    assert :ok = Events.publish(ref, matching)
    assert_receive {:spectre, :operation_event, ^matching}, 250
    assert :ok = Events.unsubscribe(ref)
    assert :ok = Events.publish(ref, matching)
    refute_receive {:spectre, :operation_event, ^matching}, 25

    assert {:error, {:instance_reference_unavailable, _reason}} = Events.subscribe(self())
  end

  test "registry, retry, budget and crash monitor keep decisions deterministic" do
    local = spec_fixture(id: :local, executor: {@executors, :one_arity})

    definition =
      Definition.new(
        id: :registry_contract,
        version: 1,
        kind: :work,
        operations: [local],
        imports: [:imported_echo]
      )

    assert {:ok, operations} = Registry.all(@agent, definition)
    assert MapSet.new(Map.keys(operations)) == MapSet.new([:local, :imported_echo])
    assert {:ok, ^local} = Registry.resolve(@agent, definition, :local)

    assert {:error, {:operation_not_registered, :missing}} =
             Registry.resolve(@agent, definition, :missing)

    missing_import = %{definition | imports: [:missing]}

    assert {:error, {:imported_operation_not_registered, :missing}} =
             Registry.all(@agent, missing_import)

    assert {:error, {:operation_agent_not_loaded, _module}} =
             Registry.all(SpectreOperationBoundaryContractTest.MissingAgent, definition)

    constant = Retry.new(max_attempts: 3, strategy: :constant, base_delay_ms: 5, max_delay_ms: 20)
    linear = Retry.new(max_attempts: 4, strategy: :linear, base_delay_ms: 5, max_delay_ms: 20)
    exponential = Retry.new(max_attempts: 5, base_delay_ms: 5, max_delay_ms: 20)
    assert Retry.delay(constant, 3) == 5
    assert Retry.delay(linear, 3) == 15
    assert Retry.delay(exponential, 4) == 20
    assert Retry.retry?(constant, :error, 2)
    refute Retry.retry?(constant, :error, 3)
    refute Retry.retry?(constant, :other, 1)

    assert_raise ArgumentError, fn -> Retry.new(max_attempts: 0) end
    assert_raise ArgumentError, fn -> Retry.new(strategy: :unknown) end
    assert_raise ArgumentError, fn -> Retry.new(base_delay_ms: 10, max_delay_ms: 1) end
    assert_raise ArgumentError, fn -> Retry.new(retry_on: ["error"]) end

    budget =
      Budget.new(
        [steps: 2, attempts: 3, retries: 1, duration_ms: 100, pages: 2, cost: 5],
        1_000
      )

    assert :ok = Budget.validate(budget)
    assert Budget.remaining(budget, :steps) == 2
    assert Budget.remaining(Budget.new(nil, 1_000), :steps) == :infinity

    consumed = Budget.consume(budget, steps: 2, attempts: 1, pages: 1, cost: 2.5)
    assert Budget.exhausted(consumed, 1_050) == {:steps, 2, 2}
    assert Budget.remaining(consumed, :pages) == 1
    assert Budget.remaining(consumed, :cost) == 2.5

    legacy = %{
      budget
      | limits: Map.delete(budget.limits, :pages),
        consumed: Map.delete(budget.consumed, :pages)
    }

    upgraded = Budget.new(legacy, 1_000)
    assert upgraded.limits.pages == nil
    assert upgraded.consumed.pages == 0
    assert Budget.remaining(upgraded, :pages) == :infinity

    duration_only = Budget.new([duration_ms: 10], 1_000)
    assert Budget.exhausted(duration_only, 1_010) == {:duration_ms, 10, 10}
    assert_raise ArgumentError, fn -> Budget.consume(budget, unknown: 1) end
    assert_raise ArgumentError, fn -> Budget.consume(budget, pages: 0.5) end
    assert_raise ArgumentError, fn -> Budget.new([pages: 0.5], 1_000) end

    invalid_budget = [
      {%{budget | limits: []}, :invalid_operational_budget_limits},
      {%{budget | limits: %{steps: 1}}, :invalid_operational_budget_dimensions},
      {%{budget | limits: Map.put(budget.limits, :steps, -1)},
       {:invalid_operational_budget_limit, {:steps, -1}}},
      {%{budget | limits: Map.put(budget.limits, :pages, 0.5)},
       {:invalid_operational_budget_limit, {:pages, 0.5}}},
      {%{budget | consumed: []}, :invalid_operational_budget_consumption},
      {%{budget | started_at: -1}, :invalid_operational_budget_start},
      {%{budget | deadline_at: 999}, :invalid_operational_budget_deadline},
      {%{budget | resources: []}, :invalid_operational_budget_resources}
    ]

    Enum.each(invalid_budget, fn {value, reason} ->
      assert {:error, ^reason} = Budget.validate(value)
    end)

    attempt = attempt_fixture()
    retrying = spec_fixture(retry: constant)
    assert Monitor.classify(attempt, retrying, :timeout) == {:retry, 5}

    assert Monitor.classify(attempt, retrying, :normal) ==
             {:fail, :runner_terminated_without_result}

    reconcilable = %{retrying | side_effect: :reconcilable}

    assert {:reconcile, {:runner_crash, :killed}} =
             Monitor.classify(attempt, reconcilable, :killed)

    non_idempotent = %{retrying | side_effect: :non_idempotent}

    assert {:fail, {:side_effect_outcome_unknown, :operation, :killed}} =
             Monitor.classify(attempt, non_idempotent, :killed)

    exhausted_retry = %{retrying | retry: Retry.new(max_attempts: 1)}

    assert {:fail, {:runner_crashed, :killed}} =
             Monitor.classify(attempt, exhausted_retry, :killed)
  end

  test "delivery authorization covers consent, dedupe, limits, quiet hours and digest" do
    destination = %{channel: :email, address: "person@example.test"}
    loop = loop_fixture(destinations: [destination], authorized_origins: [:chat], origin: :chat)
    event = Event.new(loop, :completed, agent_id: "agent", timestamp: 1_000)

    consent =
      Consent.new(
        id: "consent",
        subject_id: loop.subject_id,
        origin: :chat,
        destination: destination,
        channels: [:email],
        granted_at: 900,
        expires_at: 10_000_000
      )

    base_policy = DeliveryPolicy.new(event_types: [:completed], channels: [:email])

    assert {:error, denied} =
             Delivery.authorize(event, loop, destination, base_policy, [], now: 1_000)

    assert denied.reason == :consent_missing_expired_or_revoked

    assert {:ok, authorized} =
             Delivery.authorize(event, loop, destination, base_policy, [],
               now: 1_000,
               consent: consent,
               receipt_id: "authorized"
             )

    assert authorized.status == :authorized
    assert :ok = Spectre.Operation.Delivery.Receipt.validate(authorized)

    assert {:duplicate, ^authorized} =
             Delivery.authorize(event, loop, destination, base_policy, [authorized],
               now: 1_001,
               consent: consent
             )

    assert {:error, rate_limited} =
             Delivery.authorize(
               event,
               loop,
               destination,
               DeliveryPolicy.new(max_deliveries: 1, window_ms: 1_000),
               [authorized],
               now: 1_001,
               consent: consent,
               dedupe_key: "another"
             )

    assert rate_limited.reason == :delivery_rate_limited

    assert {:ok, deferred} =
             Delivery.authorize(
               event,
               loop,
               destination,
               DeliveryPolicy.new(quiet_hours: {0, 120}, utc_offset_minutes: 0),
               [],
               now: 60 * 60_000,
               consent: consent
             )

    assert deferred.status == :deferred
    assert deferred.not_before == 120 * 60_000

    assert {:ok, digest} =
             Delivery.authorize(
               event,
               loop,
               destination,
               DeliveryPolicy.new(mode: :digest),
               [],
               now: 1_000,
               consent: consent
             )

    assert digest.status == :digest

    unauthorized_destination = %{channel: :email, address: "other@example.test"}

    assert {:error, %{reason: :destination_not_authorized}} =
             Delivery.authorize(event, loop, unauthorized_destination, base_policy, [],
               now: 1_000,
               consent: consent
             )

    wrong_event = %{event | loop_id: "other-loop"}

    assert {:error, %{reason: :event_loop_mismatch}} =
             Delivery.authorize(wrong_event, loop, destination, base_policy, [],
               now: 1_000,
               consent: consent
             )

    assert {:error, %{reason: :event_not_deliverable}} =
             Delivery.authorize(
               %{event | type: :failed},
               loop,
               destination,
               base_policy,
               [],
               now: 1_000,
               consent: consent
             )

    assert {:error, %{reason: :channel_not_authorized}} =
             Delivery.authorize(
               event,
               loop,
               destination,
               DeliveryPolicy.new(channels: [:sms]),
               [],
               now: 1_000,
               consent: consent
             )

    assert {:ok, delivered} = Delivery.delivered(authorized, %{transport: "one"}, 1_100)
    assert delivered.status == :delivered
    assert {:ok, ^delivered} = Delivery.delivered(delivered, %{transport: "one"}, 1_200)

    assert {:ok, failed} = Delivery.failed(authorized, :transport_failed)
    assert failed.status == :failed
    assert {:ok, ^failed} = Delivery.failed(failed, :transport_failed)

    assert {:error, {:invalid_delivery_receipt_transition, :digest, :delivered}} =
             Delivery.delivered(digest, :receipt, 1_100)
  end

  defp spec_fixture(opts) do
    defaults = [
      id: :operation,
      kind: :function,
      executor: {@executors, :one_arity},
      input: :map,
      output: :map,
      timeout: 100,
      side_effect: :none
    ]

    defaults
    |> Keyword.merge(opts)
    |> Spec.new()
  end

  defp attempt_fixture(opts \\ []) do
    defaults = %{
      id: "attempt",
      loop_id: "loop",
      loop_kind: :work,
      operation: :operation,
      request_id: "request",
      number: 1,
      epoch: "epoch",
      fencing_token: "fence",
      base_revision: 1,
      context_revision: 2,
      control_generation: 3,
      trigger_generation: 4,
      snapshot_id: "snapshot",
      idempotency_key: "idempotency",
      started_at: 1_000,
      timeout: 100,
      side_effect: :none,
      retry_number: 0,
      metadata: %{}
    }

    attempt = struct!(Attempt, Map.merge(defaults, Map.new(opts)))
    assert :ok = Attempt.validate(attempt)
    attempt
  end

  defp progress_fixture do
    attempt = attempt_fixture()

    %Progress{
      id: "progress",
      attempt_id: attempt.id,
      loop_id: attempt.loop_id,
      epoch: attempt.epoch,
      fencing_token: attempt.fencing_token,
      context_revision: attempt.context_revision,
      control_generation: attempt.control_generation,
      trigger_generation: attempt.trigger_generation,
      sequence: 1,
      value: %{percent: 50},
      at: 1_001,
      metadata: %{}
    }
  end

  defp execution_context(attempt) do
    %ExecutionContext{
      agent: @agent,
      subject: Subject.new("boundary-subject"),
      loop_id: attempt.loop_id,
      loop_kind: attempt.loop_kind,
      controller: __MODULE__,
      attempt: attempt,
      input: %{},
      state: %{},
      cognitive: %{},
      progress: fn _value, _metadata -> :ok end,
      opts: [],
      metadata: %{}
    }
  end

  defp loop_fixture(opts) do
    defaults = %{
      id: "loop",
      kind: :work,
      controller: __MODULE__,
      controller_id: :boundary_work,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{},
      subject_id: "boundary-subject",
      origin: :chat,
      provenance: %{},
      correlation_id: "correlation",
      created_at: 1_000,
      updated_at: 1_000,
      budget: Budget.new(nil, 1_000),
      authorized_origins: [:chat],
      destinations: []
    }

    struct!(Loop, Map.merge(defaults, Map.new(opts)))
  end
end
