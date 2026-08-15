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
  alias Spectre.Execution.Materialization, as: ExecutionMaterialization
  alias Spectre.Governance.Verifier, as: GovernanceVerifier
  alias Spectre.Inference.Progress, as: InferenceProgress
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Inference.Stream, as: InferenceStream
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Activations
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Configuration
  alias Spectre.Instance.DefinitionCompatibility
  alias Spectre.Instance.Deliveries
  alias Spectre.Instance.Events
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.InferenceCoordinator
  alias Spectre.Instance.InferenceHeartbeat
  alias Spectre.Instance.InferenceSteering
  alias Spectre.Instance.Idle
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Operations
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Projection
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.Restore
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.RuntimeRecovery
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Submission
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Instance.Timers
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt, as: Receipt
  alias Spectre.Operation.Delivery
  alias Spectre.Operation.Delivery.Consent, as: DeliveryConsent
  alias Spectre.Operation.Delivery.Policy, as: DeliveryPolicy
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Progress, as: OperationProgress
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Operation.Result, as: OperationResult
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Operation.View, as: OperationView
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Runtime
  alias Spectre.Skill.StateBinding
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @operation_event_limit 512
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
    ref = Configuration.instance_ref!(opts)

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

    ref = Configuration.instance_ref!(opts)
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
    GenServer.call(server, {:handle, input, opts}, Configuration.timeout(opts))
  end

  @doc """
  Handles one input and returns its public Turn projection.
  """
  @spec turn(GenServer.server(), term(), keyword()) :: {:ok, Turn.t()} | {:error, term()}
  def turn(server, input, opts \\ []) do
    GenServer.call(server, {:turn, input, opts}, Configuration.timeout(opts))
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
      do: GenServer.call(server, {:stream, input, opts}, Configuration.timeout(opts)),
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
      do: GenServer.call(server, {:stream_resume, stream, opts}, Configuration.timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc false
  @spec steer_stream(GenServer.server(), InferenceStream.t(), term(), keyword()) ::
          {:ok, InferenceStream.t()} | {:error, term()}
  def steer_stream(server, %InferenceStream{} = stream, input, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do:
        GenServer.call(server, {:stream_steer, stream, input, opts}, Configuration.timeout(opts)),
      else: {:error, :invalid_stream_options}
  end

  @doc false
  @spec cancel_stream(GenServer.server(), InferenceStream.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def cancel_stream(server, %InferenceStream{} = stream, reason, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts),
      do:
        GenServer.call(
          server,
          {:stream_cancel, stream, reason, opts},
          Configuration.timeout(opts)
        ),
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
    GenServer.call(server, {:instance_resume, ref, command, opts}, Configuration.timeout(opts))
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
    GenServer.call(server, {:instance_activate, candidate_ref, opts}, Configuration.timeout(opts))
  end

  @doc "Rolls activation back to an explicitly selected ancestor Candidate."
  @spec rollback(GenServer.server(), CandidateRef.t() | String.t(), keyword()) ::
          {:ok, Activation.t()} | {:error, term()}
  def rollback(server, candidate_ref, opts \\ []) do
    GenServer.call(server, {:instance_rollback, candidate_ref, opts}, Configuration.timeout(opts))
  end

  @doc "Returns the active or explicitly selected branch for a stable Skill id."
  @spec skill_state(GenServer.server(), atom() | String.t(), keyword()) ::
          {:ok, StateBinding.t()} | {:error, term()}
  def skill_state(server, skill_id, opts \\ []) do
    GenServer.call(server, {:skill_state_fetch, skill_id, opts}, Configuration.timeout(opts))
  end

  @doc "Lists non-purged Skill-state branches newest-generation first."
  @spec skill_state_branches(GenServer.server(), atom() | String.t(), keyword()) ::
          {:ok, [StateBinding.t()]} | {:error, term()}
  def skill_state_branches(server, skill_id, opts \\ []) do
    GenServer.call(server, {:skill_state_list, skill_id, opts}, Configuration.timeout(opts))
  end

  @doc "Updates one active Skill-state branch through schema, generation and revision fences."
  @spec update_skill_state(GenServer.server(), atom() | String.t(), term(), keyword()) ::
          {:ok, StateBinding.t()} | {:error, term()}
  def update_skill_state(server, skill_id, value, opts \\ []) do
    GenServer.call(
      server,
      {:skill_state_update, skill_id, value, opts},
      Configuration.timeout(opts)
    )
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
      Configuration.timeout(opts)
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
    GenServer.call(server, {:event_admit, event, opts}, Configuration.timeout(opts))
  end

  @doc "Returns committed admitted Event Envelopes, newest first."
  @spec admitted_events(GenServer.server(), keyword()) :: [EventEnvelope.t()]
  def admitted_events(server, opts \\ []),
    do: GenServer.call(server, {:event_list, :admitted, opts}, Configuration.timeout(opts))

  @doc "Returns quarantined Event Envelopes, newest first."
  @spec quarantined_events(GenServer.server(), keyword()) :: [EventEnvelope.t()]
  def quarantined_events(server, opts \\ []),
    do: GenServer.call(server, {:event_list, :quarantined, opts}, Configuration.timeout(opts))

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
      Configuration.timeout(opts)
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
    call_opts = Keyword.put(opts, :__spectre_callers__, Operations.callers())

    GenServer.call(
      server,
      {:operation_start, :work, controller, input, call_opts},
      Configuration.timeout(opts)
    )
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
    call_opts = Keyword.put(opts, :__spectre_callers__, Operations.callers())

    GenServer.call(
      server,
      {:execution_start, materialization, call_opts},
      Configuration.timeout(opts)
    )
  end

  @doc "Registers a durable Vigil owned by this Agent Instance."
  @spec register_vigil(GenServer.server(), module(), term(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def register_vigil(server, controller, input, opts \\ []) when is_atom(controller) do
    call_opts = Keyword.put(opts, :__spectre_callers__, Operations.callers())

    GenServer.call(
      server,
      {:operation_start, :vigil, controller, input, call_opts},
      Configuration.timeout(opts)
    )
  end

  @doc "Starts a library-owned controller on the shared operational runtime."
  @spec start_controller(GenServer.server(), module(), term(), keyword()) ::
          {:ok, OperationRef.t(), OperationView.t()} | {:error, term()}
  def start_controller(server, controller, input, opts \\ []) when is_atom(controller) do
    call_opts = Keyword.put(opts, :__spectre_callers__, Operations.callers())

    GenServer.call(
      server,
      {:operation_start, :directive, controller, input, call_opts},
      Configuration.timeout(opts)
    )
  end

  @doc "Returns a committed read-only view of one operational loop."
  @spec loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def loop(server, loop, opts \\ []) do
    GenServer.call(
      server,
      {:operation_view, Loops.operation_id(loop), opts},
      Configuration.timeout(opts)
    )
  end

  @doc "Lists committed Work, Vigil and controller views visible to the caller."
  @spec loops(GenServer.server(), keyword()) :: {:ok, [OperationView.t()]} | {:error, term()}
  def loops(server, opts \\ []) do
    GenServer.call(server, {:operation_views, opts}, Configuration.timeout(opts))
  end

  @doc "Resolves exactly one visible loop or returns an explicit ambiguity."
  @spec resolve_loop(
          GenServer.server(),
          OperationRef.t() | String.t() | map() | keyword() | nil,
          keyword()
        ) ::
          {:ok, OperationView.t()} | {:error, term()}
  def resolve_loop(server, selector \\ nil, opts \\ []) do
    GenServer.call(server, {:operation_resolve, selector, opts}, Configuration.timeout(opts))
  end

  @doc "Requests a reversible pause, at a safe boundary by default."
  @spec pause_loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def pause_loop(server, loop, opts \\ []),
    do: Operations.control(server, loop, :pause, nil, opts)

  @doc "Commits an update through the controller's deterministic reducer."
  @spec update_loop(GenServer.server(), OperationRef.t() | String.t(), term(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def update_loop(server, loop, update, opts \\ []),
    do: Operations.control(server, loop, :update, update, opts)

  @doc "Pauses, updates and resumes a loop as one durable correlated intention."
  @spec update_and_resume_loop(
          GenServer.server(),
          OperationRef.t() | String.t(),
          term(),
          keyword()
        ) :: {:ok, OperationView.t()} | {:error, term()}
  def update_and_resume_loop(server, loop, update, opts \\ []),
    do: Operations.control(server, loop, :update_and_resume, update, opts)

  @doc "Resumes a reversibly paused operational loop."
  @spec resume_loop(GenServer.server(), OperationRef.t() | String.t(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def resume_loop(server, loop, opts \\ []),
    do: Operations.control(server, loop, :resume, nil, opts)

  @doc "Renews the declared expiry of a nonterminal loop."
  @spec renew_loop(
          GenServer.server(),
          OperationRef.t() | String.t(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, OperationView.t()} | {:error, term()}
  def renew_loop(server, loop, expires_at, opts \\ []),
    do: Operations.control(server, loop, :renew, %{expires_at: expires_at}, opts)

  @doc "Stops an operational loop terminally; it cannot be resumed."
  @spec stop_loop(GenServer.server(), OperationRef.t() | String.t(), term(), keyword()) ::
          {:ok, OperationView.t()} | {:error, term()}
  def stop_loop(server, loop, reason \\ :stopped, opts \\ []),
    do: Operations.control(server, loop, :stop, reason, opts)

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
      Configuration.timeout(opts)
    )
  end

  @doc "Encodes the complete canonical Agent checkpoint as strict JSON."
  @spec checkpoint(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def checkpoint(server), do: GenServer.call(server, :canonical_checkpoint)

  @doc "Waits until the current canonical revision is durably checkpointed."
  @spec flush_checkpoint(GenServer.server(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def flush_checkpoint(server, opts \\ []) do
    GenServer.call(server, :flush_canonical_checkpoint, Configuration.timeout(opts))
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
    GenServer.call(server, :reconcile_canonical_checkpoint, Configuration.timeout(opts))
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
    GenServer.call(server, {:delivery_consent_put, consent, opts}, Configuration.timeout(opts))
  end

  @doc "Revokes previously stored proactive-delivery consent."
  @spec revoke_delivery_consent(GenServer.server(), String.t(), keyword()) ::
          {:ok, DeliveryConsent.t()} | {:error, term()}
  def revoke_delivery_consent(server, consent_id, opts \\ []) do
    GenServer.call(
      server,
      {:delivery_consent_revoke, consent_id, opts},
      Configuration.timeout(opts)
    )
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
      Configuration.timeout(opts)
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
      Configuration.timeout(opts)
    )
  end

  @doc "Returns redacted committed delivery receipts."
  @spec delivery_receipts(GenServer.server(), keyword()) :: [DeliveryReceipt.t()]
  def delivery_receipts(server, opts \\ []) do
    GenServer.call(server, {:delivery_receipts, opts}, Configuration.timeout(opts))
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

    with {:ok, config} <- Configuration.load(agent, instance_ref, opts),
         {:ok, state} <- restore_initial_state(agent, opts, config.base_opts),
         {:ok, state, canonical, checkpoint_revision} <-
           Checkpoint.restore_canonical(opts, state, config.checkpoint_store, config.base_opts),
         {:ok, activation} <-
           Restore.activation(
             canonical,
             config.definition_store,
             config.checkpoint_store,
             config.base_opts
           ),
         {:ok, restored_runs} <-
           Restore.runs(
             canonical,
             config.definition_store,
             config.checkpoint_store,
             config.base_opts,
             config.max_runs
           ),
         {:ok, registry_monitor} <- monitor_registry(registry, instance_ref),
         fencing_floor <- Restore.owner_fencing_floor(activation, canonical),
         {:ok, owner, owner_lease} <-
           Owner.claim(
             config.owner,
             instance_ref,
             Keyword.put(config.base_opts, :minimum_fencing_token, fencing_floor)
           ) do
      data = %InstanceState{
        agent: agent,
        agent_ref: agent_ref,
        subject: subject,
        ref: instance_ref,
        state: state,
        canonical: canonical,
        activation: activation,
        definition_store: config.definition_store,
        owner: owner,
        owner_lease: owner_lease,
        runs: restored_runs,
        completed: Restore.completed_queue(restored_runs),
        terminal_recorded: Restore.terminal_ids(restored_runs),
        base_opts: config.base_opts,
        idle_timeout: config.idle_timeout,
        max_runs: config.max_runs,
        max_tombstones: config.max_tombstones,
        max_operation_runners: config.max_operation_runners,
        max_stream_sessions: config.max_stream_sessions,
        stream_registry: config.stream_registry,
        stream_capacity: config.stream_capacity,
        generation: Spectre.Identity.uuid7(),
        runner_supervisor: config.runner_supervisor,
        checkpoint_store: config.checkpoint_store,
        checkpoint_mode: config.checkpoint_mode,
        receipt_mode: config.receipt_mode,
        receipt_sink: config.receipt_sink,
        max_receipt_outbox: config.max_receipt_outbox,
        receipt_recovery_deferred:
          RuntimeRecovery.required_receipts_pending?(config.receipt_mode, canonical),
        checkpoint_revision: checkpoint_revision,
        checkpoint_persisted:
          if(checkpoint_revision == canonical.revision, do: canonical, else: nil),
        registry: registry,
        registry_monitor: registry_monitor
      }

      case RuntimeRecovery.recover(data) do
        {:ok, data} ->
          emit(:started, data, %{count: 1})

          {:ok,
           data
           |> Timers.schedule_restored()
           |> RunQueue.schedule()
           |> Operations.schedule()
           |> ReceiptCoordinator.start_deliveries()
           |> Idle.arm()}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:handle, input, opts}, from, data) do
    Submission.submit(input, opts, :result, from, data)
  end

  def handle_call({:turn, input, opts}, from, data) do
    Submission.submit(input, opts, :turn, from, data)
  end

  def handle_call({:stream, input, opts}, from, data) do
    Submission.submit(input, Keyword.put(opts, :streaming?, true), :stream, from, data)
  end

  def handle_call({:cognitive_inference, request, opts}, from, data) do
    Submission.submit_cognitive(request, opts, from, data)
  end

  def handle_call({:stream_resume, stream, _opts}, from, data) do
    case InferenceSteering.resume_stream(data, stream, from) do
      {:reply, reply, next} -> {:reply, reply, Idle.arm(next)}
      {:noreply, next} -> {:noreply, Idle.disarm(next)}
    end
  end

  def handle_call({:stream_steer, stream, input, opts}, from, data) do
    case InferenceSteering.steer_stream(data, stream, input, opts, from) do
      {:ok, next} -> {:noreply, next}
      {:error, reason, next} -> {:reply, {:error, reason}, Idle.arm(next)}
    end
  end

  def handle_call({:stream_cancel, stream, reason, opts}, _from, data) do
    case InferenceSteering.cancel_stream(data, stream, reason, opts) do
      {:ok, next} ->
        {:reply, :ok, Idle.arm(next)}

      {:error, :invocation_terminal, next} ->
        {:reply, :ok, Idle.arm(next)}

      {:error, cancel_reason, next} ->
        {:reply, {:error, cancel_reason}, Idle.arm(next)}
    end
  end

  def handle_call(
        {:instance_resume, %Ref{} = supplied_ref, command, opts},
        from,
        data
      ) do
    case DefinitionCompatibility.validate_turn(data, opts) do
      :ok -> handle_instance_resume(supplied_ref, command, opts, from, data)
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  # Compatibility with Spectre.Session and Spectre.Turn.resolve_policy/3.
  def handle_call({:resolve_policy, %Result{} = supplied, resolution, opts}, from, data) do
    with :ok <- DefinitionCompatibility.validate_turn(data, opts),
         {:ok, run} <- Runs.owned_result_run(data, supplied),
         :ok <- Events.authorize(data, run.definition_ref, :continuation),
         false <- RunQueue.active?(data, run.id),
         %Boundary{kind: :needs, ref: boundary_ref} <- run.waiting do
      entry = %{
        run_id: run.id,
        operation: {:resume, {:policy, boundary_ref, resolution}},
        projection: :result,
        input: run.input,
        opts: RuntimeOptions.build(data, opts, run.input),
        state_revision: data.state.revision,
        internal?: false
      }

      {:noreply, data |> RunQueue.enqueue(entry, true) |> RunQueue.put_caller(run.id, from)}
    else
      true -> {:reply, {:error, :run_already_active}, Idle.arm(data)}
      nil -> {:reply, {:error, :run_not_waiting_for_policy}, Idle.arm(data)}
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
      _other -> {:reply, {:error, :run_not_waiting_for_policy}, Idle.arm(data)}
    end
  end

  # Compatibility with Spectre.execute/3 for a live Instance.
  def handle_call({:execute, %Result{} = supplied, opts}, from, data) do
    case DefinitionCompatibility.validate_turn(data, opts) do
      :ok -> handle_instance_execute(supplied, opts, from, data)
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call(:state, _from, data), do: {:reply, data.state, Idle.arm(data)}
  def handle_call(:agent, _from, data), do: {:reply, data.agent, Idle.arm(data)}
  def handle_call(:instance_ref, _from, data), do: {:reply, data.ref, Idle.arm(data)}

  def handle_call(:instance_activation, _from, data),
    do: {:reply, data.activation, Idle.arm(data)}

  def handle_call(:instance_definition_store, _from, data),
    do: {:reply, data.definition_store, Idle.arm(data)}

  def handle_call(:instance_agent, _from, data),
    do: {:reply, data.agent, Idle.arm(data)}

  def handle_call({:skill_state_fetch, skill_id, opts}, _from, data) do
    {:reply, SkillStates.fetch(data, skill_id, opts), Idle.arm(data)}
  end

  def handle_call({:skill_state_list, skill_id, opts}, _from, data) do
    {:reply, SkillStates.list(data, skill_id, opts), Idle.arm(data)}
  end

  def handle_call({:skill_state_update, skill_id, value, opts}, _from, data) do
    with :ok <- owner_guard(data, :commit),
         {:ok, binding, next} <- SkillStates.update(data, skill_id, value, opts) do
      {:reply, {:ok, binding}, Idle.arm(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
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
      {:reply, {:ok, binding}, Idle.arm(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:instance_activate, candidate_ref, opts}, _from, data) do
    with {:ok, expected_generation} <- Activations.expected_generation(opts),
         :ok <- owner_guard(data, :activation_commit),
         {:ok, definition_store} <- Activations.require_store(data.definition_store),
         {:ok, candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             candidate_ref,
             Activations.resolver_opts(data, opts)
           ),
         :ok <-
           GovernanceVerifier.verify_activation(
             definition_store,
             candidate_resolution,
             data.activation,
             Activations.resolver_opts(data, opts)
           ),
         {:ok, prospective, skill_states} <-
           Activations.build(data, candidate_resolution, expected_generation, opts),
         {:ok, activation} <-
           Activation.compare_and_swap(data.activation, expected_generation, prospective),
         {:ok, next} <- Activations.commit(data, activation, skill_states) do
      {:reply, {:ok, activation}, Idle.arm(next)}
    else
      :not_found ->
        {:reply, {:error, :activation_candidate_not_found}, Idle.arm(data)}

      {:error, {:ambiguous, _detail} = reason} ->
        {:stop, {:activation_checkpoint_outcome_unknown, reason}, {:error, reason}, data}

      {:error, reason} when reason in [:conflict, :stale] ->
        {:stop, {:activation_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, {kind, _expected, _current} = reason} when kind in [:conflict, :stale] ->
        {:stop, {:activation_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:instance_rollback, candidate_ref, opts}, _from, data) do
    with {:ok, expected_generation} <- Activations.expected_generation(opts),
         :ok <- owner_guard(data, :activation_commit),
         {:ok, definition_store} <- Activations.require_store(data.definition_store),
         {:ok, candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             candidate_ref,
             Activations.resolver_opts(data, opts)
           ),
         :ok <-
           GovernanceVerifier.verify_rollback(
             definition_store,
             candidate_resolution,
             data.activation,
             Activations.resolver_opts(data, opts)
           ),
         rollback_opts =
           Keyword.put(
             opts,
             :provenance,
             %{source: :rollback, instance_ref: data.ref.key, external_effects_rolled_back: false}
           ),
         {:ok, prospective, skill_states} <-
           Activations.build(data, candidate_resolution, expected_generation, rollback_opts),
         {:ok, activation} <-
           Activation.compare_and_swap(data.activation, expected_generation, prospective),
         {:ok, next} <- Activations.commit(data, activation, skill_states) do
      {:reply, {:ok, activation}, Idle.arm(next)}
    else
      :not_found ->
        {:reply, {:error, :rollback_candidate_not_found}, Idle.arm(data)}

      {:error, {:ambiguous, _detail} = reason} ->
        {:stop, {:rollback_checkpoint_outcome_unknown, reason}, {:error, reason}, data}

      {:error, reason} when reason in [:conflict, :stale] ->
        {:stop, {:rollback_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, {kind, _expected, _current} = reason} when kind in [:conflict, :stale] ->
        {:stop, {:rollback_checkpoint_conflict, reason}, {:error, reason}, data}

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:event_admit, event, opts}, _from, data) do
    with :ok <- owner_guard(data, :admission),
         {:ok, envelope, next} <- Events.admit(data, event, opts) do
      {:reply, {:ok, envelope}, Idle.arm(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:event_list, status, opts}, _from, data)
      when status in [:admitted, :quarantined] do
    {:reply, Events.list(data, status, opts), Idle.arm(data)}
  end

  def handle_call({:definition_lifecycle, value}, _from, data) do
    reply =
      with {:ok, definition_ref} <- Activations.resolve_definition_ref(data, value) do
        {:ok, Events.lifecycle(data, definition_ref)}
      end

    {:reply, reply, Idle.arm(data)}
  end

  def handle_call(
        {:definition_lifecycle_transition, value, axis, status, opts},
        from,
        data
      ) do
    with :ok <- owner_guard(data, :commit),
         {:ok, definition_ref} <- Activations.resolve_definition_ref(data, value),
         {:ok, lifecycle, writes, commit_opts} <-
           Events.prepare_lifecycle_transition(data, definition_ref, axis, status, opts),
         {:ok, prepared} <-
           ReceiptCoordinator.prepare_authority(
             data,
             definition_ref,
             axis,
             status,
             lifecycle,
             writes,
             commit_opts
           ) do
      next =
        ReceiptCoordinator.commit_sections(
          data,
          {:authority_decision, from, lifecycle},
          prepared
        )

      {:noreply, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call(:instance_info, _from, data) do
    {:reply, Projection.info(data), data}
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

    {:reply, reply, Idle.arm(data)}
  end

  def handle_call({:operation_start, kind, controller, input, opts}, from, data),
    do: Operations.start(kind, controller, input, opts, from, data)

  def handle_call(
        {:execution_start, %ExecutionMaterialization{} = materialization, opts},
        from,
        data
      ),
      do: Operations.start_execution(materialization, opts, from, data)

  def handle_call({:operation_view, loop_id, opts}, _from, data),
    do: Operations.view(loop_id, opts, data)

  def handle_call({:operation_views, opts}, _from, data),
    do: Operations.views(opts, data)

  def handle_call({:operation_resolve, selector, opts}, _from, data),
    do: Operations.resolve(selector, opts, data)

  def handle_call({:operation_control, loop_id, action, payload, opts}, _from, data),
    do: Operations.request_control(loop_id, action, payload, opts, data)

  def handle_call({:operation_trigger, loop_id, trigger, opts}, _from, data),
    do: Operations.trigger(loop_id, trigger, opts, data)

  def handle_call(:canonical_checkpoint, _from, data) do
    {:reply, CanonicalCodec.encode_json(data.canonical), Idle.arm(data)}
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
        {:reply, {:error, :checkpoint_store_not_configured}, Idle.arm(data)}

      data.checkpoint_revision >= data.canonical.revision ->
        {:reply, {:ok, data.checkpoint_revision}, Idle.arm(data)}

      not is_nil(data.checkpoint_reconciliation) ->
        {:reply, {:error, Checkpoint.reconciliation_error(data)}, Idle.arm(data)}

      true ->
        target = data.canonical.revision
        next = %{data | checkpoint_waiters: [{from, target} | data.checkpoint_waiters]}
        {:noreply, Checkpoint.force(next)}
    end
  end

  def handle_call(:reconcile_canonical_checkpoint, from, data) do
    cond do
      is_nil(data.checkpoint_store) ->
        {:reply, {:error, :checkpoint_store_not_configured}, Idle.arm(data)}

      is_nil(data.checkpoint_reconciliation) ->
        {:reply, {:ok, data.checkpoint_revision}, Idle.arm(data)}

      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight) ->
        {:reply, {:error, :checkpoint_operation_in_progress}, Idle.arm(data)}

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

    {:reply, events, Idle.arm(data)}
  end

  def handle_call({:delivery_consent_put, value, opts}, _from, data) do
    with {:ok, consent} <- Deliveries.normalize_consent(value),
         :ok <- Deliveries.validate_consent_subject(consent, data),
         {:ok, next} <- Deliveries.commit_consent(data, consent, opts, :delivery_consent_granted) do
      {:reply, {:ok, consent}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:delivery_consent_revoke, consent_id, opts}, _from, data) do
    with {:ok, consent} <- Deliveries.fetch_consent(data, consent_id),
         revoked <- DeliveryConsent.revoke(consent),
         {:ok, next} <- Deliveries.commit_consent(data, revoked, opts, :delivery_consent_revoked) do
      {:reply, {:ok, revoked}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
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
          {:reply, {:ok, receipt}, Idle.arm(data)}

        {:ok, receipt} ->
          case Operations.commit_delivery_receipt(data, loop, receipt, opts) do
            {:ok, next} -> {:reply, {:ok, receipt}, next}
            {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
          end

        {:error, receipt} ->
          case Operations.commit_delivery_receipt(data, loop, receipt, opts) do
            {:ok, next} -> {:reply, {:error, {receipt.reason, receipt}}, next}
            {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def handle_call({:delivery_record, receipt_id, outcome, detail, opts}, _from, data) do
    with {:ok, receipt} <- Deliveries.fetch_receipt(data, receipt_id),
         {:ok, loop, _control} <- Loops.operation_loop(data, receipt.loop_id),
         :ok <- Loops.authorize_loop(loop, opts),
         {:ok, updated} <- Deliveries.update_receipt(receipt, outcome, detail, opts),
         {:ok, next} <- Operations.commit_delivery_receipt(data, loop, updated, opts) do
      {:reply, {:ok, updated}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
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

    {:reply, receipts, Idle.arm(data)}
  end

  def handle_call({:reset, state}, _from, data) do
    if Idle.busy?(data) or Idle.live_runs?(data) do
      {:reply, {:error, :instance_busy}, Idle.arm(data)}
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
        {:ok, next} -> {:reply, :ok, Idle.arm(%{next | last_result: nil})}
        {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
      end
    end
  end

  defp handle_instance_resume(supplied_ref, command, opts, from, data) do
    case Runs.owned_run(data, supplied_ref) do
      {:ok, run} ->
        case Events.authorize(data, run.definition_ref, :continuation) do
          :ok ->
            cond do
              RunQueue.active?(data, run.id) ->
                {:reply, {:error, {:run_already_active, run.id}}, data}

              execute_command?(command) ->
                RunExecution.dispatch(run, command, opts, :turn, from, data)

              true ->
                entry = %{
                  run_id: run.id,
                  operation: {:resume, command},
                  projection: :turn,
                  input: run.input,
                  opts: RuntimeOptions.build(data, opts, run.input),
                  state_revision: data.state.revision,
                  internal?: false
                }

                {:noreply,
                 data |> RunQueue.enqueue(entry, true) |> RunQueue.put_caller(run.id, from)}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, Idle.arm(data)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  # Execute continuations bypass the normal run queue because they already
  # carry the exact value that must enter the resumed runtime.
  defp execute_command?({:execute, _value}), do: true
  defp execute_command?(_command), do: false

  defp handle_instance_execute(supplied, opts, from, data) do
    case Runs.owned_result_run(data, supplied, true) do
      {:ok, %Run{waiting: %Invocation{} = invocation} = run} ->
        RunExecution.dispatch(
          run,
          {:execute, invocation},
          opts,
          :result,
          from,
          data
        )

      {:ok, %Run{result: %Result{} = result} = run} ->
        if Runs.terminal_result?(result) do
          {:reply, {:ok, result}, Idle.arm(data)}
        else
          {:reply, {:error, {:run_not_waiting_for_invocation, run.id}}, Idle.arm(data)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  @impl GenServer
  def handle_info({:spectre, :advance, run_id}, data) do
    data = %{data | scheduled: false}

    case RunQueue.pop(data, run_id) do
      {:ok, entry, data} ->
        {:noreply, RunExecution.start(data, entry)}

      {:error, _reason, data} ->
        {:noreply, RunQueue.schedule(data)}
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
        {:noreply, RunExecution.advance_result(data, active, outcome)}

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
            {:noreply, InferenceCoordinator.handle_receipt(data, ownership, receipt)}

          :effect ->
            data =
              data
              |> RunExecution.finish_worker(ownership.pid)
              |> Map.put(:invocations, Map.delete(data.invocations, invocation_id))
              |> Map.put(:state_lock, nil)

            {:noreply, RunExecution.commit_effect_terminal(data, ownership, receipt)}
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
      ),
      do: {:noreply, InferenceCoordinator.deadline(data, invocation_id, generation, dispatch_id)}

  def handle_info({:spectre, :receipt_payload_staged, token, result}, data),
    do: ReceiptCoordinator.payload_staged(data, token, result)

  def handle_info({:spectre, :receipt_delivery_result, receipt_id, result}, data),
    do: ReceiptCoordinator.delivery_result(data, receipt_id, result)

  def handle_info({:spectre, :receipt_delivery_retry, receipt_id}, data),
    do: ReceiptCoordinator.delivery_retry(data, receipt_id)

  def handle_info(
        {:spectre, :inference_heartbeat, invocation_id, %InferenceProgress{} = progress,
         checkpoint},
        data
      ) do
    case InferenceHeartbeat.accept(data, invocation_id, progress, checkpoint) do
      {:ok, data} ->
        {:noreply, data}

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

  def handle_info({:spectre, :operation_schedule}, data),
    do: Operations.scheduled(data)

  def handle_info({:spectre, :operation_result, %OperationResult{} = result}, data),
    do: Operations.result(result, data)

  def handle_info({:spectre, :operation_progress, %OperationProgress{} = progress}, data),
    do: Operations.progress(progress, data)

  def handle_info({:spectre, :operation_timer, loop_id, wait_id, generation}, data),
    do: Operations.timer(loop_id, wait_id, generation, data)

  def handle_info({:spectre, :operation_runner_terminating, _attempt_id, _reason}, data),
    do: {:noreply, data}

  def handle_info(
        {:spectre, :operation_attempt_timeout, loop_id, attempt_id, fencing_token},
        data
      ),
      do: Operations.attempt_timeout(loop_id, attempt_id, fencing_token, data)

  def handle_info({:spectre, :operation_memory_result, loop_id, result_id, outcome}, data),
    do: Operations.memory_result(loop_id, result_id, outcome, data)

  def handle_info(
        {:spectre, :checkpoint_result, token, revision, result},
        %{checkpoint_inflight: %{token: token, revision: revision} = inflight} = data
      ) do
    data = Checkpoint.finish_task(data)

    case result do
      :ok ->
        next =
          data
          |> Checkpoint.persisted(inflight, revision)
          |> ReceiptCoordinator.resume_durable(revision)

        next = ReceiptCoordinator.start_deliveries(next)

        emit(:checkpoint_persisted, next, %{count: 1}, %{revision: revision})
        {:noreply, Idle.arm(next)}

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

        {:noreply, Idle.arm(next)}
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
        next = ReceiptCoordinator.start_deliveries(next)
        emit(:checkpoint_reconciled, next, %{count: 1}, %{revision: revision})
        {:noreply, Idle.arm(next)}

      {:error, next, reason} ->
        GenServer.reply(from, {:error, reason})

        emit(
          :checkpoint_reconciliation_failed,
          next,
          %{count: 1},
          %{reason_class: reason_class(reason)}
        )

        {:noreply, Idle.arm(next)}
    end
  end

  def handle_info({:spectre, :checkpoint_reconcile_result, _token, _result}, data),
    do: {:noreply, data}

  def handle_info({:spectre, :checkpoint_result, _token, _revision, _result}, data),
    do: {:noreply, data}

  def handle_info({:idle_shutdown, generation}, %{idle_generation: generation} = data) do
    if Idle.busy?(data) or Idle.live_runs?(data) do
      {:noreply, Idle.arm(%{data | idle_timer: nil})}
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

        receipt_data = ReceiptCoordinator.task_down(data, pid, monitor, reason) ->
          {:noreply, receipt_data}

        invocation_id = Map.get(data.stream_monitors, pid) ->
          {:noreply,
           InferenceCoordinator.stream_session_down(data, invocation_id, pid, monitor, reason)}

        true ->
          case Map.get(data.operation_monitors, pid) do
            attempt_id when is_binary(attempt_id) ->
              {:noreply, Operations.runner_down(data, pid, monitor, attempt_id, reason)}

            nil ->
              case Map.get(data.workers, pid) do
                %{monitor: ^monitor} = worker ->
                  {:noreply, RunExecution.worker_down(data, pid, worker, reason)}

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
      worker -> {:noreply, RunExecution.worker_down(data, pid, worker, reason)}
    end
  end

  def handle_info(_message, data), do: {:noreply, data}

  @impl true
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

    Idle.arm(next)
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

    Idle.arm(next)
  end

  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)

  defp checkpoint_error_class(nil), do: nil
  defp checkpoint_error_class(reason), do: reason_class(reason)

  defp checkpoint_failure_outcome(%InstanceState{checkpoint_reconciliation: nil}), do: :failed
  defp checkpoint_failure_outcome(%InstanceState{}), do: :ambiguous

  defp normalize_event_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @operation_event_limit)

  defp normalize_event_limit(_value), do: @operation_event_limit

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end

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
end
