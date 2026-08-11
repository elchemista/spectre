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
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.Runs
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry
  alias Spectre.Instance.Timers
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Operation.Delivery
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
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Value
  alias Spectre.Runtime
  alias Spectre.Skill.StateBinding
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @default_max_runs 256
  @default_max_tombstones 256
  @default_max_operation_runners 8
  @default_terminal_loop_retention 256
  @default_correlation_retention 1_024
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
          | {:operation_terminal_loop_retention, non_neg_integer() | :unlimited}
          | {:operation_correlation_retention, non_neg_integer() | :unlimited}

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

  @doc "Returns the redacted status of canonical checkpoint persistence."
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
      :origin_conversation_ref
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

    with {:ok, max_runs} <- positive_integer(Keyword.get(opts, :max_runs, @default_max_runs)),
         {:ok, max_tombstones} <-
           non_negative_integer(Keyword.get(opts, :max_tombstones, @default_max_tombstones)),
         {:ok, max_operation_runners} <-
           positive_integer(
             Keyword.get(opts, :max_operation_runners, @default_max_operation_runners)
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
         {:ok, checkpoint_store} <- Checkpoint.store_config(agent, opts, base_opts),
         {:ok, checkpoint_mode} <- Checkpoint.mode(opts, checkpoint_store),
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
         {:ok, owner, owner_lease} <-
           Owner.claim(owner_config(agent, opts, base_opts), instance_ref, base_opts) do
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
        generation: Spectre.Identity.uuid7(),
        runner_supervisor: Keyword.get(opts, :runner_supervisor, RunnerSupervisor),
        checkpoint_store: checkpoint_store,
        checkpoint_mode: checkpoint_mode,
        checkpoint_revision: checkpoint_revision,
        checkpoint_persisted:
          if(checkpoint_revision == canonical.revision, do: canonical, else: nil),
        registry: registry,
        registry_monitor: registry_monitor
      }

      case recover_operational_state(data) do
        {:ok, data} ->
          emit(:started, data, %{count: 1})

          {:ok,
           data
           |> Timers.schedule_restored()
           |> maybe_schedule_operations()
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

  def handle_call(
        {:instance_resume, %Ref{} = supplied_ref, command, opts},
        from,
        data
      ) do
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

  # Compatibility with Spectre.Session and Spectre.Turn.resolve_policy/3.
  def handle_call({:resolve_policy, %Result{} = supplied, resolution, opts}, from, data) do
    with {:ok, run} <- Runs.owned_result_run(data, supplied),
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

  def handle_call(:state, _from, data), do: {:reply, data.state, arm_idle_timer(data)}
  def handle_call(:agent, _from, data), do: {:reply, data.agent, arm_idle_timer(data)}
  def handle_call(:instance_ref, _from, data), do: {:reply, data.ref, arm_idle_timer(data)}

  def handle_call(:instance_activation, _from, data),
    do: {:reply, data.activation, arm_idle_timer(data)}

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
        _from,
        data
      ) do
    with :ok <- owner_guard(data, :commit),
         {:ok, definition_ref} <- resolve_definition_ref(data, value),
         {:ok, lifecycle, next} <-
           Events.transition_lifecycle(data, definition_ref, axis, status, opts) do
      {:reply, {:ok, lifecycle}, arm_idle_timer(next)}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:instance_info, _from, data) do
    {:reply, info_projection(data), arm_idle_timer(data)}
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
             ExecutionAdmission.verify(materialization, data.definition_store, data.activation),
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
         :ok <-
           Events.authorize(
             data,
             Events.operation_definition_ref(data, loop),
             :continuation
           ),
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
      error: data.checkpoint_error,
      reconciliation_required: Checkpoint.reconciliation_status(data.checkpoint_reconciliation)
    }

    {:reply, status, arm_idle_timer(data)}
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
    case data.active do
      %{
        run_id: ^run_id,
        dispatch_id: ^dispatch_id,
        capability: ^capability
      } = active ->
        {:noreply, receive_advance_result(data, active, outcome)}

      _stale ->
        emit(:stale_move_result, data, %{count: 1, run_id: run_id})
        {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :invocation_result, invocation_id, %Receipt{} = receipt},
        data
      ) do
    case Runs.validate_invocation_receipt(data, invocation_id, receipt) do
      {:ok, ownership} ->
        data =
          data
          |> finish_worker(ownership.pid)
          |> Map.put(:invocations, Map.delete(data.invocations, invocation_id))
          |> Map.put(:state_lock, nil)

        {:noreply, apply_step(receipt.outcome, ownership.entry, data)}

      {:error, _reason} ->
        emit(:stale_invocation_result, data, %{count: 1, invocation_id: invocation_id})
        {:noreply, data}
    end
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
        emit(:stale_operation_result, data, %{count: 1, loop_id: result.loop_id})
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
            emit(:rejected_operation_result, data, %{
              count: 1,
              loop_id: result.loop_id,
              reason: reason_class(reason)
            })

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
        next = Checkpoint.persisted(data, inflight, revision)

        emit(:checkpoint_persisted, next, %{count: 1, revision: revision})
        {:noreply, arm_idle_timer(next)}

      {:error, reason} ->
        next = Checkpoint.persist_failed(data, inflight, reason)

        emit(:checkpoint_failed, next, %{count: 1, revision: revision})
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
        emit(:checkpoint_reconciled, next, %{count: 1, revision: revision})
        {:noreply, arm_idle_timer(next)}

      {:error, next, reason} ->
        GenServer.reply(from, {:error, reason})
        emit(:checkpoint_reconciliation_failed, next, %{count: 1})
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
      apply_step(outcome, active.entry, %{data | active: nil})
    else
      nil ->
        data

      {:error, _reason} ->
        emit(:invalid_move_result, data, %{count: 1, run_id: active.run_id})
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

    Enum.each(data.operation_timers, fn {_loop_id, timer} ->
      if is_reference(timer.ref), do: Process.cancel_timer(timer.ref)
    end)

    Enum.each(data.operation_attempt_timers, fn {_attempt_id, timer} ->
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

    _ = Owner.release(data.owner, data.ref, data.owner_lease, data.base_opts)

    :ok
  end

  defp submit(input, opts, projection, from, data) do
    case owner_guard(data, :admission) do
      :ok -> submit_owned(input, opts, projection, from, data)
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp submit_owned(input, opts, projection, from, data) do
    data = Runs.prune_for_new_run(data)

    case Conversation.policy_owner(data, input, opts) do
      :none ->
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

      {:ok, %Run{} = owner} ->
        case Events.authorize(data, owner.definition_ref, :continuation) do
          :ok -> submit_lifecycle_input(input, opts, projection, from, owner, data)
          {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
        end

      {:error, reason} ->
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

    case Run.validate_options(runtime_opts) do
      :ok ->
        run = Run.new(data.agent, %Input{}, data.state, runtime_opts)

        if Map.has_key?(data.runs, run.id) or Map.has_key?(data.tombstones, run.id) do
          {:reply, {:error, {:duplicate_instance_run, run.id}}, arm_idle_timer(data)}
        else
          entry = %{
            run_id: run.id,
            operation: {:start, input},
            projection: projection,
            input: input,
            opts: opts,
            state_revision: data.state.revision,
            internal?: false
          }

          retained = %{data | runs: Map.put(data.runs, run.id, run)}

          case Commit.run_state(retained, data.state, run) do
            {:ok, committed} ->
              {:noreply, committed |> enqueue(entry) |> put_caller(run.id, from)}

            {:error, reason} ->
              {:reply, {:error, reason}, arm_idle_timer(data)}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

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

      emit(:invocation_dispatched, next, %{
        count: 1,
        run_id: run.id,
        invocation_id: invocation.id
      })

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
      outcome = safe_step(run, fn -> Runtime.resume(run, command, runtime_opts) end)

      receipt = %Receipt{
        invocation_id: invocation.id,
        run_id: run.id,
        run_revision: run.revision,
        generation: generation,
        dispatch_id: dispatch_id,
        capability: capability,
        outcome: outcome
      }

      send(owner, {:spectre, :invocation_result, invocation.id, receipt})
    end)
  end

  defp start_advance_worker(data, entry) do
    run = Map.fetch!(data.runs, entry.run_id)

    operation =
      if match?({:start, _input}, entry.operation), do: :new_admission, else: :continuation

    case Events.authorize(data, run.definition_ref, operation) do
      :ok -> do_start_advance_worker(data, entry, run)
      {:error, reason} -> fail_run_commit(data, run, reason)
    end
  end

  defp do_start_advance_worker(data, entry, run) do
    state = State.claim_run_lifecycle(data.state, run.id)
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

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(%{operation: :advance} = entry, _run, data) do
    opts = Keyword.put(entry.opts, :state, data.state)
    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp prepare_entry(entry, run, data) do
    opts =
      entry.opts
      |> Keyword.put(:state, data.state)
      |> Keyword.put(:run_id, run.id)
      |> Keyword.put(:trace_id, run.trace_id)

    %{entry | opts: opts, state_revision: data.state.revision}
  end

  defp spawn_advance_worker(owner, run, entry, dispatch_id, capability) do
    spawn_worker(fn ->
      outcome = safe_step(run, fn -> run_operation(run, entry) end)

      send(
        owner,
        {:spectre, :advance_result, run.id, dispatch_id, capability, outcome}
      )
    end)
  end

  defp run_operation(run, %{operation: :advance, opts: opts}),
    do: Runtime.advance(run, opts)

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
            cond do
              Runs.terminal_run?(run) ->
                data
                |> reply_caller(run.id, {:error, reason})
                |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
                |> Runs.record_terminal(run)
                |> maybe_schedule()
                |> arm_idle_timer()

              start_operation?(entry) ->
                failed = Runs.terminalize_failed_run(run, reason)

                data
                |> Runs.put_run(failed)
                |> reply_caller(run.id, {:error, reason})
                |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
                |> Runs.record_terminal(failed)
                |> maybe_schedule()
                |> arm_idle_timer()

              advanced_run?(current, run) ->
                degraded = %{run | last_error: reason}

                data
                |> Runs.put_run(degraded)
                |> reply_caller(run.id, {:error, reason})
                |> tap(&emit(:run_move_degraded, &1, %{count: 1, run_id: run.id}))
                |> maybe_finalize_degraded_run(degraded)
                |> maybe_schedule()
                |> arm_idle_timer()

              true ->
                data
                |> reply_caller(run.id, {:error, reason})
                |> tap(&emit(:run_resume_rejected, &1, %{count: 1, run_id: run.id}))
                |> maybe_schedule()
                |> arm_idle_timer()
            end

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

        {:error, reason} ->
          fail_run_commit(data, run, reason)
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
          data = reply_projection(data, entry, step)
          data = maybe_finalize_reply(data, step)
          data = if Runs.terminal_run?(run), do: Runs.record_terminal(data, run), else: data

          data
          |> maybe_schedule()
          |> arm_idle_timer()

        {:error, reason} ->
          fail_run_commit(data, run, reason)
      end
    else
      reject_stale_step(data, entry, run)
    end
  end

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

  defp maybe_record_started_conversation(data, _entry, _run), do: data

  defp apply_returned_run(data, %Run{} = run, entry) do
    with :ok <- owner_guard(data, :commit) do
      next_state =
        if entry_commits_state?(entry) and entry.state_revision == data.state.revision do
          run.state
        else
          data.state
        end

      last_result = if match?(%Result{}, run.result), do: run.result, else: data.last_result

      next = %{
        data
        | runs: Map.put(data.runs, run.id, run),
          state: next_state,
          last_result: last_result
      }

      Commit.flow_state(next, next_state, run)
    end
  end

  defp fail_run_commit(data, %Run{} = run, reason) do
    failed = Runs.terminalize_failed_run(%{run | state: data.state}, reason)

    data
    |> Runs.put_run(failed)
    |> reply_caller(run.id, {:error, reason})
    |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id, reason: reason}))
    |> Runs.record_terminal(failed)
    |> maybe_schedule()
    |> arm_idle_timer()
  end

  defp reply_projection(data, %{internal?: true}, _step), do: data

  defp reply_projection(data, entry, step) do
    reply =
      case entry.projection do
        :turn -> {:ok, Turn.from_step(self(), entry.input, entry.opts, step)}
        :result -> {:ok, Runs.step_result(step)}
      end

    reply_caller(data, entry.run_id, reply)
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

  defp reply_caller(data, run_id, reply) do
    case Map.pop(data.callers, run_id) do
      {nil, callers} ->
        %{data | callers: callers}

      {from, callers} ->
        GenServer.reply(from, reply)
        %{data | callers: callers}
    end
  end

  defp run_active?(data, run_id) do
    match?(%{run_id: ^run_id}, data.active) or
      MapSet.member?(data.queued, run_id) or
      Map.has_key?(data.callers, run_id) or
      Enum.any?(data.invocations, fn {_id, ownership} -> ownership.run_id == run_id end)
  end

  defp execute_command?({:execute, _value}), do: true
  defp execute_command?(_command), do: false

  defp worker_down(data, pid, worker, reason) do
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
      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight)
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
      emit(:operation_event_route_dropped, data, %{count: 1, event_id: event.id})
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

      case Run.validate_options(runtime_opts) do
        :ok ->
          run = Run.new(data.agent, %Input{}, data.state, runtime_opts)

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
              commit_state?: true
            }

            retained = %{data | runs: Map.put(data.runs, run.id, run)}

            case Commit.run_state(retained, data.state, run) do
              {:ok, committed} -> committed |> enqueue(entry)
              {:error, _reason} -> data
            end
          end

        {:error, reason} ->
          emit(:operation_event_route_rejected, data, %{
            count: 1,
            event_id: event.id,
            reason: reason_class(reason)
          })

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
        emit(:operation_control_failed, data, %{
          count: 1,
          loop_id: loop.id,
          reason: reason_class(reason)
        })

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
        emit(:operation_evaluation_failed, data, %{
          count: 1,
          loop_id: loop.id,
          reason: reason_class(reason)
        })

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
            emit(:operation_prepare_failed, data, %{
              count: 1,
              loop_id: loop.id,
              reason: reason_class(reason)
            })

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
        emit(:operation_prepare_failed, data, %{
          count: 1,
          loop_id: loop.id,
          reason: reason_class(reason)
        })

        data
    end
  end

  defp start_operation_runner(data, loop, control, attempt, spec, request, reconcile?) do
    with :ok <- owner_guard(data, :effect_dispatch),
         :ok <-
           Events.authorize(
             data,
             Events.operation_definition_ref(data, loop),
             :dispatch
           ) do
      do_start_operation_runner(data, loop, control, attempt, spec, request, reconcile?)
    else
      {:error, reason} ->
        emit(:operation_dispatch_blocked, data, %{
          count: 1,
          loop_id: loop.id,
          reason: reason_class(reason)
        })

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
        operation_progress_clock: Map.delete(data.operation_progress_clock, ownership.attempt_id)
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
    previous = Map.get(data.operation_progress_clock, progress.attempt_id)

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
         true <- is_nil(previous) or now - previous >= minimum do
      next = %{
        data
        | operation_progress_clock:
            Map.put(data.operation_progress_clock, progress.attempt_id, now)
      }

      {:ok, loop, control, next}
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

  # A normal task sends its result before terminating. Keep the fence until that
  # message is reduced; an abnormal DOWN has no trustworthy commit outcome.
  defp checkpoint_task_down(data, :normal), do: data

  defp checkpoint_task_down(data, reason),
    do: data |> Checkpoint.task_down(reason) |> arm_idle_timer()

  defp checkpoint_reconciliation_task_down(data, :normal), do: data

  defp checkpoint_reconciliation_task_down(data, reason),
    do: data |> Checkpoint.reconciliation_task_down(reason) |> arm_idle_timer()

  defp reason_class(reason), do: InstanceTelemetry.reason_class(reason)

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
        origin_conversation_ref: Conversation.origin_conversation_key(origin_conversation_id)
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

    with {:ok, skill_states, skill_bindings} <-
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

  defp commit_activation(data, %Activation{} = activation, skill_states) do
    with :ok <- owner_guard(data, :activation_commit),
         :ok <- activation_checkpoint_ready(data),
         {:ok, lifecycles} <- Events.activation_lifecycles(data, activation),
         {:ok, snapshot} <-
           Canonical.snapshot(data.canonical,
             read: [:activation, :lifecycles, :skill_states],
             write: [:activation, :lifecycles, :skill_states],
             correlation_id: activation.activation_receipt,
             causation_id: CandidateRef.to_string(activation.candidate_ref)
           ),
         {:ok, change} <-
           Canonical.change(
             snapshot,
             %{activation: activation, lifecycles: lifecycles, skill_states: skill_states},
             provenance: %{source: :activation, instance_ref: data.ref.key},
             metadata: %{
               transition: :definition_activated,
               activation_generation: activation.generation,
               authority_epoch: activation.authority_epoch
             }
           ),
         {:ok, canonical, _transition} <- Canonical.commit(data.canonical, change),
         {:ok, persisted} <- persist_activation_checkpoint(data, canonical) do
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

      {:ok, %{persisted | canonical: canonical, activation: activation}}
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
             data.base_opts
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
    opts = Keyword.put(base_opts, :checkpoint_store, checkpoint_store)

    with {:ok, %{candidate: candidate, resolution: resolution} = candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             activation.candidate_ref,
             opts
           ),
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
               validate_restored_run_definition(
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

  defp validate_restored_run_definition(
         %Run{activation_generation: 0},
         _definition_store,
         _checkpoint_store,
         _base_opts
       ),
       do: :ok

  defp validate_restored_run_definition(%Run{}, nil, _checkpoint_store, _base_opts),
    do: {:error, :pinned_run_requires_definition_store}

  defp validate_restored_run_definition(run, definition_store, checkpoint_store, base_opts) do
    opts = Keyword.put(base_opts, :checkpoint_store, checkpoint_store)

    case DefinitionResolver.resolve_for_activation(definition_store, run.definition_ref, opts) do
      {:ok, resolution} ->
        expected = Closure.digest(resolution.manifest.execution_closure)

        if expected == run.closure_digest,
          do: :ok,
          else: {:error, {:run_closure_digest_mismatch, run.closure_digest, expected}}

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

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value), do: {:error, {:invalid_instance_max_runs, value}}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value),
    do: {:error, {:invalid_instance_max_tombstones, value}}

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

  defp emit(event, data, measurements),
    do: InstanceTelemetry.emit(event, data, measurements)

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
