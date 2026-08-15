defmodule Spectre.Instance do
  @moduledoc """
  Subject-scoped OTP owner and fair scheduler for Spectre Runs.

  An Instance is uniquely addressed by `Spectre.AgentRef + Spectre.Subject`.
  It retains every active Run, advances at most one Run move per mailbox
  scheduling message, and returns public calls at the first observable
  boundary. The legacy `Spectre.Session` remains available for
  conversation-scoped 0.1.x integrations.

  Each retained Run owns its Effect and policy lifecycle. Capability
  invocation remains serialized through the Instance state lock so commits,
  compare-and-swap persistence, and idempotency stay deterministic.
  """

  use GenServer

  alias Spectre.AgentRef
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Definition.Resolver, as: DefinitionResolver
  alias Spectre.Definition.Store, as: DefinitionStore
  alias Spectre.Event.Envelope, as: EventEnvelope
  alias Spectre.Event.SchemaRegistry, as: EventSchemaRegistry
  alias Spectre.Effect
  alias Spectre.Execution.Admission, as: ExecutionAdmission
  alias Spectre.Execution.Closure
  alias Spectre.Execution.Materialization, as: ExecutionMaterialization
  alias Spectre.Execution.Runtime, as: DataExecutionRuntime
  alias Spectre.Governance.Verifier, as: GovernanceVerifier
  alias Spectre.Input
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Conversation
  alias Spectre.Instance.Deliveries
  alias Spectre.Instance.Events
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceControl
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.Runs
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.ReceiptRecovery
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Instance.Timers
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt, as: Receipt
  alias Spectre.Inference
  alias Spectre.Inference.Budget
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Event, as: InferenceEvent
  alias Spectre.Inference.Failure, as: InferenceFailure
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Selection, as: InferenceSelection
  alias Spectre.Inference.Stream, as: InferenceStream
  alias Spectre.Inference.StreamCapacity
  alias Spectre.Inference.StreamCheckpoint
  alias Spectre.Inference.Progress, as: InferenceProgress
  alias Spectre.Inference.Usage, as: InferenceUsage
  alias Spectre.Inference.UsageAccounting
  alias Spectre.Inference.Prepared, as: PreparedInference
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Operation.Delivery
  alias Spectre.Operation.Control.Command, as: ControlCommand
  alias Spectre.Operation.Delivery.Consent, as: DeliveryConsent
  alias Spectre.Operation.Delivery.Policy, as: DeliveryPolicy
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Operation.Progress, as: OperationProgress
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Operation.Result, as: OperationResult
  alias Spectre.Operation.Runner
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Operation.Runtime, as: OperationRuntime
  alias Spectre.Operation.View, as: OperationView
  alias Spectre.Result
  alias Spectre.Receipt.Envelope, as: ReceiptEnvelope
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Prompt.Plan, as: PromptPlan
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.StartContinuation
  alias Spectre.Run.Value
  alias Spectre.Runtime
  alias Spectre.Skill.StateBinding
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @default_max_runs 256
  @default_max_tombstones 256
  @default_max_operation_runners 8
  @default_max_stream_sessions 4
  @default_max_receipt_outbox 256
  @max_timer_delay 4_294_967_295
  @default_terminal_loop_retention 256
  @default_correlation_retention 1_024
  @operation_event_limit 512
  @morph_frozen_execution_options [
    :adapter,
    :arbitrator,
    :bag_accept,
    :classifier,
    :classifier_accept,
    :classifier_margin,
    :conflict,
    :embedding,
    :embedding_accept,
    :embedding_margin,
    :input_max_bytes,
    :input_pipeline,
    :jaro_accept,
    :labels,
    :llm_classifier?,
    :model,
    :no_decision,
    :pipeline,
    :policy_global_interrupts?,
    :policy_interrupt_only?,
    :policy_interrupt_via,
    :semantic_cache?,
    :spectre_agent,
    :spectre_rules,
    :turn_handlers,
    :via
  ]

  @type option ::
          {:agent, module()}
          | {:agent_ref, AgentRef.t()}
          | {:subject, Subject.t() | term()}
          | {:state, State.t() | map() | keyword()}
          | {:opts, keyword()}
          | {:registry, atom()}
          | {:state_conversation_id, term()}
          | {:idle, timeout() | false | nil}
          | {:shutdown, timeout() | false | nil}
          | {:max_runs, pos_integer()}
          | {:max_tombstones, non_neg_integer()}
          | {:canonical_checkpoint, String.t() | map()}
          | {:checkpoint_store, CheckpointStore.config()}
          | {:checkpoint_mode, :async | :manual}
          | {:definition_store, DefinitionStore.config()}
          | {:owner, Owner.config()}
          | {:runner_supervisor, GenServer.server()}
          | {:max_operation_runners, pos_integer()}
          | {:max_stream_sessions, pos_integer()}
          | {:stream_registry, atom()}
          | {:stream_capacity, GenServer.server()}
          | {:receipt_mode, :disabled | :observational | :required}
          | {:receipt_sink, ReceiptSink.config()}
          | {:receipt_outbox_limit, pos_integer()}
          | {:operation_terminal_loop_retention, non_neg_integer() | :unlimited}
          | {:operation_correlation_retention, non_neg_integer() | :unlimited}
          | {:event_schema_registry, EventSchemaRegistry.config()}

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    ref = instance_ref!(opts)

    %{
      id: {__MODULE__, ref.key},
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }
  end

  @doc """
  Starts the unique local Instance for an Agent and Subject.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :name) do
      raise ArgumentError,
            "Spectre.Instance is always named by AgentRef + Subject; custom :name is not supported"
    end

    ref = instance_ref!(opts)
    registry = Keyword.get(opts, :registry, InstanceRegistry)
    name = InstanceRegistry.via(ref, registry)

    agent = ref.agent_ref.definition || Keyword.get(opts, :agent)

    if is_nil(agent) do
      raise ArgumentError,
            "Spectre.Instance requires a compiled :agent source for a durable AgentRef"
    end

    opts =
      opts
      |> Keyword.put(:agent, agent)
      |> Keyword.put(:agent_ref, ref.agent_ref)
      |> Keyword.put(:subject, ref.subject)
      |> Keyword.put(:instance_ref, ref)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Handles one input and returns its raw Result at the first boundary.
  """
  @spec ask(GenServer.server(), term(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def ask(server, input, opts \\ []) do
    GenServer.call(server, {:handle, input, opts}, timeout(opts))
  end

  @doc """
  Handles one input and returns its public Turn projection.
  """
  @spec turn(GenServer.server(), term(), keyword()) :: {:ok, Turn.t()} | {:error, term()}
  def turn(server, input, opts \\ []) do
    GenServer.call(server, {:turn, input, opts}, timeout(opts))
  end

  @doc """
  Starts a pull-driven inference Run and returns its one-shot Enumerable.

  The call returns after selection and dispatch intent have been committed;
  the provider is not opened until the Enumerable produces its first demand.
  """
  @spec stream(GenServer.server(), term(), keyword()) ::
          {:ok, InferenceStream.t()} | {:error, term()}
  def stream(server, input, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: GenServer.call(server, {:stream, input, opts}, timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc false
  @spec infer(GenServer.server(), InferenceRequest.t(), keyword()) ::
          {:ok, InferenceResponse.t()} | {:error, term()}
  def infer(server, %InferenceRequest{} = request, opts \\ []) when is_list(opts) do
    GenServer.call(
      server,
      {:cognitive_inference, request, opts},
      Keyword.get(opts, :timeout, :infinity)
    )
  end

  @doc false
  @spec resume_stream(GenServer.server(), InferenceStream.t(), keyword()) ::
          {:ok, InferenceStream.t()} | {:error, term()}
  def resume_stream(server, %InferenceStream{} = stream, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: GenServer.call(server, {:stream_resume, stream, opts}, timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc false
  @spec steer_stream(GenServer.server(), InferenceStream.t(), term(), keyword()) ::
          {:ok, InferenceStream.t()} | {:error, term()}
  def steer_stream(server, %InferenceStream{} = stream, input, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: GenServer.call(server, {:stream_steer, stream, input, opts}, timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc false
  @spec cancel_stream(GenServer.server(), InferenceStream.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def cancel_stream(server, %InferenceStream{} = stream, reason, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: GenServer.call(server, {:stream_cancel, stream, reason, opts}, timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc """
  Resumes an owned Run through a revision-fenced Runtime command.

  Effect execution is dispatched outside the actor and returns through the
  canonical `{:spectre, :invocation_result, invocation_id, receipt}` mailbox
  message before the actor applies the returned Run.
  """
  @spec resume(GenServer.server(), Ref.t(), term(), keyword()) ::
          {:ok, Turn.t()} | {:error, term()}
  def resume(server, %Ref{} = ref, command, opts \\ []) do
    GenServer.call(server, {:instance_resume, ref, command, opts}, timeout(opts))
  end

  @doc """
  Returns a privacy-safe operational view of the Instance scheduler.

  This is a passive monitoring read and does not extend the Instance idle
  lifetime. `trace_id/1` is derived from this projection and is passive too.
  Direct host reads such as state, `ref/1`, `agent/1`, lifecycle, and retained
  records remain activity and re-arm the idle timer.
  """
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :instance_info)

  @doc """
  Returns the logical Instance reference.
  """
  @spec ref(GenServer.server()) :: InstanceRef.t()
  def ref(server), do: GenServer.call(server, :instance_ref)

  @doc "Returns the currently committed Definition Activation, if any."
  @spec activation(GenServer.server()) :: Activation.t() | nil
  def activation(server), do: GenServer.call(server, :instance_activation)

  @doc "Returns the configured Definition Store, if any."
  @spec definition_store(GenServer.server()) :: Spectre.Definition.Store.config() | nil
  def definition_store(server), do: GenServer.call(server, :instance_definition_store)

  @doc "Returns the compiled Agent module this Instance runs."
  @spec agent(GenServer.server()) :: module()
  def agent(server), do: GenServer.call(server, :instance_agent)

  @doc """
  Activates a published bootstrap or approved governed Candidate through generation CAS.

  `:expected_generation` is mandatory and must be `0` for the first
  activation. Candidate, Definition, Manifest, and publication receipt are
  re-read from the configured Definition Store inside the Instance sequencer.
  Governed Candidates additionally replay exact gate and approval evidence.
  """
  @spec activate(GenServer.server(), CandidateRef.t() | String.t(), keyword()) ::
          {:ok, Activation.t()} | {:error, term()}
  def activate(server, candidate_ref, opts \\ []) do
    GenServer.call(server, {:instance_activate, candidate_ref, opts}, timeout(opts))
  end

  @doc "Rolls activation back to an explicitly selected ancestor Candidate."
  @spec rollback(GenServer.server(), CandidateRef.t() | String.t(), keyword()) ::
          {:ok, Activation.t()} | {:error, term()}
  def rollback(server, candidate_ref, opts \\ []) do
    GenServer.call(server, {:instance_rollback, candidate_ref, opts}, timeout(opts))
  end

  @doc "Returns the active or explicitly selected branch for a stable Skill id."
  @spec skill_state(GenServer.server(), atom() | String.t(), keyword()) ::
          {:ok, StateBinding.t()} | {:error, term()}
  def skill_state(server, skill_id, opts \\ []) do
    GenServer.call(server, {:skill_state_fetch, skill_id, opts}, timeout(opts))
  end

  @doc "Lists non-purged Skill-state branches newest-generation first."
  @spec skill_state_branches(GenServer.server(), atom() | String.t(), keyword()) ::
          {:ok, [StateBinding.t()]} | {:error, term()}
  def skill_state_branches(server, skill_id, opts \\ []) do
    GenServer.call(server, {:skill_state_list, skill_id, opts}, timeout(opts))
  end

  @doc "Updates one active Skill-state branch through schema, generation and revision fences."
  @spec update_skill_state(GenServer.server(), atom() | String.t(), term(), keyword()) ::
          {:ok, StateBinding.t()} | {:error, term()}
  def update_skill_state(server, skill_id, value, opts \\ []) do
    GenServer.call(server, {:skill_state_update, skill_id, value, opts}, timeout(opts))
  end

  @doc "Transitions one dormant Skill-state branch through the retention lifecycle."
  @spec transition_skill_state_retention(
          GenServer.server(),
          atom() | String.t(),
          String.t(),
          StateBinding.retention(),
          keyword()
        ) :: {:ok, StateBinding.t()} | {:error, term()}
  def transition_skill_state_retention(server, skill_id, branch_id, retention, opts \\ []) do
    GenServer.call(
      server,
      {:skill_state_retention, skill_id, branch_id, retention, opts},
      timeout(opts)
    )
  end

  @doc """
  Admits an ownership-based Event Envelope on the Instance sequencer.

  The origin is retained as evidence. Replies and progress are owned by their
  continuation's pinned Definition; new input is owned by the active
  Definition. Unresolvable or ambiguous continuations are quarantined.
  """
  @spec admit_event(GenServer.server(), EventEnvelope.t() | map() | keyword(), keyword()) ::
          {:ok, EventEnvelope.t()} | {:error, term()}
  def admit_event(server, event, opts \\ []) do
    GenServer.call(server, {:event_admit, event, opts}, timeout(opts))
  end

  @doc "Returns committed admitted Event Envelopes, newest first."
  @spec admitted_events(GenServer.server(), keyword()) :: [EventEnvelope.t()]
  def admitted_events(server, opts \\ []),
    do: GenServer.call(server, {:event_list, :admitted, opts}, timeout(opts))

  @doc "Returns quarantined Event Envelopes, newest first."
  @spec quarantined_events(GenServer.server(), keyword()) :: [EventEnvelope.t()]
  def quarantined_events(server, opts \\ []),
    do: GenServer.call(server, {:event_list, :quarantined, opts}, timeout(opts))

  @doc "Returns the current lifecycle axes for one Definition or `:active`."
  @spec definition_lifecycle(GenServer.server(), DefinitionRef.t() | String.t() | :active) ::
          {:ok, Lifecycle.t()} | {:error, term()}
  def definition_lifecycle(server, definition_ref \\ :active),
    do: GenServer.call(server, {:definition_lifecycle, definition_ref})

  @doc "Transitions one Definition lifecycle axis through revision CAS."
  @spec transition_definition_lifecycle(
          GenServer.server(),
          DefinitionRef.t() | String.t() | :active,
          Lifecycle.axis(),
          atom(),
          keyword()
        ) :: {:ok, Lifecycle.t()} | {:error, term()}
  def transition_definition_lifecycle(server, definition_ref, axis, value, opts \\ []) do
    GenServer.call(
      server,
      {:definition_lifecycle_transition, definition_ref, axis, value, opts},
      timeout(opts)
    )
  end

  @doc "Moves a Definition to draining: continuations remain admissible, new work does not."
  @spec drain_definition(
          GenServer.server(),
          DefinitionRef.t() | String.t() | :active,
          keyword()
        ) :: {:ok, Lifecycle.t()} | {:error, term()}
  def drain_definition(server, definition_ref \\ :active, opts \\ []),
    do: transition_definition_lifecycle(server, definition_ref, :admission, :draining, opts)

  @doc "Revokes current Definition authority and advances its authority epoch."
  @spec revoke_definition(
          GenServer.server(),
          DefinitionRef.t() | String.t() | :active,
          keyword()
        ) :: {:ok, Lifecycle.t()} | {:error, term()}
  def revoke_definition(server, definition_ref \\ :active, opts \\ []),
    do: transition_definition_lifecycle(server, definition_ref, :authority, :revoked, opts)

  @doc """
  Returns the Instance's trace identifier.

  One trace spans one Instance generation: a new id is minted whenever the
  agent process (re)starts, which matches journal session semantics. Returns
  `{:error, reason}` instead of raising when the Instance is unreachable, so
  hosts can fall back to their own identifier.

      {:ok, trace_id} = Spectre.Instance.trace_id(instance)
  """
  @spec trace_id(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def trace_id(server) do
    case info(server) do
      %{generation: generation} when is_binary(generation) -> {:ok, generation}
      other -> {:error, {:invalid_instance_info, other}}
    end
  catch
    :exit, reason -> {:error, {:instance_unreachable, reason}}
  end

  @doc """
  Returns a compact view of one retained Run or tombstone.
  """
  @spec run(GenServer.server(), String.t() | Ref.t()) :: {:ok, map()} | {:error, term()}
  def run(server, %Ref{run_id: run_id}), do: run(server, run_id)
  def run(server, run_id), do: GenServer.call(server, {:instance_run, run_id})

  @doc """
  Starts a precise Work owned by this Agent Instance.

  This is a host boundary. Operational Runners and their isolated executor
  processes cannot call it; a Directive starts Work through a declared
  Agent-side reducer intent.
  """
  @spec start_work(GenServer.server(), module(), term(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def start_work(server, controller, input, opts \\ []) when is_atom(controller) do
    call_opts = Keyword.put(opts, :__spectre_callers__, operation_callers())
    GenServer.call(server, {:operation_start, :work, controller, input, call_opts}, timeout(opts))
  end

  @doc "Starts a verified data-driven Work on the shared operational runtime."
  @spec start_execution(GenServer.server(), ExecutionMaterialization.t(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def start_execution(server, materialization, opts \\ [])

  def start_execution(server, %ExecutionMaterialization{} = materialization, opts)
      when is_list(opts) do
    if Keyword.keyword?(opts) do
      start_execution_call(server, materialization, opts)
    else
      {:error, :invalid_data_driven_execution_options}
    end
  end

  def start_execution(_server, materialization, opts),
    do:
      {:error,
       {:invalid_data_driven_execution_start, execution_shape(materialization),
        execution_shape(opts)}}

  defp start_execution_call(server, materialization, opts) do
    call_opts = Keyword.put(opts, :__spectre_callers__, operation_callers())

    GenServer.call(
      server,
      {:execution_start, materialization, call_opts},
      timeout(opts)
    )
  end

  @doc "Registers a durable Vigil owned by this Agent Instance."
  @spec register_vigil(GenServer.server(), module(), term(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def register_vigil(server, controller, input, opts \\ []) when is_atom(controller) do
    call_opts = Keyword.put(opts, :__spectre_callers__, operation_callers())

    GenServer.call(
      server,
      {:operation_start, :vigil, controller, input, call_opts},
      timeout(opts)
    )
  end

  @doc "Starts a library-owned controller on the shared operational runtime."
  @spec start_controller(GenServer.server(), module(), term(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def start_controller(server, controller, input, opts \\ []) when is_atom(controller) do
    call_opts = Keyword.put(opts, :__spectre_callers__, operation_callers())

    GenServer.call(
      server,
      {:operation_start, :directive, controller, input, call_opts},
      timeout(opts)
    )
  end

  @doc "Returns a committed read-only view of one operational loop."
  @spec loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def loop(server, loop, opts \\ []) do
    GenServer.call(server, {:operation_view, Loops.operation_id(loop), opts}, timeout(opts))
  end

  @doc "Lists committed Work, Vigil and controller views visible to the caller."
  @spec loops(GenServer.server(), keyword()) :: {:ok, [OperationView.t()]} | {:error, term()}
  def loops(server, opts \\ []) do
    GenServer.call(server, {:operation_views, opts}, timeout(opts))
  end

  @doc "Resolves exactly one visible loop or returns an explicit ambiguity."
  @spec resolve_loop(
          GenServer.server(),
          OperationRef.t() | String.t() | map() | keyword() | nil,
          keyword()
        ) ::
          {:ok, OperationView.t()} | {:error, term()}
  def resolve_loop(server, selector \\ nil, opts \\ []) do
    GenServer.call(server, {:operation_resolve, selector, opts}, timeout(opts))
  end

  @doc "Requests a reversible pause, at a safe boundary by default."
  @spec pause_loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def pause_loop(server, loop, opts \\ []),
    do: control_loop(server, loop, :pause, nil, opts)

  @doc "Commits an update through the controller's deterministic reducer."
  @spec update_loop(GenServer.server(), OperationRef.t() | String.t(), term(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def update_loop(server, loop, update, opts \\ []),
    do: control_loop(server, loop, :update, update, opts)

  @doc "Pauses, updates and resumes a loop as one durable correlated intention."
  @spec update_and_resume_loop(
          GenServer.server(),
          OperationRef.t() | String.t(),
          term(),
          keyword()
        ) :: {:ok, OperationView.t()} | {:error, term()}
  def update_and_resume_loop(server, loop, update, opts \\ []),
    do: control_loop(server, loop, :update_and_resume, update, opts)

  @doc "Resumes a reversibly paused operational loop."
  @spec resume_loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def resume_loop(server, loop, opts \\ []),
    do: control_loop(server, loop, :resume, nil, opts)

  @doc "Renews the declared expiry of a nonterminal loop."
  @spec renew_loop(
          GenServer.server(),
          OperationRef.t() | String.t(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, OperationView.t()} | {:error, term()}
  def renew_loop(server, loop, expires_at, opts \\ []),
    do: control_loop(server, loop, :renew, %{expires_at: expires_at}, opts)

  @doc "Stops an operational loop terminally; it cannot be resumed."
  @spec stop_loop(GenServer.server(), OperationRef.t() | String.t(), term(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def stop_loop(server, loop, reason \\ :stopped, opts \\ []),
    do: control_loop(server, loop, :stop, reason, opts)

  @doc """
  Delivers a declared timer/event/human trigger to a waiting loop.

  Echo `view.wait_ref.id` as `:wait_id` and `view.wait_ref.generation` as
  `:generation`. Definitions using strict trigger correlation require both.
  """
  @spec trigger_loop(GenServer.server(), OperationRef.t() | String.t(), term(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def trigger_loop(server, loop, trigger, opts \\ []) do
    GenServer.call(
      server,
      {:operation_trigger, Loops.operation_id(loop), trigger, opts},
      timeout(opts)
    )
  end

  @doc "Encodes the complete canonical Agent checkpoint as strict JSON."
  @spec checkpoint(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def checkpoint(server), do: GenServer.call(server, :canonical_checkpoint)

  @doc "Waits until the current canonical revision is durably checkpointed."
  @spec flush_checkpoint(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def flush_checkpoint(server, opts \\ []) do
    GenServer.call(server, :flush_canonical_checkpoint, timeout(opts))
  end

  @doc """
  Returns the redacted status of canonical checkpoint persistence.

  This is a passive monitoring read and does not extend the Instance idle
  lifetime.
  """
  @spec checkpoint_status(GenServer.server()) :: map()
  def checkpoint_status(server), do: GenServer.call(server, :canonical_checkpoint_status)

  @doc "Explicitly reconciles a checkpoint write whose commit outcome was ambiguous."
  @spec reconcile_checkpoint(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_checkpoint(server, opts \\ []) do
    GenServer.call(server, :reconcile_canonical_checkpoint, timeout(opts))
  end

  @doc "Returns committed operational events without turning them into notifications."
  @spec operation_events(GenServer.server(), keyword()) :: [OperationEvent.t()]
  def operation_events(server, opts \\ []) do
    GenServer.call(server, {:operation_events, opts})
  end

  @doc "Stores revocable proactive-delivery consent for this Subject."
  @spec put_delivery_consent(
          GenServer.server(),
          DeliveryConsent.t() | map() | keyword(),
          keyword()
        ) ::
          {:ok, DeliveryConsent.t()} | {:error, term()}
  def put_delivery_consent(server, consent, opts \\ []) do
    GenServer.call(server, {:delivery_consent_put, consent, opts}, timeout(opts))
  end

  @doc "Revokes previously stored proactive-delivery consent."
  @spec revoke_delivery_consent(GenServer.server(), String.t(), keyword()) ::
          {:ok, DeliveryConsent.t()} | {:error, term()}
  def revoke_delivery_consent(server, consent_id, opts \\ []) do
    GenServer.call(server, {:delivery_consent_revoke, consent_id, opts}, timeout(opts))
  end

  @doc "Authorizes, defers, digests or denies delivery without sending it."
  @spec authorize_delivery(
          GenServer.server(),
          String.t(),
          term(),
          DeliveryPolicy.t() | map() | keyword(),
          keyword()
        ) ::
          {:ok, DeliveryReceipt.t()} | {:error, term()}
  def authorize_delivery(server, event_id, destination, policy, opts \\ []) do
    GenServer.call(
      server,
      {:delivery_authorize, event_id, destination, policy, opts},
      timeout(opts)
    )
  end

  @doc "Re-authorizes a deferred/digest receipt or records its transport outcome."
  @spec record_delivery(
          GenServer.server(),
          String.t(),
          :authorized | :delivered | :failed,
          term(),
          keyword()
        ) ::
          {:ok, DeliveryReceipt.t()} | {:error, term()}
  def record_delivery(server, receipt_id, outcome, detail, opts \\ []) do
    GenServer.call(
      server,
      {:delivery_record, receipt_id, outcome, detail, opts},
      timeout(opts)
    )
  end

  @doc "Returns redacted committed delivery receipts."
  @spec delivery_receipts(GenServer.server(), keyword()) :: [DeliveryReceipt.t()]
  def delivery_receipts(server, opts \\ []) do
    GenServer.call(server, {:delivery_receipts, opts}, timeout(opts))
  end

  @doc false
  @spec operation_event_limit() :: pos_integer()
  def operation_event_limit, do: @operation_event_limit

  # Canonical checkpoints are decoded with String.to_existing_atom/1 under the
  # contract that loading this producer module registers every atom the commit
  # machinery writes (see the 0.2.0 compatibility fixture). The writes now live
  # in Instance.Commit, Instance.Deliveries and Instance.Checkpoint, so their
  # metadata, provenance and event vocabulary must stay literal here.
  @doc false
  @spec canonical_vocabulary() :: [atom()]
  def canonical_vocabulary do
    [
      :transition,
      :loop_id,
      :loop_ids,
      :loop_kind,
      :revision,
      :causation_id,
      :source,
      :run_id,
      :flow,
      :flow_state_committed,
      :operational_transition,
      :instance_key,
      :owner_fencing_token,
      :records,
      :ids,
      :delivery_decision,
      :delivery_policy,
      :receipt_id,
      :consent_id,
      :delivery_authorized,
      :delivery_deferred,
      :delivery_digest_queued,
      :delivery_denied,
      :delivery_recorded,
      :delivery_failed,
      :authorized,
      :deferred,
      :digest,
      :denied,
      :delivered,
      :failed,
      :status,
      :reason,
      :state_persistence,
      :conversation_ref,
      :origin_conversation_ref,
      :receipt_kind,
      :receipt_id,
      :receipted_run_state_committed,
      :receipt_delivery_acknowledged,
      :receipt,
      :receipt_delivery,
      :inference_control,
      :inference_progress,
      :receipt_outbox,
      :inference_steer_committed,
      :inference_steer_applied,
      :inference_steer_rejected,
      :inference_cancel_applied,
      :inference_progress_committed,
      :stream_control,
      :steering,
      :steering_restart,
      :target_kind
    ]
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    agent = Keyword.fetch!(opts, :agent)
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    subject = Keyword.fetch!(opts, :subject)
    instance_ref = Keyword.fetch!(opts, :instance_ref)
    registry = Keyword.get(opts, :registry, InstanceRegistry)

    with {:ok, max_runs} <-
           positive_integer(Keyword.get(opts, :max_runs, @default_max_runs), :max_runs),
         {:ok, max_tombstones} <-
           non_negative_integer(Keyword.get(opts, :max_tombstones, @default_max_tombstones)),
         {:ok, max_operation_runners} <-
           positive_integer(
             Keyword.get(opts, :max_operation_runners, @default_max_operation_runners),
             :max_operation_runners
           ),
         {:ok, max_stream_sessions} <-
           positive_integer(
             Keyword.get(opts, :max_stream_sessions, @default_max_stream_sessions),
             :max_stream_sessions
           ),
         base_opts <- base_opts(opts, instance_ref),
         {:ok, terminal_loop_retention} <-
           instance_retention(
             first_configured([
               {opts, :operation_terminal_loop_retention},
               {base_opts, :operation_terminal_loop_retention}
             ]),
             :operation_terminal_loop_retention,
             @default_terminal_loop_retention
           ),
         {:ok, correlation_retention} <-
           instance_retention(
             first_configured([
               {opts, :operation_correlation_retention},
               {base_opts, :operation_correlation_retention}
             ]),
             :operation_correlation_retention,
             @default_correlation_retention
           ),
         base_opts <-
           base_opts
           |> Keyword.put(:operation_terminal_loop_retention, terminal_loop_retention)
           |> Keyword.put(:operation_correlation_retention, correlation_retention),
         {:ok, base_opts} <- normalize_inference_observer_config(opts, base_opts),
         {:ok, checkpoint_store} <- Checkpoint.store_config(agent, opts, base_opts),
         {:ok, checkpoint_mode} <- Checkpoint.mode(opts, checkpoint_store),
         {:ok, receipt_mode} <- receipt_mode(opts, base_opts),
         {:ok, receipt_sink} <- receipt_sink(opts, base_opts),
         {:ok, max_receipt_outbox} <-
           positive_integer(
             first_configured([
               {opts, :receipt_outbox_limit},
               {base_opts, :receipt_outbox_limit}
             ]) || @default_max_receipt_outbox,
             :receipt_outbox_limit
           ),
         base_opts <- Keyword.put(base_opts, :receipt_outbox_limit, max_receipt_outbox),
         :ok <- validate_receipt_configuration(receipt_mode, receipt_sink, checkpoint_store),
         {:ok, definition_store} <- definition_store_config(agent, opts, base_opts),
         :ok <- validate_definition_store_pair(checkpoint_store, definition_store),
         {:ok, state} <- restore_initial_state(agent, opts, base_opts),
         {:ok, state, canonical, checkpoint_revision} <-
           Checkpoint.restore_canonical(opts, state, checkpoint_store, base_opts),
         {:ok, activation} <-
           restore_activation(canonical, definition_store, checkpoint_store, base_opts),
         {:ok, restored_runs} <-
           restore_runs(canonical, definition_store, checkpoint_store, base_opts, max_runs),
         {:ok, registry_monitor} <- monitor_registry(registry, instance_ref),
         fencing_floor <- persisted_owner_fencing_floor(activation, canonical),
         {:ok, owner, owner_lease} <-
           Owner.claim(
             owner_config(agent, opts, base_opts),
             instance_ref,
             Keyword.put(base_opts, :minimum_fencing_token, fencing_floor)
           ) do
      data = %InstanceState{
        agent: agent,
        agent_ref: agent_ref,
        subject: subject,
        ref: instance_ref,
        state: state,
        canonical: canonical,
        activation: activation,
        definition_store: definition_store,
        owner: owner,
        owner_lease: owner_lease,
        runs: restored_runs,
        completed: restored_completed_queue(restored_runs),
        terminal_recorded: restored_terminal_ids(restored_runs),
        base_opts: base_opts,
        idle_timeout: idle_timeout(agent, opts, base_opts),
        max_runs: max_runs,
        max_tombstones: max_tombstones,
        max_operation_runners: max_operation_runners,
        max_stream_sessions: max_stream_sessions,
        stream_registry: Keyword.get(opts, :stream_registry, Spectre.Inference.StreamRegistry),
        stream_capacity: Keyword.get(opts, :stream_capacity, StreamCapacity),
        generation: Spectre.Identity.uuid7(),
        runner_supervisor: Keyword.get(opts, :runner_supervisor, RunnerSupervisor),
        checkpoint_store: checkpoint_store,
        checkpoint_mode: checkpoint_mode,
        receipt_mode: receipt_mode,
        receipt_sink: receipt_sink,
        max_receipt_outbox: max_receipt_outbox,
        receipt_recovery_deferred: required_receipt_recovery_pending?(receipt_mode, canonical),
        checkpoint_revision: checkpoint_revision,
        checkpoint_persisted:
          if(checkpoint_revision == canonical.revision, do: canonical, else: nil),
        registry: registry,
        registry_monitor: registry_monitor
      }

      case recover_runtime_state(data) do
        {:ok, data} ->
          emit(:started, data, %{count: 1})

          {:ok,
           data
           |> Timers.schedule_restored()
           |> maybe_schedule()
           |> maybe_schedule_operations()
           |> maybe_start_receipt_deliveries()
           |> arm_idle_timer()}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:handle, input, opts}, from, data) do
    submit(input, opts, :result, from, data)
  end

  def handle_call({:turn, input, opts}, from, data) do
    submit(input, opts, :turn, from, data)
  end

  def handle_call({:stream, input, opts}, from, data) do
    submit(input, Keyword.put(opts, :streaming?, true), :stream, from, data)
  end

  def handle_call({:cognitive_inference, request, opts}, from, data) do
    submit_cognitive_inference(request, opts, from, data)
  end

  def handle_call({:stream_resume, stream, _opts}, from, data) do
    case resume_inference_stream(data, stream, from) do
      {:reply, reply, next} -> {:reply, reply, arm_idle_timer(next)}
      {:noreply, next} -> {:noreply, disarm_idle_timer(next)}
    end
  end

  def handle_call({:stream_steer, stream, input, opts}, from, data) do
    case steer_inference_stream(data, stream, input, opts, from) do
      {:ok, next} -> {:noreply, next}
      {:error, reason, next} -> {:reply, {:error, reason}, arm_idle_timer(next)}
    end
  end

  def handle_call({:stream_cancel, stream, reason, opts}, _from, data) do
    case cancel_inference_stream(data, stream, reason, opts) do
      {:ok, next} ->
        {:reply, :ok, arm_idle_timer(next)}

      {:error, :invocation_terminal, next} ->
        {:reply, :ok, arm_idle_timer(next)}

      {:error, cancel_reason, next} ->
        {:reply, {:error, cancel_reason}, arm_idle_timer(next)}
    end
  end

  def handle_call(
        {:instance_resume, %Ref{} = supplied_ref, command, opts},
        from,
        data
      ) do
    case morph_turn_options(data, opts) do
      :ok -> handle_instance_resume(supplied_ref, command, opts, from, data)
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  # Compatibility with Spectre.Session and Spectre.Turn.resolve_policy/3.
  def handle_call({:resolve_policy, %Result{} = supplied, resolution, opts}, from, data) do
    with :ok <- morph_turn_options(data, opts),
         {:ok, run} <- Runs.owned_result_run(data, supplied),
         :ok <- Events.authorize(data, run.definition_ref, :continuation),
         false <- run_active?(data, run.id),
         %Boundary{kind: :needs, ref: boundary_ref} <- run.waiting do
      entry = %{
        run_id: run.id,
        operation: {:resume, {:policy, boundary_ref, resolution}},
        projection: :result,
        input: run.input,
        opts: runtime_opts(data, opts, run.input),
        state_revision: data.state.revision,
        internal?: false
      }

      {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
    else
      true -> {:reply, {:error, :run_already_active}, arm_idle_timer(data)}
      nil -> {:reply, {:error, :run_not_waiting_for_policy}, arm_idle_timer(data)}
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
      _other -> {:reply, {:error, :run_not_waiting_for_policy}, arm_idle_timer(data)}
    end
  end

  # Compatibility with Spectre.execute/3 for a live Instance.
  def handle_call({:execute, %Result{} = supplied, opts}, from, data) do
    case morph_turn_options(data, opts) do
      :ok -> handle_instance_execute(supplied, opts, from, data)
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:state, _from, data), do: {:reply, data.state, arm_idle_timer(data)}
  def handle_call(:agent, _from, data), do: {:reply, data.agent, arm_idle_timer(data)}
  def handle_call(:instance_ref, _from, data), do: {:reply, data.ref, arm_idle_timer(data)}

  def handle_call(:instance_activation, _from, data),
    do: {:reply, data.activation, arm_idle_timer(data)}

  def handle_call(:instance_definition_store, _from, data),
    do: {:reply, data.definition_store, arm_idle_timer(data)}

  def handle_call(:instance_agent, _from, data),
    do: {:reply, data.agent, arm_idle_timer(data)}

  def handle_call({:skill_state_fetch, skill_id, opts}, _from, data) do
    {:reply, SkillStates.fetch(data, skill_id, opts), arm_idle_timer(data)}
  end

  def handle_call({:skill_state_list, skill_id, opts}, _from, data) do
    {:reply, SkillStates.list(data, skill_id, opts), arm_idle_timer(data)}
  end

  def handle_call({:skill_state_update, skill_id, value, opts}, _from, data) do
    with :ok <- owner_guard(data, :commit),
         {:ok, binding, next} <- SkillStates.update(data, skill_id, value, opts) do
      {:reply, {:ok, binding}, arm_idle_timer(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(
        {:skill_state_retention, skill_id, branch_id, retention, opts},
        _from,
        data
      ) do
    with :ok <- owner_guard(data, :commit),
         {:ok, binding, next} <-
           SkillStates.transition_retention(data, skill_id, branch_id, retention, opts) do
      {:reply, {:ok, binding}, arm_idle_timer(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:instance_activate, candidate_ref, opts}, _from, data) do
    with {:ok, expected_generation} <- activation_expected_generation(opts),
         :ok <- owner_guard(data, :activation_commit),
         {:ok, definition_store} <- require_definition_store(data.definition_store),
         {:ok, candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             candidate_ref,
             activation_resolver_opts(data, opts)
           ),
         :ok <-
           GovernanceVerifier.verify_activation(
             definition_store,
             candidate_resolution,
             data.activation,
             activation_resolver_opts(data, opts)
           ),
         {:ok, prospective, skill_states} <-
           build_activation(data, candidate_resolution, expected_generation, opts),
         {:ok, activation} <-
           Activation.compare_and_swap(data.activation, expected_generation, prospective),
         {:ok, next} <- commit_activation(data, activation, skill_states) do
      {:reply, {:ok, activation}, arm_idle_timer(next)}
    else
      :not_found ->
        {:reply, {:error, :activation_candidate_not_found}, arm_idle_timer(data)}

      {:error, {:ambiguous, _detail} = reason} ->
        {:stop, {:activation_checkpoint_outcome_unknown, reason}, {:error, reason}, data}

      {:error, reason} when reason in [:conflict, :stale] ->
        {:stop, {:activation_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, {kind, _expected, _current} = reason} when kind in [:conflict, :stale] ->
        {:stop, {:activation_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:instance_rollback, candidate_ref, opts}, _from, data) do
    with {:ok, expected_generation} <- activation_expected_generation(opts),
         :ok <- owner_guard(data, :activation_commit),
         {:ok, definition_store} <- require_definition_store(data.definition_store),
         {:ok, candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             candidate_ref,
             activation_resolver_opts(data, opts)
           ),
         :ok <-
           GovernanceVerifier.verify_rollback(
             definition_store,
             candidate_resolution,
             data.activation,
             activation_resolver_opts(data, opts)
           ),
         rollback_opts =
           Keyword.put(
             opts,
             :provenance,
             %{source: :rollback, instance_ref: data.ref.key, external_effects_rolled_back: false}
           ),
         {:ok, prospective, skill_states} <-
           build_activation(data, candidate_resolution, expected_generation, rollback_opts),
         {:ok, activation} <-
           Activation.compare_and_swap(data.activation, expected_generation, prospective),
         {:ok, next} <- commit_activation(data, activation, skill_states) do
      {:reply, {:ok, activation}, arm_idle_timer(next)}
    else
      :not_found ->
        {:reply, {:error, :rollback_candidate_not_found}, arm_idle_timer(data)}

      {:error, {:ambiguous, _detail} = reason} ->
        {:stop, {:rollback_checkpoint_outcome_unknown, reason}, {:error, reason}, data}

      {:error, reason} when reason in [:conflict, :stale] ->
        {:stop, {:rollback_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, {kind, _expected, _current} = reason} when kind in [:conflict, :stale] ->
        {:stop, {:rollback_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:event_admit, event, opts}, _from, data) do
    with :ok <- owner_guard(data, :admission),
         {:ok, envelope, next} <- Events.admit(data, event, opts) do
      {:reply, {:ok, envelope}, arm_idle_timer(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:event_list, status, opts}, _from, data)
      when status in [:admitted, :quarantined] do
    {:reply, Events.list(data, status, opts), arm_idle_timer(data)}
  end

  def handle_call({:definition_lifecycle, value}, _from, data) do
    reply =
      with {:ok, definition_ref} <- resolve_definition_ref(data, value) do
        {:ok, Events.lifecycle(data, definition_ref)}
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call(
        {:definition_lifecycle_transition, value, axis, status, opts},
        from,
        data
      ) do
    with :ok <- owner_guard(data, :commit),
         {:ok, definition_ref} <- resolve_definition_ref(data, value),
         {:ok, lifecycle, writes, commit_opts} <-
           Events.prepare_lifecycle_transition(data, definition_ref, axis, status, opts),
         {:ok, prepared} <-
           prepare_authority_decision_receipt(
             data,
             definition_ref,
             axis,
             status,
             lifecycle,
             writes,
             commit_opts
           ) do
      next =
        commit_or_stage_sections_receipt(
          data,
          {:authority_decision, from, lifecycle},
          prepared
        )

      {:noreply, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:instance_info, _from, data) do
    {:reply, info_projection(data), data}
  end

  def handle_call({:instance_run, run_id}, _from, data) do
    reply =
      case Map.get(data.runs, run_id) do
        %Run{} = run ->
          {:ok, Runs.run_projection(run)}

        nil ->
          case Map.fetch(data.tombstones, run_id) do
            {:ok, tombstone} -> {:ok, tombstone}
            :error -> {:error, :instance_run_not_found}
          end
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call({:operation_start, kind, controller, input, opts}, from, data) do
    caller = elem(from, 0)
    callers = Enum.uniq([caller | Keyword.get(opts, :__spectre_callers__, [])])
    opts = Keyword.delete(opts, :__spectre_callers__)

    active_definition_ref = Events.active_definition_ref(data)

    if nested_work?(data, callers, kind) do
      {:reply, {:error, :work_cannot_start_work}, arm_idle_timer(data)}
    else
      with :ok <- Events.authorize(data, active_definition_ref, :new_admission),
           env <- Loops.operation_env(data),
           {:ok, loop, control, event_specs} <-
             OperationRuntime.start(kind, controller, input, opts, env) do
        case Loops.operation_loop(data, loop.id) do
          {:ok, existing, existing_control} ->
            if Loops.same_loop_request?(existing, loop) do
              view = OperationView.from_loop(existing, existing_control)
              {:reply, {:ok, OperationRef.from_loop(existing), view}, arm_idle_timer(data)}
            else
              {:reply, {:error, {:duplicate_operational_loop, loop.id}}, arm_idle_timer(data)}
            end

          {:error, :operation_loop_not_found} ->
            case commit_operational(data, loop, control, event_specs,
                   correlation_id: loop.correlation_id,
                   provenance: loop.provenance,
                   transition: :loop_started
                 ) do
              {:ok, next, _events} ->
                next = next |> queue_operation(loop) |> maybe_schedule_operations()
                view = OperationView.from_loop(loop, control)
                {:reply, {:ok, OperationRef.from_loop(loop), view}, disarm_idle_timer(next)}

              {:error, reason} ->
                {:reply, {:error, reason}, arm_idle_timer(data)}
            end
        end
      else
        {:error, reason} ->
          {:reply, {:error, reason}, arm_idle_timer(data)}
      end
    end
  end

  def handle_call(
        {:execution_start, %ExecutionMaterialization{} = materialization, opts},
        from,
        data
      ) do
    caller = elem(from, 0)
    callers = Enum.uniq([caller | Keyword.get(opts, :__spectre_callers__, [])])
    opts = Keyword.delete(opts, :__spectre_callers__)
    active_definition_ref = Events.active_definition_ref(data)

    if nested_work?(data, callers, :work) do
      {:reply, {:error, :work_cannot_start_work}, arm_idle_timer(data)}
    else
      with :ok <- Events.authorize(data, active_definition_ref, :new_admission),
           :ok <-
             ExecutionAdmission.verify(
               materialization,
               data.definition_store,
               data.activation,
               data.base_opts
             ),
           env <- Loops.operation_env(data),
           {:ok, loop, control, event_specs} <-
             DataExecutionRuntime.start(materialization, opts, env) do
        case Loops.operation_loop(data, loop.id) do
          {:ok, existing, existing_control} ->
            if Loops.same_loop_request?(existing, loop) do
              view = OperationView.from_loop(existing, existing_control)
              {:reply, {:ok, OperationRef.from_loop(existing), view}, arm_idle_timer(data)}
            else
              {:reply, {:error, {:duplicate_operational_loop, loop.id}}, arm_idle_timer(data)}
            end

          {:error, :operation_loop_not_found} ->
            case commit_operational(data, loop, control, event_specs,
                   correlation_id: loop.correlation_id,
                   provenance: loop.provenance,
                   transition: :data_driven_work_started
                 ) do
              {:ok, next, _events} ->
                next = next |> queue_operation(loop) |> maybe_schedule_operations()
                view = OperationView.from_loop(loop, control)
                {:reply, {:ok, OperationRef.from_loop(loop), view}, disarm_idle_timer(next)}

              {:error, reason} ->
                {:reply, {:error, reason}, arm_idle_timer(data)}
            end
        end
      else
        {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
      end
    end
  end

  def handle_call({:operation_view, loop_id, opts}, _from, data) do
    reply =
      with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
           :ok <- Loops.authorize_loop(loop, opts) do
        {:ok, OperationView.from_loop(loop, control)}
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call({:operation_views, opts}, _from, data) do
    views =
      data
      |> Loops.all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, Loops.authorize_loop(loop, opts)) and Loops.loop_filter?(loop, opts)
      end)
      |> Enum.map(fn {loop, control} -> OperationView.from_loop(loop, control) end)

    {:reply, {:ok, views}, arm_idle_timer(data)}
  end

  def handle_call({:operation_resolve, selector, opts}, _from, data) do
    matches =
      data
      |> Loops.all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, Loops.authorize_loop(loop, opts)) and Loops.selector_matches?(loop, selector)
      end)

    reply =
      case matches do
        [{loop, control}] ->
          {:ok, OperationView.from_loop(loop, control)}

        [] ->
          {:error, :operation_loop_not_found}

        many ->
          candidates =
            Enum.map(many, fn {loop, control} ->
              view = OperationView.from_loop(loop, control)
              Map.take(view, [:id, :kind, :definition, :status, :phase, :updated_at])
            end)

          {:error, {:ambiguous_operation_loops, candidates}}
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call({:operation_control, loop_id, action, payload, opts}, _from, data) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, command} <- Loops.control_command(loop, action, payload, opts),
         result <-
           OperationRuntime.request_control(loop, control, command, Loops.operation_env(data)) do
      case result do
        {:duplicate, duplicate_loop, duplicate_control} ->
          {:reply, {:ok, OperationView.from_loop(duplicate_loop, duplicate_control)},
           arm_idle_timer(data)}

        {:ok, next_loop, next_control, pid_action, event_specs} ->
          case commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: command.correlation_id,
                 causation_id: command.causation_id,
                 provenance: command.provenance,
                 transition: {:loop_control, action}
               ) do
            {:ok, next, committed_events} ->
              next =
                next
                |> maybe_emit_uncorrelated_operation_trigger(committed_events)
                |> apply_runner_action(pid_action)
                |> maybe_queue_after_transition(next_loop, next_control)
                |> Timers.maybe_schedule_wait_timer(next_loop)
                |> maybe_schedule_operations()

              {:reply, {:ok, OperationView.from_loop(next_loop, next_control)}, next}

            {:error, reason} ->
              {:reply, {:error, reason}, data}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, data}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:operation_trigger, loop_id, trigger, opts}, _from, data) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, operation_definition_ref} <- Events.operation_definition_ref(data, loop),
         :ok <- Events.authorize(data, operation_definition_ref, :continuation),
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.trigger(loop, control, trigger, opts, Loops.operation_env(data)),
         {:ok, next, committed_events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
             causation_id: Keyword.get(opts, :causation_id),
             provenance: Keyword.get(opts, :provenance, %{}),
             transition: :loop_triggered
           ) do
      next =
        next
        |> maybe_emit_uncorrelated_operation_trigger(committed_events)
        |> Timers.maybe_schedule_wait_timer(next_loop)
        |> queue_operation(next_loop)
        |> maybe_schedule_operations()

      {:reply, {:ok, OperationView.from_loop(next_loop, next_control)}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:canonical_checkpoint, _from, data) do
    {:reply, CanonicalCodec.encode_json(data.canonical), arm_idle_timer(data)}
  end

  def handle_call(:canonical_checkpoint_status, _from, data) do
    status = %{
      mode: data.checkpoint_mode,
      configured: not is_nil(data.checkpoint_store),
      canonical_revision: data.canonical.revision,
      persisted_revision: data.checkpoint_revision,
      inflight_revision: data.checkpoint_inflight && data.checkpoint_inflight.revision,
      pending_revision: data.checkpoint_pending && data.checkpoint_pending.revision,
      error: checkpoint_error_class(data.checkpoint_error),
      reconciliation_required: Checkpoint.reconciliation_status(data.checkpoint_reconciliation)
    }

    {:reply, status, data}
  end

  def handle_call(:flush_canonical_checkpoint, from, data) do
    cond do
      is_nil(data.checkpoint_store) ->
        {:reply, {:error, :checkpoint_store_not_configured}, arm_idle_timer(data)}

      data.checkpoint_revision >= data.canonical.revision ->
        {:reply, {:ok, data.checkpoint_revision}, arm_idle_timer(data)}

      not is_nil(data.checkpoint_reconciliation) ->
        {:reply, {:error, Checkpoint.reconciliation_error(data)}, arm_idle_timer(data)}

      true ->
        target = data.canonical.revision
        next = %{data | checkpoint_waiters: [{from, target} | data.checkpoint_waiters]}
        {:noreply, Checkpoint.force(next)}
    end
  end

  def handle_call(:reconcile_canonical_checkpoint, from, data) do
    cond do
      is_nil(data.checkpoint_store) ->
        {:reply, {:error, :checkpoint_store_not_configured}, arm_idle_timer(data)}

      is_nil(data.checkpoint_reconciliation) ->
        {:reply, {:ok, data.checkpoint_revision}, arm_idle_timer(data)}

      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight) ->
        {:reply, {:error, :checkpoint_operation_in_progress}, arm_idle_timer(data)}

      true ->
        {:noreply, Checkpoint.start_reconciliation(data, from)}
    end
  end

  def handle_call({:operation_events, opts}, _from, data) do
    limit = normalize_event_limit(Keyword.get(opts, :limit, @operation_event_limit))
    types = Keyword.get(opts, :types)

    events =
      data
      |> Loops.canonical_value!(:events)
      |> Map.get(:records, [])
      |> Enum.filter(fn event ->
        (is_nil(types) or event.type in List.wrap(types)) and
          Loops.event_visible?(data, event, opts)
      end)
      |> Enum.take(limit)

    {:reply, events, arm_idle_timer(data)}
  end

  def handle_call({:delivery_consent_put, value, opts}, _from, data) do
    with {:ok, consent} <- Deliveries.normalize_consent(value),
         :ok <- Deliveries.validate_consent_subject(consent, data),
         {:ok, next} <- Deliveries.commit_consent(data, consent, opts, :delivery_consent_granted) do
      {:reply, {:ok, consent}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_consent_revoke, consent_id, opts}, _from, data) do
    with {:ok, consent} <- Deliveries.fetch_consent(data, consent_id),
         revoked <- DeliveryConsent.revoke(consent),
         {:ok, next} <- Deliveries.commit_consent(data, revoked, opts, :delivery_consent_revoked) do
      {:reply, {:ok, revoked}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_authorize, event_id, destination, policy_value, opts}, _from, data) do
    with {:ok, event} <- Deliveries.committed_operation_event(data, event_id),
         {:ok, loop, _control} <- Loops.operation_loop(data, event.loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, policy} <- Deliveries.normalize_policy(policy_value) do
      now = Keyword.get(opts, :now, System.system_time(:millisecond))

      consent =
        Keyword.get(opts, :consent) || Deliveries.find_consent(data, loop, destination, now)

      history = Deliveries.committed_receipts(data)

      case Delivery.authorize(
             event,
             loop,
             destination,
             policy,
             history,
             Keyword.put(opts, :consent, consent)
           ) do
        {:duplicate, receipt} ->
          {:reply, {:ok, receipt}, arm_idle_timer(data)}

        {:ok, receipt} ->
          case commit_delivery_receipt(data, loop, receipt, opts) do
            {:ok, next} -> {:reply, {:ok, receipt}, next}
            {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
          end

        {:error, receipt} ->
          case commit_delivery_receipt(data, loop, receipt, opts) do
            {:ok, next} -> {:reply, {:error, {receipt.reason, receipt}}, next}
            {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_record, receipt_id, outcome, detail, opts}, _from, data) do
    with {:ok, receipt} <- Deliveries.fetch_receipt(data, receipt_id),
         {:ok, loop, _control} <- Loops.operation_loop(data, receipt.loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, updated} <- Deliveries.update_receipt(receipt, outcome, detail, opts),
         {:ok, next} <- commit_delivery_receipt(data, loop, updated, opts) do
      {:reply, {:ok, updated}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_receipts, opts}, _from, data) do
    limit = normalize_event_limit(Keyword.get(opts, :limit, @operation_event_limit))

    receipts =
      data
      |> Deliveries.committed_receipts()
      |> Enum.filter(&Deliveries.receipt_visible?(data, &1, opts))
      |> Enum.sort_by(& &1.decided_at, :desc)
      |> Enum.take(limit)

    {:reply, receipts, arm_idle_timer(data)}
  end

  def handle_call({:reset, state}, _from, data) do
    if busy?(data) or live_runs?(data) do
      {:reply, {:error, :instance_busy}, arm_idle_timer(data)}
    else
      state =
        state
        |> State.new()
        |> put_conversation_id(Keyword.fetch!(data.base_opts, :conversation_id))

      case Commit.canonical_sections(data, %{flow: state},
             correlation_id: Spectre.Identity.uuid7(),
             provenance: %{source: :instance_reset},
             metadata: %{transition: :flow_state_reset}
           ) do
        {:ok, next} -> {:reply, :ok, arm_idle_timer(%{next | last_result: nil})}
        {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
      end
    end
  end

  defp handle_instance_resume(supplied_ref, command, opts, from, data) do
    case Runs.owned_run(data, supplied_ref) do
      {:ok, run} ->
        case Events.authorize(data, run.definition_ref, :continuation) do
          :ok ->
            cond do
              run_active?(data, run.id) ->
                {:reply, {:error, {:run_already_active, run.id}}, data}

              execute_command?(command) ->
                dispatch_invocation(run, command, opts, :turn, from, data)

              true ->
                entry = %{
                  run_id: run.id,
                  operation: {:resume, command},
                  projection: :turn,
                  input: run.input,
                  opts: runtime_opts(data, opts, run.input),
                  state_revision: data.state.revision,
                  internal?: false
                }

                {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, arm_idle_timer(data)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp handle_instance_execute(supplied, opts, from, data) do
    case Runs.owned_result_run(data, supplied, true) do
      {:ok, %Run{waiting: %Invocation{} = invocation} = run} ->
        dispatch_invocation(
          run,
          {:execute, invocation},
          opts,
          :result,
          from,
          data
        )

      {:ok, %Run{result: %Result{} = result} = run} ->
        if Runs.terminal_result?(result) do
          {:reply, {:ok, result}, arm_idle_timer(data)}
        else
          {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, arm_idle_timer(data)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  @impl GenServer
  def handle_info({:spectre, :advance, run_id}, data) do
    data = %{data | scheduled: false}

    case pop_ready(data, run_id) do
      {:ok, entry, data} ->
        {:noreply, start_advance_worker(data, entry)}

      {:error, _reason, data} ->
        {:noreply, maybe_schedule(data)}
    end
  end

  def handle_info(
        {:spectre, :advance_result, run_id, dispatch_id, capability, outcome},
        data
      ) do
    handle_info(
      {:spectre, :advance_result, run_id, dispatch_id, capability, outcome, []},
      data
    )
  end

  def handle_info(
        {:spectre, :advance_result, run_id, dispatch_id, capability, outcome, samples},
        data
      ) do
    case data.active do
      %{
        run_id: ^run_id,
        dispatch_id: ^dispatch_id,
        capability: ^capability
      } = active ->
        active = put_in(active, [:entry, :nondeterminism_samples], samples)
        {:noreply, receive_advance_result(data, active, outcome)}

      _stale ->
        emit(:stale_move_result, data, %{count: 1}, %{run_id: id_digest(run_id)})
        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :invocation_result, invocation_id, %Receipt{} = receipt},
        data
      ) do
    case Runs.validate_invocation_receipt(data, invocation_id, receipt) do
      {:ok, ownership} ->
        case receipt.kind do
          :inference ->
            case inference_receipt_disposition(data, ownership, receipt) do
              :accept ->
                {:noreply, accept_inference_receipt(data, ownership, receipt)}

              {:cancel, reason} ->
                cancelled = cancelled_race_receipt(receipt, reason)
                {:noreply, accept_inference_receipt(data, ownership, cancelled)}

              :stale ->
                emit(
                  :stale_invocation_result,
                  data,
                  %{count: 1},
                  %{invocation_id: id_digest(invocation_id), reason_class: :control_revision}
                )

                {:noreply, data}
            end

          :effect ->
            data =
              data
              |> finish_worker(ownership.pid)
              |> Map.put(:invocations, Map.delete(data.invocations, invocation_id))
              |> Map.put(:state_lock, nil)

            {:noreply, commit_effect_terminal(data, ownership, receipt)}
        end

      {:error, _reason} ->
        emit(
          :stale_invocation_result,
          data,
          %{count: 1},
          %{invocation_id: id_digest(invocation_id)}
        )

        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :inference_attempt_deadline, invocation_id, generation, dispatch_id},
        data
      ) do
    case {Map.get(data.inference_attempt_timers, invocation_id),
          Map.get(data.invocations, invocation_id)} do
      {%{generation: ^generation, dispatch_id: ^dispatch_id, deadline_at: deadline},
       %{mode: :one_shot, generation: ^generation, dispatch_id: ^dispatch_id} = ownership} ->
        if Spectre.Determinism.system_time(:millisecond) < deadline do
          {:noreply, rearm_inference_attempt_timer(data, ownership, deadline)}
        else
          if Process.alive?(ownership.pid), do: Process.exit(ownership.pid, :kill)

          receipt = %Receipt{
            invocation_id: ownership.invocation.id,
            run_id: ownership.run_id,
            run_revision: ownership.run_revision,
            generation: ownership.generation,
            dispatch_id: ownership.dispatch_id,
            capability: ownership.capability,
            kind: :inference,
            attempt_id: ownership.invocation.attempt_id,
            control_revision: ownership.invocation.control_revision,
            stream_epoch: ownership.invocation.stream_epoch,
            provider_started: true,
            usage: %{},
            outcome: {:error, :inference_deadline_exceeded},
            metadata: %{remote_status: :ambiguous}
          }

          next =
            data
            |> clear_inference_attempt_timer(invocation_id)
            |> accept_inference_receipt(ownership, receipt)

          {:noreply, next}
        end

      _stale ->
        {:noreply, data}
    end
  end

  def handle_info({:spectre, :receipt_payload_staged, token, result}, data) do
    case Map.pop(data.receipt_staging, token) do
      {nil, _staging} ->
        {:noreply, data}

      {staging, remaining} ->
        Process.demonitor(staging.monitor, [:flush])
        data = %{data | receipt_staging: remaining}

        case result do
          {:ok, payload_ref} ->
            case Receipts.refresh(data, staging.prepared) do
              {:ok, %{envelope: envelope} = prepared}
              when envelope == staging.prepared.envelope ->
                retained = maybe_retain_staged_run(data, staging.run)

                case Receipts.commit(retained, prepared, :required, payload_ref) do
                  {:ok, committed, envelope} ->
                    committed = %{
                      committed
                      | receipt_resumes:
                          Map.put(committed.receipt_resumes, envelope.id, staging.resume)
                    }

                    next = committed |> Checkpoint.force() |> maybe_start_receipt_deliveries()
                    {:noreply, next}

                  {:error, reason} ->
                    {:noreply, fail_receipt_staging(data, staging, reason)}
                end

              {:ok, refreshed} ->
                {:noreply, restage_required_receipt(data, staging, refreshed)}

              {:error, reason} ->
                {:noreply, fail_receipt_staging(data, staging, reason)}
            end

          {:error, reason} ->
            failure = {:required_receipt_payload_failed, reason}
            {:noreply, fail_receipt_staging(data, staging, failure)}
        end
    end
  end

  def handle_info({:spectre, :receipt_delivery_result, receipt_id, result}, data) do
    case Map.pop(data.receipt_deliveries, receipt_id) do
      {nil, _deliveries} ->
        {:noreply, data}

      {delivery, remaining} ->
        Process.demonitor(delivery.monitor, [:flush])
        data = %{data | receipt_deliveries: remaining}
        {:noreply, apply_receipt_delivery_result(data, delivery, result)}
    end
  end

  def handle_info({:spectre, :receipt_delivery_retry, receipt_id}, data) do
    {_timer, timers} = Map.pop(data.receipt_retry_timers, receipt_id)
    data = %{data | receipt_retry_timers: timers}

    if Map.has_key?(data.receipt_deliveries, receipt_id) do
      {:noreply, data}
    else
      {:noreply, maybe_start_receipt_delivery(data, receipt_id)}
    end
  end

  def handle_info(
        {:spectre, :inference_heartbeat, invocation_id, %InferenceProgress{} = progress,
         checkpoint},
        data
      ) do
    case validate_inference_heartbeat(data, invocation_id, progress, checkpoint) do
      :ok ->
        now = System.monotonic_time(:millisecond)

        liveness = %{
          at: now,
          sequence: progress.sequence,
          state: progress.state,
          usage: progress.usage,
          output_bytes: progress.output_bytes
        }

        data = %{
          data
          | inference_liveness_clock:
              Map.put(data.inference_liveness_clock, invocation_id, liveness)
        }

        {:noreply, maybe_commit_inference_checkpoint(data, progress, checkpoint, now)}

      {:error, _reason} ->
        emit(
          :stale_inference_heartbeat,
          data,
          %{count: 1},
          %{invocation_id: id_digest(invocation_id)}
        )

        {:noreply, data}
    end
  end

  # Compatibility with sessions from the same release during a rolling code
  # upgrade. They carry no raw recovery checkpoint and remain non-resumable.
  def handle_info(
        {:spectre, :inference_heartbeat, invocation_id, %InferenceProgress{} = progress},
        data
      ) do
    handle_info({:spectre, :inference_heartbeat, invocation_id, progress, nil}, data)
  end

  def handle_info({:spectre, :operation_schedule}, data) do
    data = %{data | operation_scheduled: false}

    case pop_operation(data) do
      {:ok, loop_key, next} ->
        {:noreply, next |> advance_operation(loop_key) |> maybe_schedule_operations()}

      {:empty, next} ->
        {:noreply, arm_idle_timer(next)}
    end
  end

  def handle_info({:spectre, :operation_result, %OperationResult{} = result}, data) do
    case Map.get(data.operation_runners, result.attempt_id) do
      nil ->
        emit(
          :stale_operation_result,
          data,
          %{count: 1},
          %{loop_id: id_digest(result.loop_id)}
        )

        {:noreply, data}

      ownership ->
        with {:ok, loop, control} <- Loops.operation_loop(data, result.loop_id),
             {:ok, next_loop, next_control, event_specs, start_loop_intents} <-
               normalize_operation_result(
                 OperationRuntime.apply_result_with_start_loops(
                   loop,
                   control,
                   result,
                   Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
                 )
               ),
             {:ok, started_loops, already_started} <-
               materialize_start_loop_intents(data, next_loop, result, start_loop_intents),
             {:ok, next, _events} <-
               commit_operation_result_with_started_loops(
                 data,
                 next_loop,
                 next_control,
                 event_specs,
                 result,
                 started_loops,
                 already_started
               ) do
          next =
            next
            |> finish_operation_runner(ownership)
            |> maybe_remember_operation_result(next_loop, result, ownership.spec)
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)
            |> queue_started_loops(started_loops)
            |> maybe_schedule_operations()

          {:noreply, next}
        else
          {:duplicate, _loop} ->
            next = data |> finish_operation_runner(ownership) |> maybe_schedule_operations()
            {:noreply, next}

          {:error, reason} ->
            emit(
              :rejected_operation_result,
              data,
              %{count: 1},
              %{
                loop_id: id_digest(result.loop_id),
                reason_class: reason_class(reason)
              }
            )

            {:noreply, reject_operation_result(data, ownership, result, reason)}
        end
    end
  end

  def handle_info({:spectre, :operation_progress, %OperationProgress{} = progress}, data) do
    case accept_operation_progress(data, progress) do
      {:ok, loop, control, next} ->
        loop =
          loop
          |> Map.put(:last_progress, progress.value)
          |> Map.put(:progress_sequence, progress.sequence)
          |> OperationLoop.touch(at: progress.at)

        case commit_operational(next, loop, control, [],
               correlation_id: loop.correlation_id,
               causation_id: progress.id,
               provenance: %{runner_attempt: progress.attempt_id},
               transition: :operation_progress
             ) do
          {:ok, committed, _events} -> {:noreply, committed}
          {:error, _reason} -> {:noreply, next}
        end

      {:throttled, next} ->
        {:noreply, next}

      :drop ->
        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :operation_timer, loop_id, wait_id, generation},
        data
      ) do
    case Timers.consume_wait_timer(data, loop_id, wait_id, generation) do
      {:ok, data} ->
        with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.trigger(
                 loop,
                 control,
                 {:timer, wait_id},
                 [wait_id: wait_id, generation: generation],
                 Loops.operation_env(data)
               ),
             {:ok, next, _events} <-
               commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 causation_id: wait_id,
                 provenance: %{trigger: :timer},
                 transition: :operation_timer
               ) do
          next = next |> queue_operation(next_loop) |> maybe_schedule_operations()
          {:noreply, next}
        else
          {:error, _reason} -> {:noreply, data}
        end

      :stale ->
        {:noreply, data}
    end
  end

  def handle_info({:spectre, :operation_runner_terminating, _attempt_id, _reason}, data),
    do: {:noreply, data}

  def handle_info(
        {:spectre, :operation_attempt_timeout, loop_id, attempt_id, fencing_token},
        data
      ) do
    case Timers.consume_attempt_timer(data, loop_id, attempt_id, fencing_token) do
      {:ok, ownership, next} ->
        _ = RunnerSupervisor.stop_runner(next.runner_supervisor, ownership.pid)
        next = finish_operation_runner(next, ownership)

        with {:ok, loop, control} <- Loops.operation_loop(next, loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id, fencing_token: ^fencing_token}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 :timeout,
                 Loops.operation_env(next, snapshot_id: ownership.snapshot_id)
               ),
             {:ok, committed, _events} <-
               commit_operational(next, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 causation_id: attempt_id,
                 provenance: %{source: :attempt_watchdog, attempt_id: attempt_id},
                 transition: :operation_timeout
               ) do
          committed =
            committed
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)
            |> maybe_schedule_operations()

          {:noreply, committed}
        else
          _stale_or_invalid -> {:noreply, maybe_schedule_operations(next)}
        end

      :stale ->
        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :operation_memory_result, loop_id, result_id, outcome},
        data
      ) do
    with {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         true <- operation_result_committed?(data, loop, result_id),
         event_type <- if(outcome == :ok, do: :memory_committed, else: :memory_commit_failed),
         {:ok, next, _events} <-
           commit_operational(
             data,
             loop,
             control,
             [
               %{
                 type: event_type,
                 payload: %{result_id: result_id, status: memory_status(outcome)}
               }
             ],
             correlation_id: loop.correlation_id,
             causation_id: result_id,
             provenance: %{source: :operation_memory},
             transition: :operation_memory
           ) do
      {:noreply, arm_idle_timer(next)}
    else
      _stale -> {:noreply, arm_idle_timer(data)}
    end
  end

  def handle_info(
        {:spectre, :checkpoint_result, token, revision, result},
        %{checkpoint_inflight: %{token: token, revision: revision} = inflight} = data
      ) do
    data = Checkpoint.finish_task(data)

    case result do
      :ok ->
        next =
          data |> Checkpoint.persisted(inflight, revision) |> resume_durable_boundaries(revision)

        next = maybe_start_receipt_deliveries(next)

        emit(:checkpoint_persisted, next, %{count: 1}, %{revision: revision})
        {:noreply, arm_idle_timer(next)}

      {:error, reason} ->
        next = Checkpoint.persist_failed(data, inflight, reason)

        emit(
          :checkpoint_failed,
          next,
          %{count: 1},
          %{
            revision: revision,
            reason_class: reason_class(reason),
            outcome: checkpoint_failure_outcome(next)
          }
        )

        {:noreply, arm_idle_timer(next)}
    end
  end

  def handle_info(
        {:spectre, :checkpoint_reconcile_result, token, result},
        %{checkpoint_reconcile_inflight: %{token: token, from: from}} = data
      ) do
    data = Checkpoint.finish_reconciliation_task(data)

    case Checkpoint.apply_reconciliation(data, result) do
      {:ok, next, revision} ->
        GenServer.reply(from, {:ok, revision})
        next = maybe_start_receipt_deliveries(next)
        emit(:checkpoint_reconciled, next, %{count: 1}, %{revision: revision})
        {:noreply, arm_idle_timer(next)}

      {:error, next, reason} ->
        GenServer.reply(from, {:error, reason})

        emit(
          :checkpoint_reconciliation_failed,
          next,
          %{count: 1},
          %{reason_class: reason_class(reason)}
        )

        {:noreply, arm_idle_timer(next)}
    end
  end

  def handle_info({:spectre, :checkpoint_reconcile_result, _token, _result}, data),
    do: {:noreply, data}

  def handle_info({:spectre, :checkpoint_result, _token, _revision, _result}, data),
    do: {:noreply, data}

  def handle_info({:idle_shutdown, generation}, %{idle_generation: generation} = data) do
    if busy?(data) or live_runs?(data) do
      {:noreply, arm_idle_timer(%{data | idle_timer: nil})}
    else
      emit(:idle_shutdown, data, %{count: 1})
      {:stop, :normal, %{data | idle_timer: nil}}
    end
  end

  def handle_info({:idle_shutdown, _stale_generation}, data), do: {:noreply, data}

  def handle_info({:DOWN, monitor, :process, pid, reason}, data) do
    if monitor == data.registry_monitor do
      {:stop, :normal, data}
    else
      cond do
        match?(%{pid: ^pid, monitor: ^monitor}, data.checkpoint_inflight) ->
          {:noreply, checkpoint_task_down(data, reason)}

        match?(%{pid: ^pid, monitor: ^monitor}, data.checkpoint_reconcile_inflight) ->
          {:noreply, checkpoint_reconciliation_task_down(data, reason)}

        receipt_staging = receipt_staging_by_pid(data, pid, monitor) ->
          {:noreply, receipt_staging_down(data, receipt_staging, reason)}

        receipt_delivery = receipt_delivery_by_pid(data, pid, monitor) ->
          {:noreply, receipt_delivery_down(data, receipt_delivery, reason)}

        invocation_id = Map.get(data.stream_monitors, pid) ->
          {:noreply, stream_session_down(data, invocation_id, pid, monitor, reason)}

        true ->
          case Map.get(data.operation_monitors, pid) do
            attempt_id when is_binary(attempt_id) ->
              {:noreply, operation_runner_down(data, pid, monitor, attempt_id, reason)}

            nil ->
              case Map.get(data.workers, pid) do
                %{monitor: ^monitor} = worker ->
                  {:noreply, worker_down(data, pid, worker, reason)}

                _unknown ->
                  {:noreply, data}
              end
          end
      end
    end
  end

  def handle_info({:EXIT, pid, :normal}, data) when is_map_key(data.workers, pid),
    do: {:noreply, data}

  def handle_info({:EXIT, pid, reason}, data) do
    case Map.get(data.workers, pid) do
      nil -> {:noreply, data}
      worker -> {:noreply, worker_down(data, pid, worker, reason)}
    end
  end

  def handle_info(_message, data), do: {:noreply, data}

  defp receive_advance_result(data, active, outcome) do
    with %Run{} = current <- Map.get(data.runs, active.run_id),
         :ok <- Runs.validate_move_outcome(outcome, current, active.entry) do
      data = finish_worker(data, active.pid)
      data = %{data | active: nil}

      if policy_resolution_entry?(active.entry) do
        commit_policy_decision(data, outcome, active.entry)
      else
        apply_step(outcome, active.entry, data)
      end
    else
      nil ->
        data

      {:error, _reason} ->
        emit(:invalid_move_result, data, %{count: 1}, %{run_id: id_digest(active.run_id)})
        data
    end
  end

  @impl GenServer
  def terminate(_reason, data) do
    Enum.each(Map.keys(data.workers), fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    Enum.each(data.operation_runners, fn {_attempt_id, ownership} ->
      if Process.alive?(ownership.pid) do
        _ = RunnerSupervisor.stop_runner(data.runner_supervisor, ownership.pid)
      end
    end)

    Enum.each(data.stream_sessions, fn {_invocation_id, ownership} ->
      if Process.alive?(ownership.pid) do
        _ = RunnerSupervisor.stop_runner(data.runner_supervisor, ownership.pid)
      end
    end)

    :ok = InferenceCapacity.release_all(data)

    Enum.each(data.operation_timers, fn {_loop_id, timer} ->
      if is_reference(timer.ref), do: Process.cancel_timer(timer.ref)
    end)

    Enum.each(data.operation_attempt_timers, fn {_attempt_id, timer} ->
      if is_reference(timer.ref), do: Process.cancel_timer(timer.ref)
    end)

    Enum.each(data.inference_attempt_timers, fn {_invocation_id, timer} ->
      if is_reference(timer.ref), do: Process.cancel_timer(timer.ref)
    end)

    case data.checkpoint_inflight do
      %{pid: pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
      _none -> :ok
    end

    case data.checkpoint_reconcile_inflight do
      %{pid: pid} when is_pid(pid) -> Process.exit(pid, :shutdown)
      _none -> :ok
    end

    Enum.each(data.receipt_staging, fn {_token, staging} ->
      if Process.alive?(staging.pid), do: Process.exit(staging.pid, :shutdown)
    end)

    Enum.each(data.receipt_deliveries, fn {_receipt_id, delivery} ->
      if Process.alive?(delivery.pid), do: Process.exit(delivery.pid, :shutdown)
    end)

    Enum.each(data.receipt_retry_timers, fn {_receipt_id, timer} ->
      if is_reference(timer), do: Process.cancel_timer(timer)
    end)

    _ = Owner.release(data.owner, data.ref, data.owner_lease, data.base_opts)

    :ok
  end

  defp submit(input, opts, projection, from, data) do
    case {owner_guard(data, :admission), morph_turn_options(data, opts)} do
      {:ok, :ok} -> submit_owned(input, opts, projection, from, data)
      {{:error, reason}, _guard} -> {:reply, {:error, reason}, arm_idle_timer(data)}
      {:ok, {:error, reason}} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  # Cognitive operations use the same Run/Invocation lifecycle as every other
  # inference, but their Run is internal and state-neutral. A deterministic
  # Run id lets a restarted Operation Runner attach to work already recovered
  # by the Instance instead of dispatching the model twice.
  defp submit_cognitive_inference(
         %InferenceRequest{} = request,
         opts,
         from,
         data
       )
       when is_list(opts) do
    input = Keyword.get(opts, :inference_input, %Input{})
    run_id = cognitive_inference_run_id(data, request, opts)

    with :ok <- owner_guard(data, :admission),
         :ok <- Receipts.admission_available?(data),
         :ok <- valid_cognitive_inference_run_id(run_id) do
      case Map.get(data.runs, run_id) do
        %Run{} = run ->
          attach_cognitive_inference(run, request, from, data)

        nil ->
          admit_cognitive_inference(run_id, request, input, opts, from, data)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp submit_cognitive_inference(request, _opts, _from, data),
    do:
      {:reply, {:error, {:invalid_cognitive_request, execution_shape(request)}},
       arm_idle_timer(data)}

  defp admit_cognitive_inference(run_id, request, input, opts, from, data) do
    data = Runs.prune_for_new_run(data)

    with true <- map_size(data.runs) < data.max_runs,
         :ok <- Events.authorize(data, Events.active_definition_ref(data), :new_admission),
         admission_opts <- cognitive_inference_admission_opts(run_id, request, opts),
         runtime_opts <- runtime_opts(data, admission_opts, input),
         {:ok, %Run{} = run} <-
           Runtime.admit_inference(
             data.agent,
             request,
             input,
             data.state,
             runtime_opts,
             admission_opts
           ) do
      entry = %{
        run_id: run.id,
        operation: {:inference, request},
        projection: :inference_response,
        input: run.input,
        opts: runtime_opts,
        state_revision: data.state.revision,
        internal?: true,
        commit_state?: false,
        admitted?: false
      }

      payload = %{
        input: run.input,
        entrypoint: :inference,
        inference_request_id: request.id,
        recoverable?: run.start_continuation.recoverable?,
        recovery_reason: run.start_continuation.reason
      }

      receipt_opts = [
        causation_id: Keyword.get(admission_opts, :causation_id, request.id),
        payload_schema_ref: "spectre.run.input-admitted/1",
        privacy: :confidential
      ]

      retained =
        data
        |> Runs.put_run(run)
        |> put_or_replace_cognitive_caller(run.id, from)

      case Receipts.prepare_run(
             retained,
             data.state,
             run,
             :run_input_admitted,
             payload,
             receipt_opts
           ) do
        {:ok, prepared_receipt} ->
          next =
            commit_or_stage_run_receipt(
              retained,
              run,
              {:run_input_admitted, entry},
              prepared_receipt
            )

          {:noreply, next}

        {:error, reason} ->
          {:noreply, fail_run_commit(retained, run, reason)}
      end
    else
      false -> {:reply, {:error, :instance_run_capacity_reached}, arm_idle_timer(data)}
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp attach_cognitive_inference(run, request, from, data) do
    with :ok <- cognitive_inference_run_matches(run, request),
         :ok <- Events.authorize(data, run.definition_ref, :continuation) do
      case run.status do
        :complete ->
          {:reply, cognitive_inference_response(run.result), arm_idle_timer(data)}

        :failed ->
          {:reply, {:error, run.last_error || :cognitive_inference_failed}, arm_idle_timer(data)}

        _active ->
          case attach_cognitive_caller(data, run.id, from) do
            {:ok, next} -> {:noreply, disarm_idle_timer(next)}
            {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp cognitive_inference_admission_opts(run_id, request, opts) do
    attempt_id = Keyword.get(opts, :operation_attempt_id)
    loop_id = Keyword.get(opts, :operation_loop_id)

    metadata =
      opts
      |> Keyword.get(:run_metadata, %{})
      |> Map.merge(%{
        internal_cognitive_inference: true,
        inference_request_id: request.id,
        inference_purpose: request.purpose,
        operation_attempt_id: attempt_id,
        operation_loop_id: loop_id
      })

    opts
    |> Keyword.delete(:timeout)
    |> Keyword.delete(:inference_input)
    |> Keyword.put(:run_id, run_id)
    |> Keyword.put_new(:trace_id, run_id)
    |> Keyword.put_new(:causation_id, attempt_id || request.id)
    |> Keyword.put_new(:correlation_id, loop_id || attempt_id || request.id)
    |> Keyword.put(:run_metadata, metadata)
  end

  defp cognitive_inference_run_id(data, request, opts) do
    Keyword.get(opts, :run_id) ||
      Value.token(
        "cognitive-inference-run",
        {data.ref.key, Keyword.get(opts, :operation_attempt_id), request.id}
      )
  end

  defp valid_cognitive_inference_run_id(value) when is_binary(value) and value != "", do: :ok
  defp valid_cognitive_inference_run_id(_value), do: {:error, :invalid_cognitive_inference_run_id}

  defp cognitive_inference_run_matches(
         %Run{
           metadata: %{
             internal_cognitive_inference: true,
             inference_request_id: request_id,
             inference_purpose: purpose
           }
         },
         %InferenceRequest{id: request_id, purpose: purpose}
       ),
       do: :ok

  defp cognitive_inference_run_matches(_run, _request),
    do: {:error, :cognitive_inference_run_conflict}

  defp attach_cognitive_caller(data, run_id, from) do
    new_pid = elem(from, 0)

    case Map.get(data.callers, run_id) do
      nil ->
        {:ok, put_or_replace_cognitive_caller(data, run_id, from)}

      {^new_pid, _old_tag} ->
        # A caller may retry after its previous GenServer.call timed out. The
        # new tag must replace the one that can no longer receive a reply.
        {:ok, put_or_replace_cognitive_caller(data, run_id, from)}

      {old_pid, _old_tag} when is_pid(old_pid) ->
        if process_alive?(old_pid),
          do: {:error, :cognitive_inference_already_attached},
          else: {:ok, put_or_replace_cognitive_caller(data, run_id, from)}
    end
  end

  defp put_or_replace_cognitive_caller(data, run_id, from),
    do: %{data | callers: Map.put(data.callers, run_id, from)}

  defp process_alive?(pid) do
    Process.alive?(pid)
  rescue
    _exception -> false
  end

  defp submit_owned(input, opts, projection, from, data) do
    data = Runs.prune_for_new_run(data)

    case {Receipts.admission_available?(data), Conversation.policy_owner(data, input, opts)} do
      {{:error, reason}, _policy_owner} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}

      {:ok, :none} ->
        case Events.authorize(data, Events.active_definition_ref(data), :new_admission) do
          :ok ->
            if map_size(data.runs) >= data.max_runs do
              {:reply, {:error, :instance_run_capacity_reached}, arm_idle_timer(data)}
            else
              reserve_submitted_run(input, opts, projection, from, data)
            end

          {:error, reason} ->
            {:reply, {:error, reason}, arm_idle_timer(data)}
        end

      {:ok, {:ok, %Run{}}} when projection == :stream ->
        {:reply, {:error, {:streaming_unsupported, :policy_continuation}}, arm_idle_timer(data)}

      {:ok, {:ok, %Run{} = owner}} ->
        case Events.authorize(data, owner.definition_ref, :continuation) do
          :ok -> submit_lifecycle_input(input, opts, projection, from, owner, data)
          {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
        end

      {:ok, {:error, reason}} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp submit_lifecycle_input(input, opts, projection, from, %Run{} = run, data) do
    case run do
      %Run{status: :boundary, cursor: :policy, waiting: %Boundary{}} ->
        if run_active?(data, run.id) do
          {:reply, {:error, {:run_already_active, run.id}}, arm_idle_timer(data)}
        else
          entry = %{
            run_id: run.id,
            operation: {:resume, {:input, input}},
            projection: projection,
            input: input,
            opts: runtime_opts(data, opts, input),
            state_revision: data.state.revision,
            internal?: false
          }

          {:noreply, data |> enqueue(entry, true) |> put_caller(run.id, from)}
        end

      _invalid ->
        {:reply, {:error, {:run_not_waiting_for_policy, run.id}}, arm_idle_timer(data)}
    end
  end

  defp reserve_submitted_run(input, opts, projection, from, data) do
    runtime_opts = runtime_opts(data, opts, input)

    case Runtime.admit(data.agent, input, data.state, runtime_opts, opts) do
      {:ok, %Run{} = run} ->
        if Map.has_key?(data.runs, run.id) or Map.has_key?(data.tombstones, run.id) do
          {:reply, {:error, {:duplicate_instance_run, run.id}}, arm_idle_timer(data)}
        else
          case InferenceCapacity.reserve(data, run.id, projection) do
            {:ok, reserved, reservation} ->
              entry = %{
                run_id: run.id,
                operation: {:start, input},
                projection: projection,
                input: input,
                opts: opts,
                state_revision: reserved.state.revision,
                internal?: false,
                admitted?: true,
                stream_capacity_reservation: reservation
              }

              payload = %{
                input: run.input,
                recoverable?: run.start_continuation.recoverable?,
                recovery_reason: run.start_continuation.reason
              }

              receipt_opts = [
                causation_id: run.trace_id,
                payload_schema_ref: "spectre.run.input-admitted/1",
                privacy: :confidential
              ]

              retained =
                reserved
                |> Runs.put_run(run)
                |> put_caller(run.id, from)

              case Receipts.prepare_run(
                     retained,
                     reserved.state,
                     run,
                     :run_input_admitted,
                     payload,
                     receipt_opts
                   ) do
                {:ok, prepared_receipt} ->
                  next =
                    commit_or_stage_run_receipt(
                      retained,
                      run,
                      {:run_input_admitted, entry},
                      prepared_receipt
                    )

                  {:noreply, next}

                {:error, reason} ->
                  next =
                    retained
                    |> InferenceCapacity.release(run.id)
                    |> fail_run_commit(run, reason)

                  {:noreply, next}
              end

            {:error, reason} ->
              {:reply, {:error, reason}, arm_idle_timer(data)}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp resume_inference_stream(data, %InferenceStream{} = old_stream, from) do
    with :ok <- owner_guard(data, :inference_resume),
         %Run{
           status: :awaiting,
           cursor: :inference,
           inference_continuation: %{stream_recovery: recovery}
         } = run <- Map.get(data.runs, old_stream.run_id),
         :ok <- validate_stream_resume_handle(run, recovery, old_stream) do
      case stream_session_for_run(data, run.id) do
        {_invocation_id, %{stream: %InferenceStream{} = stream}} ->
          {:reply, {:ok, stream}, data}

        nil when is_map_key(data.callers, run.id) ->
          {:reply, {:error, :stream_resume_already_waiting}, data}

        nil ->
          {:noreply, put_caller(data, run.id, from)}
      end
    else
      nil -> {:reply, {:error, :stream_resume_unavailable}, data}
      {:error, reason} -> {:reply, {:error, reason}, data}
      _mismatch -> {:reply, {:error, :stream_resume_unavailable}, data}
    end
  end

  defp validate_stream_resume_handle(run, recovery, old_stream) when is_map(recovery) do
    expected_digest = Map.get(recovery, :previous_consumer_token_digest)

    cond do
      run.id != old_stream.run_id or
          run.inference_continuation.inference_id != old_stream.inference_id ->
        {:error, :stale_stream_handle}

      Map.get(recovery, :previous_invocation_id) != old_stream.invocation_id or
          Map.get(recovery, :previous_stream_epoch) != old_stream.stream_epoch ->
        {:error, :stale_stream_handle}

      not is_binary(expected_digest) or
          expected_digest != stream_token_digest(old_stream.consumer_token) ->
        {:error, :invalid_stream_consumer_token}

      true ->
        :ok
    end
  end

  defp validate_stream_resume_handle(_run, _recovery, _old_stream),
    do: {:error, :stream_resume_unavailable}

  defp cancel_inference_stream(data, %InferenceStream{} = stream, reason, opts) do
    with :ok <- owner_guard(data, :inference_cancel),
         {:ok, ownership, run} <- current_stream_ownership(data, stream),
         {:ok, command} <- build_cancel_command(run, stream, reason, opts),
         {:ok, committed} <- commit_stream_cancel(data, run, command) do
      send(
        ownership.pid,
        {:spectre, :stream_cancel_committed, ownership.invocation.id, portable_failure(reason),
         command.id}
      )

      {:ok, committed}
    else
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp build_cancel_command(run, stream, reason, opts) do
    portable_reason = portable_failure(reason)

    command_id =
      Keyword.get_lazy(opts, :command_id, fn ->
        Value.token(
          "inference-cancel",
          {stream.invocation_id, stream.control_revision, portable_reason}
        )
      end)

    command =
      ControlCommand.new(stream.inference_id, :cancel,
        id: command_id,
        payload: %{reason: portable_reason},
        correlation_id: run.id,
        causation_id: stream.invocation_id,
        base_revision: stream.control_revision,
        provenance: %{source: :stream_control},
        metadata: %{
          target_kind: :inference,
          invocation_id: stream.invocation_id,
          stream_epoch: stream.stream_epoch
        }
      )

    case ControlCommand.validate(command) do
      :ok -> {:ok, command}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:invalid_stream_cancel, exception.__struct__}}
  end

  defp commit_stream_cancel(data, run, command) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         control <-
           Map.get(
             controls,
             command.loop_id,
             InferenceControl.new(run.inference_continuation.control_revision)
           ) do
      case InferenceControl.apply_cancel(control, command) do
        :duplicate ->
          {:ok, data}

        {:ok, next_control} ->
          Commit.canonical_sections(
            data,
            %{inference_control: Map.put(controls, command.loop_id, next_control)},
            correlation_id: run.id,
            causation_id: command.id,
            provenance: %{source: :inference_control, command_id: command.id},
            metadata: %{transition: :inference_cancel_applied}
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp steer_inference_stream(data, %InferenceStream{} = stream, input, opts, from) do
    with :ok <- owner_guard(data, :inference_steer),
         {:ok, ownership, run} <- current_stream_ownership(data, stream),
         {:ok, steer_input} <- normalize_steer_input(input, opts, data),
         {:ok, command} <- build_steer_command(run, stream, steer_input, opts),
         {:ok, committed, control} <- commit_pending_steer(data, run, command),
         {:ok, next} <-
           apply_committed_steer(
             committed,
             ownership,
             run,
             steer_input,
             command,
             control,
             opts,
             from
           ) do
      {:ok, next}
    else
      {:error, reason, next} -> {:error, reason, next}
      {:error, reason} -> {:error, reason, data}
    end
  end

  defp current_stream_ownership(data, stream) do
    ownership = Map.get(data.stream_sessions, stream.invocation_id)
    invocation_ownership = Map.get(data.invocations, stream.invocation_id)

    cond do
      is_nil(ownership) or is_nil(invocation_ownership) ->
        {:error, :invocation_terminal}

      not secure_stream_token?(ownership.stream.consumer_token, stream.consumer_token) ->
        {:error, :invalid_stream_consumer_token}

      ownership.stream != stream ->
        {:error, :stale_stream_handle}

      true ->
        case Map.get(data.runs, ownership.run_id) do
          %Run{
            status: :awaiting,
            cursor: :inference,
            waiting: %Invocation{id: invocation_id},
            inference_continuation: continuation
          } = run
          when invocation_id == stream.invocation_id and
                 continuation.control_revision == stream.control_revision ->
            {:ok, ownership, run}

          %Run{} ->
            {:error, :invocation_terminal}

          nil ->
            {:error, :unknown_stream_run}
        end
    end
  end

  defp normalize_steer_input(input, opts, data) do
    logical = input |> Input.new() |> Spectre.Run.Codec.logical_input()

    max_bytes =
      Keyword.get(
        opts,
        :stream_steer_max_bytes,
        Keyword.get(data.base_opts, :stream_steer_max_bytes, 32_000)
      )

    cond do
      not is_binary(logical.text) or logical.text == "" ->
        {:error, :empty_stream_steer_input}

      byte_size(logical.text) > max_bytes ->
        {:error, {:stream_steer_input_too_large, byte_size(logical.text), max_bytes}}

      true ->
        {:ok, logical}
    end
  rescue
    exception -> {:error, {:invalid_stream_steer_input, exception.__struct__}}
  end

  defp build_steer_command(run, stream, steer_input, opts) do
    command_id =
      Keyword.get_lazy(opts, :command_id, fn ->
        Value.token(
          "inference-steer",
          {stream.invocation_id, stream.control_revision, steer_input}
        )
      end)

    command =
      ControlCommand.new(stream.inference_id, :steer,
        id: command_id,
        payload: %{input: steer_input},
        correlation_id: run.id,
        causation_id: stream.invocation_id,
        base_revision: stream.control_revision,
        provenance: %{source: :stream_control},
        metadata: %{target_kind: :inference, stream_epoch: stream.stream_epoch}
      )

    case ControlCommand.validate(command) do
      :ok -> {:ok, command}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_pending_steer(data, run, command) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         control <-
           Map.get(
             controls,
             run.inference_continuation.inference_id,
             InferenceControl.new(run.inference_continuation.control_revision)
           ),
         {:ok, next_control} <- InferenceControl.begin_steer(control, command),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{inference_control: Map.put(controls, command.loop_id, next_control)},
             correlation_id: run.id,
             causation_id: command.id,
             provenance: %{source: :inference_control, command_id: command.id},
             metadata: %{transition: :inference_steer_committed}
           ) do
      {:ok, committed, next_control}
    end
  end

  defp apply_committed_steer(
         data,
         ownership,
         run,
         steer_input,
         command,
         control,
         opts,
         from
       ) do
    with {:ok, successor, invocation, prepared, entry} <-
           build_steer_successor(data, ownership, run, steer_input, control, opts),
         {:ok, writes} <- Commit.run_writes(data, data.state, successor),
         applied_command <- ControlCommand.applied(control.pending),
         applied_control <- InferenceControl.finish(control, applied_command),
         {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         writes <-
           Map.put(
             writes,
             :inference_control,
             Map.put(controls, invocation.inference_id, applied_control)
           ),
         successor_reservation <- {data.ref.key, run.id, invocation.attempt_id},
         :ok <-
           InferenceCapacity.replace(
             data,
             ownership.capacity_reservation,
             successor_reservation,
             self()
           ) do
      case Commit.canonical_sections(data, writes,
             correlation_id: run.id,
             causation_id: command.id,
             provenance: %{source: :inference_control, command_id: command.id},
             metadata: %{transition: :inference_steer_applied}
           ) do
        {:ok, committed} ->
          send(
            ownership.pid,
            {:spectre, :stream_superseded, ownership.invocation.id,
             %{
               successor_invocation_digest: id_digest(invocation.id),
               provider_cancel: :best_effort
             }}
          )

          Process.demonitor(ownership.monitor, [:flush])

          next = %{
            committed
            | runs: Map.put(committed.runs, successor.id, successor),
              invocations: Map.delete(committed.invocations, ownership.invocation.id),
              stream_sessions: Map.delete(committed.stream_sessions, ownership.invocation.id),
              stream_monitors: Map.delete(committed.stream_monitors, ownership.pid),
              stream_reservations:
                Map.put(committed.stream_reservations, run.id, successor_reservation),
              inference_liveness_clock:
                Map.delete(committed.inference_liveness_clock, ownership.invocation.id),
              state_lock: %{run_id: run.id, invocation_id: invocation.id}
          }

          next = put_caller(next, run.id, from)

          {:ok,
           commit_inference_supersession_receipt(
             next,
             successor,
             ownership.invocation,
             invocation,
             prepared,
             entry,
             command
           )}

        {:error, reason} ->
          # Capacity changes before the canonical commit so a session crash
          # cannot leave a committed successor without an admission slot.
          _ =
            InferenceCapacity.replace(
              data,
              successor_reservation,
              ownership.capacity_reservation,
              ownership.pid
            )

          rejected = reject_pending_steer(data, run, control, reason)
          {:error, reason, rejected}
      end
    else
      {:error, reason} ->
        rejected = reject_pending_steer(data, run, control, reason)
        {:error, reason, rejected}
    end
  end

  defp build_steer_successor(data, ownership, run, steer_input, control, opts) do
    current = run.inference_continuation
    attempt = current.attempt + 1

    plan =
      PromptPlan.append_context_data(current.descriptor.plan, steer_input.text,
        id: Value.token("steer-context", {current.inference_id, control.generation}),
        provenance: %{source: :steering, command_id: control.pending.id}
      )

    descriptor = %{current.descriptor | plan: plan}

    %InferenceSelection{} = current_selection = ownership.prepared.selection

    selection = %InferenceSelection{
      current_selection
      | attempt: attempt,
        reason: :steering_restart,
        metadata:
          Map.put(
            current_selection.metadata,
            :steering_command_id,
            control.pending.id
          )
    }

    frozen = FrozenSelection.from_selection(selection)

    case settle_superseded_attempt(data, current, ownership.invocation) do
      {:ok, budget, previous} ->
        continuation = %{
          current
          | descriptor: descriptor,
            frozen_selection: frozen,
            invocation: nil,
            stream_epoch: nil,
            attempt: attempt,
            previous_attempts: Enum.take([previous | current.previous_attempts], 32),
            control_revision: control.generation,
            provider_status: :selected,
            provider_request_id: nil,
            provider_request_digest: nil,
            resume_cursor: nil,
            consumer_token_digest: nil,
            stream_recovery: nil,
            stream_provider_sequence: nil,
            stream_usage: %InferenceUsage{},
            stream_usage_quality: :unavailable,
            stream_output_bytes: 0,
            budget: budget,
            recovery: %{status: :steer_successor_selected, command_id: control.pending.id},
            last_response: nil
        }

        successor = %{
          run
          | revision: run.revision + 1,
            step_id: Value.token("inference-steer-step", {run.id, control.generation}),
            waiting: nil,
            inference_continuation: continuation,
            last_error: nil
        }

        invocation = Invocation.from_inference(successor, continuation, streaming?: true)

        continuation = %{
          continuation
          | invocation: invocation,
            stream_epoch: invocation.stream_epoch
        }

        successor = %{successor | waiting: invocation, inference_continuation: continuation}

        prepared = %{
          ownership.prepared
          | descriptor: descriptor,
            selection: selection,
            frozen_selection: frozen
        }

        entry = %{
          ownership.entry
          | opts: ownership.entry.opts |> Keyword.merge(opts) |> Keyword.put(:streaming?, true),
            state_revision: data.state.revision,
            stream_capacity_reservation: nil,
            admitted?: false
        }

        {:ok, successor, invocation, prepared, entry}

      {:error, reason} ->
        {:error, {:inference_budget_settlement_failed, portable_failure(reason)}}
    end
  end

  defp commit_inference_supersession_receipt(
         data,
         successor,
         previous_invocation,
         successor_invocation,
         prepared,
         entry,
         command
       ) do
    previous = hd(successor.inference_continuation.previous_attempts)

    continuation = %{
      successor.inference_continuation
      | recovery: %{
          status: :supersession_receipted,
          command_id: command.id,
          previous_invocation_id: previous_invocation.id
        }
    }

    receipted = %{successor | inference_continuation: continuation}

    payload = %{
      outcome: :superseded,
      previous_attempt: previous,
      successor_invocation_id: successor_invocation.id,
      provider_cancel: if(previous.settlement == :confirmed, do: :not_started, else: :ambiguous)
    }

    receipt_opts =
      inference_receipt_opts(
        previous_invocation,
        "spectre.inference.attempt-superseded/1"
      )

    case Receipts.prepare_run(
           data,
           data.state,
           receipted,
           :inference_attempt_superseded,
           payload,
           receipt_opts
         ) do
      {:ok, prepared_receipt} ->
        commit_or_stage_run_receipt(
          data,
          receipted,
          {:inference_superseded, successor_invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        fail_run_commit(%{data | state_lock: nil}, receipted, reason)
    end
  end

  defp settle_superseded_attempt(data, continuation, invocation) do
    liveness = Map.get(data.inference_liveness_clock, invocation.id, %{})
    usage = Map.get(liveness, :usage, %InferenceUsage{})
    status = if Map.get(liveness, :state) == :awaiting_consumer, do: :confirmed, else: :ambiguous

    previous = %{
      attempt: continuation.attempt,
      attempt_id: invocation.attempt_id,
      invocation_id: invocation.id,
      stream_epoch: invocation.stream_epoch,
      control_revision: invocation.control_revision,
      outcome: :superseded,
      usage: usage,
      settlement: status
    }

    case continuation.budget do
      %Budget{} = budget ->
        case Budget.settle(budget, invocation.attempt_id, usage, status) do
          {:ok, settled} -> {:ok, settled, previous}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:ok, nil, previous}
    end
  end

  defp reject_pending_steer(data, run, control, reason) do
    rejected = ControlCommand.rejected(control.pending, portable_failure(reason))
    next_control = InferenceControl.finish(control, rejected)

    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{inference_control: Map.put(controls, control.pending.loop_id, next_control)},
             correlation_id: run.id,
             causation_id: control.pending.id,
             provenance: %{source: :inference_control, command_id: control.pending.id},
             metadata: %{transition: :inference_steer_rejected}
           ) do
      committed
    else
      _error -> data
    end
  end

  defp secure_stream_token?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_stream_token?(_left, _right), do: false

  defp stream_token_digest(token) when is_binary(token) and token != "",
    do: Value.token("stream-consumer-token", token)

  defp dispatch_invocation(run, command, opts, projection, from, data) do
    with :ok <- owner_guard(data, :effect_dispatch),
         :ok <- Events.authorize(data, run.definition_ref, :dispatch),
         %Invocation{} = invocation <- run.waiting,
         false <- run_active?(data, run.id),
         nil <- other_active_run(data, run.id),
         nil <- data.state_lock do
      run = Runs.rebase_run(run, data.state)
      data = Runs.put_run(data, run)
      runtime_opts = runtime_opts(data, opts, run.input)
      dispatch_id = Spectre.Identity.uuid7()
      capability = make_ref()
      owner = self()

      entry = %{
        run_id: run.id,
        operation: {:resume, command},
        projection: projection,
        input: run.input,
        opts: runtime_opts,
        state_revision: data.state.revision,
        internal?: false
      }

      {pid, monitor} =
        spawn_invocation_worker(
          owner,
          run,
          invocation,
          command,
          runtime_opts,
          data.generation,
          dispatch_id,
          capability
        )

      ownership = %{
        invocation_id: invocation.id,
        invocation: invocation,
        run_id: run.id,
        run_revision: run.revision,
        generation: data.generation,
        dispatch_id: dispatch_id,
        capability: capability,
        pid: pid,
        monitor: monitor,
        entry: entry
      }

      worker = Map.merge(ownership, %{kind: :invocation})

      next =
        data
        |> put_caller(run.id, from)
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
        |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
        |> Map.put(:workers, Map.put(data.workers, pid, worker))
        |> disarm_idle_timer()

      emit(
        :invocation_dispatched,
        next,
        %{count: 1},
        %{
          run_id: id_digest(run.id),
          invocation_id: id_digest(invocation.id)
        }
      )

      {:noreply, next}
    else
      nil ->
        {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, arm_idle_timer(data)}

      %Boundary{} ->
        {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, arm_idle_timer(data)}

      true ->
        {:reply, {:error, {:run_already_active, run.id}}, arm_idle_timer(data)}

      {:instance_busy, active_run_id} ->
        {:reply, {:error, {:instance_busy, active_run_id}}, arm_idle_timer(data)}

      %{} ->
        {:reply, {:error, :instance_state_locked}, arm_idle_timer(data)}

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp other_active_run(%{active: nil}, _run_id), do: nil
  defp other_active_run(%{active: %{run_id: run_id}}, run_id), do: nil

  defp other_active_run(%{active: active}, _run_id),
    do: {:instance_busy, Map.get(active, :run_id)}

  defp spawn_invocation_worker(
         owner,
         run,
         invocation,
         command,
         runtime_opts,
         generation,
         dispatch_id,
         capability
       ) do
    spawn_worker(fn ->
      {outcome, samples} =
        Spectre.Determinism.capture(runtime_opts, fn ->
          safe_step(run, fn -> Runtime.resume(run, command, runtime_opts) end)
        end)

      receipt = %Receipt{
        invocation_id: invocation.id,
        run_id: run.id,
        run_revision: run.revision,
        generation: generation,
        dispatch_id: dispatch_id,
        capability: capability,
        kind: :effect,
        provider_started: true,
        outcome: outcome,
        metadata: %{remote_status: :confirmed, nondeterminism_samples: samples}
      }

      send(owner, {:spectre, :invocation_result, invocation.id, receipt})
    end)
  end

  defp start_advance_worker(data, entry) do
    run = Map.fetch!(data.runs, entry.run_id)

    # `submit_owned/5` already admitted a new Run against the then-active
    # Definition before persisting it. From this point the queued Run is a
    # pinned continuation: activation may move, while authority/revocation is
    # still re-checked at dispatch time.
    with :ok <-
           validate_pinned_run_definition(
             run,
             data.definition_store,
             data.checkpoint_store,
             data.base_opts
           ),
         :ok <- Events.authorize(data, run.definition_ref, :continuation) do
      do_start_advance_worker(data, entry, run)
    else
      {:error, reason} -> fail_run_commit(data, run, reason)
    end
  end

  defp do_start_advance_worker(data, entry, run) do
    # Internal inference Runs are state-neutral and must not claim an unowned
    # Effect from the parent conversational lifecycle. Ordinary turns retain
    # the existing claim-before-execute behavior.
    state =
      if entry_commits_state?(entry),
        do: State.claim_run_lifecycle(data.state, run.id),
        else: data.state

    run = Runs.rebase_run(run, state)
    data = %{data | state: state}

    entry = prepare_entry(entry, run, data)
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()

    {pid, monitor} =
      spawn_advance_worker(owner, run, entry, dispatch_id, capability)

    active = %{
      kind: :advance,
      run_id: run.id,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry
    }

    data
    |> Map.put(:runs, Map.put(data.runs, run.id, run))
    |> Map.put(:active, active)
    |> Map.put(:workers, Map.put(data.workers, pid, active))
    |> disarm_idle_timer()
  end

  defp prepare_entry(%{operation: {:start, input}} = entry, run, data) do
    opts =
      data
      |> runtime_opts(entry.opts, input)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)
      |> put_run_pin(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(%{operation: :advance} = entry, run, data) do
    opts =
      entry.opts
      |> Keyword.put(:state, data.state)
      |> put_run_pin(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(entry, run, data) do
    opts =
      entry.opts
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)
      |> put_run_pin(run)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp spawn_advance_worker(owner, run, entry, dispatch_id, capability) do
    spawn_worker(fn ->
      {outcome, samples} =
        Spectre.Determinism.capture(entry.opts, fn ->
          safe_step(run, fn -> run_operation(run, entry) end)
        end)

      send(
        owner,
        {:spectre, :advance_result, run.id, dispatch_id, capability, outcome, samples}
      )
    end)
  end

  defp run_operation(run, %{operation: :advance, opts: opts}),
    do: Runtime.advance(run, opts)

  defp run_operation(
         run,
         %{operation: {:inference, %InferenceRequest{} = request}, opts: opts}
       ),
       do: Runtime.prepare_inference(run, request, opts)

  defp run_operation(run, %{operation: {:start, input}, opts: opts}) do
    case Runtime.start(run.agent, input, opts) do
      {:error, reason, %Run{} = failed} ->
        {:error, reason, %{failed | state: run.state}}

      step ->
        step
    end
  end

  defp run_operation(run, %{operation: {:resume, command}, opts: opts}),
    do: Runtime.resume(run, command, opts)

  defp apply_step(outcome, entry, data) do
    case outcome do
      {:error, reason, %Run{} = run} ->
        current = Map.get(data.runs, run.id)

        case apply_returned_run(data, run, entry) do
          {:ok, data} ->
            finish_committed_error_step(data, run, reason, entry, current)

          {:error, commit_reason} ->
            fail_run_commit(data, run, commit_reason)
        end

      step ->
        apply_successful_step(step, entry, data)
    end
  end

  defp start_operation?(%{operation: {:start, _input}}), do: true
  defp start_operation?(_entry), do: false

  defp advanced_run?(%Run{} = current, %Run{} = returned),
    do: returned.revision > current.revision

  defp advanced_run?(_current, _returned), do: true

  defp maybe_finalize_degraded_run(
         data,
         %Run{waiting: %Boundary{kind: :reply} = boundary} = run
       ) do
    maybe_finalize_reply(data, {:boundary, boundary, run})
  end

  defp maybe_finalize_degraded_run(data, _run), do: data

  defp apply_successful_step({:continue, %Run{} = run}, entry, data) do
    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      case apply_returned_run(data, run, entry) do
        {:ok, data} ->
          finish_committed_continue_step(data, run, entry)

        {:error, reason} ->
          fail_run_commit(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(
         {:dispatch, %Invocation{kind: :inference} = invocation, %Run{} = run,
          %PreparedInference{} = prepared},
         entry,
         data
       ) do
    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      with :ok <- owner_guard(data, :commit),
           selected <- mark_inference_selection_receipted(run),
           projected <- project_returned_run(data, selected, entry),
           {:ok, prepared_receipt} <-
             prepare_inference_selection_receipt(
               projected,
               selected,
               invocation,
               entry
             ) do
        commit_or_stage_run_receipt(
          projected,
          selected,
          {:inference_selected, invocation, prepared, entry},
          prepared_receipt
        )
      else
        {:error, reason} -> fail_run_commit(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(step, entry, data) do
    run = Runs.step_run(step)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      case apply_returned_run(data, run, entry) do
        {:ok, data} ->
          finish_committed_successful_step(data, step, entry)

        {:error, reason} ->
          fail_run_commit(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  # Receipt-gated boundaries commit their returned Run before delivery. These
  # helpers perform only the post-commit work, so acknowledging a receipt can
  # never apply the same state transition twice.
  defp finish_committed_step(
         data,
         {:error, reason, %Run{} = run},
         entry,
         previous
       ) do
    finish_committed_error_step(data, run, reason, entry, previous)
  end

  defp finish_committed_step(data, {:continue, %Run{} = run}, entry, _previous),
    do: finish_committed_continue_step(data, run, entry)

  defp finish_committed_step(
         data,
         {:dispatch, %Invocation{kind: :inference}, %Run{}, %PreparedInference{}} = step,
         entry,
         _previous
       ) do
    # The effect or policy boundary is already durable, while inference
    # selection is a distinct nondeterministic boundary with its own receipt.
    apply_successful_step(step, %{entry | state_revision: data.state.revision}, data)
  end

  defp finish_committed_step(data, step, entry, _previous),
    do: finish_committed_successful_step(data, step, entry)

  defp finish_committed_error_step(data, run, reason, entry, current) do
    cond do
      Runs.terminal_run?(run) ->
        data
        |> reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_failed, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> Runs.record_terminal(run)
        |> maybe_schedule()
        |> arm_idle_timer()

      start_operation?(entry) ->
        failed = Runs.terminalize_failed_run(run, reason)

        data
        |> Runs.put_run(failed)
        |> reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_failed, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> Runs.record_terminal(failed)
        |> maybe_schedule()
        |> arm_idle_timer()

      advanced_run?(current, run) ->
        degraded = %{run | last_error: reason}

        data
        |> Runs.put_run(degraded)
        |> reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_move_degraded, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> maybe_finalize_degraded_run(degraded)
        |> maybe_schedule()
        |> arm_idle_timer()

      true ->
        data
        |> reply_caller(run.id, {:error, reason})
        |> tap(
          &emit(:run_resume_rejected, &1, %{count: 1}, %{
            run_id: id_digest(run.id),
            reason_class: reason_class(reason)
          })
        )
        |> maybe_schedule()
        |> arm_idle_timer()
    end
  end

  defp finish_committed_continue_step(data, run, entry) do
    data = maybe_record_started_conversation(data, entry, run)

    continuation = %{
      entry
      | operation: :advance,
        input: run.input,
        state_revision: data.state.revision
    }

    data
    |> enqueue_continuation(continuation, start_operation?(entry))
    |> arm_idle_timer()
  end

  defp finish_committed_successful_step(data, step, entry) do
    run = Runs.step_run(step)
    data = reply_projection(data, entry, step)
    data = maybe_finalize_reply(data, step)
    data = if Runs.terminal_run?(run), do: Runs.record_terminal(data, run), else: data

    data
    |> maybe_schedule()
    |> arm_idle_timer()
  end

  defp policy_resolution_entry?(%{operation: {:resume, {:policy, _ref, _resolution}}}),
    do: true

  defp policy_resolution_entry?(_entry), do: false

  defp commit_policy_decision(data, outcome, entry) do
    {:resume, {:policy, boundary_ref, resolution}} = entry.operation

    outcome =
      map_returned_step_run(outcome, fn run ->
        marker = %{
          boundary_id: boundary_ref.boundary_id,
          decision: portable_value(resolution)
        }

        %{run | metadata: Map.put(run.metadata, :policy_decision, marker)}
      end)

    payload = %{
      boundary_id: boundary_ref.boundary_id,
      decision: portable_value(resolution),
      outcome: step_outcome(outcome),
      nondeterminism_samples: Map.get(entry, :nondeterminism_samples, [])
    }

    commit_receipted_step(
      data,
      outcome,
      entry,
      :policy_decision,
      payload,
      causation_id: boundary_ref.boundary_id,
      payload_schema_ref: "spectre.policy.decision/1",
      privacy: :confidential
    )
  end

  defp commit_effect_terminal(data, ownership, %Receipt{} = receipt) do
    invocation = Map.fetch!(ownership, :invocation)

    kind =
      if elem(invocation.operation, 0) == :action, do: :action_terminal, else: :effect_terminal

    outcome =
      map_returned_step_run(receipt.outcome, fn run ->
        marker = %{
          invocation_id: invocation.id,
          effect_id: invocation.subject_id,
          kind: kind,
          idempotency_key: invocation.idempotency_key
        }

        %{run | metadata: Map.put(run.metadata, :effect_terminal, marker)}
      end)

    receipt = %{receipt | outcome: outcome}
    effect = terminal_effect(outcome, invocation.subject_id)

    payload = %{
      effect: effect_receipt_projection(effect, invocation),
      idempotency_key: invocation.idempotency_key,
      operation: invocation.operation,
      outcome: step_outcome(receipt.outcome),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :confirmed),
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }

    commit_receipted_step(
      data,
      receipt.outcome,
      ownership.entry,
      kind,
      payload,
      invocation_id: invocation.id,
      causation_id: invocation.id,
      payload_schema_ref:
        if(kind == :action_terminal,
          do: "spectre.action.terminal/1",
          else: "spectre.effect.terminal/1"
        ),
      privacy: :confidential
    )
  end

  defp commit_receipted_step(data, outcome, entry, kind, payload, receipt_opts) do
    run = returned_step_run(outcome)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      previous = Map.get(data.runs, run.id)

      with :ok <- owner_guard(data, :commit),
           projected <- project_returned_run(data, run, entry),
           {:ok, prepared} <-
             Receipts.prepare_run(
               data,
               projected.state,
               run,
               kind,
               payload,
               receipt_opts
             ) do
        commit_or_stage_run_receipt(
          projected,
          run,
          {:committed_step, outcome, entry, previous},
          prepared
        )
      else
        {:error, reason} -> fail_run_commit(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp returned_step_run({:continue, %Run{} = run}), do: run
  defp returned_step_run({:error, _reason, %Run{} = run}), do: run
  defp returned_step_run(step), do: Runs.step_run(step)

  defp map_returned_step_run({:continue, %Run{} = run}, mapper),
    do: {:continue, mapper.(run)}

  defp map_returned_step_run({:await, invocation, %Run{} = run}, mapper),
    do: {:await, invocation, mapper.(run)}

  defp map_returned_step_run({:dispatch, invocation, %Run{} = run, prepared}, mapper),
    do: {:dispatch, invocation, mapper.(run), prepared}

  defp map_returned_step_run({:boundary, boundary, %Run{} = run}, mapper),
    do: {:boundary, boundary, mapper.(run)}

  defp map_returned_step_run({:complete, result, %Run{} = run}, mapper),
    do: {:complete, result, mapper.(run)}

  defp map_returned_step_run({:error, reason, %Run{} = run}, mapper),
    do: {:error, reason, mapper.(run)}

  defp step_outcome({:continue, %Run{}}), do: :continue
  defp step_outcome({:await, %Invocation{}, %Run{}}), do: :await
  defp step_outcome({:dispatch, %Invocation{}, %Run{}, %PreparedInference{}}), do: :dispatch
  defp step_outcome({:boundary, %Boundary{}, %Run{}}), do: :boundary
  defp step_outcome({:complete, %Result{}, %Run{}}), do: :complete

  defp step_outcome({:error, reason, %Run{}}),
    do: %{status: :error, reason: portable_failure(reason)}

  defp terminal_effect(outcome, effect_id) do
    run = returned_step_run(outcome)

    case run.result do
      %Result{effects: effects} ->
        Enum.find(Enum.reverse(effects), &(&1.id == effect_id and Effect.terminal?(&1))) ||
          State.resolved_effect(run.state, effect_id)

      _missing_result ->
        State.resolved_effect(run.state, effect_id)
    end
  end

  defp effect_receipt_projection(%Effect{} = effect, _invocation) do
    %{
      id: effect.id,
      kind: effect.kind,
      name: effect.name,
      status: effect.status,
      via: Effect.via(effect),
      schema_hash: Effect.schema_hash(effect),
      result: portable_value(effect.result),
      error: portable_value(effect.error),
      evidence: Effect.result_evidence(effect)
    }
  end

  defp effect_receipt_projection(nil, invocation) do
    %{
      id: invocation.subject_id,
      kind: elem(invocation.operation, 0),
      name: elem(invocation.operation, 1),
      status: :unresolved
    }
  end

  defp portable_value(value) do
    case Value.validate(value) do
      :ok -> value
      {:error, _reason} -> %{class: reason_class(value)}
    end
  end

  # The dispatch intent is a separate durable state from selection. Recovery
  # may safely dispatch `:selected`, while `:dispatching` is treated as an
  # uncertain external call unless the adapter can reconcile it.
  defp commit_inference_dispatch_intent(data, run, invocation, prepared, entry) do
    with {:ok, run, budget_snapshot} <-
           reserve_inference_budget(run, invocation, prepared, entry),
         {run, entry} <- prepare_stream_consumer_token(run, invocation, entry) do
      continuation = %{
        run.inference_continuation
        | provider_status: :dispatching,
          recovery: %{status: :dispatch_intent_committed}
      }

      dispatching = %{run | inference_continuation: continuation}

      payload = %{
        idempotency_key: invocation.idempotency_key,
        selection: dispatching.inference_continuation.frozen_selection,
        streaming?: invocation.metadata.streaming?,
        consumer_token_digest: continuation.consumer_token_digest,
        resume?: Map.has_key?(entry, :stream_resume_from),
        resume_cursor_digest: provider_cursor_digest(continuation.resume_cursor),
        budget: budget_snapshot
      }

      receipt_opts = inference_receipt_opts(invocation, "spectre.inference.attempt-started/1")

      case Receipts.prepare_run(
             data,
             data.state,
             dispatching,
             :inference_attempt_started,
             payload,
             receipt_opts
           ) do
        {:ok, prepared_receipt} ->
          commit_or_stage_run_receipt(
            data,
            dispatching,
            {:inference_attempt_started, invocation, prepared, entry, budget_snapshot},
            prepared_receipt
          )

        {:error, reason} ->
          fail_run_commit(%{data | state_lock: nil}, dispatching, reason)
      end
    else
      {:error, reason} -> fail_run_commit(%{data | state_lock: nil}, run, reason)
    end
  end

  # Only a digest crosses the canonical boundary. The bearer token itself is
  # held by the caller/session and authorizes attach and control operations.
  defp prepare_stream_consumer_token(run, %{metadata: %{streaming?: true}}, entry) do
    token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())

    continuation = %{
      run.inference_continuation
      | consumer_token_digest: stream_token_digest(token)
    }

    {%{run | inference_continuation: continuation}, Map.put(entry, :stream_consumer_token, token)}
  end

  defp prepare_stream_consumer_token(run, _invocation, entry), do: {run, entry}

  defp prepare_inference_selection_receipt(data, run, invocation, entry) do
    payload = %{
      purpose: run.inference_continuation.purpose,
      attempt: run.inference_continuation.attempt,
      selection: run.inference_continuation.frozen_selection,
      recoverable?: run.inference_continuation.recoverable?,
      nondeterminism_samples: Map.get(entry, :nondeterminism_samples, [])
    }

    Receipts.prepare_run(
      data,
      data.state,
      run,
      :inference_selected,
      payload,
      inference_receipt_opts(invocation, "spectre.inference.selected/1")
    )
  end

  defp mark_inference_selection_receipted(run) do
    continuation = %{
      run.inference_continuation
      | recovery: %{status: :selection_receipted}
    }

    %{run | inference_continuation: continuation}
  end

  defp inference_receipt_opts(invocation, schema_ref) do
    [
      inference_id: invocation.inference_id,
      invocation_id: invocation.id,
      attempt_id: invocation.attempt_id,
      control_revision: invocation.control_revision,
      stream_epoch: invocation.stream_epoch,
      causation_id: invocation.id,
      payload_schema_ref: schema_ref,
      privacy: :confidential
    ]
  end

  defp start_inference_worker(data, run, invocation, prepared, entry, budget_snapshot) do
    if invocation.metadata.streaming? do
      start_inference_stream(data, run, invocation, prepared, entry, budget_snapshot)
    else
      start_one_shot_inference(data, run, invocation, prepared, entry, budget_snapshot)
    end
  end

  defp start_one_shot_inference(data, run, invocation, prepared, entry, budget_snapshot) do
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()

    {pid, monitor} =
      spawn_worker(fn ->
        {outcome, samples} =
          Spectre.Determinism.capture(entry.opts, fn ->
            Inference.execute(prepared, entry.opts)
          end)

        outcome = InferenceFailure.sanitize_outcome(outcome)

        {usage, usage_quality} =
          UsageAccounting.complete_response_outcome(outcome, budget_snapshot)

        receipt = %Receipt{
          invocation_id: invocation.id,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: dispatch_id,
          capability: capability,
          kind: :inference,
          attempt_id: invocation.attempt_id,
          control_revision: invocation.control_revision,
          stream_epoch: invocation.stream_epoch,
          provider_started: true,
          outcome: outcome,
          usage: usage,
          usage_quality: usage_quality,
          metadata: %{remote_status: :confirmed, nondeterminism_samples: samples}
        }

        send(owner, {:spectre, :invocation_result, invocation.id, receipt})
      end)

    ownership = %{
      mode: :one_shot,
      invocation_id: invocation.id,
      invocation_kind: :inference,
      invocation: invocation,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry,
      prepared: prepared,
      budget_snapshot: budget_snapshot
    }

    worker = Map.put(ownership, :kind, :invocation)

    data
    |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
    |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
    |> Map.put(:workers, Map.put(data.workers, pid, worker))
    |> arm_inference_attempt_timer(ownership, budget_snapshot)
    |> disarm_idle_timer()
    |> tap(fn next ->
      emit(
        :invocation_dispatched,
        next,
        %{count: 1},
        %{run_id: id_digest(run.id), invocation_id: id_digest(invocation.id), kind: :inference}
      )
    end)
  end

  defp start_inference_stream(data, run, invocation, prepared, entry, budget_snapshot) do
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    consumer_token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())
    reservation = Map.get(data.stream_reservations, run.id)

    stream =
      InferenceStream.new(
        inference_id: invocation.inference_id,
        invocation_id: invocation.id,
        attempt_id: invocation.attempt_id,
        run_id: run.id,
        run_revision: run.revision,
        generation: data.generation,
        dispatch_id: dispatch_id,
        control_revision: invocation.control_revision,
        stream_epoch: invocation.stream_epoch,
        consumer_token: consumer_token,
        instance_ref: data.ref,
        registry: data.stream_registry,
        instance_registry: data.registry,
        demand: Keyword.get(entry.opts, :stream_demand, 8),
        next_timeout: Keyword.get(entry.opts, :stream_next_timeout, 30_000)
      )

    session_opts = [
      instance: self(),
      invocation: invocation,
      prepared: prepared,
      generation: data.generation,
      dispatch_id: dispatch_id,
      capability: capability,
      consumer_token: consumer_token,
      registry: data.stream_registry,
      capacity_reservation: reservation,
      capacity_server: data.stream_capacity,
      budget_snapshot: budget_snapshot,
      resume_from: Map.get(entry, :stream_resume_from),
      determinism_opts: entry.opts
    ]

    case RunnerSupervisor.start_stream_session(data.runner_supervisor, session_opts) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        ownership = %{
          mode: :stream,
          invocation_id: invocation.id,
          invocation_kind: :inference,
          invocation: invocation,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: dispatch_id,
          capability: capability,
          pid: pid,
          monitor: monitor,
          entry: entry,
          stream: stream,
          prepared: prepared,
          budget_snapshot: budget_snapshot,
          capacity_reservation: reservation
        }

        data
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
        |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
        |> Map.put(:stream_sessions, Map.put(data.stream_sessions, invocation.id, ownership))
        |> Map.put(:stream_monitors, Map.put(data.stream_monitors, pid, invocation.id))
        |> Map.put(:stream_reservations, Map.delete(data.stream_reservations, run.id))
        |> reply_stream_caller(run.id, stream)
        |> disarm_idle_timer()
        |> tap(fn next ->
          emit(
            :inference_stream_reserved,
            next,
            %{count: 1},
            %{
              run_id: id_digest(run.id),
              invocation_id: id_digest(invocation.id),
              stream_epoch: id_digest(invocation.stream_epoch)
            }
          )
        end)

      {:error, reason} ->
        data
        |> InferenceCapacity.release(run.id)
        |> Map.put(:state_lock, nil)
        |> fail_run_commit(run, {:stream_session_start_failed, reason})
    end
  end

  defp reserve_inference_budget(run, invocation, prepared, entry) do
    continuation = run.inference_continuation

    with {:ok, budget} <- inference_budget(continuation, prepared, entry),
         requested <- inference_budget_reservation(prepared, budget),
         {:ok, budget, snapshot} <- Budget.reserve(budget, invocation.attempt_id, requested) do
      continuation = %{continuation | budget: budget}
      {:ok, %{run | inference_continuation: continuation}, snapshot}
    end
  end

  defp inference_budget(%{budget: %Budget{} = budget}, prepared, entry) do
    with :ok <- validate_cost_budget(budget.limits, budget.pricing_ref, prepared, entry),
         :ok <- validate_rebound_pricing_ref(budget, entry) do
      {:ok, budget}
    end
  end

  defp inference_budget(continuation, prepared, entry),
    do: new_inference_budget(continuation, prepared, entry)

  defp new_inference_budget(continuation, prepared, entry) do
    with {:ok, configured} <- normalize_inference_budget(entry.opts),
         {:ok, attempts} <- inference_attempt_limit(prepared, entry),
         {:ok, pricing_ref} <- inference_pricing_ref(entry.opts),
         :ok <- validate_cost_budget(configured, pricing_ref, prepared, entry) do
      constraints = prepared.descriptor.constraints
      aggregate_input = multiply_limit(constraints.context_tokens, attempts)
      aggregate_output = multiply_limit(constraints.maximum_output_tokens, attempts)

      limits =
        configured
        |> maybe_put_budget_limit(:input_tokens, aggregate_input)
        |> maybe_put_budget_limit(:output_tokens, aggregate_output)
        |> maybe_put_budget_limit(:total_tokens, sum_limits(aggregate_input, aggregate_output))
        |> maybe_put_budget_limit(:attempts, attempts)
        |> maybe_put_budget_limit(
          :duration_ms,
          Keyword.get(entry.opts, :stream_max_duration_ms, constraints.maximum_latency_ms)
        )

      deadline_at =
        case Map.get(limits, :duration_ms) do
          duration when is_integer(duration) and duration > 0 ->
            Spectre.Determinism.system_time(:millisecond) + duration

          _none ->
            nil
        end

      {:ok,
       Budget.new(continuation.inference_id,
         limits: limits,
         deadline_at: deadline_at,
         pricing_ref: pricing_ref,
         estimation_policy:
           if(MapSet.member?(prepared.stream_capabilities, :incremental_usage),
             do: :provider,
             else: :conservative
           )
       )}
    end
  end

  defp normalize_inference_budget(opts) do
    value = Keyword.get(opts, :inference_budget, %{})

    with {:ok, entries} <- budget_entries(value) do
      Enum.reduce_while(entries, {:ok, %{}}, fn {key, limit}, {:ok, limits} ->
        with {:ok, field} <- budget_field(key),
             :ok <- validate_budget_limit(field, limit) do
          {:cont, {:ok, Map.put(limits, field, limit)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp budget_entries(value) when is_list(value) do
    if Keyword.keyword?(value), do: {:ok, value}, else: {:error, :invalid_inference_budget}
  end

  defp budget_entries(value) when is_map(value) and not is_struct(value),
    do: {:ok, Map.to_list(value)}

  defp budget_entries(_value), do: {:error, :invalid_inference_budget}

  defp budget_field(field)
       when field in [
              :input_tokens,
              :output_tokens,
              :total_tokens,
              :cost,
              :attempts,
              :duration_ms
            ],
       do: {:ok, field}

  defp budget_field(field) when is_binary(field) do
    case field do
      "input_tokens" -> {:ok, :input_tokens}
      "output_tokens" -> {:ok, :output_tokens}
      "total_tokens" -> {:ok, :total_tokens}
      "cost" -> {:ok, :cost}
      "attempts" -> {:ok, :attempts}
      "duration_ms" -> {:ok, :duration_ms}
      _unknown -> {:error, {:unknown_inference_budget_limit, field}}
    end
  end

  defp budget_field(field), do: {:error, {:unknown_inference_budget_limit, field}}

  defp validate_budget_limit(:attempts, value) when is_integer(value) and value > 0, do: :ok

  defp validate_budget_limit(:attempts, value),
    do: {:error, {:invalid_inference_budget_limit, :attempts, value}}

  defp validate_budget_limit(_field, value) when is_number(value) and value >= 0,
    do: :ok

  defp validate_budget_limit(field, value),
    do: {:error, {:invalid_inference_budget_limit, field, value}}

  defp inference_attempt_limit(prepared, entry) do
    fallback_attempts = length(prepared.selection.fallback_chain) + 1

    one_shot_default =
      if prepared.selection.selector == Spectre.Inference.Selector.Default,
        do: max(fallback_attempts, 1),
        else: max(fallback_attempts, 2)

    value =
      prepared.descriptor.constraints.max_attempts ||
        if(prepared.stream_adapter,
          do: Keyword.get(entry.opts, :stream_max_attempts, 3),
          else: Keyword.get(entry.opts, :inference_max_attempts, one_shot_default)
        )

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, {:invalid_inference_attempt_limit, value}}
  end

  defp inference_pricing_ref(opts) do
    case Keyword.get(opts, :inference_pricing_ref) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_inference_pricing_ref, value}}
    end
  end

  defp validate_cost_budget(configured, pricing_ref, prepared, entry) do
    if Map.has_key?(configured, :cost) do
      cond do
        is_nil(pricing_ref) ->
          {:error, :inference_cost_budget_requires_pricing_ref}

        prepared.stream_adapter &&
            not MapSet.member?(prepared.stream_capabilities, :cost_usage) ->
          {:error, :inference_cost_budget_usage_unavailable}

        is_nil(prepared.stream_adapter) &&
            Keyword.get(entry.opts, :inference_cost_usage?, false) != true ->
          {:error, :inference_cost_budget_usage_unavailable}

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_rebound_pricing_ref(%Budget{limits: limits}, _entry)
       when not is_map_key(limits, :cost),
       do: :ok

  defp validate_rebound_pricing_ref(%Budget{pricing_ref: expected}, entry) do
    case inference_pricing_ref(entry.opts) do
      {:ok, ^expected} -> :ok
      {:ok, _different} -> {:error, :inference_pricing_ref_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp inference_budget_reservation(prepared, budget) do
    input_tokens = prepared.descriptor.constraints.context_tokens || 0
    output_tokens = prepared.descriptor.constraints.maximum_output_tokens || 0
    # Cost cannot be predicted safely from the core. Reserve the complete
    # remaining cost allowance so an ambiguous attempt blocks successors
    # until reconciliation establishes an authoritative settlement.
    cost = Map.get(Budget.remaining(budget), :cost, 0)

    %InferenceUsage{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens,
      cost: cost
    }
  end

  defp maybe_put_budget_limit(limits, _field, nil), do: limits
  defp maybe_put_budget_limit(limits, field, value), do: Map.put_new(limits, field, value)

  defp multiply_limit(nil, _multiplier), do: nil
  defp multiply_limit(value, multiplier), do: value * multiplier

  defp sum_limits(left, right) when is_number(left) and is_number(right),
    do: left + right

  # A missing component means that dimension is unbounded. Treating it as
  # zero would accidentally turn an input estimate into a hard total-token
  # ceiling for ordinary one-shot inference.
  defp sum_limits(_left, _right), do: nil

  defp accept_inference_receipt(data, ownership, receipt) do
    data =
      data
      |> clear_inference_attempt_timer(receipt.invocation_id)
      |> maybe_finish_inference_worker(ownership)
      |> Map.put(:invocations, Map.delete(data.invocations, receipt.invocation_id))

    case receipt.outcome do
      {:ok, %InferenceResponse{} = response} ->
        case enforce_inference_attempt_budget(ownership, receipt.usage) do
          :ok ->
            commit_inference_terminal(data, ownership, receipt, response)

          {:error, field} ->
            reason = {:inference_budget_exceeded, field}
            failed_receipt = %{receipt | outcome: {:error, reason}}
            fail_inference_attempt(data, ownership, failed_receipt, reason)
        end

      {:error, reason} ->
        fail_inference_attempt(data, ownership, receipt, reason)
    end
  end

  defp inference_receipt_disposition(data, ownership, receipt) do
    invocation = ownership.invocation

    case Canonical.fetch(data.canonical, :inference_control) do
      {:ok, controls} ->
        controls
        |> Map.get(invocation.inference_id)
        |> InferenceControl.receipt_disposition(invocation, receipt.outcome)

      {:error, _reason} ->
        :stale
    end
  end

  defp cancelled_race_receipt(receipt, reason) do
    metadata =
      receipt.metadata
      |> Map.put(:semantic, :cancelled)
      |> Map.put(:remote_status, :ambiguous)

    %{receipt | outcome: {:error, {:cancelled, reason}}, metadata: metadata}
  end

  defp maybe_finish_inference_worker(data, %{mode: :stream}), do: data
  defp maybe_finish_inference_worker(data, ownership), do: finish_worker(data, ownership.pid)

  defp commit_inference_terminal(data, ownership, receipt, response) do
    run = Map.fetch!(data.runs, ownership.run_id)

    case settle_inference_budget(
           run.inference_continuation,
           ownership.invocation.attempt_id,
           receipt.usage,
           :confirmed
         ) do
      {:ok, continuation} ->
        commit_settled_inference_terminal(
          data,
          run,
          continuation,
          ownership,
          receipt,
          response
        )

      {:error, continuation, reason} ->
        commit_budget_settlement_failure(
          data,
          run,
          continuation,
          ownership,
          receipt,
          reason
        )
    end
  end

  defp commit_settled_inference_terminal(
         data,
         run,
         continuation,
         ownership,
         receipt,
         response
       ) do
    portable_response = %{
      response
      | selection: continuation.frozen_selection,
        usage: if(map_size(receipt.usage) > 0, do: receipt.usage, else: response.usage),
        provider_request_id: provider_request_digest(response.provider_request_id),
        metadata: portable_response_metadata(response.metadata)
    }

    accepted_continuation = %{
      continuation
      | provider_status: :terminal,
        stream_usage_quality: receipt.usage_quality,
        last_response: portable_response,
        recovery: %{status: :terminal_receipt_committed}
    }

    accepted = %{run | inference_continuation: accepted_continuation}

    payload = %{
      outcome: :completed,
      provider_started: true,
      response: portable_response,
      usage: portable_response.usage,
      usage_quality: receipt.usage_quality,
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }

    receipt_opts = [
      inference_id: accepted_continuation.inference_id,
      invocation_id: ownership.invocation.id,
      attempt_id: ownership.invocation.attempt_id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      causation_id: ownership.invocation.id,
      payload_schema_ref: "spectre.inference.attempt-terminal/1",
      privacy: :confidential
    ]

    case Receipts.prepare_run(
           data,
           data.state,
           accepted,
           :inference_attempt_terminal,
           payload,
           receipt_opts
         ) do
      {:ok, prepared} ->
        commit_or_stage_inference_receipt(
          data,
          accepted,
          ownership,
          {:success, portable_response},
          prepared
        )

      {:error, reason} ->
        fail_run_commit(%{data | state_lock: nil}, accepted, reason)
    end
  end

  defp commit_or_stage_inference_receipt(
         data,
         accepted,
         ownership,
         resume,
         prepared
       ) do
    commit_or_stage_run_receipt(
      data,
      accepted,
      {:inference_terminal, ownership, resume},
      prepared
    )
  end

  defp prepare_authority_decision_receipt(
         data,
         definition_ref,
         axis,
         value,
         lifecycle,
         writes,
         commit_opts
       ) do
    previous = Events.lifecycle(data, definition_ref)
    {manifest_digest, closure_digest} = receipt_definition_digests(data, definition_ref)

    payload = %{
      definition_ref: to_string(definition_ref),
      axis: axis,
      from: Map.fetch!(previous, axis),
      to: value,
      lifecycle_revision: lifecycle.revision,
      authority_epoch: lifecycle.authority_epoch,
      changed_at: lifecycle.changed_at
    }

    Receipts.prepare_sections(
      data,
      writes,
      :authority_decision,
      payload,
      correlation_id: Keyword.fetch!(commit_opts, :correlation_id),
      causation_id: Keyword.get(commit_opts, :causation_id),
      definition_ref: to_string(definition_ref),
      manifest_digest: manifest_digest,
      closure_digest: closure_digest,
      payload_schema_ref: "spectre.authority.decision/1",
      privacy: :internal
    )
  end

  defp receipt_definition_digests(
         %{activation: %Activation{definition_ref: definition_ref} = activation},
         definition_ref
       ),
       do: {activation.manifest_digest, activation.closure_digest}

  defp receipt_definition_digests(_data, _definition_ref), do: {nil, nil}

  defp commit_or_stage_run_receipt(data, run, resume, prepared) do
    case data.receipt_mode do
      :required ->
        start_required_receipt_staging(data, run, resume, prepared)

      mode when mode in [:disabled, :observational] ->
        retained = Runs.put_run(data, run)

        case Receipts.commit(retained, prepared, mode) do
          {:ok, committed, envelope} ->
            committed =
              if mode == :observational,
                do: start_observational_receipt_delivery(committed, envelope),
                else: committed

            resume_live_receipted_boundary(committed, run, resume, envelope)

          {:error, reason} ->
            fail_run_commit(%{data | state_lock: nil}, run, reason)
        end
    end
  end

  defp commit_or_stage_sections_receipt(data, resume, prepared) do
    case data.receipt_mode do
      :required ->
        start_required_sections_receipt_staging(data, resume, prepared)

      mode when mode in [:disabled, :observational] ->
        case Receipts.commit(data, prepared, mode) do
          {:ok, committed, envelope} ->
            committed =
              if mode == :observational,
                do: start_observational_receipt_delivery(committed, envelope),
                else: committed

            resume_live_receipted_boundary(committed, nil, resume, envelope)

          {:error, reason} ->
            fail_receipted_boundary(data, resume, reason)
        end
    end
  end

  defp start_required_receipt_staging(data, run, resume, prepared) do
    do_start_required_receipt_staging(data, run, resume, prepared)
  end

  defp start_required_sections_receipt_staging(data, resume, prepared) do
    do_start_required_receipt_staging(data, nil, resume, prepared)
  end

  defp do_start_required_receipt_staging(data, run, resume, prepared, attempt \\ 0) do
    owner = self()
    token = Spectre.Identity.uuid7()
    sink = data.receipt_sink
    opts = receipt_sink_opts(data)

    callback = fn ->
      result = ReceiptSink.put_payload(sink, prepared.envelope, opts)
      send(owner, {:spectre, :receipt_payload_staged, token, result})
    end

    case Task.Supervisor.start_child(Spectre.Receipt.TaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        staging = %{
          token: token,
          pid: pid,
          monitor: monitor,
          run: run,
          resume: resume,
          prepared: prepared,
          attempt: attempt
        }

        data
        |> Map.put(
          :state_lock,
          data.state_lock ||
            %{
              run_id: run && run.id,
              receipt_id: prepared.envelope.id,
              receipt_kind: prepared.envelope.kind
            }
        )
        |> Map.put(:receipt_staging, Map.put(data.receipt_staging, token, staging))
        |> disarm_idle_timer()

      {:error, reason} ->
        fail_receipted_boundary(
          %{data | state_lock: nil},
          resume,
          {:receipt_payload_task_start_failed, reason},
          run
        )
    end
  end

  defp maybe_retain_staged_run(data, %Run{} = run), do: Runs.put_run(data, run)
  defp maybe_retain_staged_run(data, nil), do: data

  defp fail_receipt_staging(data, staging, reason) do
    fail_receipted_boundary(
      %{data | state_lock: nil},
      staging.resume,
      reason,
      staging.run
    )
  end

  defp restage_required_receipt(data, staging, prepared) do
    limit = Keyword.get(data.base_opts, :receipt_staging_rebase_limit, 16)

    if is_integer(limit) and limit > 0 and staging.attempt < limit do
      do_start_required_receipt_staging(
        data,
        staging.run,
        staging.resume,
        prepared,
        staging.attempt + 1
      )
    else
      fail_receipt_staging(data, staging, :required_receipt_staging_starved)
    end
  end

  defp fail_receipted_boundary(data, _resume, reason, %Run{} = run),
    do: fail_run_commit(data, run, reason)

  defp fail_receipted_boundary(data, resume, reason, nil),
    do: fail_receipted_boundary(data, resume, reason)

  defp fail_receipted_boundary(data, {:authority_decision, from, _lifecycle}, reason) do
    GenServer.reply(from, {:error, reason})
    data |> Map.put(:state_lock, nil) |> arm_idle_timer()
  end

  defp start_observational_receipt_delivery(data, envelope) do
    start_receipt_delivery_task(data, envelope.id, %{envelope: envelope, mode: :observational})
  end

  defp maybe_start_receipt_deliveries(%{receipt_mode: :required} = data) do
    case Canonical.fetch(data.canonical, :receipt_outbox) do
      {:ok, %{entries: entries}} ->
        Enum.reduce(entries, data, fn entry, acc ->
          if entry.inserted_revision <= acc.checkpoint_revision and
               not Map.has_key?(acc.receipt_deliveries, entry.id) do
            start_receipt_delivery_task(acc, entry.id, %{entry: entry, mode: :required})
          else
            acc
          end
        end)

      {:error, _reason} ->
        data
    end
  end

  defp maybe_start_receipt_deliveries(data), do: data

  defp maybe_start_receipt_delivery(%{receipt_mode: :required} = data, receipt_id) do
    with {:ok, %{entries: entries}} <- Canonical.fetch(data.canonical, :receipt_outbox),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.id == receipt_id)),
         true <- entry.inserted_revision <= data.checkpoint_revision do
      start_receipt_delivery_task(data, receipt_id, %{entry: entry, mode: :required})
    else
      _missing_or_not_durable -> data
    end
  end

  defp maybe_start_receipt_delivery(data, _receipt_id), do: data

  defp start_receipt_delivery_task(data, receipt_id, delivery) do
    owner = self()
    sink = data.receipt_sink
    opts = receipt_sink_opts(data)

    callback = fn ->
      result = deliver_receipt(sink, delivery, opts)
      send(owner, {:spectre, :receipt_delivery_result, receipt_id, result})
    end

    case Task.Supervisor.start_child(Spectre.Receipt.TaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        ownership = Map.merge(delivery, %{id: receipt_id, pid: pid, monitor: monitor})

        data
        |> clear_receipt_retry(receipt_id)
        |> Map.put(
          :receipt_deliveries,
          Map.put(data.receipt_deliveries, receipt_id, ownership)
        )
        |> disarm_idle_timer()

      {:error, reason} ->
        emit(
          :receipt_delivery_failed,
          data,
          %{count: 1},
          %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
        )

        if delivery.mode == :required do
          data
          |> mark_required_receipt_delivery_failure(receipt_id, reason)
          |> schedule_receipt_retry(receipt_id)
        else
          data
        end
    end
  end

  defp deliver_receipt(sink, %{mode: :observational, envelope: envelope}, opts) do
    case ReceiptSink.append(sink, envelope, opts) do
      {:ok, status} -> {:ok, status, envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_receipt(sink, %{mode: :required, entry: entry}, opts) do
    with {:ok, %ReceiptEnvelope{id: id} = envelope} <-
           ReceiptSink.get_payload(sink, entry.payload_ref, opts),
         true <- id == entry.id,
         true <- ReceiptEnvelope.digest(envelope) == entry.digest do
      case ReceiptSink.append(sink, envelope, opts) do
        {:ok, status} -> {:ok, status, envelope}
        {:error, reason} -> reconcile_receipt_append(sink, envelope, reason, opts)
      end
    else
      :not_found -> {:error, :required_receipt_payload_missing}
      false -> {:error, :required_receipt_payload_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_receipt_append(sink, envelope, append_reason, opts) do
    case ReceiptSink.lookup(sink, envelope.id, opts) do
      {:ok, ^envelope} -> {:ok, :idempotent, envelope}
      {:ok, _different} -> {:error, :receipt_append_reconciliation_conflict}
      :not_found -> {:error, append_reason}
      {:error, reason} -> {:error, {:receipt_append_reconciliation_failed, reason}}
    end
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :observational, id: receipt_id},
         result
       ) do
    outcome = if match?({:ok, _, _}, result), do: :ok, else: :error

    emit(
      :receipt_observed,
      data,
      %{count: 1},
      %{receipt_id: id_digest(receipt_id), outcome: outcome}
    )

    data
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :required, id: receipt_id, entry: entry},
         {:ok, _status, %ReceiptEnvelope{} = envelope}
       ) do
    {resume, remaining_resumes} = Map.pop(data.receipt_resumes, receipt_id)

    with :ok <- ReceiptRecovery.validate(data, entry, envelope),
         {:ok, writes, resume} <- prepare_required_receipt_ack(data, envelope, resume),
         {:ok, committed} <- Receipts.acknowledge(data, receipt_id, writes) do
      committed =
        committed
        |> clear_receipt_retry(receipt_id)
        |> Map.put(:receipt_resumes, remaining_resumes)

      committed
      |> continue_required_receipted_boundary(envelope, resume)
      |> maybe_complete_receipt_recovery()
      |> maybe_start_receipt_deliveries()
    else
      {:error, reason} ->
        emit(
          :receipt_delivery_failed,
          data,
          %{count: 1},
          %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
        )

        data
        |> mark_required_receipt_delivery_failure(receipt_id, reason)
        |> schedule_receipt_retry(receipt_id)
    end
  end

  defp apply_receipt_delivery_result(
         data,
         %{mode: :required, id: receipt_id},
         {:error, reason}
       ) do
    emit(
      :receipt_delivery_failed,
      data,
      %{count: 1},
      %{receipt_id: id_digest(receipt_id), reason_class: reason_class(reason)}
    )

    data
    |> mark_required_receipt_delivery_failure(receipt_id, reason)
    |> schedule_receipt_retry(receipt_id)
  end

  defp prepare_required_receipt_ack(
         data,
         %ReceiptEnvelope{kind: :inference_attempt_started, run_id: run_id},
         resume
       ) do
    with %Run{inference_continuation: continuation} = run <- Map.get(data.runs, run_id),
         {:ok, token, resume} <- required_stream_token(continuation, resume),
         next_continuation <- %{
           continuation
           | consumer_token_digest:
               if(is_binary(token), do: stream_token_digest(token), else: nil),
             recovery: %{status: :provider_dispatch_released}
         },
         next_run <- %{run | inference_continuation: next_continuation},
         {:ok, writes} <- Commit.run_writes(data, data.state, next_run) do
      {:ok, writes, resume}
    else
      nil -> {:error, :required_receipt_run_missing}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_required_receipt_ack(_data, _envelope, resume),
    do: {:ok, %{}, resume}

  defp required_stream_token(
         %{invocation: %{metadata: %{streaming?: true}}},
         {:inference_attempt_started, invocation, prepared, entry, budget_snapshot}
       ) do
    token = Map.get(entry, :stream_consumer_token, Spectre.Identity.uuid7())
    entry = Map.put(entry, :stream_consumer_token, token)

    {:ok, token, {:inference_attempt_started, invocation, prepared, entry, budget_snapshot}}
  end

  defp required_stream_token(%{invocation: %{metadata: %{streaming?: true}}}, nil) do
    token = Spectre.Identity.uuid7()
    {:ok, token, {:recover_inference_attempt_started, token}}
  end

  defp required_stream_token(_continuation, nil),
    do: {:ok, nil, {:recover_inference_attempt_started, nil}}

  defp required_stream_token(_continuation, resume), do: {:ok, nil, resume}

  defp continue_required_receipted_boundary(
         data,
         %ReceiptEnvelope{kind: :inference_attempt_started} = envelope,
         resume
       ) do
    revision = data.canonical.revision
    action = {envelope, resume}
    actions = Map.update(data.durability_resumes, revision, [action], &[action | &1])

    data
    |> Map.put(:durability_resumes, actions)
    |> Checkpoint.force()
  end

  defp continue_required_receipted_boundary(data, envelope, resume),
    do: resume_required_receipted_boundary(data, envelope, resume)

  # Receipt delivery is the durable gate for a non-deterministic boundary. The
  # continuation is intentionally kept outside canonical state while the
  # process is alive; after recovery it is reconstructed from the envelope and
  # the committed Run by `resume_receipted_boundary/2` instead.
  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_terminal, ownership, resume},
         _envelope
       ) do
    resume_inference_boundary(data, run, ownership, resume)
  end

  defp resume_live_receipted_boundary(
         data,
         _run,
         {:committed_step, outcome, entry, previous},
         _envelope
       ) do
    data
    |> Map.put(:state_lock, nil)
    |> finish_committed_step(outcome, entry, previous)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:run_input_admitted, entry},
         _envelope
       ) do
    # Admission has already reserved the Run and its caller before the receipt
    # commit.  The general enqueue guard treats that caller as active, so this
    # continuation must enter the ready queue directly after the durable gate.
    # An unrelated Run may still own the global state lock; only release the
    # receipt lock created for this admission.
    data
    |> release_admission_receipt_lock(run.id)
    |> enqueue_continuation(entry, false)
  end

  defp resume_live_receipted_boundary(
         data,
         _run,
         {:authority_decision, from, lifecycle},
         _envelope
       ) do
    GenServer.reply(from, {:ok, lifecycle})
    data |> Map.put(:state_lock, nil) |> arm_idle_timer()
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_superseded, invocation, prepared, entry},
         _envelope
       ) do
    data =
      publish_inference_lifecycle_event(
        data,
        :attempt_superseded,
        run.inference_continuation.inference_id,
        Map.get(run.inference_continuation.recovery, :previous_invocation_id),
        hd(run.inference_continuation.previous_attempts),
        %{successor_invocation_digest: id_digest(invocation.id)}
      )

    selected = mark_inference_selection_receipted(run)
    projected = Runs.put_run(data, selected)

    case prepare_inference_selection_receipt(projected, selected, invocation, entry) do
      {:ok, prepared_receipt} ->
        commit_or_stage_run_receipt(
          projected,
          selected,
          {:inference_selected, invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        fail_run_commit(%{data | state_lock: nil}, selected, reason)
    end
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_selected, invocation, prepared, entry},
         _envelope
       ) do
    data
    |> maybe_record_started_conversation(entry, run)
    |> commit_inference_dispatch_intent(run, invocation, prepared, entry)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_stream_restarted, invocation, prepared, entry},
         _envelope
       ) do
    data
    |> publish_inference_lifecycle_event(
      :stream_interrupted,
      invocation.inference_id,
      Map.get(run.inference_continuation.stream_recovery, :previous_invocation_id),
      hd(run.inference_continuation.previous_attempts),
      %{outcome: :resuming, successor_invocation_digest: id_digest(invocation.id)}
    )
    |> commit_inference_dispatch_intent(run, invocation, prepared, entry)
  end

  defp resume_live_receipted_boundary(
         data,
         run,
         {:inference_attempt_started, invocation, prepared, entry, budget_snapshot},
         _envelope
       ) do
    start_inference_worker(data, run, invocation, prepared, entry, budget_snapshot)
  end

  defp release_admission_receipt_lock(
         %{state_lock: %{run_id: run_id, receipt_kind: :run_input_admitted}} = data,
         run_id
       ),
       do: %{data | state_lock: nil}

  defp release_admission_receipt_lock(data, _run_id), do: data

  defp resume_required_receipted_boundary(
         %{receipt_recovery_deferred: true} = data,
         _envelope,
         _resume
       ),
       do: data

  defp resume_required_receipted_boundary(data, envelope, nil),
    do: resume_receipted_boundary(data, envelope)

  defp resume_required_receipted_boundary(data, envelope, resume) do
    run = if envelope.run_id, do: Map.get(data.runs, envelope.run_id)
    resume_live_receipted_boundary(data, run, resume, envelope)
  end

  # Provider work is released only after the receipt acknowledgement marker
  # itself is durable. A crash before this callback restores the outbox; a
  # crash after it restores `:provider_dispatch_released` and is reconciled as
  # an uncertain external dispatch instead of being repeated blindly.
  defp resume_durable_boundaries(data, persisted_revision) do
    {ready, pending} =
      Enum.split_with(data.durability_resumes, fn {revision, _actions} ->
        revision <= persisted_revision
      end)

    data = %{data | durability_resumes: Map.new(pending)}

    ready
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(data, fn {_revision, actions}, acc ->
      actions
      |> Enum.reverse()
      |> Enum.reduce(acc, fn {envelope, resume}, next ->
        resume_durable_boundary(next, envelope, resume)
      end)
    end)
  end

  defp resume_durable_boundary(data, envelope, {:recover_inference_attempt_started, token}) do
    data
    |> recover_receipted_inference_attempt(envelope, token)
    |> maybe_complete_receipt_recovery()
  end

  defp resume_durable_boundary(data, envelope, resume) do
    run = if envelope.run_id, do: Map.get(data.runs, envelope.run_id)
    next = resume_live_receipted_boundary(data, run, resume, envelope)

    maybe_complete_receipt_recovery(next)
  end

  defp recover_receipted_inference_attempt(data, envelope, consumer_token) do
    with %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{id: invocation_id} = invocation,
           inference_continuation: continuation
         } = run <- Map.get(data.runs, envelope.run_id),
         true <- invocation_id == envelope.invocation_id,
         opts <-
           data
           |> runtime_opts(Inference.Descriptor.options(continuation.descriptor), run.input)
           |> put_run_pin(run),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         entry <- recovered_inference_entry(data, run, opts),
         {:ok, run, budget_snapshot} <-
           reserve_inference_budget(run, invocation, prepared, entry),
         {:ok, data, reservation} <-
           reserve_recovered_stream_capacity(data, run, invocation),
         entry <-
           entry
           |> Map.put(:stream_capacity_reservation, reservation)
           |> maybe_put_recovered_stream_token(consumer_token) do
      data
      |> Runs.put_run(run)
      |> start_inference_worker(run, invocation, prepared, entry, budget_snapshot)
    else
      false ->
        terminalize_recovered_inference(data, envelope.run_id, :stale_attempt_start_receipt)

      nil ->
        terminalize_recovered_inference(data, envelope.run_id, :missing_attempt_start_run)

      {:error, reason} ->
        terminalize_recovered_inference(data, envelope.run_id, reason)
    end
  end

  defp reserve_recovered_stream_capacity(data, run, %{metadata: %{streaming?: true}}) do
    InferenceCapacity.reserve(data, run.id, :stream)
  end

  defp reserve_recovered_stream_capacity(data, _run, _invocation),
    do: {:ok, data, nil}

  defp maybe_put_recovered_stream_token(entry, token) when is_binary(token),
    do: Map.put(entry, :stream_consumer_token, token)

  defp maybe_put_recovered_stream_token(entry, _token), do: entry

  defp maybe_complete_receipt_recovery(%{receipt_recovery_deferred: true} = data) do
    case Canonical.fetch(data.canonical, :receipt_outbox) do
      {:ok, %{entries: []}} when map_size(data.durability_resumes) > 0 ->
        data

      {:ok, %{entries: []}} ->
        candidate = %{data | receipt_recovery_deferred: false, state_lock: nil}

        case recover_runtime_state(candidate) do
          {:ok, recovered} ->
            recovered
            |> maybe_schedule()
            |> maybe_schedule_operations()

          {:error, reason} ->
            emit(
              :receipt_recovery_failed,
              candidate,
              %{count: 1},
              %{reason_class: reason_class(reason)}
            )

            %{
              candidate
              | checkpoint_error: {:required_receipt_recovery_failed, reason},
                state_lock: %{receipt_recovery_failed: true}
            }
        end

      _pending_or_invalid ->
        data
    end
  end

  defp maybe_complete_receipt_recovery(data), do: data

  defp resume_receipted_boundary(
         data,
         %ReceiptEnvelope{
           kind: :inference_attempt_terminal,
           run_id: run_id,
           invocation_id: receipt_invocation_id
         }
       ) do
    case Map.get(data.runs, run_id) do
      %Run{
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{kind: :inference} = invocation,
        inference_continuation: %{last_response: %InferenceResponse{} = response}
      } = run ->
        opts =
          data
          |> runtime_opts(
            Spectre.Inference.Descriptor.options(run.inference_continuation.descriptor),
            run.input
          )
          |> put_run_pin(run)

        entry = %{
          run_id: run.id,
          operation: :advance,
          projection: :result,
          input: run.input,
          opts: opts,
          state_revision: data.state.revision,
          internal?: not Map.has_key?(data.callers, run.id),
          admitted?: false
        }

        start_inference_resume_worker(
          data,
          run,
          %{invocation: invocation, entry: entry},
          response
        )

      %Run{status: :failed, last_error: failure} = run ->
        data
        |> Map.put(:state_lock, nil)
        |> notify_stream_attempt_failed(receipt_invocation_id, failure)
        |> reply_caller(run.id, {:error, failure})
        |> Runs.record_terminal(run)
        |> maybe_schedule()
        |> arm_idle_timer()

      _already_applied_or_missing ->
        data
    end
  end

  defp resume_receipted_boundary(
         data,
         %ReceiptEnvelope{
           kind: kind,
           run_id: run_id,
           invocation_id: invocation_id
         }
       )
       when kind == :inference_consumer_never_attached do
    case Map.get(data.runs, run_id) do
      %Run{status: :failed, last_error: failure} = run ->
        data
        |> Map.put(:state_lock, nil)
        |> notify_stream_attempt_failed(invocation_id, failure)
        |> reply_caller(run.id, {:error, failure})
        |> Runs.record_terminal(run)
        |> maybe_schedule()
        |> arm_idle_timer()

      _already_applied_or_missing ->
        data
    end
  end

  defp resume_receipted_boundary(data, _envelope), do: data

  defp schedule_receipt_retry(data, receipt_id) do
    if Map.has_key?(data.receipt_retry_timers, receipt_id) do
      data
    else
      delay = positive_timeout(data.base_opts, :receipt_retry_interval, 1_000)
      timer = Process.send_after(self(), {:spectre, :receipt_delivery_retry, receipt_id}, delay)

      %{data | receipt_retry_timers: Map.put(data.receipt_retry_timers, receipt_id, timer)}
    end
  end

  defp clear_receipt_retry(data, receipt_id) do
    case Map.pop(data.receipt_retry_timers, receipt_id) do
      {nil, timers} ->
        %{data | receipt_retry_timers: timers}

      {timer, timers} ->
        _cancelled = Process.cancel_timer(timer)
        %{data | receipt_retry_timers: timers}
    end
  end

  defp positive_timeout(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> min(value, @max_timer_delay)
      _invalid -> default
    end
  end

  defp receipt_staging_by_pid(data, pid, monitor) do
    Enum.find_value(data.receipt_staging, fn {_token, staging} ->
      if staging.pid == pid and staging.monitor == monitor, do: staging
    end)
  end

  defp receipt_delivery_by_pid(data, pid, monitor) do
    Enum.find_value(data.receipt_deliveries, fn {_id, delivery} ->
      if delivery.pid == pid and delivery.monitor == monitor, do: delivery
    end)
  end

  defp receipt_staging_down(data, _staging, :normal), do: data

  defp receipt_staging_down(data, staging, reason) do
    remaining = Map.delete(data.receipt_staging, staging.token)
    failure = {:required_receipt_payload_task_down, reason}

    fail_receipt_staging(
      %{data | receipt_staging: remaining, state_lock: nil},
      staging,
      failure
    )
  end

  defp receipt_delivery_down(data, _delivery, :normal), do: data

  defp receipt_delivery_down(data, delivery, reason) do
    remaining = Map.delete(data.receipt_deliveries, delivery.id)
    data = %{data | receipt_deliveries: remaining}

    if delivery.mode == :required do
      emit(
        :receipt_delivery_failed,
        data,
        %{count: 1},
        %{receipt_id: id_digest(delivery.id), reason_class: reason_class(reason)}
      )

      data
      |> mark_required_receipt_delivery_failure(delivery.id, reason)
      |> schedule_receipt_retry(delivery.id)
    else
      data
    end
  end

  defp receipt_sink_opts(data) do
    [
      instance_ref: data.ref,
      owner_fencing_token: data.owner_lease.fencing_token
    ]
  end

  defp mark_required_receipt_delivery_failure(data, receipt_id, reason) do
    case Receipts.mark_delivery_failure(data, receipt_id, reason_class(reason)) do
      {:ok, committed} -> committed
      {:error, _reason} -> data
    end
  end

  defp stream_session_down(data, invocation_id, pid, monitor, reason) do
    case Map.get(data.stream_sessions, invocation_id) do
      %{pid: ^pid, monitor: ^monitor, run_id: run_id} = ownership ->
        data = %{
          data
          | stream_sessions: Map.delete(data.stream_sessions, invocation_id),
            stream_monitors: Map.delete(data.stream_monitors, pid)
        }

        case {Map.has_key?(data.invocations, invocation_id), Map.get(data.runs, run_id)} do
          {true, %Run{status: status}} when status not in [:complete, :failed] ->
            liveness = Map.get(data.inference_liveness_clock, invocation_id, %{})

            receipt = %Receipt{
              invocation_id: invocation_id,
              run_id: run_id,
              run_revision: ownership.run_revision,
              generation: ownership.generation,
              dispatch_id: ownership.dispatch_id,
              capability: ownership.capability,
              kind: :inference,
              attempt_id: ownership.invocation.attempt_id,
              control_revision: ownership.invocation.control_revision,
              stream_epoch: ownership.invocation.stream_epoch,
              provider_started: Map.get(liveness, :state) != :awaiting_consumer,
              usage: Map.get(liveness, :usage, %{}),
              outcome: {:error, {:stream_interrupted, reason_class(reason)}},
              metadata: %{semantic: :interrupted, remote_status: :ambiguous}
            }

            accept_inference_receipt(data, ownership, receipt)

          _consumed_terminal_or_missing ->
            # A terminal receipt consumes the invocation before the enclosing
            # Run necessarily replies. A later session DOWN belongs to that
            # already-settled attempt and must only release transient ownership.
            data |> maybe_schedule() |> arm_idle_timer()
        end

      _stale ->
        data
    end
  end

  defp validate_inference_heartbeat(data, invocation_id, progress, checkpoint) do
    ownership = Map.get(data.stream_sessions, invocation_id)
    invocation = Map.get(data.invocations, invocation_id)
    previous = Map.get(data.inference_liveness_clock, invocation_id)

    cond do
      is_nil(ownership) or is_nil(invocation) ->
        {:error, :unknown_inference_stream}

      invocation != ownership ->
        {:error, :inference_heartbeat_ownership_mismatch}

      progress.invocation_id != invocation_id or
        progress.inference_id != ownership.invocation.inference_id or
          progress.attempt_id != ownership.invocation.attempt_id ->
        {:error, :inference_heartbeat_identity_mismatch}

      progress.run_revision != ownership.run_revision or
        progress.generation != ownership.generation or
          progress.dispatch_id != ownership.dispatch_id ->
        {:error, :inference_heartbeat_dispatch_fence_mismatch}

      progress.control_revision != ownership.invocation.control_revision or
          progress.stream_epoch != ownership.invocation.stream_epoch ->
        {:error, :inference_heartbeat_control_fence_mismatch}

      is_map(previous) and progress.sequence < previous.sequence ->
        {:error, :inference_heartbeat_sequence_regressed}

      true ->
        with :ok <- InferenceProgress.validate(progress) do
          validate_stream_checkpoint(progress, checkpoint)
        end
    end
  end

  defp validate_stream_checkpoint(_progress, nil), do: :ok

  defp validate_stream_checkpoint(progress, %StreamCheckpoint{} = checkpoint) do
    with :ok <- StreamCheckpoint.validate(checkpoint),
         true <- checkpoint.provider_request_digest == progress.provider_request_digest,
         true <- checkpoint.resume_cursor_digest == progress.provider_cursor_digest,
         true <- checkpoint.usage == progress.usage,
         true <- checkpoint.usage_quality == progress.usage_quality,
         true <- checkpoint.output_bytes == progress.output_bytes do
      :ok
    else
      false -> {:error, :inference_stream_checkpoint_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_stream_checkpoint(_progress, _checkpoint),
    do: {:error, :invalid_inference_stream_checkpoint}

  defp maybe_commit_inference_checkpoint(data, progress, checkpoint, now) do
    checkpoint? = checkpoint_commit_due?(data, progress, checkpoint, now)
    progress? = progress_commit_due?(data, progress, now)

    if checkpoint? or progress? do
      commit_inference_checkpoint(data, progress, checkpoint, now, checkpoint?, progress?)
    else
      data
    end
  end

  defp checkpoint_commit_due?(data, progress, %StreamCheckpoint{} = checkpoint, now) do
    interval = Keyword.get(data.base_opts, :inference_stream_checkpoint_interval, 5_000)
    last = Map.get(data.inference_checkpoint_clock, progress.invocation_id)

    StreamCheckpoint.meaningful?(checkpoint) and interval_due?(last, now, interval) and
      stream_checkpoint_changed?(data, progress.invocation_id, checkpoint)
  end

  defp checkpoint_commit_due?(_data, _progress, _checkpoint, _now), do: false

  defp progress_commit_due?(data, progress, now) do
    enabled? = Keyword.get(data.base_opts, :inference_observer_lane, false)
    interval = Keyword.get(data.base_opts, :inference_progress_commit_interval, 5_000)
    last = Map.get(data.inference_progress_commit_clock, progress.invocation_id)

    enabled? and interval_due?(last, now, interval)
  end

  # Monotonic clocks may have any origin, including a negative one. `nil` is
  # the only safe sentinel for the first periodic commit.
  defp interval_due?(nil, _now, _interval), do: true
  defp interval_due?(last, now, interval), do: now - last >= interval

  defp stream_checkpoint_changed?(data, invocation_id, checkpoint) do
    with %{run_id: run_id} <- Map.get(data.stream_sessions, invocation_id),
         %Run{inference_continuation: continuation} <- Map.get(data.runs, run_id) do
      continuation.provider_request_digest != checkpoint.provider_request_digest or
        provider_cursor_digest(continuation.resume_cursor) != checkpoint.resume_cursor_digest or
        continuation.stream_provider_sequence != checkpoint.provider_sequence or
        continuation.stream_usage != checkpoint.usage or
        continuation.stream_usage_quality != checkpoint.usage_quality or
        continuation.stream_output_bytes != checkpoint.output_bytes
    else
      _missing -> false
    end
  end

  defp commit_inference_checkpoint(data, progress, checkpoint, now, checkpoint?, progress?) do
    revision = data.canonical.revision + 1

    with {:ok, writes, run} <-
           inference_checkpoint_writes(
             data,
             progress,
             checkpoint,
             checkpoint?,
             progress?,
             revision
           ),
         {:ok, committed} <-
           Commit.canonical_sections(data, writes,
             correlation_id: progress.inference_id,
             causation_id: progress.invocation_id,
             provenance: %{source: :inference_checkpoint, invocation_id: progress.invocation_id},
             metadata: %{
               transition: :inference_checkpoint_committed,
               progress: progress?,
               recovery_cursor: checkpoint?
             }
           ) do
      committed = if run, do: Runs.put_run(committed, run), else: committed

      committed =
        update_inference_checkpoint_clocks(committed, progress, now, checkpoint?, progress?)

      if progress? do
        publish_committed_inference_progress(committed, %{progress | canonical_revision: revision})
      else
        committed
      end
    else
      {:error, reason} ->
        emit(
          :inference_progress_commit_failed,
          data,
          %{count: 1},
          %{reason_class: reason_class(reason)}
        )

        data
    end
  end

  defp inference_checkpoint_writes(
         data,
         progress,
         checkpoint,
         checkpoint?,
         progress?,
         revision
       ) do
    with {:ok, writes, run} <-
           maybe_put_stream_checkpoint(data, progress, checkpoint, checkpoint?),
         {:ok, writes} <- maybe_put_progress_snapshot(data, writes, progress, progress?, revision) do
      {:ok, writes, run}
    end
  end

  defp maybe_put_stream_checkpoint(data, progress, checkpoint, true) do
    with %{run_id: run_id} <- Map.get(data.stream_sessions, progress.invocation_id),
         %Run{
           inference_continuation: %{invocation: %Invocation{id: invocation_id}} = continuation
         } = run <- Map.get(data.runs, run_id),
         true <- invocation_id == progress.invocation_id,
         next_continuation <- %{
           continuation
           | provider_status: :streaming,
             provider_request_id: checkpoint.provider_request_id,
             provider_request_digest: checkpoint.provider_request_digest,
             resume_cursor: checkpoint.resume_cursor,
             stream_provider_sequence: checkpoint.provider_sequence,
             stream_usage: checkpoint.usage,
             stream_usage_quality: checkpoint.usage_quality,
             stream_output_bytes: checkpoint.output_bytes,
             recovery: %{status: :stream_checkpointed}
         },
         next_run <- %{run | inference_continuation: next_continuation},
         {:ok, writes} <- Commit.run_writes(data, data.state, next_run) do
      {:ok, writes, next_run}
    else
      false -> {:error, :stale_inference_stream_checkpoint}
      nil -> {:error, :missing_inference_stream_checkpoint_owner}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_stream_checkpoint(_data, _progress, _checkpoint, false),
    do: {:ok, %{}, nil}

  defp maybe_put_progress_snapshot(data, writes, progress, true, revision) do
    with {:ok, snapshots} <- Canonical.fetch(data.canonical, :inference_progress) do
      committed_progress = %{progress | canonical_revision: revision}
      limit = Keyword.get(data.base_opts, :inference_progress_limit, 256)

      snapshots =
        snapshots
        |> Map.put(progress.inference_id, committed_progress)
        |> Enum.sort_by(fn {_id, snapshot} -> snapshot.at end, :desc)
        |> Enum.take(limit)
        |> Map.new()

      {:ok, Map.put(writes, :inference_progress, snapshots)}
    end
  end

  defp maybe_put_progress_snapshot(_data, writes, _progress, false, _revision),
    do: {:ok, writes}

  defp update_inference_checkpoint_clocks(data, progress, now, checkpoint?, progress?) do
    data =
      if checkpoint? do
        %{
          data
          | inference_checkpoint_clock:
              Map.put(data.inference_checkpoint_clock, progress.invocation_id, now)
        }
      else
        data
      end

    if progress? do
      %{
        data
        | inference_progress_commit_clock:
            Map.put(data.inference_progress_commit_clock, progress.invocation_id, now)
      }
    else
      data
    end
  end

  defp publish_committed_inference_progress(data, committed_progress) do
    event =
      InferenceEvent.new(:progress_committed, committed_progress,
        instance_key: data.ref.key,
        canonical_revision: committed_progress.canonical_revision
      )

    _ = Spectre.Inference.Events.publish(data.ref, event)
    data
  end

  defp start_inference_resume_worker(data, run, ownership, response) do
    invocation = ownership.invocation
    data = notify_stream_attempt_committed(data, invocation.id, response)

    entry =
      Map.merge(ownership.entry, %{
        operation: {:resume, {:inference, invocation, response}},
        state_revision: data.state.revision,
        admitted?: false
      })

    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()
    {pid, monitor} = spawn_advance_worker(owner, run, entry, dispatch_id, capability)

    active = %{
      kind: :advance,
      run_id: run.id,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry
    }

    data
    |> Map.put(:active, active)
    |> Map.put(:state_lock, nil)
    |> Map.put(:workers, Map.put(data.workers, pid, active))
    |> disarm_idle_timer()
  end

  defp resume_inference_boundary(data, run, ownership, {:success, response}) do
    data =
      publish_inference_lifecycle_event(
        data,
        :terminal_committed,
        ownership.invocation.inference_id,
        ownership.invocation.id,
        ownership.invocation,
        %{outcome: :completed}
      )

    start_inference_resume_worker(data, run, ownership, response)
  end

  defp resume_inference_boundary(data, run, ownership, {:retry, reason}) do
    data =
      publish_inference_lifecycle_event(
        data,
        inference_failure_event_type(reason),
        ownership.invocation.inference_id,
        ownership.invocation.id,
        ownership.invocation,
        %{outcome: :failed, retrying?: true, reason_class: reason_class(reason)}
      )

    start_inference_retry(data, run, ownership, reason)
  end

  defp resume_inference_boundary(data, run, ownership, {:failure, failure}) do
    data
    |> publish_inference_lifecycle_event(
      inference_failure_event_type(failure),
      ownership.invocation.inference_id,
      ownership.invocation.id,
      ownership.invocation,
      %{outcome: :failed, reason_class: reason_class(failure)}
    )
    |> Map.put(:state_lock, nil)
    |> notify_stream_attempt_failed(ownership.invocation.id, failure)
    |> reply_caller(run.id, {:error, failure})
    |> Runs.record_terminal(run)
    |> maybe_schedule()
    |> arm_idle_timer()
  end

  defp start_inference_retry(data, run, ownership, previous_reason) do
    continuation = run.inference_continuation
    attempt = continuation.attempt + 1

    entry =
      case Map.get(ownership, :entry) do
        %{opts: _opts} = entry ->
          Map.merge(entry, %{
            state_revision: data.state.revision,
            admitted?: false,
            recovered?: Map.get(entry, :recovered?, false)
          })

        _missing ->
          opts =
            data
            |> runtime_opts(
              Spectre.Inference.Descriptor.options(continuation.descriptor),
              run.input
            )
            |> put_run_pin(run)

          recovered_inference_entry(data, run, opts)
      end

    retry_opts = Keyword.put(entry.opts, :inference_previous_errors, [previous_reason])
    entry = %{entry | opts: retry_opts}

    case Inference.prepare_attempt(
           data.agent,
           continuation.descriptor,
           attempt,
           run.input,
           data.state,
           retry_opts
         ) do
      {:ok, %PreparedInference{} = prepared} ->
        successor = build_retry_successor(run, continuation, prepared, attempt, previous_reason)
        invocation = successor.waiting
        selected = mark_inference_selection_receipted(successor)
        retained = Runs.put_run(data, selected)

        case prepare_inference_selection_receipt(retained, selected, invocation, entry) do
          {:ok, prepared_receipt} ->
            commit_or_stage_run_receipt(
              retained,
              selected,
              {:inference_selected, invocation, prepared, entry},
              prepared_receipt
            )

          {:error, reason} ->
            finalize_inference_retry_failure(data, run, attempt, reason)
        end

      {:error, reason} ->
        finalize_inference_retry_failure(data, run, attempt, reason)
    end
  end

  defp build_retry_successor(run, continuation, prepared, attempt, previous_reason) do
    recoverable? =
      continuation.recoverable? and not is_function(prepared.selection.model) and
        match?(:ok, Value.validate(prepared.selection.model))

    next_continuation = %{
      continuation
      | descriptor: prepared.descriptor,
        frozen_selection: prepared.frozen_selection,
        invocation: nil,
        stream_epoch: nil,
        attempt: attempt,
        provider_status: :selected,
        provider_request_id: nil,
        provider_request_digest: nil,
        resume_cursor: nil,
        consumer_token_digest: nil,
        stream_recovery: nil,
        stream_provider_sequence: nil,
        stream_usage: %InferenceUsage{},
        stream_usage_quality: :unavailable,
        stream_output_bytes: 0,
        recovery: %{
          status: :retry_selected,
          previous_reason: portable_failure(previous_reason)
        },
        last_response: nil,
        recoverable?: recoverable?
    }

    successor = %{
      run
      | revision: run.revision + 1,
        step_id: Value.token("inference-retry-step", {run.id, attempt}),
        waiting: nil,
        inference_continuation: next_continuation,
        last_error: nil
    }

    invocation = Invocation.from_inference(successor, next_continuation, streaming?: false)

    next_continuation = %{
      next_continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch
    }

    %{successor | waiting: invocation, inference_continuation: next_continuation}
  end

  defp finalize_inference_retry_failure(data, run, attempt, reason) do
    failure = {:inference_retry_selection_failed, attempt, portable_failure(reason)}
    failed = Runs.terminalize_failed_run(run, failure)
    retained = Runs.put_run(data, failed)

    case Commit.run_state(retained, data.state, failed) do
      {:ok, committed} ->
        committed
        |> Map.put(:state_lock, nil)
        |> reply_caller(run.id, {:error, failure})
        |> Runs.record_terminal(failed)
        |> maybe_schedule()
        |> arm_idle_timer()

      {:error, commit_reason} ->
        fail_run_commit(%{data | state_lock: nil}, failed, commit_reason)
    end
  end

  defp fail_inference_attempt(data, ownership, receipt, reason) do
    # Provider errors may contain response bodies, credentials or request
    # identifiers. Only a bounded semantic class is allowed past this point.
    reason = portable_failure(reason)
    run = Map.fetch!(data.runs, ownership.run_id)

    settlement =
      if receipt.metadata[:remote_status] == :ambiguous, do: :ambiguous, else: :confirmed

    case settle_inference_budget(
           run.inference_continuation,
           ownership.invocation.attempt_id,
           receipt.usage,
           settlement
         ) do
      {:ok, continuation} ->
        if inference_retry_allowed?(run, continuation, ownership, reason, settlement) do
          commit_retryable_inference_failure(
            data,
            run,
            continuation,
            ownership,
            receipt,
            reason,
            settlement
          )
        else
          commit_terminal_inference_failure(
            data,
            run,
            continuation,
            ownership,
            receipt,
            reason
          )
        end

      {:error, continuation, settlement_reason} ->
        commit_budget_settlement_failure(
          data,
          run,
          continuation,
          ownership,
          receipt,
          settlement_reason
        )
    end
  end

  defp inference_retry_allowed?(run, continuation, ownership, reason, settlement) do
    retryable_reason? =
      reason != :consumer_never_attached and
        reason != :inference_deadline_exceeded and
        not match?({:cancelled, _reason}, reason) and
        not match?({:inference_budget_exceeded, _field}, reason)

    with true <- ownership.mode == :one_shot,
         true <- settlement == :confirmed,
         true <- retryable_reason?,
         false <- run.inference_continuation.descriptor.constraints.strict?,
         %{status: status} when status != :budget_settlement_failed <- continuation.recovery,
         {:ok, limit} <- inference_attempt_limit(ownership.prepared, ownership.entry) do
      continuation.attempt < limit
    else
      _not_retryable -> false
    end
  end

  defp commit_retryable_inference_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         reason,
         settlement
       ) do
    attempt_record = %{
      attempt: continuation.attempt,
      attempt_id: ownership.invocation.attempt_id,
      invocation_id: ownership.invocation.id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      outcome: :failed,
      reason: portable_failure(reason),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :unknown),
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      settlement: settlement
    }

    retrying_continuation = %{
      continuation
      | provider_status: :terminal,
        previous_attempts: Enum.take([attempt_record | continuation.previous_attempts], 32),
        recovery: %{
          status: :retry_pending,
          reason: portable_failure(reason),
          next_attempt: continuation.attempt + 1
        },
        last_response: nil
    }

    retrying = %{run | inference_continuation: retrying_continuation}
    payload = inference_failure_payload(receipt, reason)

    case Receipts.prepare_run(
           data,
           data.state,
           retrying,
           :inference_attempt_terminal,
           payload,
           inference_receipt_opts(
             ownership.invocation,
             "spectre.inference.attempt-terminal/1"
           )
         ) do
      {:ok, prepared_receipt} ->
        commit_or_stage_inference_receipt(
          data,
          retrying,
          ownership,
          {:retry, portable_failure(reason)},
          prepared_receipt
        )

      {:error, commit_reason} ->
        fail_run_commit(%{data | state_lock: nil}, retrying, commit_reason)
    end
  end

  defp commit_terminal_inference_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         reason
       ) do
    failure = {:inference_attempt_failed, run.inference_continuation.attempt, reason}

    failed =
      run
      |> Map.put(:inference_continuation, continuation)
      |> Runs.terminalize_failed_run(failure)
      |> put_inference_terminal_metadata(continuation, ownership.invocation, receipt)

    payload = inference_failure_payload(receipt, reason)

    kind =
      if reason == :consumer_never_attached,
        do: :inference_consumer_never_attached,
        else: :inference_attempt_terminal

    receipt_opts =
      inference_receipt_opts(
        ownership.invocation,
        "spectre.inference.attempt-terminal/1"
      )

    case Receipts.prepare_run(data, data.state, failed, kind, payload, receipt_opts) do
      {:ok, prepared} ->
        commit_or_stage_inference_receipt(
          data,
          failed,
          ownership,
          {:failure, failure},
          prepared
        )

      {:error, commit_reason} ->
        fail_run_commit(%{data | state_lock: nil}, failed, commit_reason)
    end
  end

  defp inference_failure_payload(receipt, reason) do
    %{
      outcome: failure_outcome(reason),
      reason: portable_failure(reason),
      provider_started: receipt.provider_started,
      remote_status: Map.get(receipt.metadata, :remote_status, :unknown),
      control_command_digest: Map.get(receipt.metadata, :control_command_digest),
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      nondeterminism_samples: Map.get(receipt.metadata, :nondeterminism_samples, [])
    }
  end

  defp commit_budget_settlement_failure(
         data,
         run,
         continuation,
         ownership,
         receipt,
         settlement_reason
       ) do
    reason = {:inference_budget_settlement_failed, portable_failure(settlement_reason)}
    receipt = %{receipt | outcome: {:error, reason}}

    commit_terminal_inference_failure(
      data,
      run,
      continuation,
      ownership,
      receipt,
      reason
    )
  end

  defp settle_inference_budget(
         %{budget: %Budget{} = budget} = continuation,
         attempt_id,
         usage,
         status
       ) do
    case Budget.settle(budget, attempt_id, usage, status) do
      {:ok, settled} ->
        {:ok, %{continuation | budget: settled}}

      {:error, reason} ->
        failed = %{
          continuation
          | recovery: %{
              status: :budget_settlement_failed,
              reason: portable_failure(reason)
            }
        }

        {:error, failed, reason}
    end
  end

  defp settle_inference_budget(continuation, _attempt_id, _usage, _status),
    do: {:ok, continuation}

  defp put_inference_terminal_metadata(run, continuation, invocation, receipt) do
    terminal = %{
      inference_id: continuation.inference_id,
      invocation_id: invocation.id,
      attempt_id: invocation.attempt_id,
      control_revision: invocation.control_revision,
      stream_epoch: invocation.stream_epoch,
      usage: receipt.usage,
      usage_quality: receipt.usage_quality,
      budget: continuation.budget
    }

    %{run | metadata: Map.put(run.metadata, :inference_terminal, terminal)}
  end

  defp failure_outcome(:consumer_never_attached), do: :cancelled_before_provider_start
  defp failure_outcome({:cancelled, _reason}), do: :cancelled
  defp failure_outcome(_reason), do: :failed

  defp portable_failure(reason) do
    InferenceFailure.sanitize(reason)
  end

  defp arm_inference_attempt_timer(data, _ownership, nil), do: data

  defp arm_inference_attempt_timer(
         data,
         _ownership,
         %BudgetSnapshot{deadline_at: nil}
       ),
       do: data

  defp arm_inference_attempt_timer(
         data,
         ownership,
         %BudgetSnapshot{deadline_at: deadline}
       ) do
    rearm_inference_attempt_timer(data, ownership, deadline)
  end

  defp rearm_inference_attempt_timer(data, ownership, deadline) do
    data = clear_inference_attempt_timer(data, ownership.invocation.id)
    remaining = max(deadline - Spectre.Determinism.system_time(:millisecond), 0)
    delay = min(remaining, @max_timer_delay)

    ref =
      Process.send_after(
        self(),
        {:spectre, :inference_attempt_deadline, ownership.invocation.id, ownership.generation,
         ownership.dispatch_id},
        delay
      )

    timer = %{
      ref: ref,
      deadline_at: deadline,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id
    }

    %{
      data
      | inference_attempt_timers:
          Map.put(data.inference_attempt_timers, ownership.invocation.id, timer)
    }
  end

  defp clear_inference_attempt_timer(data, invocation_id) do
    case Map.pop(data.inference_attempt_timers, invocation_id) do
      {nil, timers} ->
        %{data | inference_attempt_timers: timers}

      {%{ref: ref}, timers} ->
        _cancelled = Process.cancel_timer(ref)
        %{data | inference_attempt_timers: timers}
    end
  end

  defp notify_stream_attempt_committed(data, invocation_id, response) do
    case Map.get(data.stream_sessions, invocation_id) do
      %{pid: pid} ->
        send(pid, {:spectre, :stream_attempt_committed, invocation_id, response})
        data

      nil ->
        data
    end
  end

  defp notify_stream_attempt_failed(data, invocation_id, reason) do
    case Map.get(data.stream_sessions, invocation_id) do
      %{pid: pid} ->
        send(pid, {:spectre, :stream_attempt_failed, invocation_id, reason})
        data

      nil ->
        data
    end
  end

  defp publish_inference_lifecycle_event(
         data,
         type,
         inference_id,
         invocation_id,
         attempt,
         metadata
       ) do
    if Keyword.get(data.base_opts, :inference_observer_lane, false) and
         is_binary(inference_id) and is_binary(invocation_id) do
      event =
        InferenceEvent.new(type,
          instance_key: data.ref.key,
          inference_id: inference_id,
          invocation_id: invocation_id,
          attempt_id: Map.get(attempt, :attempt_id),
          stream_epoch: Map.get(attempt, :stream_epoch),
          canonical_revision: data.canonical.revision,
          metadata: metadata
        )

      _ = Spectre.Inference.Events.publish(data.ref, event)
    end

    data
  rescue
    _invalid_observer_projection -> data
  end

  defp inference_failure_event_type({:stream_interrupted, _reason}), do: :stream_interrupted

  defp inference_failure_event_type({:inference_attempt_failed, _attempt, reason}),
    do: inference_failure_event_type(reason)

  defp inference_failure_event_type(_reason), do: :terminal_committed

  defp provider_request_digest(nil), do: nil
  defp provider_request_digest(value), do: Value.token("provider-request", value)

  defp provider_cursor_digest(nil), do: nil
  defp provider_cursor_digest(value), do: Value.token("provider", value)

  # Adapter response metadata has no core-owned schema and may duplicate raw
  # headers, provider request ids or credentials. Normalized fields live on
  # Response itself; untyped provider metadata therefore remains live-only.
  defp portable_response_metadata(_metadata), do: %{}

  defp enforce_inference_attempt_budget(%{budget_snapshot: %BudgetSnapshot{} = snapshot}, usage) do
    BudgetSnapshot.exceeded(snapshot, usage)
  end

  defp enforce_inference_attempt_budget(_ownership, _usage), do: :ok

  defp reject_stale_step(data, entry, run) do
    reason =
      {:stale_instance_state, run.id, entry.state_revision, data.state.revision}

    failed = Runs.terminalize_failed_run(run, reason)
    data = data |> Runs.put_run(failed) |> reply_caller(run.id, {:error, reason})
    data |> Runs.record_terminal(failed) |> maybe_schedule() |> arm_idle_timer()
  end

  defp maybe_record_started_conversation(
         data,
         %{operation: {:start, _input}, opts: opts},
         run
       ),
       do: Conversation.record_conversation(data, run, opts)

  defp maybe_record_started_conversation(
         data,
         %{admitted?: true, opts: opts},
         run
       ),
       do: Conversation.record_conversation(data, run, opts)

  defp maybe_record_started_conversation(data, _entry, _run), do: data

  defp apply_returned_run(data, %Run{} = run, entry) do
    with :ok <- owner_guard(data, :commit) do
      next = project_returned_run(data, run, entry)
      Commit.flow_state(next, next.state, run)
    end
  end

  # Builds the in-memory projection used by both ordinary Run commits and
  # receipted inference boundaries. Keeping this calculation in one place
  # prevents the receipt path from observing a different Flow state.
  defp project_returned_run(data, %Run{} = run, entry) do
    next_state =
      if entry_commits_state?(entry) and entry.state_revision == data.state.revision do
        run.state
      else
        data.state
      end

    last_result = if match?(%Result{}, run.result), do: run.result, else: data.last_result

    %{
      data
      | runs: Map.put(data.runs, run.id, run),
        state: next_state,
        last_result: last_result
    }
  end

  defp fail_run_commit(data, %Run{} = run, reason) do
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, reason)

    data
    |> Runs.put_run(failed)
    |> reply_caller(run.id, {:error, reason})
    |> tap(
      &emit(:run_failed, &1, %{count: 1}, %{
        run_id: id_digest(run.id),
        reason_class: reason_class(reason)
      })
    )
    |> Runs.record_terminal(failed)
    |> maybe_schedule()
    |> arm_idle_timer()
  end

  defp reply_projection(data, %{projection: :inference_response} = entry, step) do
    reply =
      step
      |> Runs.step_result()
      |> cognitive_inference_response()

    reply_caller(data, entry.run_id, reply)
  end

  defp reply_projection(data, %{internal?: true, run_id: run_id}, step) do
    # Recovery has no live GenServer caller, but a resumed stream session is
    # still waiting for the canonical Run result. Treat that session as the
    # terminal projection consumer so a successful recovered Run cannot leave
    # its replacement Enumerable parked in `:awaiting_result`.
    if stream_session_for_run(data, run_id) do
      reply_caller(data, run_id, {:ok, Runs.step_result(step)})
    else
      data
    end
  end

  defp reply_projection(data, entry, step) do
    reply =
      case entry.projection do
        :turn -> {:ok, Turn.from_step(self(), entry.input, entry.opts, step)}
        :result -> {:ok, Runs.step_result(step)}
        :stream -> stream_projection(data, entry.run_id, step)
      end

    reply_caller(data, entry.run_id, reply)
  end

  defp cognitive_inference_response(%Result{
         metadata: %{cognitive_inference: %{response: %InferenceResponse{} = response}}
       }),
       do: {:ok, response}

  defp cognitive_inference_response(%Result{}),
    do: {:error, :cognitive_inference_response_missing}

  defp cognitive_inference_response(nil),
    do: {:error, :cognitive_inference_result_missing}

  defp stream_projection(data, run_id, step) do
    if stream_session_for_run(data, run_id) do
      {:ok, Runs.step_result(step)}
    else
      {:error, {:streaming_unsupported, :handler_did_not_start_inference}}
    end
  end

  defp maybe_finalize_reply(data, {:boundary, %Boundary{kind: :reply}, %Run{} = run}) do
    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: runtime_opts(data, [], run.input),
      state_revision: data.state.revision,
      internal?: true
    }

    enqueue(data, entry)
  end

  defp maybe_finalize_reply(data, _step), do: data

  defp enqueue(data, entry, priority? \\ false) do
    if MapSet.member?(data.queued, entry.run_id) or run_active?(data, entry.run_id) do
      data
    else
      put_ready_entry(data, entry, priority?)
    end
  end

  # A closed `{:continue, run}` is the same public call advancing by another
  # mailbox move. Its caller remains registered while the Run returns to the
  # ready queue. Start is intentionally a bounded two-move sequence so another
  # Run cannot normalize against State and then wait behind the first Run's
  # commit.
  defp enqueue_continuation(data, entry, priority?),
    do: put_ready_entry(data, entry, priority?)

  defp put_ready_entry(data, entry, priority?) do
    ready =
      if priority?,
        do: :queue.in_r(entry.run_id, data.ready),
        else: :queue.in(entry.run_id, data.ready)

    data =
      %{
        data
        | ready: ready,
          queued: MapSet.put(data.queued, entry.run_id),
          entries: Map.put(data.entries, entry.run_id, entry)
      }

    maybe_schedule(data)
  end

  defp maybe_schedule(%{scheduled: true} = data), do: data
  defp maybe_schedule(%{active: active} = data) when not is_nil(active), do: data
  defp maybe_schedule(%{state_lock: lock} = data) when not is_nil(lock), do: data

  defp maybe_schedule(data) do
    case :queue.peek(data.ready) do
      {:value, run_id} ->
        maybe_schedule_run(data, run_id)

      :empty ->
        data
    end
  end

  defp maybe_schedule_run(data, run_id) do
    send(self(), {:spectre, :advance, run_id})
    %{data | scheduled: true}
  end

  defp pop_ready(data, expected_run_id) do
    case :queue.out(data.ready) do
      {{:value, ^expected_run_id}, ready} ->
        entry = Map.fetch!(data.entries, expected_run_id)

        next = %{
          data
          | ready: ready,
            queued: MapSet.delete(data.queued, expected_run_id),
            entries: Map.delete(data.entries, expected_run_id)
        }

        {:ok, entry, next}

      {{:value, _other}, _ready} ->
        {:error, :out_of_order_advance, data}

      {:empty, _ready} ->
        {:error, :empty_ready_queue, data}
    end
  end

  defp put_caller(data, run_id, from) do
    %{data | callers: Map.put_new(data.callers, run_id, from)}
  end

  defp reply_stream_caller(data, run_id, stream) do
    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, {:ok, stream})
        %{data | callers: callers}
    end
  end

  defp reply_caller(data, run_id, reply) do
    data = data |> notify_stream_result(run_id, reply) |> InferenceCapacity.release(run_id)

    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, reply)
        %{data | callers: callers}
    end
  end

  defp notify_stream_result(data, run_id, reply) do
    case stream_session_for_run(data, run_id) do
      nil ->
        data

      {invocation_id, ownership} ->
        send(ownership.pid, {:spectre, :stream_result, invocation_id, reply})
        Process.demonitor(ownership.monitor, [:flush])

        %{
          data
          | stream_sessions: Map.delete(data.stream_sessions, invocation_id),
            stream_monitors: Map.delete(data.stream_monitors, ownership.pid)
        }
    end
  end

  defp stream_session_for_run(data, run_id) do
    Enum.find(data.stream_sessions, fn {_invocation_id, ownership} ->
      ownership.run_id == run_id
    end)
  end

  defp run_active?(data, run_id) do
    match?(%{run_id: ^run_id}, data.active) or
      MapSet.member?(data.queued, run_id) or
      Map.has_key?(data.callers, run_id) or
      Enum.any?(data.invocations, fn {_id, ownership} -> ownership.run_id == run_id end)
  end

  defp execute_command?({:execute, _value}), do: true
  defp execute_command?(_command), do: false

  defp worker_down(
         data,
         pid,
         %{invocation_kind: :inference} = ownership,
         reason
       ) do
    data = finish_worker(data, pid)

    receipt = %Receipt{
      invocation_id: ownership.invocation.id,
      run_id: ownership.run_id,
      run_revision: ownership.run_revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: ownership.capability,
      kind: :inference,
      attempt_id: ownership.invocation.attempt_id,
      control_revision: ownership.invocation.control_revision,
      stream_epoch: ownership.invocation.stream_epoch,
      provider_started: true,
      usage: %{},
      outcome: {:error, {:inference_worker_down, reason_class(reason)}},
      metadata: %{remote_status: :ambiguous}
    }

    accept_inference_receipt(data, ownership, receipt)
  end

  defp worker_down(
         data,
         pid,
         %{kind: :invocation, invocation: %Invocation{kind: :effect} = invocation} = ownership,
         reason
       ) do
    failure = {:effect_worker_down, reason_class(reason)}
    run = Map.fetch!(data.runs, ownership.run_id)
    failed = Runs.terminalize_failed_run(run, failure)

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: ownership.run_id,
      run_revision: ownership.run_revision,
      generation: ownership.generation,
      dispatch_id: ownership.dispatch_id,
      capability: ownership.capability,
      kind: :effect,
      provider_started: true,
      outcome: {:error, failure, failed},
      metadata: %{remote_status: :ambiguous}
    }

    data =
      data
      |> finish_worker(pid)
      |> Map.put(:invocations, Map.delete(data.invocations, invocation.id))
      |> Map.put(:state_lock, nil)

    commit_effect_terminal(data, ownership, receipt)
  end

  defp worker_down(data, pid, %{kind: :advance, entry: entry} = worker, reason) do
    if policy_resolution_entry?(entry) do
      failure = {:policy_worker_down, reason_class(reason)}
      run = Map.fetch!(data.runs, worker.run_id)
      failed = Runs.terminalize_failed_run(run, failure)

      data =
        data
        |> finish_worker(pid)
        |> Map.put(:active, nil)

      commit_policy_decision(data, {:error, failure, failed}, entry)
    else
      finish_failed_worker(data, pid, worker, reason)
    end
  end

  defp worker_down(data, pid, worker, reason) do
    finish_failed_worker(data, pid, worker, reason)
  end

  defp finish_failed_worker(data, pid, worker, reason) do
    data = finish_worker(data, pid)
    failure = {:instance_worker_down, worker.kind, reason}
    run = Map.get(data.runs, worker.run_id)

    failed = if run, do: Runs.terminalize_failed_run(run, failure), else: nil

    data =
      data
      |> Map.put(:active, if(match?(%{pid: ^pid}, data.active), do: nil, else: data.active))
      |> Map.put(:state_lock, nil)
      |> Map.put(
        :invocations,
        Enum.reject(data.invocations, fn {_id, value} -> value.pid == pid end) |> Map.new()
      )

    data = if failed, do: Runs.put_run(data, failed), else: data
    data = reply_caller(data, worker.run_id, {:error, failure})
    data = if failed, do: Runs.record_terminal(data, failed), else: data
    data |> maybe_schedule() |> arm_idle_timer()
  end

  defp spawn_worker(fun) do
    :erlang.spawn_opt(fun, [:link, :monitor])
  end

  defp safe_step(run, fun) do
    fun.()
  rescue
    exception ->
      failed =
        Runs.terminalize_failed_run(
          run,
          {:instance_worker_exception, exception.__struct__}
        )

      {:error, failed.last_error, failed}
  catch
    kind, reason ->
      failed = Runs.terminalize_failed_run(run, {:instance_worker_failure, kind, reason})

      {:error, failed.last_error, failed}
  end

  defp finish_worker(data, pid) do
    case Map.pop(data.workers, pid) do
      {nil, workers} ->
        %{data | workers: workers}

      {%{monitor: monitor}, workers} ->
        Process.demonitor(monitor, [:flush])
        Process.unlink(pid)
        %{data | workers: workers}
    end
  end

  defp state_neutral_step?(entry, %Run{}), do: not entry_commits_state?(entry)

  defp entry_commits_state?(entry),
    do: Map.get(entry, :commit_state?, not Map.get(entry, :internal?, false))

  defp busy?(data) do
    not is_nil(data.active) or not is_nil(data.state_lock) or
      not :queue.is_empty(data.ready) or map_size(data.invocations) > 0 or
      map_size(data.operation_runners) > 0 or not :queue.is_empty(data.operation_ready) or
      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight) or
      map_size(data.receipt_staging) > 0 or map_size(data.receipt_deliveries) > 0 or
      map_size(data.receipt_resumes) > 0 or data.receipt_recovery_deferred or
      map_size(data.stream_sessions) > 0 or map_size(data.stream_reservations) > 0
  end

  defp live_runs?(data) do
    Enum.any?(data.runs, fn {_id, run} -> not Runs.terminal_run?(run) end) or
      Enum.any?(Loops.all_operation_loops(data), fn {loop, _control} ->
        not OperationLoop.terminal?(loop)
      end)
  end

  defp info_projection(data) do
    %{
      ref: data.ref.key,
      agent_ref: AgentRef.key(data.agent_ref),
      subject: Subject.key(data.subject),
      generation: data.generation,
      activation:
        case data.activation do
          nil ->
            nil

          %Activation{} = activation ->
            %{
              definition_ref: activation.definition_ref,
              candidate_ref: activation.candidate_ref,
              generation: activation.generation,
              authority_epoch: activation.authority_epoch,
              closure_digest: activation.closure_digest
            }
        end,
      owner_fencing_token: data.owner_lease.fencing_token,
      state_revision: data.state.revision,
      canonical_revision: data.canonical.revision,
      conversations: data.conversations,
      runs: Map.new(data.runs, fn {id, run} -> {id, Runs.run_projection(run)} end),
      ready: :queue.to_list(data.ready),
      active_run: data.active && data.active.run_id,
      invocations:
        Map.new(data.invocations, fn {id, ownership} ->
          {id,
           %{
             run_id: ownership.run_id,
             run_revision: ownership.run_revision
           }}
        end),
      tombstones: data.tombstones,
      operational_loops:
        Map.new(Loops.all_operation_loops(data), fn {loop, control} ->
          {loop.id, OperationView.from_loop(loop, control)}
        end),
      operation_runners:
        Map.new(data.operation_runners, fn {attempt_id, ownership} ->
          {attempt_id, %{loop_id: ownership.loop_id, operation: ownership.operation}}
        end)
    }
  end

  defp control_loop(server, loop, action, payload, opts) do
    GenServer.call(
      server,
      {:operation_control, Loops.operation_id(loop), action, payload, opts},
      timeout(opts)
    )
  end

  defp commit_operational(data, loop, control, event_specs, opts) do
    with {:ok, next, events} <- Commit.operational(data, loop, control, event_specs, opts) do
      {:ok, route_committed_events(next, events), events}
    end
  end

  defp commit_operational_batch(data, entries, commit_opts) do
    with {:ok, next, events} <- Commit.operational_batch(data, entries, commit_opts) do
      {:ok, route_committed_events(next, events), events}
    end
  end

  defp route_committed_events(data, []), do: data

  defp route_committed_events(data, events) do
    configured = Keyword.get(data.agent.__spectre_config__(), :route_operation_events, false)

    Enum.each(events, &Spectre.Operation.Events.publish(data.ref, &1))

    events
    |> Enum.filter(&route_operation_event?(&1, configured))
    |> Enum.reduce(data, &enqueue_operation_event/2)
    |> maybe_schedule()
  end

  defp route_operation_event?(_event, false), do: false
  defp route_operation_event?(_event, :all), do: true
  defp route_operation_event?(event, types) when is_list(types), do: event.type in types
  defp route_operation_event?(_event, _invalid), do: false

  defp enqueue_operation_event(event, data) do
    data = Runs.prune_for_new_run(data)

    if map_size(data.runs) >= data.max_runs do
      emit(
        :operation_event_route_dropped,
        data,
        %{count: 1},
        %{event_id: id_digest(event.id)}
      )

      data
    else
      input = OperationEvent.to_input(event)

      opts = [
        run_id: Value.token("operation-event-run", event.id),
        trace_id: event.correlation_id,
        correlation_id: event.correlation_id,
        causation_id: event.id,
        run_metadata: %{
          internal_event: true,
          operation_event_id: event.id,
          operation_loop_id: event.loop_id,
          operation_loop_kind: event.loop_kind
        }
      ]

      runtime_opts = runtime_opts(data, opts, input)

      case Runtime.admit(data.agent, input, data.state, runtime_opts, opts) do
        {:ok, %Run{} = run} ->
          if Map.has_key?(data.runs, run.id) or Map.has_key?(data.tombstones, run.id) do
            data
          else
            entry = %{
              run_id: run.id,
              operation: {:start, input},
              projection: :result,
              input: input,
              opts: opts,
              state_revision: data.state.revision,
              internal?: true,
              commit_state?: true,
              admitted?: true
            }

            retained = %{data | runs: Map.put(data.runs, run.id, run)}

            case Commit.run_state(retained, data.state, run) do
              {:ok, committed} -> committed |> enqueue(entry)
              {:error, _reason} -> data
            end
          end

        {:error, reason} ->
          emit(
            :operation_event_route_rejected,
            data,
            %{count: 1},
            %{
              event_id: id_digest(event.id),
              reason_class: reason_class(reason)
            }
          )

          data
      end
    end
  end

  defp commit_delivery_receipt(data, loop, receipt, opts) do
    with {:ok, next, events} <- Deliveries.commit_receipt(data, loop, receipt, opts) do
      {:ok, route_committed_events(next, events)}
    end
  end

  defp nested_work?(data, callers, :work) do
    Enum.any?(data.operation_runners, fn {_attempt_id, ownership} ->
      ownership.pid in callers
    end)
  end

  defp nested_work?(_data, _caller, _kind), do: false

  defp operation_callers do
    [self() | List.wrap(Process.get(:"$callers"))]
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  defp queue_operation(data, %OperationLoop{} = loop) do
    key = {loop.kind, loop.id}

    if MapSet.member?(data.operation_queued, key) do
      data
    else
      %{
        data
        | operation_ready: :queue.in(key, data.operation_ready),
          operation_queued: MapSet.put(data.operation_queued, key)
      }
    end
  end

  defp pop_operation(data) do
    case :queue.out(data.operation_ready) do
      {{:value, key}, ready} ->
        {:ok, key,
         %{
           data
           | operation_ready: ready,
             operation_queued: MapSet.delete(data.operation_queued, key)
         }}

      {:empty, _ready} ->
        {:empty, data}
    end
  end

  defp maybe_schedule_operations(data) do
    capacity? = map_size(data.operation_runners) < data.max_operation_runners

    next =
      if not data.operation_scheduled and not :queue.is_empty(data.operation_ready) and capacity? do
        send(self(), {:spectre, :operation_schedule})
        %{data | operation_scheduled: true}
      else
        data
      end

    arm_idle_timer(next)
  end

  defp maybe_queue_after_transition(data, loop, control) do
    cond do
      OperationLoop.terminal?(loop) ->
        data

      not is_nil(control.pending) and OperationLoop.quiescent?(loop) ->
        queue_operation(data, loop)

      OperationLoop.runnable?(loop) and control.state == :active ->
        queue_operation(data, loop)

      true ->
        data
    end
  end

  defp advance_operation(data, {_kind, loop_id}) do
    case Loops.operation_loop(data, loop_id) do
      {:ok, loop, control} ->
        cond do
          not is_nil(control.pending) and OperationLoop.quiescent?(loop) ->
            advance_operation_control(data, loop, control)

          loop.status == :evaluating ->
            evaluate_operation(data, loop, control)

          OperationLoop.runnable?(loop) and control.state == :active ->
            prepare_operation(data, loop, control)

          loop.status == :waiting ->
            Timers.maybe_schedule_wait_timer(data, loop)

          true ->
            data
        end

      {:error, _reason} ->
        data
    end
  end

  defp advance_operation_control(data, loop, control) do
    command = control.pending

    with {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.advance_control(loop, control, Loops.operation_env(data)),
         {:ok, next, committed_events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: command.correlation_id,
             causation_id: command.causation_id,
             provenance: command.provenance,
             transition: {:control_advanced, command.action}
           ) do
      next
      |> maybe_emit_uncorrelated_operation_trigger(committed_events)
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
    else
      {:error, reason} ->
        emit(
          :operation_control_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp evaluate_operation(data, loop, control) do
    with {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.evaluate(loop, control, Loops.operation_env(data)),
         {:ok, next, _events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: loop.correlation_id,
             causation_id: loop.last_result && loop.last_result.id,
             provenance: %{source: :completion_reducer},
             transition: :loop_evaluated
           ) do
      next
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
    else
      {:error, reason} ->
        emit(
          :operation_evaluation_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp prepare_operation(data, loop, control) do
    env = Loops.operation_snapshot_env(data, loop)

    case OperationRuntime.prepare(loop, control, env) do
      {:run, next_loop, attempt, spec, request, reconcile?, event_specs} ->
        case commit_operational(data, next_loop, control, event_specs,
               correlation_id: loop.correlation_id,
               causation_id: request.id,
               provenance: %{source: :operation_scheduler},
               transition: :attempt_committed
             ) do
          {:ok, committed, _events} ->
            committed
            |> Timers.maybe_schedule_wait_timer(next_loop)
            |> start_operation_runner(
              next_loop,
              control,
              attempt,
              spec,
              request,
              reconcile?
            )

          {:error, reason} ->
            emit(
              :operation_prepare_failed,
              data,
              %{count: 1},
              %{
                loop_id: id_digest(loop.id),
                reason_class: reason_class(reason)
              }
            )

            data
        end

      {:transition, next_loop, next_control, event_specs} ->
        case commit_operational(data, next_loop, next_control, event_specs,
               correlation_id: loop.correlation_id,
               provenance: %{source: :operation_scheduler},
               transition: :loop_boundary
             ) do
          {:ok, next, _events} ->
            next
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)

          {:error, _reason} ->
            data
        end

      {:error, reason} ->
        emit(
          :operation_prepare_failed,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp start_operation_runner(data, loop, control, attempt, spec, request, reconcile?) do
    with :ok <- owner_guard(data, :effect_dispatch),
         {:ok, operation_definition_ref} <- Events.operation_definition_ref(data, loop),
         :ok <- Events.authorize(data, operation_definition_ref, :dispatch) do
      do_start_operation_runner(data, loop, control, attempt, spec, request, reconcile?)
    else
      {:error, reason} ->
        emit(
          :operation_dispatch_blocked,
          data,
          %{count: 1},
          %{
            loop_id: id_digest(loop.id),
            reason_class: reason_class(reason)
          }
        )

        data
    end
  end

  defp do_start_operation_runner(data, loop, control, attempt, spec, request, reconcile?) do
    runner_opts = [
      owner: self(),
      attempt: attempt,
      spec: spec,
      request: request,
      agent: data.agent,
      subject: data.subject,
      controller: loop.controller,
      input: loop.effective_input,
      agent_state: data.state,
      cognitive: loop.cognitive,
      reconcile?: reconcile?,
      defer_execute: true,
      opts: operation_runner_opts(data, loop, attempt),
      metadata: %{instance_ref: data.ref.key}
    ]

    case RunnerSupervisor.start_runner(data.runner_supervisor, runner_opts) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        ownership = %{
          attempt_id: attempt.id,
          loop_id: loop.id,
          loop_kind: loop.kind,
          operation: attempt.operation,
          snapshot_id: attempt.snapshot_id,
          fencing_token: attempt.fencing_token,
          pid: pid,
          monitor: monitor,
          control_generation: control.generation,
          context_revision: loop.context_revision,
          spec: spec
        }

        next =
          %{
            data
            | operation_runners: Map.put(data.operation_runners, attempt.id, ownership),
              operation_monitors: Map.put(data.operation_monitors, pid, attempt.id)
          }
          |> Timers.schedule_attempt_timeout(loop, attempt)
          |> disarm_idle_timer()

        :ok = Runner.execute(pid)
        next

      {:error, reason} ->
        handle_operation_start_failure(data, loop, control, spec, reason)
    end
  end

  defp handle_operation_start_failure(data, loop, control, spec, reason) do
    case OperationRuntime.runner_down(
           loop,
           control,
           spec,
           {:runner_start_failed, reason},
           Loops.operation_env(data)
         ) do
      {:ok, next_loop, next_control, event_specs} ->
        case commit_operational(data, next_loop, next_control, event_specs,
               correlation_id: loop.correlation_id,
               provenance: %{source: :runner_supervisor},
               transition: :runner_start_failed
             ) do
          {:ok, next, _events} ->
            next
            |> maybe_queue_after_transition(next_loop, next_control)
            |> Timers.maybe_schedule_wait_timer(next_loop)

          {:error, _reason} ->
            data
        end

      {:error, _reason} ->
        data
    end
  end

  defp operation_runner_opts(data, loop, attempt) do
    data.base_opts
    |> Keyword.put(:instance_pid, self())
    |> Keyword.put(:operation_loop_id, loop.id)
    |> Keyword.put(:operation_loop_kind, loop.kind)
    |> Keyword.put(:operation_attempt_id, attempt.id)
    |> Keyword.put(:idempotency_key, attempt.idempotency_key)
    |> Keyword.put(:subject_id, data.subject.id)
  end

  defp operation_runner_down(data, pid, monitor, attempt_id, reason) do
    case Map.get(data.operation_runners, attempt_id) do
      %{pid: ^pid, monitor: ^monitor} = ownership ->
        data = drop_operation_runner(data, ownership)

        with {:ok, loop, control} <- Loops.operation_loop(data, ownership.loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 reason,
                 Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
               ),
             {:ok, next, _events} <-
               commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 provenance: %{source: :runner_monitor, attempt_id: attempt_id},
                 transition: :runner_down
               ) do
          next
          |> maybe_queue_after_transition(next_loop, next_control)
          |> Timers.maybe_schedule_wait_timer(next_loop)
          |> maybe_schedule_operations()
        else
          _stale_or_invalid -> maybe_schedule_operations(data)
        end

      _unknown ->
        data
    end
  end

  defp finish_operation_runner(data, ownership) do
    Process.demonitor(ownership.monitor, [:flush])
    drop_operation_runner(data, ownership)
  end

  defp reject_operation_result(data, ownership, result, reason) do
    data = finish_operation_runner(data, ownership)

    with {:ok, loop, control} <- Loops.operation_loop(data, result.loop_id),
         %OperationLoop{attempt: %{id: attempt_id}} when attempt_id == ownership.attempt_id <-
           loop,
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.runner_down(
             loop,
             control,
             ownership.spec,
             {:invalid_operation_result, reason},
             Loops.operation_env(data, snapshot_id: ownership.snapshot_id)
           ),
         {:ok, next, _events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: loop.correlation_id,
             causation_id: result.id,
             provenance: %{source: :result_validator, attempt_id: ownership.attempt_id},
             transition: :operation_result_rejected
           ) do
      next
      |> maybe_queue_after_transition(next_loop, next_control)
      |> Timers.maybe_schedule_wait_timer(next_loop)
      |> maybe_schedule_operations()
    else
      _invalid -> maybe_schedule_operations(data)
    end
  end

  defp drop_operation_runner(data, ownership) do
    data = Timers.cancel_attempt_timer(data, ownership.attempt_id)

    %{
      data
      | operation_runners: Map.delete(data.operation_runners, ownership.attempt_id),
        operation_monitors: Map.delete(data.operation_monitors, ownership.pid),
        operation_progress_clock: Map.delete(data.operation_progress_clock, ownership.attempt_id),
        operation_liveness_clock: Map.delete(data.operation_liveness_clock, ownership.attempt_id)
    }
  end

  defp apply_runner_action(data, :keep_runner), do: data

  defp apply_runner_action(data, {:terminate_runner, attempt_id}) do
    case Map.get(data.operation_runners, attempt_id) do
      nil ->
        data

      ownership ->
        _ = RunnerSupervisor.stop_runner(data.runner_supervisor, ownership.pid)
        finish_operation_runner(data, ownership)
    end
  end

  defp normalize_operation_result({:ok, loop, control, events, start_loops}),
    do: {:ok, loop, control, events, start_loops}

  defp normalize_operation_result({:duplicate, loop}), do: {:duplicate, loop}
  defp normalize_operation_result({:error, _reason} = error), do: error

  defp materialize_start_loop_intents(_data, _parent, _result, []), do: {:ok, [], []}

  defp materialize_start_loop_intents(data, parent, result, intents) do
    Enum.reduce_while(intents, {:ok, [], []}, fn intent, {:ok, started, already} ->
      case Keyword.fetch(intent.opts, :id) do
        {:ok, child_id} ->
          case Loops.operation_loop(data, child_id) do
            {:ok, existing, _control} ->
              if started_by_same_intent?(existing, parent, intent) do
                entry = %{intent_id: intent.intent_id, loop: existing}
                {:cont, {:ok, started, [entry | already]}}
              else
                {:halt, {:error, {:duplicate_operational_loop, child_id}}}
              end

            {:error, :operation_loop_not_found} ->
              case materialize_start_loop_intent(data, parent, result, intent) do
                {:ok, child} -> {:cont, {:ok, [child | started], already}}
                {:error, _reason} = error -> {:halt, error}
              end
          end

        :error ->
          {:halt, {:error, {:operation_start_loop_id_missing, intent.intent_id}}}
      end
    end)
    |> case do
      {:ok, started, already} -> {:ok, Enum.reverse(started), Enum.reverse(already)}
      {:error, _reason} = error -> error
    end
  end

  # Start intents are idempotent: re-proposing an intent whose Work already
  # exists with the same parent and intent provenance is a committed no-op.
  # Only an id collision with different provenance rejects the transition.
  defp started_by_same_intent?(existing, parent, intent) do
    Map.get(existing.provenance, :parent_loop_id) == parent.id and
      Map.get(existing.provenance, :loop_start_intent_id) == intent.intent_id
  end

  defp materialize_start_loop_intent(data, parent, result, intent) do
    with {:ok, metadata} <- start_loop_intent_metadata(intent, parent) do
      provenance =
        parent.provenance
        |> Map.put(:source, :directive)
        |> Map.put(:parent_loop_id, parent.id)
        |> Map.put(:loop_start_intent_id, intent.intent_id)

      opts =
        intent.opts
        |> Keyword.put(:origin, parent.origin)
        |> Keyword.put(:provenance, provenance)
        |> Keyword.put(:turn_id, parent.source_turn_id)
        |> Keyword.put(:authorized_origins, parent.authorized_origins)
        |> Keyword.put(:visibility, parent.visibility)
        |> Keyword.put(:destinations, parent.destinations)
        |> Keyword.put(:causation_id, result.id)
        |> Keyword.put(:metadata, metadata)

      case OperationRuntime.start(
             :work,
             intent.controller,
             intent.input,
             opts,
             Loops.operation_env(data)
           ) do
        {:ok, loop, control, event_specs} ->
          commit_opts = [
            correlation_id: loop.correlation_id,
            causation_id: result.id,
            provenance: provenance,
            transition: {:loop_started_by, parent.id}
          ]

          {:ok,
           %{
             intent_id: intent.intent_id,
             loop: loop,
             control: control,
             event_specs: event_specs,
             opts: commit_opts
           }}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp start_loop_intent_metadata(intent, parent) do
    case Keyword.get(intent.opts, :metadata, %{}) do
      metadata when is_map(metadata) ->
        {:ok,
         metadata
         |> Map.put(:parent_loop_id, parent.id)
         |> Map.put(:parent_loop_kind, parent.kind)
         |> Map.put(:loop_start_intent_id, intent.intent_id)}

      _invalid ->
        {:error, :invalid_operation_start_loop_metadata}
    end
  end

  defp commit_operation_result_with_started_loops(
         data,
         parent,
         parent_control,
         event_specs,
         result,
         started_loops,
         already_started
       ) do
    parent_events =
      case {started_loops, already_started} do
        {[], []} ->
          event_specs

        {started, already} ->
          event_specs ++
            [
              %{
                type: :loops_started,
                payload: %{
                  loops:
                    Enum.map(started, &start_loop_event_entry(&1, false)) ++
                      Enum.map(already, &start_loop_event_entry(&1, true))
                }
              }
            ]
      end

    parent_opts = [
      correlation_id: parent.correlation_id,
      causation_id: result.id,
      provenance: %{runner_attempt: result.attempt_id},
      transition: :operation_result
    ]

    parent_entry = %{
      loop: parent,
      control: parent_control,
      event_specs: parent_events,
      opts: parent_opts
    }

    child_entries =
      Enum.map(started_loops, fn child ->
        Map.take(child, [:loop, :control, :event_specs, :opts])
      end)

    commit_operational_batch(data, [parent_entry | child_entries], parent_opts)
  end

  defp start_loop_event_entry(child, already_started?) do
    %{
      intent_id: child.intent_id,
      id: child.loop.id,
      kind: child.loop.kind,
      already_started: already_started?
    }
  end

  defp queue_started_loops(data, started_loops) do
    Enum.reduce(started_loops, data, fn child, acc ->
      acc
      |> queue_operation(child.loop)
      |> Timers.maybe_schedule_wait_timer(child.loop)
    end)
  end

  defp accept_operation_progress(data, progress) do
    ownership = Map.get(data.operation_runners, progress.attempt_id)
    now = System.monotonic_time(:millisecond)
    minimum = Keyword.get(data.base_opts, :operation_progress_commit_interval, 500)
    previous_commit = Map.get(data.operation_progress_clock, progress.attempt_id)
    previous_liveness = Map.get(data.operation_liveness_clock, progress.attempt_id)

    with :ok <- OperationProgress.validate(progress),
         %{
           loop_id: loop_id,
           fencing_token: token,
           control_generation: control_generation,
           context_revision: context_revision
         } <- ownership,
         true <- loop_id == progress.loop_id and token == progress.fencing_token,
         true <- ownership.spec.id == ownership.operation,
         {:ok, loop, control} <- Loops.operation_loop(data, loop_id),
         %{id: attempt_id, epoch: epoch} <- loop.attempt,
         true <- attempt_id == progress.attempt_id and epoch == progress.epoch,
         true <- progress.context_revision == context_revision,
         true <- progress.context_revision == loop.context_revision,
         true <- progress.control_generation == control_generation,
         true <- progress.control_generation == control.generation,
         true <- progress.trigger_generation == loop.trigger_generation,
         true <- progress.sequence > loop.progress_sequence,
         true <-
           is_nil(previous_liveness) or progress.sequence > previous_liveness.sequence do
      next = %{
        data
        | operation_liveness_clock:
            Map.put(data.operation_liveness_clock, progress.attempt_id, %{
              at: now,
              sequence: progress.sequence
            })
      }

      if is_nil(previous_commit) or now - previous_commit >= minimum do
        committed_clock =
          Map.put(next.operation_progress_clock, progress.attempt_id, now)

        {:ok, loop, control, %{next | operation_progress_clock: committed_clock}}
      else
        {:throttled, next}
      end
    else
      _invalid_or_throttled -> :drop
    end
  end

  defp maybe_remember_operation_result(data, _loop, %OperationResult{status: status}, _spec)
       when status != :ok,
       do: data

  defp maybe_remember_operation_result(data, _loop, _result, %{remember: false}), do: data

  defp maybe_remember_operation_result(data, loop, result, spec) do
    policy = if spec.remember == true, do: %{}, else: spec.remember
    include = Map.get(policy, :include, Map.get(policy, "include", [:value, :artifacts]))

    payload =
      %{
        loop_id: loop.id,
        loop_kind: loop.kind,
        definition: loop.controller_id,
        definition_version: loop.controller_version,
        subject_id: loop.subject_id,
        result_id: result.id,
        operation: result.operation,
        committed_revision: data.canonical.revision,
        provenance: loop.provenance
      }
      |> maybe_put_memory_field(:value, result.value, include)
      |> maybe_put_memory_field(:artifacts, result.artifacts, include)
      |> maybe_put_memory_field(:receipt, result.receipt, include)

    owner = self()
    agent = data.agent

    memory_opts =
      data.base_opts
      |> Keyword.put(:idempotency_key, result.id)
      |> Keyword.put(:operation_loop_id, loop.id)
      |> Keyword.put(:operation_result_id, result.id)

    callback = fn ->
      outcome = Spectre.Operation.Memory.persist(agent, payload, memory_opts)
      send(owner, {:spectre, :operation_memory_result, loop.id, result.id, outcome})
    end

    case Task.Supervisor.start_child(Spectre.Operation.TaskSupervisor, callback) do
      {:ok, _pid} ->
        disarm_idle_timer(data)

      {:error, reason} ->
        send(
          self(),
          {:spectre, :operation_memory_result, loop.id, result.id,
           {:error, {:memory_task_start_failed, reason}}}
        )

        disarm_idle_timer(data)
    end
  end

  defp maybe_put_memory_field(payload, key, value, include) do
    if key in List.wrap(include), do: Map.put(payload, key, value), else: payload
  end

  defp operation_result_committed?(data, loop, result_id) do
    match?(%OperationResult{id: ^result_id}, loop.last_result) or
      Enum.any?(Map.get(Loops.canonical_value!(data, :events), :records, []), fn event ->
        event.loop_id == loop.id and event.causation_id == result_id
      end)
  end

  defp memory_status(:ok), do: :committed
  defp memory_status({:error, _reason}), do: :failed
  defp memory_status(_outcome), do: :failed

  defp recover_operational_state(data) do
    Enum.reduce_while(Loops.all_operation_loops(data), {:ok, data}, fn {loop, control},
                                                                       {:ok, acc} ->
      case OperationRuntime.recover(loop, control, Loops.operation_env(acc)) do
        {:ok, ^loop, ^control, []} ->
          next = maybe_queue_after_transition(acc, loop, control)
          {:cont, {:ok, next}}

        {:ok, next_loop, next_control, event_specs} ->
          case commit_operational(acc, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 provenance: %{source: :agent_restart},
                 transition: :loop_recovered
               ) do
            {:ok, next, _events} ->
              next = maybe_queue_after_transition(next, next_loop, next_control)
              {:cont, {:ok, next}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, {:operational_recovery_failed, loop.id, reason}}}
      end
    end)
  end

  # Required receipts form a recovery barrier. No Run or operation is resumed
  # until every durable outbox pointer has been reconciled with the sink; this
  # prevents restored work from crossing a boundary whose evidence is still
  # uncertain.
  defp recover_runtime_state(%{receipt_recovery_deferred: true} = data),
    do: {:ok, data}

  defp recover_runtime_state(data) do
    case recover_conversational_state(data) do
      {:ok, data} -> recover_operational_state(data)
      {:error, _reason} = error -> error
    end
  end

  defp required_receipt_recovery_pending?(:required, canonical) do
    match?({:ok, %{entries: [_ | _]}}, Canonical.fetch(canonical, :receipt_outbox))
  end

  defp required_receipt_recovery_pending?(_mode, _canonical), do: false

  # Ready queue entries are process-local, so they must be reconstructed from
  # the durable admission continuation before operational recovery is allowed
  # to schedule competing work.
  defp recover_conversational_state(data) do
    data.runs
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, data}, fn run, {:ok, acc} ->
      case recover_conversational_run(acc, run) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:run_recovery_failed, run.id, reason}}}
      end
    end)
  end

  defp recover_conversational_run(
         %{invocations: invocations} = data,
         %Run{waiting: %Invocation{id: invocation_id}}
       )
       when is_map_key(invocations, invocation_id),
       do: {:ok, data}

  defp recover_conversational_run(
         data,
         %Run{
           status: :ready,
           cursor: :turn,
           start_continuation: %StartContinuation{recoverable?: true} = continuation
         } = run
       ) do
    restored_opts =
      data
      |> runtime_opts(StartContinuation.runtime_options(continuation), run.input)
      |> put_run_pin(run)

    case recovered_start_entry(run, continuation, restored_opts, data.state.revision) do
      {:ok, entry} -> {:ok, enqueue(data, entry)}
      {:error, reason} -> terminalize_unrecoverable_run(data, run, reason)
    end
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation:
             %{provider_status: :selected, recoverable?: true} =
               continuation
         } = run
       ) do
    restored_opts =
      data
      |> runtime_opts(
        Spectre.Inference.Descriptor.options(continuation.descriptor),
        run.input
      )
      |> put_run_pin(run)

    case Inference.rebind(
           data.agent,
           continuation.descriptor,
           continuation.frozen_selection,
           run.input,
           data.state,
           restored_opts
         ) do
      {:ok, prepared} ->
        entry = recovered_inference_entry(data, run, restored_opts)

        next =
          case get_in(continuation.recovery || %{}, [:status]) do
            :stream_restart_receipted ->
              entry =
                Map.put(entry, :stream_resume_from, %{
                  provider_request_id: continuation.provider_request_id,
                  resume_cursor: continuation.resume_cursor,
                  provider_sequence: continuation.stream_provider_sequence,
                  usage: continuation.stream_usage,
                  usage_quality: continuation.stream_usage_quality,
                  output_bytes: continuation.stream_output_bytes
                })

              resume_recovered_stream_dispatch(data, run, invocation, prepared, entry)

            recovery_status ->
              resume_recovered_selected_dispatch(
                data,
                run,
                invocation,
                prepared,
                entry,
                recovery_status
              )
          end

        {:ok, next}

      {:error, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:inference_rebind_failed, reason})}
    end
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation: %{
             provider_status: :terminal,
             recovery: %{status: :retry_pending, reason: reason}
           }
         } = run
       ) do
    opts =
      data
      |> runtime_opts(
        Spectre.Inference.Descriptor.options(run.inference_continuation.descriptor),
        run.input
      )
      |> put_run_pin(run)

    entry = recovered_inference_entry(data, run, opts)
    ownership = %{mode: :one_shot, invocation: invocation, entry: entry}
    {:ok, start_inference_retry(data, run, ownership, reason)}
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation: %{
             provider_status: :terminal,
             last_response: %InferenceResponse{} = response
           }
         } = run
       ) do
    opts =
      data
      |> runtime_opts(
        Spectre.Inference.Descriptor.options(run.inference_continuation.descriptor),
        run.input
      )
      |> put_run_pin(run)

    entry = recovered_inference_entry(data, run, opts)
    ownership = %{invocation: invocation, entry: entry}
    {:ok, start_inference_resume_worker(data, run, ownership, response)}
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference, metadata: %{streaming?: true}},
           inference_continuation: %{provider_status: status} = continuation
         } = run
       )
       when status in [:streaming, :interrupted] do
    recover_streaming_attempt(data, run, continuation)
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference, metadata: %{streaming?: true}},
           inference_continuation: %{provider_status: status}
         } = run
       )
       when status in [:dispatching, :ambiguous] do
    recover_uncertain_inference(data, run, status)
  end

  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :inference,
           inference_continuation: %{provider_status: status}
         } = run
       )
       when status in [:dispatching, :streaming, :interrupted, :ambiguous] do
    {:ok, terminalize_recovered_inference(data, run.id, status)}
  end

  defp recover_conversational_run(
         data,
         %Run{status: :awaiting, cursor: :inference} = run
       ) do
    {:ok, terminalize_recovered_inference(data, run.id, :inference_recovery_unavailable)}
  end

  # An Effect worker may have crossed its external boundary before the owner
  # crashed. Re-dispatch would risk duplicating it, while leaving the Run
  # awaiting a dead worker leaks a retained slot forever. Record the explicit
  # ambiguous terminal through the normal effect/action receipt path.
  defp recover_conversational_run(
         data,
         %Run{
           status: :awaiting,
           cursor: :effect,
           waiting: %Invocation{kind: :effect} = invocation
         } = run
       ) do
    {:ok, terminalize_recovered_effect(data, run, invocation)}
  end

  # A reply boundary contains no external work. It is safe to advance the
  # already-committed Result to its terminal Run projection after restart.
  defp recover_conversational_run(
         data,
         %Run{status: :boundary, cursor: :complete, waiting: %Boundary{kind: :reply}} = run
       ) do
    opts =
      data
      |> runtime_opts([], run.input)
      |> put_run_pin(run)

    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false,
      admitted?: false,
      recovered?: true
    }

    {:ok, enqueue(data, entry)}
  end

  # Policy boundaries are intentionally durable waits for a future host
  # command. They have no dead process ownership to reconstruct.
  defp recover_conversational_run(
         data,
         %Run{status: :boundary, cursor: :policy, waiting: %Boundary{kind: :needs}}
       ),
       do: {:ok, data}

  defp recover_conversational_run(
         data,
         %Run{status: :ready, cursor: :turn, start_continuation: continuation} = run
       ) do
    reason =
      case continuation do
        %StartContinuation{reason: reason} when not is_nil(reason) -> reason
        _missing -> :missing_start_continuation
      end

    terminalize_unrecoverable_run(data, run, reason)
  end

  defp recover_conversational_run(data, %Run{}), do: {:ok, data}

  defp recovered_start_entry(
         run,
         %StartContinuation{entrypoint: :turn},
         opts,
         state_revision
       ) do
    {:ok,
     %{
       run_id: run.id,
       operation: :advance,
       projection: :result,
       input: run.input,
       opts: opts,
       state_revision: state_revision,
       internal?: true,
       commit_state?: true,
       admitted?: true,
       recovered?: true
     }}
  end

  defp recovered_start_entry(
         run,
         %StartContinuation{
           entrypoint: :inference,
           inference_request: %InferenceRequest{} = request
         },
         opts,
         state_revision
       ) do
    {:ok,
     %{
       run_id: run.id,
       operation: {:inference, request},
       projection: :inference_response,
       input: run.input,
       opts: opts,
       state_revision: state_revision,
       internal?: true,
       commit_state?: false,
       admitted?: false,
       recovered?: true
     }}
  end

  defp recovered_start_entry(_run, _continuation, _opts, _state_revision),
    do: {:error, :invalid_start_continuation_entrypoint}

  defp recovered_inference_entry(data, run, opts) do
    projection = recovered_inference_projection(run.inference_continuation)

    %{
      run_id: run.id,
      operation: :advance,
      projection: projection,
      input: run.input,
      opts: opts,
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: projection != :inference_response,
      admitted?: false,
      recovered?: true
    }
  end

  defp recovered_inference_projection(%{postprocessor: :cognitive_operation}),
    do: :inference_response

  defp recovered_inference_projection(_continuation), do: :result

  # Capacity reservations are process-local leases. A checkpoint can retain a
  # selected streaming Invocation, but it cannot retain the reservation owned
  # by the crashed Instance. Reacquire that lease before releasing any recovered
  # selection receipt; otherwise the session would start with no capacity fence.
  defp resume_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         recovery_status
       ) do
    case reserve_recovered_stream_capacity(data, run, invocation) do
      {:ok, reserved, reservation} ->
        entry = Map.put(entry, :stream_capacity_reservation, reservation)

        continue_recovered_selected_dispatch(
          reserved,
          run,
          invocation,
          prepared,
          entry,
          recovery_status
        )

      {:error, reason} ->
        terminalize_recovered_inference(data, run.id, reason)
    end
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :selection_receipted
       ) do
    commit_inference_dispatch_intent(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :supersession_receipted
       ) do
    commit_recovered_selection_receipt(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         :steer_successor_selected
       ) do
    commit_recovered_supersession_receipt(data, run, invocation, prepared, entry)
  end

  defp continue_recovered_selected_dispatch(
         data,
         run,
         invocation,
         prepared,
         entry,
         _unreceipted_selection
       ) do
    commit_recovered_selection_receipt(data, run, invocation, prepared, entry)
  end

  defp resume_recovered_stream_dispatch(data, run, invocation, prepared, entry) do
    case InferenceCapacity.reserve(data, run.id, :stream) do
      {:ok, reserved, reservation} ->
        entry = Map.put(entry, :stream_capacity_reservation, reservation)
        commit_inference_dispatch_intent(reserved, run, invocation, prepared, entry)

      {:error, reason} ->
        terminalize_recovered_inference(data, run.id, reason)
    end
  end

  defp recover_streaming_attempt(data, run, continuation) do
    opts =
      data
      |> runtime_opts(Inference.Descriptor.options(continuation.descriptor), run.input)
      |> put_run_pin(run)

    with :continue <- recovered_inference_control(data, run),
         true <- continuation.recoverable?,
         true <- not is_nil(continuation.resume_cursor),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         true <- MapSet.member?(prepared.stream_capabilities, :resume),
         {:ok, reserved, reservation} <- InferenceCapacity.reserve(data, run.id, :stream),
         {:ok, successor, invocation, entry} <-
           build_recovered_stream_successor(
             reserved,
             run,
             opts,
             reservation
           ),
         {:ok, committed} <- Commit.run_state(reserved, data.state, successor) do
      retained =
        committed
        |> Runs.put_run(successor)
        |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})

      {:ok,
       commit_recovered_stream_restart_receipt(
         retained,
         successor,
         run.waiting,
         invocation,
         prepared,
         entry
       )}
    else
      {:cancelled, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:cancelled, reason})}

      {:error, :pending_inference_control_on_recovery} ->
        reject_interrupted_inference_control(data, run)

      false ->
        recover_uncertain_inference(data, run, :stream_resume_capability_unavailable)

      {:error, reason} ->
        :ok = InferenceCapacity.release_reservation(data, {data.ref.key, run.id})
        recover_uncertain_inference(data, run, {:stream_resume_unavailable, reason})
    end
  end

  defp recover_uncertain_inference(data, run, recovery_reason) do
    continuation = run.inference_continuation

    opts =
      data
      |> runtime_opts(Inference.Descriptor.options(continuation.descriptor), run.input)
      |> put_run_pin(run)

    with :continue <- recovered_inference_control(data, run),
         true <- not is_nil(continuation.provider_request_id),
         {:ok, prepared} <-
           Inference.rebind(
             data.agent,
             continuation.descriptor,
             continuation.frozen_selection,
             run.input,
             data.state,
             opts
           ),
         true <- MapSet.member?(prepared.stream_capabilities, :reconcile) do
      entry = recovered_inference_entry(data, run, opts)
      {:ok, start_inference_reconciliation(data, run, prepared, entry)}
    else
      {:cancelled, reason} ->
        {:ok, terminalize_recovered_inference(data, run.id, {:cancelled, reason})}

      {:error, :pending_inference_control_on_recovery} ->
        reject_interrupted_inference_control(data, run)

      _unavailable ->
        {:ok, terminalize_recovered_inference(data, run.id, recovery_reason)}
    end
  end

  # A restart can land after the durable `:committed` steering command but
  # before the successor Run and `:applied` control are committed together.
  # The old provider is already fenced by the new Instance generation, but the
  # canonical command must not remain pending forever. Reject it explicitly,
  # then close the uncertain attempt through its normal terminal receipt path.
  defp reject_interrupted_inference_control(data, run) do
    with {:ok, controls} <- Canonical.fetch(data.canonical, :inference_control),
         %{pending: %ControlCommand{} = pending} = control <-
           Map.get(controls, run.inference_continuation.inference_id),
         rejected <-
           ControlCommand.rejected(pending, :instance_restarted_before_control_apply),
         next_control <- InferenceControl.finish(control, rejected),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{
               inference_control:
                 Map.put(controls, run.inference_continuation.inference_id, next_control)
             },
             correlation_id: run.id,
             causation_id: pending.id,
             provenance: %{source: :agent_restart, command_id: pending.id},
             metadata: %{transition: :inference_control_rejected_on_recovery}
           ) do
      {:ok,
       terminalize_recovered_inference(
         committed,
         run.id,
         :pending_inference_control_interrupted
       )}
    else
      nil -> {:error, :missing_pending_inference_control}
      {:error, reason} -> {:error, {:inference_control_rejection_failed, reason}}
    end
  end

  # Control is canonical independently from the Run checkpoint. Recovery must
  # inspect it before touching the provider, otherwise a crash between a
  # committed cancel and its terminal receipt could resurrect the stream.
  defp recovered_inference_control(data, %Run{waiting: %Invocation{} = invocation}) do
    case Canonical.fetch(data.canonical, :inference_control) do
      {:ok, controls} ->
        controls
        |> Map.get(invocation.inference_id)
        |> InferenceControl.recover(invocation)

      {:error, reason} ->
        {:error, {:inference_control_recovery_failed, reason_class(reason)}}
    end
  end

  defp start_inference_reconciliation(data, run, prepared, entry) do
    invocation = run.waiting
    dispatch_id = Spectre.Identity.uuid7()
    capability = make_ref()
    owner = self()
    budget_snapshot = recovered_inference_budget_snapshot(run, invocation.attempt_id)

    {pid, monitor} =
      spawn_worker(fn ->
        result =
          Inference.reconcile(
            prepared,
            run.inference_continuation.provider_request_id,
            entry.opts
          )

        {outcome, provider_started?, remote_status} = reconciliation_outcome(result)

        {usage, usage_quality} =
          UsageAccounting.complete_response_outcome(outcome, budget_snapshot)

        receipt = %Receipt{
          invocation_id: invocation.id,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: dispatch_id,
          capability: capability,
          kind: :inference,
          attempt_id: invocation.attempt_id,
          control_revision: invocation.control_revision,
          stream_epoch: invocation.stream_epoch,
          provider_started: provider_started?,
          outcome: outcome,
          usage: usage,
          usage_quality: usage_quality,
          metadata: %{remote_status: remote_status, reconciliation: true}
        }

        send(owner, {:spectre, :invocation_result, invocation.id, receipt})
      end)

    ownership = %{
      mode: :reconcile,
      invocation_id: invocation.id,
      invocation_kind: :inference,
      invocation: invocation,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: dispatch_id,
      capability: capability,
      pid: pid,
      monitor: monitor,
      entry: entry,
      prepared: prepared,
      budget_snapshot: budget_snapshot
    }

    worker = Map.put(ownership, :kind, :invocation)

    data
    |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
    |> Map.put(:invocations, Map.put(data.invocations, invocation.id, ownership))
    |> Map.put(:workers, Map.put(data.workers, pid, worker))
    |> disarm_idle_timer()
  end

  defp recovered_inference_budget_snapshot(
         %Run{inference_continuation: %{budget: %Budget{} = budget}},
         attempt_id
       ) do
    case Budget.reserve(budget, attempt_id, %InferenceUsage{}) do
      {:ok, _unchanged, %BudgetSnapshot{} = snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp recovered_inference_budget_snapshot(_run, _attempt_id), do: nil

  defp reconciliation_outcome({:ok, %InferenceResponse{} = response}),
    do: {{:ok, response}, true, :confirmed}

  defp reconciliation_outcome(:not_found),
    do: {{:error, :inference_reconciliation_not_found}, false, :confirmed}

  defp reconciliation_outcome(:pending),
    do: {{:error, :inference_reconciliation_pending}, true, :ambiguous}

  defp reconciliation_outcome({:error, reason}),
    do: {{:error, {:inference_reconciliation_failed, portable_failure(reason)}}, true, :ambiguous}

  defp build_recovered_stream_successor(data, run, opts, reservation) do
    current = run.inference_continuation
    previous_invocation = current.invocation
    # Restart changes the data-plane epoch, not the user control revision.
    # The new Run revision is enough to derive a distinct Invocation id.
    control_revision = current.control_revision

    previous = %{
      attempt: current.attempt,
      attempt_id: previous_invocation.attempt_id,
      invocation_id: previous_invocation.id,
      stream_epoch: previous_invocation.stream_epoch,
      control_revision: previous_invocation.control_revision,
      outcome: :superseded,
      reason: :instance_restart,
      usage: current.stream_usage,
      settlement: :ambiguous
    }

    stream_recovery = %{
      mode: :provider_resume,
      previous_invocation_id: previous_invocation.id,
      previous_stream_epoch: previous_invocation.stream_epoch,
      previous_consumer_token_digest: current.consumer_token_digest,
      provider_request_digest: current.provider_request_digest,
      resume_cursor_digest: provider_cursor_digest(current.resume_cursor),
      provider_sequence: current.stream_provider_sequence
    }

    continuation = %{
      current
      | invocation: nil,
        stream_epoch: nil,
        control_revision: control_revision,
        provider_status: :selected,
        consumer_token_digest: nil,
        stream_recovery: stream_recovery,
        previous_attempts: Enum.take([previous | current.previous_attempts], 32),
        recovery: %{status: :stream_restart_selected},
        last_response: nil
    }

    successor = %{
      run
      | revision: run.revision + 1,
        step_id:
          Value.token("inference-stream-restart", {
            run.id,
            previous_invocation.id,
            control_revision
          }),
        waiting: nil,
        inference_continuation: continuation,
        last_error: nil
    }

    invocation =
      Invocation.from_inference(successor, continuation,
        attempt_id: previous_invocation.attempt_id,
        streaming?: true
      )

    continuation = %{
      continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch
    }

    successor = %{successor | waiting: invocation, inference_continuation: continuation}

    entry =
      data
      |> recovered_inference_entry(successor, Keyword.put(opts, :streaming?, true))
      |> Map.put(:stream_capacity_reservation, reservation)
      |> Map.put(:stream_resume_from, %{
        provider_request_id: current.provider_request_id,
        resume_cursor: current.resume_cursor,
        provider_sequence: current.stream_provider_sequence,
        usage: current.stream_usage,
        usage_quality: current.stream_usage_quality,
        output_bytes: current.stream_output_bytes
      })

    {:ok, successor, invocation, entry}
  end

  defp commit_recovered_stream_restart_receipt(
         data,
         successor,
         previous_invocation,
         successor_invocation,
         prepared,
         entry
       ) do
    previous = hd(successor.inference_continuation.previous_attempts)

    continuation = %{
      successor.inference_continuation
      | recovery: %{
          status: :stream_restart_receipted,
          previous_invocation_id: previous_invocation.id
        }
    }

    receipted = %{successor | inference_continuation: continuation}

    payload = %{
      outcome: :superseded,
      reason: :instance_restart,
      previous_attempt: previous,
      successor_invocation_id: successor_invocation.id,
      provider_cancel: :ambiguous,
      resume_cursor_digest: provider_cursor_digest(continuation.resume_cursor)
    }

    case Receipts.prepare_run(
           data,
           data.state,
           receipted,
           :inference_attempt_superseded,
           payload,
           inference_receipt_opts(
             previous_invocation,
             "spectre.inference.attempt-superseded/1"
           )
         ) do
      {:ok, prepared_receipt} ->
        commit_or_stage_run_receipt(
          data,
          receipted,
          {:inference_stream_restarted, successor_invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        data
        |> InferenceCapacity.release(successor.id)
        |> Map.put(:state_lock, nil)
        |> fail_run_commit(receipted, reason)
    end
  end

  defp commit_recovered_selection_receipt(data, run, invocation, prepared, entry) do
    selected = mark_inference_selection_receipted(run)
    retained = Runs.put_run(data, selected)

    case prepare_inference_selection_receipt(retained, selected, invocation, entry) do
      {:ok, prepared_receipt} ->
        commit_or_stage_run_receipt(
          retained,
          selected,
          {:inference_selected, invocation, prepared, entry},
          prepared_receipt
        )

      {:error, reason} ->
        fail_run_commit(%{data | state_lock: nil}, selected, reason)
    end
  end

  defp commit_recovered_supersession_receipt(data, run, invocation, prepared, entry) do
    case run.inference_continuation.previous_attempts do
      [previous | _rest] ->
        continuation = %{
          run.inference_continuation
          | recovery: %{
              status: :supersession_receipted,
              recovered: true,
              previous_invocation_id: Map.get(previous, :invocation_id)
            }
        }

        receipted = %{run | inference_continuation: continuation}

        payload = %{
          outcome: :superseded,
          previous_attempt: previous,
          successor_invocation_id: invocation.id,
          provider_cancel:
            if(Map.get(previous, :settlement) == :confirmed,
              do: :not_started,
              else: :ambiguous
            )
        }

        receipt_opts = [
          inference_id: continuation.inference_id,
          invocation_id: Map.get(previous, :invocation_id),
          attempt_id: Map.get(previous, :attempt_id),
          control_revision: Map.get(previous, :control_revision),
          stream_epoch: Map.get(previous, :stream_epoch),
          causation_id: Map.get(previous, :invocation_id),
          payload_schema_ref: "spectre.inference.attempt-superseded/1",
          privacy: :confidential
        ]

        case Receipts.prepare_run(
               data,
               data.state,
               receipted,
               :inference_attempt_superseded,
               payload,
               receipt_opts
             ) do
          {:ok, prepared_receipt} ->
            commit_or_stage_run_receipt(
              data,
              receipted,
              {:inference_superseded, invocation, prepared, entry},
              prepared_receipt
            )

          {:error, reason} ->
            fail_run_commit(%{data | state_lock: nil}, receipted, reason)
        end

      [] ->
        fail_run_commit(
          %{data | state_lock: nil},
          run,
          :missing_recovered_superseded_attempt
        )
    end
  end

  defp terminalize_unrecoverable_run(data, run, reason) do
    failure = {:run_recovery_unavailable, reason}
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, failure)
    retained = Runs.put_run(data, failed)

    case Commit.run_state(retained, data.state, failed) do
      {:ok, committed} -> {:ok, Runs.record_terminal(committed, failed)}
      {:error, commit_reason} -> {:error, commit_reason}
    end
  end

  defp terminalize_recovered_effect(data, run, invocation) do
    failure = {:effect_outcome_ambiguous, :instance_restarted}
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, failure)

    entry = %{
      run_id: run.id,
      operation: :advance,
      projection: :result,
      input: run.input,
      opts: [],
      state_revision: data.state.revision,
      internal?: true,
      commit_state?: false,
      admitted?: false,
      recovered?: true
    }

    receipt = %Receipt{
      invocation_id: invocation.id,
      run_id: run.id,
      run_revision: run.revision,
      generation: data.generation,
      dispatch_id: Value.token("recovered-effect-dispatch", invocation.id),
      capability: make_ref(),
      kind: :effect,
      provider_started: true,
      outcome: {:error, failure, failed},
      metadata: %{remote_status: :ambiguous, recovered: true}
    }

    commit_effect_terminal(data, %{invocation: invocation, entry: entry}, receipt)
  end

  defp terminalize_recovered_inference(data, run_id, reason) do
    case Map.get(data.runs, run_id) do
      %Run{
        status: :awaiting,
        cursor: :inference,
        waiting: %Invocation{kind: :inference} = invocation,
        inference_continuation: continuation
      } = run ->
        usage = %InferenceUsage{}

        {continuation, failure_reason, semantic} =
          case settle_inference_budget(
                 continuation,
                 invocation.attempt_id,
                 usage,
                 :ambiguous
               ) do
            {:ok, settled} ->
              {failure_reason, semantic} = recovered_inference_failure(reason)
              {settled, failure_reason, semantic}

            {:error, failed, settlement_reason} ->
              failure_reason =
                {:inference_budget_settlement_failed, portable_failure(settlement_reason)}

              {failed, failure_reason, :failed}
          end

        failure = {:inference_attempt_failed, continuation.attempt, failure_reason}

        receipt = %Receipt{
          invocation_id: invocation.id,
          run_id: run.id,
          run_revision: run.revision,
          generation: data.generation,
          dispatch_id: Value.token("recovered-dispatch", invocation.id),
          capability: make_ref(),
          kind: :inference,
          attempt_id: invocation.attempt_id,
          control_revision: invocation.control_revision,
          stream_epoch: invocation.stream_epoch,
          provider_started: continuation.provider_status not in [:not_started, :selected],
          usage: InferenceUsage.to_map(usage),
          outcome: {:error, failure_reason},
          metadata: %{semantic: semantic, remote_status: :ambiguous, recovered: true}
        }

        failed =
          run
          |> Map.put(:inference_continuation, continuation)
          |> Runs.terminalize_failed_run(failure)
          |> put_inference_terminal_metadata(continuation, invocation, receipt)

        payload = inference_failure_payload(receipt, failure_reason)
        ownership = %{mode: :recovery, invocation: invocation, run_id: run.id}

        case Receipts.prepare_run(
               data,
               data.state,
               failed,
               :inference_attempt_terminal,
               payload,
               inference_receipt_opts(invocation, "spectre.inference.attempt-terminal/1")
             ) do
          {:ok, prepared} ->
            data
            |> Map.put(:state_lock, %{run_id: run.id, invocation_id: invocation.id})
            |> commit_or_stage_inference_receipt(
              failed,
              ownership,
              {:failure, failure},
              prepared
            )

          {:error, commit_reason} ->
            %{data | checkpoint_error: {:inference_recovery_commit_failed, commit_reason}}
        end

      nil ->
        data

      _terminal ->
        data
    end
  end

  defp recovered_inference_failure({:cancelled, reason}),
    do: {{:cancelled, portable_failure(reason)}, :cancelled}

  defp recovered_inference_failure(reason),
    do: {{:inference_recovery_ambiguous, portable_failure(reason)}, :ambiguous}

  # A normal task sends its result before terminating. Keep the fence until that
  # message is reduced; an abnormal DOWN has no trustworthy commit outcome.
  defp checkpoint_task_down(data, :normal), do: data

  defp checkpoint_task_down(data, reason) do
    revision = data.checkpoint_inflight && data.checkpoint_inflight.revision
    next = Checkpoint.task_down(data, reason)

    emit(
      :checkpoint_failed,
      next,
      %{count: 1},
      %{
        revision: revision,
        reason_class: reason_class(reason),
        outcome: checkpoint_failure_outcome(next)
      }
    )

    arm_idle_timer(next)
  end

  defp checkpoint_reconciliation_task_down(data, :normal), do: data

  defp checkpoint_reconciliation_task_down(data, reason) do
    next = Checkpoint.reconciliation_task_down(data, reason)

    emit(
      :checkpoint_reconciliation_failed,
      next,
      %{count: 1},
      %{reason_class: reason_class(reason)}
    )

    arm_idle_timer(next)
  end

  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)

  defp checkpoint_error_class(nil), do: nil
  defp checkpoint_error_class(reason), do: reason_class(reason)

  defp checkpoint_failure_outcome(%InstanceState{checkpoint_reconciliation: nil}), do: :failed
  defp checkpoint_failure_outcome(%InstanceState{}), do: :ambiguous

  defp normalize_event_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @operation_event_limit)

  defp normalize_event_limit(_value), do: @operation_event_limit

  defp runtime_opts(data, opts, input) do
    origin_conversation_id =
      Conversation.first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        Conversation.input_conversation_id(input)
      ])

    opts =
      data.base_opts
      |> Keyword.merge(
        Keyword.drop(opts, [
          :timeout,
          :state,
          :conversation_id,
          :origin_conversation_id,
          :subject
        ])
      )
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:subject, data.subject)
      |> Keyword.put(:subject_id, data.subject.id)
      |> Keyword.put(:conversation_id, Keyword.fetch!(data.base_opts, :conversation_id))
      |> Keyword.put(:instance_run_lifecycle?, true)
      |> Keyword.put(:instance_pid, self())
      |> Keyword.put(:instance_definition_store, data.definition_store)
      |> put_activation_pin(data.activation)
      |> maybe_put(:origin_conversation_id, origin_conversation_id)

    metadata =
      case Keyword.get(opts, :run_metadata, %{}) do
        value when is_map(value) -> value
        _invalid -> %{}
      end
      |> Map.merge(%{
        instance_ref: data.ref,
        agent_ref: data.agent_ref,
        subject: data.subject,
        conversation_ref: Conversation.conversation_key(input, origin_conversation_id),
        origin_conversation_ref: Conversation.origin_conversation_key(origin_conversation_id),
        runtime_skill_dispatch?: Keyword.get(opts, :runtime_skill_dispatch?, false)
      })

    Keyword.put(opts, :run_metadata, metadata)
  end

  defp put_activation_pin(opts, nil), do: opts

  defp put_activation_pin(opts, %Activation{} = activation) do
    opts
    |> Keyword.put(:definition_ref, activation.definition_ref)
    |> Keyword.put(:activation_generation, activation.generation)
    |> Keyword.put(:authority_epoch, activation.authority_epoch)
    |> Keyword.put(:closure_digest, activation.closure_digest)
    |> Keyword.put(
      :runtime_skill_dispatch?,
      Map.get(activation.provenance, :change_surface?, false)
    )
  end

  # Admission, not worker start, selects a Run's executable Definition. Queueing,
  # activation changes and restart must never rewrite that immutable pin.
  defp put_run_pin(opts, %Run{} = run) do
    runtime_skill_dispatch? =
      Map.get(
        run.metadata,
        :runtime_skill_dispatch?,
        Map.get(run.metadata, "runtime_skill_dispatch?", false)
      )

    metadata =
      case Keyword.get(opts, :run_metadata, %{}) do
        value when is_map(value) ->
          value
          |> Map.delete("runtime_skill_dispatch?")
          |> Map.put(:runtime_skill_dispatch?, runtime_skill_dispatch? == true)

        _invalid ->
          %{runtime_skill_dispatch?: runtime_skill_dispatch? == true}
      end

    opts
    |> Keyword.put(:definition_ref, run.definition_ref)
    |> Keyword.put(:activation_generation, run.activation_generation)
    |> Keyword.put(:authority_epoch, run.authority_epoch)
    |> Keyword.put(:closure_digest, run.closure_digest)
    |> Keyword.put(:runtime_skill_dispatch?, runtime_skill_dispatch? == true)
    |> Keyword.put(:run_metadata, metadata)
  end

  defp activation_expected_generation(opts) when is_list(opts) do
    case Keyword.fetch(opts, :expected_generation) do
      {:ok, generation} when is_integer(generation) and generation >= 0 -> {:ok, generation}
      {:ok, value} -> {:error, {:invalid_expected_activation_generation, value}}
      :error -> {:error, :expected_activation_generation_required}
    end
  end

  defp activation_expected_generation(value),
    do: {:error, {:invalid_activation_options, value}}

  defp build_activation(data, %{candidate: candidate, resolution: resolution}, _expected, opts) do
    current_generation = Activation.generation(data.activation)
    current_epoch = Events.current_authority_epoch(data)
    activated_at = Keyword.get(opts, :activated_at, System.system_time(:millisecond))

    base_bindings =
      Keyword.get_lazy(opts, :state_bindings, fn ->
        case data.activation do
          %Activation{state_bindings: bindings} -> bindings
          nil -> %{}
        end
      end)

    provenance =
      Keyword.get(opts, :provenance, %{
        source: :trusted_host,
        instance_ref: data.ref.key
      })
      |> Map.put(:build_evidence, resolution.drift)
      |> Map.put(:change_surface?, change_surface?(resolution.definition))

    with :ok <- verify_morph_execution_profile(data.base_opts, resolution.definition),
         {:ok, skill_states, skill_bindings} <-
           SkillStates.prepare_activation(
             data,
             resolution.definition_ref,
             Keyword.put(opts, :activated_at, activated_at)
           ),
         {:ok, state_bindings} <-
           SkillStates.merge_activation_bindings(base_bindings, skill_bindings),
         {:ok, activation} <-
           Activation.new(candidate, resolution,
             generation: current_generation + 1,
             authority_epoch: Keyword.get(opts, :authority_epoch, current_epoch),
             owner_fencing_token: data.owner_lease.fencing_token,
             state_bindings: state_bindings,
             activated_at: activated_at,
             provenance: provenance
           ) do
      {:ok, activation, skill_states}
    end
  end

  defp change_surface?(definition) do
    match?(
      {:ok, _component},
      Spectre.Definition.Canonical.fetch_component(definition, :change_surface)
    )
  end

  defp verify_activation_change_surface_marker(%Activation{} = activation, definition) do
    expected = change_surface?(definition)

    case Map.fetch(activation.provenance, :change_surface?) do
      {:ok, ^expected} ->
        :ok

      :error when expected == false ->
        # Checkpoints written before Morph had no marker. They remain valid
        # only when the resolved Definition has no change surface either.
        :ok

      supplied ->
        {:error,
         {:restored_activation_change_surface_marker_mismatch, marker_value(supplied), expected}}
    end
  end

  defp verify_run_change_surface_marker(%Run{} = run, definition) do
    expected = change_surface?(definition)
    supplied = run_runtime_skill_dispatch?(run)

    if supplied == expected,
      do: :ok,
      else: {:error, {:run_change_surface_marker_mismatch, supplied, expected}}
  end

  defp run_runtime_skill_dispatch?(%Run{} = run) do
    Map.get(
      run.metadata,
      :runtime_skill_dispatch?,
      Map.get(run.metadata, "runtime_skill_dispatch?", false)
    ) == true
  end

  defp marker_value({:ok, value}), do: value
  defp marker_value(:error), do: :missing

  defp verify_morph_execution_profile(base_opts, definition) when is_list(base_opts) do
    if change_surface?(definition) do
      case frozen_execution_options(base_opts) do
        [] -> :ok
        keys -> {:error, {:morph_instance_execution_profile_overridden, keys}}
      end
    else
      :ok
    end
  end

  defp morph_turn_options(%{activation: %Activation{provenance: provenance}}, opts)
       when is_list(opts) do
    if Map.get(provenance, :change_surface?, false) do
      case frozen_execution_options(opts) do
        [] -> :ok
        keys -> {:error, {:morph_turn_execution_profile_overridden, keys}}
      end
    else
      :ok
    end
  end

  defp morph_turn_options(_data, _opts), do: :ok

  defp frozen_execution_options(opts) do
    opts
    |> Keyword.keys()
    |> Enum.filter(&(&1 in @morph_frozen_execution_options))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp commit_activation(data, %Activation{} = activation, skill_states) do
    with :ok <- owner_guard(data, :activation_commit),
         :ok <- activation_checkpoint_ready(data),
         {:ok, lifecycles} <- Events.activation_lifecycles(data, activation),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{
               activation: activation,
               correlations: owner_fenced_correlations(data),
               lifecycles: lifecycles,
               skill_states: skill_states
             },
             correlation_id: activation.activation_receipt,
             causation_id: CandidateRef.to_string(activation.candidate_ref),
             provenance: %{source: :activation, instance_ref: data.ref.key},
             metadata: %{
               transition: :definition_activated,
               activation_generation: activation.generation,
               authority_epoch: activation.authority_epoch
             },
             checkpoint: :defer
           ),
         {:ok, persisted} <- persist_activation_checkpoint(committed, committed.canonical) do
      _ =
        Spectre.Journal.record(
          data.agent,
          :definition_activated,
          %{
            definition_ref: to_string(activation.definition_ref),
            candidate_ref: CandidateRef.to_string(activation.candidate_ref),
            activation_generation: activation.generation,
            authority_epoch: activation.authority_epoch,
            activation_receipt: activation.activation_receipt
          },
          data.base_opts
        )

      {:ok, %{persisted | activation: activation}}
    end
  end

  defp activation_checkpoint_ready(%{checkpoint_store: nil}), do: :ok

  defp activation_checkpoint_ready(data) do
    cond do
      not is_nil(data.checkpoint_reconciliation) ->
        {:error, Checkpoint.reconciliation_error(data)}

      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight) ->
        {:error, :activation_checkpoint_operation_in_progress}

      not is_nil(data.checkpoint_pending) ->
        {:error, :activation_checkpoint_pending}

      data.checkpoint_revision != data.canonical.revision ->
        {:error,
         {:activation_checkpoint_not_current, data.checkpoint_revision, data.canonical.revision}}

      true ->
        :ok
    end
  end

  defp persist_activation_checkpoint(%{checkpoint_store: nil} = data, _canonical),
    do: {:ok, data}

  defp persist_activation_checkpoint(data, canonical) do
    with {:ok, encoded} <- CanonicalCodec.encode_json(canonical),
         :ok <-
           CheckpointStore.persist(
             data.checkpoint_store,
             data.ref,
             encoded,
             data.checkpoint_revision,
             canonical.revision,
             checkpoint_store_opts(data)
           ) do
      {:ok,
       %{
         data
         | checkpoint_revision: canonical.revision,
           checkpoint_persisted: canonical,
           checkpoint_error: nil
       }}
    end
  end

  defp activation_resolver_opts(data, opts) do
    data.base_opts
    |> Keyword.merge(opts)
    |> Keyword.drop([
      :timeout,
      :expected_generation,
      :authority_epoch,
      :state_bindings,
      :skill_state_transitions
    ])
    |> Keyword.put(:checkpoint_store, data.checkpoint_store)
    |> Keyword.put(:observe_builds, true)
    |> Keyword.put(:on_drift, :reject)
  end

  defp definition_store_config(agent, opts, base_opts) do
    value =
      first_configured([
        {opts, :definition_store},
        {base_opts, :definition_store},
        {agent.__spectre_config__(), :definition_store}
      ])

    case value do
      value when value in [nil, false] -> {:ok, nil}
      value -> DefinitionStore.normalize(value)
    end
  end

  defp validate_definition_store_pair(_checkpoint_store, nil), do: :ok

  defp validate_definition_store_pair(checkpoint_store, definition_store),
    do: DefinitionStore.validate_durability_pair(checkpoint_store, definition_store)

  defp checkpoint_store_opts(data) do
    Keyword.put(data.base_opts, :owner_fencing_token, data.owner_lease.fencing_token)
  end

  defp persisted_owner_fencing_floor(activation, canonical) do
    [
      activation_fencing_token(activation),
      correlation_fencing_token(canonical)
      | persisted_section_fencing_tokens(canonical)
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp activation_fencing_token(%Activation{owner_fencing_token: token}), do: token
  defp activation_fencing_token(nil), do: 0

  defp correlation_fencing_token(canonical) do
    case Canonical.fetch(canonical, :correlations) do
      {:ok, %{owner_fencing_token: token}} when is_integer(token) and token > 0 -> token
      _missing -> 0
    end
  end

  defp owner_fenced_correlations(data) do
    {:ok, correlations} = Canonical.fetch(data.canonical, :correlations)
    Map.put(correlations, :owner_fencing_token, data.owner_lease.fencing_token)
  end

  defp persisted_section_fencing_tokens(canonical) do
    skill_state_fencing_tokens(canonical) ++ event_fencing_tokens(canonical)
  end

  defp skill_state_fencing_tokens(canonical) do
    case Canonical.fetch(canonical, :skill_states) do
      {:ok, states} when is_map(states) ->
        Enum.flat_map(states, fn
          {_skill_id, %{branches: branches}} when is_map(branches) ->
            Enum.flat_map(branches, fn
              {_branch_id, %StateBinding{fencing_token: token}} -> [token]
              _invalid -> []
            end)

          _invalid ->
            []
        end)

      _missing ->
        []
    end
  end

  defp event_fencing_tokens(canonical) do
    Enum.flat_map([:event_admissions, :event_quarantine], fn section ->
      case Canonical.fetch(canonical, section) do
        {:ok, %{records: records}} when is_list(records) ->
          Enum.flat_map(records, fn
            %EventEnvelope{owner_fencing_token: token} when is_integer(token) -> [token]
            _invalid -> []
          end)

        _missing ->
          []
      end
    end)
  end

  defp require_definition_store(nil), do: {:error, :definition_store_not_configured}
  defp require_definition_store(store), do: {:ok, store}

  defp owner_config(agent, opts, base_opts) do
    first_configured([
      {opts, :owner},
      {base_opts, :owner},
      {agent.__spectre_config__(), :owner}
    ])
  end

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

  defp resolve_definition_ref(data, :active), do: {:ok, Events.active_definition_ref(data)}

  defp resolve_definition_ref(_data, %DefinitionRef{} = definition_ref) do
    if DefinitionRef.valid?(definition_ref),
      do: {:ok, definition_ref},
      else: {:error, {:invalid_definition_lifecycle_ref, definition_ref}}
  end

  defp resolve_definition_ref(data, value) when is_binary(value) do
    known =
      [data.activation && data.activation.definition_ref]
      |> Kernel.++(Enum.map(data.runs, fn {_id, run} -> run.definition_ref end))
      |> Kernel.++(
        case Canonical.fetch(data.canonical, :lifecycles) do
          {:ok, lifecycles} ->
            Enum.map(lifecycles, fn {_key, lifecycle} -> lifecycle.definition_ref end)

          _invalid ->
            []
        end
      )
      |> Enum.reject(&is_nil/1)

    case Enum.find(known, &(DefinitionRef.to_string(&1) == value)) do
      %DefinitionRef{} = definition_ref -> {:ok, definition_ref}
      nil -> DefinitionRef.parse(value)
    end
  end

  defp resolve_definition_ref(_data, value),
    do: {:error, {:invalid_definition_lifecycle_ref, value}}

  defp restore_activation(canonical, definition_store, checkpoint_store, base_opts) do
    with {:ok, activation} <- Canonical.fetch(canonical, :activation) do
      validate_restored_activation(activation, definition_store, checkpoint_store, base_opts)
    end
  end

  defp validate_restored_activation(nil, _definition_store, _checkpoint_store, _base_opts),
    do: {:ok, nil}

  defp validate_restored_activation(%Activation{}, nil, _checkpoint_store, _base_opts),
    do: {:error, :restored_activation_requires_definition_store}

  defp validate_restored_activation(
         %Activation{} = activation,
         definition_store,
         checkpoint_store,
         base_opts
       ) do
    opts =
      base_opts
      |> Keyword.put(:checkpoint_store, checkpoint_store)
      |> Keyword.put(:observe_builds, true)
      |> Keyword.put(:on_drift, :reject)

    with {:ok, %{candidate: candidate, resolution: resolution} = candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             activation.candidate_ref,
             opts
           ),
         :ok <- verify_morph_execution_profile(base_opts, resolution.definition),
         :ok <- verify_activation_change_surface_marker(activation, resolution.definition),
         :ok <- GovernanceVerifier.verify_recovery(definition_store, candidate_resolution, opts),
         {:ok, rebuilt} <-
           Activation.new(candidate, resolution,
             generation: activation.generation,
             authority_epoch: activation.authority_epoch,
             owner_fencing_token: activation.owner_fencing_token,
             state_bindings: activation.state_bindings,
             activated_at: activation.activated_at,
             provenance: activation.provenance
           ),
         true <- rebuilt == activation do
      {:ok, activation}
    else
      false -> {:error, :restored_activation_integrity_mismatch}
      :not_found -> {:error, :restored_activation_candidate_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp validate_restored_activation(value, _definition_store, _checkpoint_store, _base_opts),
    do: {:error, {:invalid_restored_activation, value}}

  defp restore_runs(canonical, definition_store, checkpoint_store, base_opts, max_runs) do
    with {:ok, checkpoints} <- Canonical.fetch(canonical, :runs),
         true <- is_map(checkpoints) and not is_struct(checkpoints),
         true <- map_size(checkpoints) <= max_runs do
      Enum.reduce_while(checkpoints, {:ok, %{}}, fn {run_id, checkpoint}, {:ok, runs} ->
        with true <- is_binary(run_id) and is_binary(checkpoint),
             {:ok, %Run{id: ^run_id} = run} <- Run.restore(checkpoint),
             :ok <-
               validate_pinned_run_definition(
                 run,
                 definition_store,
                 checkpoint_store,
                 base_opts
               ) do
          {:cont, {:ok, Map.put(runs, run_id, run)}}
        else
          false ->
            {:halt, {:error, {:invalid_restored_run_checkpoint, run_id}}}

          {:ok, %Run{id: other_id}} ->
            {:halt, {:error, {:restored_run_id_mismatch, run_id, other_id}}}

          {:error, reason} ->
            {:halt, {:error, {:restored_run_invalid, run_id, reason}}}
        end
      end)
    else
      false ->
        {:error, {:restored_run_capacity_exceeded, map_size(canonical_runs(canonical)), max_runs}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_pinned_run_definition(
         %Run{activation_generation: 0},
         _definition_store,
         _checkpoint_store,
         _base_opts
       ),
       do: :ok

  defp validate_pinned_run_definition(%Run{}, nil, _checkpoint_store, _base_opts),
    do: {:error, :pinned_run_requires_definition_store}

  defp validate_pinned_run_definition(run, definition_store, checkpoint_store, base_opts) do
    opts =
      base_opts
      |> Keyword.put(:checkpoint_store, checkpoint_store)
      |> Keyword.put(:observe_builds, true)
      |> Keyword.put(:on_drift, :reject)

    case DefinitionResolver.resolve_for_activation(definition_store, run.definition_ref, opts) do
      {:ok, resolution} ->
        expected = Closure.digest(resolution.manifest.execution_closure)

        with :ok <- verify_run_change_surface_marker(run, resolution.definition),
             true <- expected == run.closure_digest do
          :ok
        else
          false -> {:error, {:run_closure_digest_mismatch, run.closure_digest, expected}}
          {:error, _reason} = error -> error
        end

      :not_found ->
        {:error, {:pinned_run_definition_not_found, to_string(run.definition_ref)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp canonical_runs(canonical) do
    case Canonical.fetch(canonical, :runs) do
      {:ok, runs} when is_map(runs) -> runs
      _invalid -> %{}
    end
  end

  defp restored_terminal_ids(runs) do
    runs
    |> Enum.filter(fn {_id, run} -> Runs.terminal_run?(run) end)
    |> Enum.map(fn {id, _run} -> id end)
    |> MapSet.new()
  end

  defp restored_completed_queue(runs) do
    runs
    |> restored_terminal_ids()
    |> MapSet.to_list()
    |> Enum.sort()
    |> :queue.from_list()
  end

  defp base_opts(opts, instance_ref) do
    state_conversation_id =
      Keyword.get(opts, :state_conversation_id, instance_ref.key)
      |> validate_state_conversation_id!()

    opts
    |> Keyword.get(:opts, [])
    |> maybe_put(:event_schema_registry, Keyword.get(opts, :event_schema_registry))
    |> Keyword.put(:conversation_id, state_conversation_id)
    |> Keyword.put(:subject, instance_ref.subject)
    |> Keyword.put(:subject_id, instance_ref.subject.id)
  end

  defp validate_state_conversation_id!(value) do
    case Value.validate(value, [:instance, :state_conversation_id]) do
      :ok ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "invalid Instance state_conversation_id: #{inspect(reason)}"
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp restore_initial_state(agent, opts, base_opts) do
    if Keyword.has_key?(opts, :state) do
      state =
        opts
        |> Keyword.fetch!(:state)
        |> State.new()
        |> put_conversation_id(Keyword.fetch!(base_opts, :conversation_id))

      {:ok, state}
    else
      Runtime.restore_state(agent, base_opts)
    end
  end

  defp put_conversation_id(%State{} = state, nil), do: state
  defp put_conversation_id(%State{} = state, id), do: %{state | conversation_id: id}

  defp instance_ref!(opts) do
    agent_ref =
      case Keyword.get(opts, :agent_ref) do
        %AgentRef{} = ref ->
          AgentRef.new(ref)

        nil ->
          agent = Keyword.fetch!(opts, :agent)

          case Keyword.get(opts, :agent_id) do
            nil -> AgentRef.new(agent)
            id -> AgentRef.new(agent, id: id)
          end
      end

    subject =
      case Keyword.fetch(opts, :subject) do
        {:ok, %Subject{} = subject} -> Subject.new(subject)
        {:ok, subject} -> Subject.new(subject)
        :error -> raise ArgumentError, "Spectre.Instance requires an explicit :subject"
      end

    InstanceRef.new(agent_ref, subject)
  end

  defp idle_timeout(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    first_configured([
      {opts, :idle},
      {opts, :shutdown},
      {base_opts, :idle},
      {base_opts, :shutdown},
      {config, :idle},
      {config, :shutdown}
    ])
  end

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp arm_idle_timer(data) do
    data = disarm_idle_timer(data)
    generation = data.idle_generation + 1

    timer =
      case data.idle_timeout do
        timeout when is_integer(timeout) and timeout > 0 ->
          if busy?(data) or live_runs?(data),
            do: nil,
            else: Process.send_after(self(), {:idle_shutdown, generation}, timeout)

        _other ->
          nil
      end

    %{data | idle_timer: timer, idle_generation: generation}
  end

  defp disarm_idle_timer(data) do
    if is_reference(data.idle_timer), do: Process.cancel_timer(data.idle_timer)
    %{data | idle_timer: nil}
  end

  defp positive_integer(value, _key) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value, :max_runs), do: {:error, {:invalid_instance_max_runs, value}}

  # Preserve the pre-streaming public error for the existing runner limit.
  defp positive_integer(value, :max_operation_runners),
    do: {:error, {:invalid_instance_max_runs, value}}

  defp positive_integer(value, key), do: {:error, {:invalid_instance_option, key, value}}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value),
    do: {:error, {:invalid_instance_max_tombstones, value}}

  defp receipt_mode(opts, base_opts) do
    mode =
      first_configured([
        {opts, :receipt_mode},
        {base_opts, :receipt_mode}
      ]) || :disabled

    if mode in [:disabled, :observational, :required],
      do: {:ok, mode},
      else: {:error, {:invalid_receipt_mode, mode}}
  end

  defp normalize_inference_observer_config(opts, base_opts) do
    enabled =
      first_configured([
        {opts, :inference_observer_lane},
        {base_opts, :inference_observer_lane}
      ]) || false

    interval =
      first_configured([
        {opts, :inference_progress_commit_interval},
        {base_opts, :inference_progress_commit_interval}
      ]) || 5_000

    limit =
      first_configured([
        {opts, :inference_progress_limit},
        {base_opts, :inference_progress_limit}
      ]) || 256

    checkpoint_interval =
      first_configured([
        {opts, :inference_stream_checkpoint_interval},
        {base_opts, :inference_stream_checkpoint_interval}
      ]) || 5_000

    cond do
      not is_boolean(enabled) ->
        {:error, {:invalid_inference_observer_lane, enabled}}

      not is_integer(interval) or interval <= 0 ->
        {:error, {:invalid_inference_progress_commit_interval, interval}}

      not is_integer(limit) or limit <= 0 ->
        {:error, {:invalid_inference_progress_limit, limit}}

      not is_integer(checkpoint_interval) or checkpoint_interval <= 0 ->
        {:error, {:invalid_inference_stream_checkpoint_interval, checkpoint_interval}}

      true ->
        {:ok,
         base_opts
         |> Keyword.put(:inference_observer_lane, enabled)
         |> Keyword.put(:inference_progress_commit_interval, interval)
         |> Keyword.put(:inference_progress_limit, limit)
         |> Keyword.put(:inference_stream_checkpoint_interval, checkpoint_interval)}
    end
  end

  defp receipt_sink(opts, base_opts) do
    first_configured([
      {opts, :receipt_sink},
      {base_opts, :receipt_sink}
    ])
    |> ReceiptSink.normalize()
  end

  defp validate_receipt_configuration(:disabled, _sink, _checkpoint_store), do: :ok

  defp validate_receipt_configuration(:observational, nil, _checkpoint_store),
    do: {:error, :receipt_sink_required}

  defp validate_receipt_configuration(:observational, _sink, _checkpoint_store), do: :ok

  defp validate_receipt_configuration(:required, nil, _checkpoint_store),
    do: {:error, :receipt_sink_required}

  defp validate_receipt_configuration(:required, _sink, nil),
    do: {:error, :required_receipts_need_checkpoint_store}

  defp validate_receipt_configuration(:required, sink, _checkpoint_store) do
    if ReceiptSink.payload_capable?(sink),
      do: :ok,
      else: {:error, :required_receipt_sink_lacks_payload_store}
  end

  defp instance_retention(nil, _key, default), do: {:ok, default}
  defp instance_retention(:unlimited, _key, _default), do: {:ok, :unlimited}

  defp instance_retention(value, _key, _default)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp instance_retention(value, key, _default),
    do: {:error, {:invalid_instance_retention, key, value}}

  defp timeout(opts), do: Keyword.get(opts, :timeout, :timer.minutes(5))

  defp execution_shape(value) when is_map(value), do: :map
  defp execution_shape(value) when is_list(value), do: :list
  defp execution_shape(value) when is_binary(value), do: :binary
  defp execution_shape(value) when is_tuple(value), do: :tuple
  defp execution_shape(value) when is_atom(value), do: :atom
  defp execution_shape(_value), do: :other

  defp monitor_registry(registry, instance_ref) when is_atom(registry) do
    case Process.whereis(registry) do
      pid when is_pid(pid) ->
        monitor_registry_pid(pid, registry, instance_ref)

      nil ->
        {:error, :instance_registry_unavailable}
    end
  catch
    :exit, _reason -> {:error, :instance_registry_unavailable}
  end

  defp monitor_registry_pid(pid, registry, instance_ref) do
    monitor = Process.monitor(pid)

    if registered_instance?(registry, instance_ref) do
      {:ok, monitor}
    else
      Process.demonitor(monitor, [:flush])
      {:error, :instance_registry_registration_lost}
    end
  end

  defp registered_instance?(registry, instance_ref) do
    Enum.any?(Registry.lookup(registry, instance_ref.key), fn
      {instance, _value} -> instance == self()
    end)
  end

  defp emit(event, data, measurements, metadata \\ %{}),
    do: InstanceTelemetry.emit(event, data, measurements, metadata)

  defp id_digest(value), do: InstanceTelemetry.id_digest(value)

  defp maybe_emit_uncorrelated_operation_trigger(data, events) do
    if Enum.any?(events, fn event ->
         event.type == :triggered and is_map(event.payload) and
           Map.get(event.payload, :correlation) == :legacy
       end) do
      emit(:uncorrelated_operation_trigger, data, %{count: 1})
    end

    data
  end
end
