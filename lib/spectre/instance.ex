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
  alias Spectre.Input
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Canonical.Validator, as: CanonicalValidator
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Invocation.Receipt
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command, as: ControlCommand
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
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @default_max_runs 256
  @default_max_tombstones 256
  @default_max_operation_runners 8
  @operation_event_limit 512
  @delivery_receipt_limit 512

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
          | {:runner_supervisor, GenServer.server()}
          | {:max_operation_runners, pos_integer()}

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

    opts =
      opts
      |> Keyword.put(:agent, ref.agent_ref.definition)
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
    GenServer.call(server, {:operation_view, operation_id(loop), opts}, timeout(opts))
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
    GenServer.call(server, {:operation_trigger, operation_id(loop), trigger, opts}, timeout(opts))
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

  @doc "Records the transport outcome for a previously authorized receipt."
  @spec record_delivery(GenServer.server(), String.t(), :delivered | :failed, term(), keyword()) ::
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
         {:ok, checkpoint_store} <- checkpoint_store(agent, opts, base_opts),
         {:ok, checkpoint_mode} <- checkpoint_mode(opts, checkpoint_store),
         {:ok, state} <- restore_initial_state(agent, opts, base_opts),
         {:ok, state, canonical, checkpoint_revision} <-
           restore_initial_canonical(opts, state, checkpoint_store, base_opts),
         {:ok, registry_monitor} <- monitor_registry(registry, instance_ref) do
      data = %InstanceState{
        agent: agent,
        agent_ref: agent_ref,
        subject: subject,
        ref: instance_ref,
        state: state,
        canonical: canonical,
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
           |> schedule_restored_timers()
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
    case owned_run(data, supplied_ref) do
      {:ok, run} ->
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
  end

  # Compatibility with Spectre.Session and Spectre.Turn.resolve_policy/3.
  def handle_call({:resolve_policy, %Result{} = supplied, resolution, opts}, from, data) do
    with {:ok, run} <- owned_result_run(data, supplied),
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
    case owned_result_run(data, supplied, true) do
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
        if terminal_result?(result) do
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

  def handle_call(:instance_info, _from, data) do
    {:reply, info_projection(data), arm_idle_timer(data)}
  end

  def handle_call({:instance_run, run_id}, _from, data) do
    reply =
      case Map.get(data.runs, run_id) do
        %Run{} = run ->
          {:ok, run_projection(run)}

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

    if nested_work?(data, callers, kind) do
      {:reply, {:error, :work_cannot_start_work}, arm_idle_timer(data)}
    else
      env = operation_env(data)

      case OperationRuntime.start(kind, controller, input, opts, env) do
        {:ok, loop, control, event_specs} ->
          case operation_loop(data, loop.id) do
            {:ok, existing, existing_control} ->
              if same_loop_request?(existing, loop) do
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

        {:error, reason} ->
          {:reply, {:error, reason}, arm_idle_timer(data)}
      end
    end
  end

  def handle_call({:operation_view, loop_id, opts}, _from, data) do
    reply =
      with {:ok, loop, control} <- operation_loop(data, loop_id),
           :ok <- authorize_loop(loop, opts) do
        {:ok, OperationView.from_loop(loop, control)}
      end

    {:reply, reply, arm_idle_timer(data)}
  end

  def handle_call({:operation_views, opts}, _from, data) do
    views =
      data
      |> all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, authorize_loop(loop, opts)) and loop_filter?(loop, opts)
      end)
      |> Enum.map(fn {loop, control} -> OperationView.from_loop(loop, control) end)

    {:reply, {:ok, views}, arm_idle_timer(data)}
  end

  def handle_call({:operation_resolve, selector, opts}, _from, data) do
    matches =
      data
      |> all_operation_loops()
      |> Enum.filter(fn {loop, _control} ->
        match?(:ok, authorize_loop(loop, opts)) and selector_matches?(loop, selector)
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
    with {:ok, loop, control} <- operation_loop(data, loop_id),
         :ok <- authorize_loop(loop, opts),
         {:ok, command} <- control_command(loop, action, payload, opts),
         result <- OperationRuntime.request_control(loop, control, command, operation_env(data)) do
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
                |> maybe_schedule_wait_timer(next_loop)
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
    with {:ok, loop, control} <- operation_loop(data, loop_id),
         :ok <- authorize_loop(loop, opts),
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.trigger(loop, control, trigger, opts, operation_env(data)),
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
        |> maybe_schedule_wait_timer(next_loop)
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
      reconciliation_required: checkpoint_reconciliation_status(data.checkpoint_reconciliation)
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
        {:reply, {:error, checkpoint_reconciliation_error(data)}, arm_idle_timer(data)}

      true ->
        target = data.canonical.revision
        next = %{data | checkpoint_waiters: [{from, target} | data.checkpoint_waiters]}
        {:noreply, force_checkpoint(next)}
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
        {:noreply, start_checkpoint_reconciliation(data, from)}
    end
  end

  def handle_call({:operation_events, opts}, _from, data) do
    limit = normalize_event_limit(Keyword.get(opts, :limit, @operation_event_limit))
    types = Keyword.get(opts, :types)

    events =
      data
      |> canonical_value!(:events)
      |> Map.get(:records, [])
      |> Enum.filter(fn event ->
        (is_nil(types) or event.type in List.wrap(types)) and
          operation_event_visible?(data, event, opts)
      end)
      |> Enum.take(limit)

    {:reply, events, arm_idle_timer(data)}
  end

  def handle_call({:delivery_consent_put, value, opts}, _from, data) do
    with {:ok, consent} <- normalize_delivery_consent(value),
         :ok <- validate_delivery_consent_subject(consent, data),
         {:ok, next} <- commit_delivery_consent(data, consent, opts, :delivery_consent_granted) do
      {:reply, {:ok, consent}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_consent_revoke, consent_id, opts}, _from, data) do
    with {:ok, consent} <- fetch_delivery_consent(data, consent_id),
         revoked <- DeliveryConsent.revoke(consent),
         {:ok, next} <- commit_delivery_consent(data, revoked, opts, :delivery_consent_revoked) do
      {:reply, {:ok, revoked}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call({:delivery_authorize, event_id, destination, policy_value, opts}, _from, data) do
    with {:ok, event} <- committed_operation_event(data, event_id),
         {:ok, loop, _control} <- operation_loop(data, event.loop_id),
         :ok <- authorize_loop(loop, opts),
         {:ok, policy} <- normalize_delivery_policy(policy_value) do
      now = Keyword.get(opts, :now, System.system_time(:millisecond))
      consent = Keyword.get(opts, :consent) || find_delivery_consent(data, loop, destination, now)
      history = committed_delivery_receipts(data)

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
    with {:ok, receipt} <- fetch_delivery_receipt(data, receipt_id),
         {:ok, loop, _control} <- operation_loop(data, receipt.loop_id),
         :ok <- authorize_loop(loop, opts),
         {:ok, updated} <- update_delivery_receipt(receipt, outcome, detail),
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
      |> committed_delivery_receipts()
      |> Enum.filter(&delivery_receipt_visible?(data, &1, opts))
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

      case commit_canonical_sections(data, %{flow: state},
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
    case validate_invocation_receipt(data, invocation_id, receipt) do
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
        with {:ok, loop, control} <- operation_loop(data, result.loop_id),
             {:ok, next_loop, next_control, event_specs, start_loop_intents} <-
               normalize_operation_result(
                 OperationRuntime.apply_result_with_start_loops(
                   loop,
                   control,
                   result,
                   operation_env(data, snapshot_id: ownership.snapshot_id)
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
            |> maybe_schedule_wait_timer(next_loop)
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
    case consume_operation_timer(data, loop_id, wait_id, generation) do
      {:ok, data} ->
        with {:ok, loop, control} <- operation_loop(data, loop_id),
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.trigger(
                 loop,
                 control,
                 {:timer, wait_id},
                 [wait_id: wait_id, generation: generation],
                 operation_env(data)
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
    case consume_operation_attempt_timer(data, loop_id, attempt_id, fencing_token) do
      {:ok, ownership, next} ->
        _ = RunnerSupervisor.stop_runner(next.runner_supervisor, ownership.pid)
        next = finish_operation_runner(next, ownership)

        with {:ok, loop, control} <- operation_loop(next, loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id, fencing_token: ^fencing_token}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 :timeout,
                 operation_env(next, snapshot_id: ownership.snapshot_id)
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
            |> maybe_schedule_wait_timer(next_loop)
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
    with {:ok, loop, control} <- operation_loop(data, loop_id),
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
      {:noreply, next}
    else
      _stale -> {:noreply, data}
    end
  end

  def handle_info(
        {:spectre, :checkpoint_result, token, revision, result},
        %{checkpoint_inflight: %{token: token, revision: revision} = inflight} = data
      ) do
    data = finish_checkpoint_task(data)

    case result do
      :ok ->
        next =
          data
          |> Map.put(:checkpoint_revision, revision)
          |> Map.put(:checkpoint_persisted, inflight.canonical)
          |> Map.put(:checkpoint_reconciliation, nil)
          |> Map.put(:checkpoint_error, nil)
          |> reply_checkpoint_waiters()
          |> start_pending_checkpoint()

        emit(:checkpoint_persisted, next, %{count: 1, revision: revision})
        {:noreply, arm_idle_timer(next)}

      {:error, reason} ->
        next = checkpoint_persist_failed(data, inflight, reason)

        emit(:checkpoint_failed, next, %{count: 1, revision: revision})
        {:noreply, arm_idle_timer(next)}
    end
  end

  def handle_info(
        {:spectre, :checkpoint_reconcile_result, token, result},
        %{checkpoint_reconcile_inflight: %{token: token, from: from}} = data
      ) do
    data = finish_checkpoint_reconciliation_task(data)

    case reconcile_checkpoint_result(data, result) do
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
         :ok <- validate_move_outcome(outcome, current, active.entry) do
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

    :ok
  end

  defp submit(input, opts, projection, from, data) do
    data = prune_for_new_run(data)

    case policy_owner(data, input, opts) do
      :none ->
        if map_size(data.runs) >= data.max_runs do
          {:reply, {:error, :instance_run_capacity_reached}, arm_idle_timer(data)}
        else
          reserve_submitted_run(input, opts, projection, from, data)
        end

      {:ok, %Run{} = owner} ->
        submit_lifecycle_input(input, opts, projection, from, owner, data)

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

          next =
            data
            |> Map.put(:runs, Map.put(data.runs, run.id, run))
            |> enqueue(entry)
            |> put_caller(run.id, from)

          {:noreply, next}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  defp dispatch_invocation(run, command, opts, projection, from, data) do
    run = rebase_run(run, data.state)
    data = put_run(data, run)

    with %Invocation{} = invocation <- run.waiting,
         false <- run_active?(data, run.id),
         nil <- data.state_lock do
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

      true ->
        {:reply, {:error, {:run_already_active, run.id}}, arm_idle_timer(data)}

      %{} ->
        {:reply, {:error, :instance_state_locked}, arm_idle_timer(data)}
    end
  end

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

  defp validate_invocation_receipt(data, invocation_id, %Receipt{} = receipt) do
    ownership = Map.get(data.invocations, invocation_id)

    cond do
      is_nil(ownership) ->
        {:error, :unknown_invocation}

      receipt.invocation_id != invocation_id ->
        {:error, :invocation_id_mismatch}

      receipt.run_id != ownership.run_id or
          receipt.run_revision != ownership.run_revision ->
        {:error, :run_fence_mismatch}

      receipt.generation != ownership.generation or
          receipt.dispatch_id != ownership.dispatch_id ->
        {:error, :dispatch_fence_mismatch}

      receipt.capability !== ownership.capability ->
        {:error, :invalid_receipt_capability}

      true ->
        with %Run{} = current <- Map.get(data.runs, ownership.run_id),
             true <- current.revision == ownership.run_revision,
             %Invocation{id: ^invocation_id} <- current.waiting,
             :ok <- validate_receipt_outcome(receipt.outcome, current) do
          {:ok, ownership}
        else
          _invalid -> {:error, :invalid_receipt_outcome}
        end
    end
  end

  defp validate_receipt_outcome({:continue, %Run{} = returned}, current),
    do: validate_returned_run(returned, current, :advanced)

  defp validate_receipt_outcome(
         {:await, %Invocation{} = invocation, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == invocation,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_await_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:boundary, %Boundary{} = boundary, %Run{} = returned},
         current
       ) do
    with true <- returned.waiting == boundary,
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_boundary_receipt}
    end
  end

  defp validate_receipt_outcome(
         {:complete, %Result{} = result, %Run{} = returned},
         current
       ) do
    with true <- returned.result == result,
         true <- returned.status == :complete and is_nil(returned.waiting),
         :ok <- validate_returned_run(returned, current, :advanced) do
      :ok
    else
      _invalid -> {:error, :invalid_completion_receipt}
    end
  end

  defp validate_receipt_outcome({:error, _reason, %Run{} = returned}, current) do
    cond do
      returned == current ->
        :ok

      returned.revision == current.revision + 1 ->
        validate_returned_run(returned, current, :advanced)

      true ->
        {:error, :invalid_error_receipt}
    end
  end

  defp validate_receipt_outcome(_outcome, _current),
    do: {:error, :invalid_receipt_shape}

  defp validate_move_outcome(
         {:continue, %Run{} = returned},
         current,
         %{operation: {:start, _input}}
       ) do
    validate_started_run(returned, current)
  end

  defp validate_move_outcome(
         {:error, _reason, %Run{} = returned},
         current,
         %{operation: {:start, _input}}
       ) do
    if returned.status == :failed,
      do: validate_receipt_outcome({:error, nil, returned}, current),
      else: validate_started_run(returned, current)
  end

  defp validate_move_outcome(outcome, current, _entry),
    do: validate_receipt_outcome(outcome, current)

  defp validate_started_run(%Run{} = returned, %Run{} = current) do
    with :ok <- validate_run_identity(returned, current),
         :ok <- validate_started_shape(returned, current),
         true <- returned.state.revision == current.state.revision do
      :ok
    else
      false -> {:error, :state_revision_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_run_identity(returned, current) do
    if {returned.id, returned.agent, returned.trace_id} ==
         {current.id, current.agent, current.trace_id},
       do: :ok,
       else: {:error, :run_lineage_mismatch}
  end

  defp validate_started_shape(returned, current) do
    if {returned.revision, returned.status, returned.cursor, returned.waiting, returned.result} ==
         {current.revision, :ready, :turn, nil, nil},
       do: :ok,
       else: {:error, :invalid_started_run}
  end

  defp validate_returned_run(%Run{} = returned, %Run{} = current, :advanced) do
    cond do
      returned.id != current.id or returned.agent != current.agent or
          returned.trace_id != current.trace_id ->
        {:error, :run_lineage_mismatch}

      returned.revision != current.revision + 1 ->
        {:error, :run_revision_mismatch}

      returned.state.revision not in [current.state.revision, current.state.revision + 1] ->
        {:error, :state_revision_mismatch}

      not valid_result_lineage?(returned) ->
        {:error, :result_lineage_mismatch}

      true ->
        :ok
    end
  end

  defp valid_result_lineage?(%Run{result: nil}), do: true

  defp valid_result_lineage?(%Run{result: %Result{} = result} = run) do
    case get_in(result.metadata, [:run]) do
      %{
        id: id,
        revision: revision,
        status: status,
        cursor: cursor,
        ref: %Ref{run_id: ref_run_id, revision: ref_revision}
      } ->
        id == run.id and revision == run.revision and status == run.status and
          cursor == run.cursor and ref_run_id == run.id and ref_revision == run.revision

      _missing ->
        false
    end
  end

  defp valid_result_lineage?(_run), do: false

  defp start_advance_worker(data, entry) do
    run = Map.fetch!(data.runs, entry.run_id)
    state = State.claim_run_lifecycle(data.state, run.id)
    run = rebase_run(run, state)
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
        data = apply_returned_run(data, run, entry)

        cond do
          terminal_run?(run) ->
            data
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
            |> record_terminal(run)
            |> maybe_schedule()
            |> arm_idle_timer()

          start_operation?(entry) ->
            failed = terminalize_failed_run(run, reason)

            data
            |> put_run(failed)
            |> reply_caller(run.id, {:error, reason})
            |> tap(&emit(:run_failed, &1, %{count: 1, run_id: run.id}))
            |> record_terminal(failed)
            |> maybe_schedule()
            |> arm_idle_timer()

          advanced_run?(current, run) ->
            degraded = %{run | last_error: reason}

            data
            |> put_run(degraded)
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
      data =
        data
        |> apply_returned_run(run, entry)
        |> maybe_record_started_conversation(entry, run)

      continuation = %{
        entry
        | operation: :advance,
          input: run.input,
          state_revision: data.state.revision
      }

      data
      |> enqueue_continuation(continuation, start_operation?(entry))
      |> arm_idle_timer()
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp apply_successful_step(step, entry, data) do
    run = step_run(step)

    if entry.state_revision == data.state.revision or state_neutral_step?(entry, run) do
      data = apply_returned_run(data, run, entry)
      data = reply_projection(data, entry, step)
      data = maybe_finalize_reply(data, step)
      data = if terminal_run?(run), do: record_terminal(data, run), else: data

      data
      |> maybe_schedule()
      |> arm_idle_timer()
    else
      reject_stale_step(data, entry, run)
    end
  end

  defp reject_stale_step(data, entry, run) do
    reason =
      {:stale_instance_state, run.id, entry.state_revision, data.state.revision}

    failed = terminalize_failed_run(run, reason)
    data = data |> put_run(failed) |> reply_caller(run.id, {:error, reason})
    data |> record_terminal(failed) |> maybe_schedule() |> arm_idle_timer()
  end

  defp maybe_record_started_conversation(
         data,
         %{operation: {:start, _input}, opts: opts},
         run
       ),
       do: record_conversation(data, run, opts)

  defp maybe_record_started_conversation(data, _entry, _run), do: data

  defp apply_returned_run(data, %Run{} = run, entry) do
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

    if next_state == data.state do
      next
    else
      commit_flow_state(next, next_state, run)
    end
  end

  defp reply_projection(data, %{internal?: true}, _step), do: data

  defp reply_projection(data, entry, step) do
    reply =
      case entry.projection do
        :turn -> {:ok, Turn.from_step(self(), entry.input, entry.opts, step)}
        :result -> {:ok, step_result(step)}
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

  defp owned_result_run(data, %Result{} = result, allow_terminal_replay? \\ false) do
    case get_in(result.metadata, [:run, :id]) do
      run_id when is_binary(run_id) ->
        owned_result_run_by_id(data, result, run_id, allow_terminal_replay?)

      _missing ->
        {:error, :result_has_no_run_reference}
    end
  end

  defp owned_result_run_by_id(data, result, run_id, allow_terminal_replay?) do
    case Map.get(data.runs, run_id) do
      %Run{} = run ->
        validate_owned_result(run, result, allow_terminal_replay?)

      nil ->
        {:error, {:unknown_instance_run, run_id}}
    end
  end

  defp validate_owned_result(run, result, allow_terminal_replay?) do
    supplied_ref = get_in(result.metadata, [:run, :ref])

    cond do
      run_ref_matches?(run, supplied_ref) ->
        {:ok, run}

      allow_terminal_replay? and terminal_replay?(result, run.result) ->
        {:ok, run}

      is_nil(supplied_ref) ->
        {:error, :result_has_no_run_reference}

      true ->
        {:error, {:stale_instance_run_reference, run.id}}
    end
  end

  defp owned_run(data, %Ref{} = supplied_ref) do
    case Map.get(data.runs, supplied_ref.run_id) do
      %Run{status: status} when status in [:complete, :failed] ->
        {:error, {:instance_run_terminal, supplied_ref.run_id, status}}

      %Run{} = run ->
        if run_ref_matches?(run, supplied_ref),
          do: {:ok, run},
          else:
            {:error,
             {:stale_instance_run_reference, supplied_ref.run_id, supplied_ref.revision,
              run.revision}}

      nil ->
        {:error, {:unknown_instance_run, supplied_ref.run_id}}
    end
  end

  defp run_ref_matches?(
         %Run{revision: revision, waiting: %{ref: %Ref{} = expected}},
         %Ref{} = supplied
       ),
       do: expected.revision == revision and expected == supplied

  defp run_ref_matches?(
         %Run{revision: revision, result: %Result{} = result},
         %Ref{} = supplied
       ) do
    case get_in(result.metadata, [:run, :ref]) do
      %Ref{revision: ^revision} = expected -> expected == supplied
      _missing_or_stale -> false
    end
  end

  defp run_ref_matches?(_run, _supplied), do: false

  defp policy_owner(data, input, opts) do
    policies =
      data.runs
      |> Map.values()
      |> Enum.filter(&policy_boundary?/1)
      |> Enum.sort_by(& &1.id)

    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        input_conversation_id(input)
      ])

    conversation_ref = conversation_key(input, origin_conversation_id)
    origin_conversation_ref = origin_conversation_key(origin_conversation_id)
    source_missing? = conversation_source_missing?(input)

    matches =
      Enum.filter(
        policies,
        &policy_origin_matches?(
          &1,
          conversation_ref,
          origin_conversation_ref,
          source_missing?
        )
      )

    select_policy_owner(matches, policies, origin_conversation_id)
  end

  defp policy_origin_matches?(
         %Run{metadata: metadata},
         conversation_ref,
         origin_conversation_ref,
         source_missing?
       ) do
    exact? =
      not is_nil(conversation_ref) and
        Map.get(metadata, :conversation_ref) == conversation_ref

    fallback? =
      source_missing? and not is_nil(origin_conversation_ref) and
        Map.get(metadata, :origin_conversation_ref) == origin_conversation_ref

    exact? or fallback?
  end

  defp select_policy_owner([%Run{} = run], _policies, _origin), do: {:ok, run}

  defp select_policy_owner([_first, _second | _rest] = matches, _policies, _origin),
    do: {:error, {:ambiguous_instance_policy, Enum.map(matches, & &1.id)}}

  defp select_policy_owner([], _policies, origin) when not is_nil(origin), do: :none
  defp select_policy_owner([], [%Run{} = run], nil), do: {:ok, run}

  defp select_policy_owner([], [_first, _second | _rest] = policies, nil),
    do: {:error, {:ambiguous_instance_policy, Enum.map(policies, & &1.id)}}

  defp select_policy_owner([], [], nil), do: :none

  defp policy_boundary?(%Run{
         status: :boundary,
         cursor: :policy,
         waiting: %Boundary{kind: :needs}
       }),
       do: true

  defp policy_boundary?(_run), do: false

  defp conversation_source_missing?(input) do
    source = input_source(input)
    is_nil(source_field(source, :kind)) and is_nil(source_field(source, :mount))
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

    failed = if run, do: terminalize_failed_run(run, failure), else: nil

    data =
      data
      |> Map.put(:active, if(match?(%{pid: ^pid}, data.active), do: nil, else: data.active))
      |> Map.put(:state_lock, nil)
      |> Map.put(
        :invocations,
        Enum.reject(data.invocations, fn {_id, value} -> value.pid == pid end) |> Map.new()
      )

    data = if failed, do: put_run(data, failed), else: data
    data = reply_caller(data, worker.run_id, {:error, failure})
    data = if failed, do: record_terminal(data, failed), else: data
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
        terminalize_failed_run(
          run,
          {:instance_worker_exception, exception.__struct__}
        )

      {:error, failed.last_error, failed}
  catch
    kind, reason ->
      failed = terminalize_failed_run(run, {:instance_worker_failure, kind, reason})

      {:error, failed.last_error, failed}
  end

  defp terminalize_failed_run(%Run{} = run, failure) do
    failed = %{
      run
      | status: :failed,
        cursor: :complete,
        revision: run.revision + 1,
        waiting: nil,
        last_error: failure
    }

    put_failure_lineage(failed)
  end

  defp put_failure_lineage(%Run{result: %Result{} = result} = run) do
    boundary_id = Value.token("instance-error", {run.id, run.revision})
    ref = Ref.new(run.id, run.revision, :error, boundary_id)

    lineage = %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      step_id: run.step_id,
      trace_id: run.trace_id,
      ref: ref
    }

    result = %{result | metadata: Map.put(result.metadata, :run, lineage)}
    %{run | result: result}
  end

  defp put_failure_lineage(%Run{} = run), do: run

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

  defp step_run({:await, %Invocation{}, %Run{} = run}), do: run
  defp step_run({:boundary, %Boundary{}, %Run{} = run}), do: run
  defp step_run({:complete, %Result{}, %Run{} = run}), do: run

  defp step_result({:await, %Invocation{}, %Run{result: result}}), do: result
  defp step_result({:boundary, %Boundary{}, %Run{result: result}}), do: result
  defp step_result({:complete, %Result{} = result, %Run{}}), do: result
  defp state_neutral_step?(entry, %Run{}), do: not entry_commits_state?(entry)

  defp entry_commits_state?(entry),
    do: Map.get(entry, :commit_state?, not Map.get(entry, :internal?, false))

  defp terminal_run?(%Run{status: status}), do: status in [:complete, :failed]

  defp terminal_result?(%Result{} = result) do
    is_nil(Spectre.Result.pending_effect(result)) and
      Enum.any?(result.effects, &Spectre.Effect.terminal?/1)
  end

  defp terminal_replay?(%Result{} = supplied, %Result{} = current) do
    terminal_result?(supplied) and terminal_result?(current) and
      terminal_effects(supplied) == terminal_effects(current)
  end

  defp terminal_replay?(_supplied, _current), do: false

  defp terminal_effects(%Result{} = result) do
    result.effects
    |> Enum.filter(&Spectre.Effect.terminal?/1)
    |> Enum.map(&{&1.id, &1.status})
    |> Enum.sort()
  end

  defp record_terminal(data, %Run{} = run) do
    if MapSet.member?(data.terminal_recorded, run.id) do
      data
    else
      completed = :queue.in(run.id, data.completed)

      %{
        data
        | completed: completed,
          terminal_recorded: MapSet.put(data.terminal_recorded, run.id)
      }
      |> prune_terminal()
    end
  end

  defp prune_terminal(data) when map_size(data.runs) <= data.max_runs, do: data

  defp prune_terminal(data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            tombstone = run_projection(run)

            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, tombstone),
                tombstone_order: :queue.in(run_id, data.tombstone_order)
            }

            next |> prune_tombstones() |> prune_terminal()

          nil ->
            prune_terminal(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  defp prune_for_new_run(data) when map_size(data.runs) < data.max_runs, do: data

  defp prune_for_new_run(data) do
    case :queue.out(data.completed) do
      {{:value, run_id}, completed} ->
        case Map.get(data.runs, run_id) do
          %Run{} = run ->
            next = %{
              data
              | runs: Map.delete(data.runs, run_id),
                completed: completed,
                terminal_recorded: MapSet.delete(data.terminal_recorded, run_id),
                tombstones: Map.put(data.tombstones, run_id, run_projection(run)),
                tombstone_order: :queue.in(run_id, data.tombstone_order)
            }

            next |> prune_tombstones() |> prune_for_new_run()

          nil ->
            prune_for_new_run(%{data | completed: completed})
        end

      {:empty, _completed} ->
        data
    end
  end

  defp prune_tombstones(%{max_tombstones: max} = data)
       when map_size(data.tombstones) <= max,
       do: data

  defp prune_tombstones(data) do
    case :queue.out(data.tombstone_order) do
      {{:value, run_id}, order} ->
        prune_tombstones(%{
          data
          | tombstones: Map.delete(data.tombstones, run_id),
            tombstone_order: order
        })

      {:empty, _order} ->
        %{data | tombstones: %{}}
    end
  end

  defp put_run(data, %Run{} = run), do: %{data | runs: Map.put(data.runs, run.id, run)}

  defp rebase_run(%Run{} = run, %State{} = state) do
    result =
      case run.result do
        %Result{} = result ->
          metadata =
            case Map.get(result.metadata, :state_persistence) do
              persistence when is_map(persistence) ->
                Map.put(
                  result.metadata,
                  :state_persistence,
                  Map.put(persistence, :revision, state.revision)
                )

              _missing ->
                result.metadata
            end

          %{result | state: state, metadata: metadata}

        nil ->
          nil
      end

    %{run | state: state, result: result}
  end

  defp busy?(data) do
    not is_nil(data.active) or not is_nil(data.state_lock) or
      not :queue.is_empty(data.ready) or map_size(data.invocations) > 0 or
      map_size(data.operation_runners) > 0 or not :queue.is_empty(data.operation_ready) or
      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight)
  end

  defp live_runs?(data) do
    Enum.any?(data.runs, fn {_id, run} -> not terminal_run?(run) end) or
      Enum.any?(all_operation_loops(data), fn {loop, _control} ->
        not OperationLoop.terminal?(loop)
      end)
  end

  defp info_projection(data) do
    %{
      ref: data.ref.key,
      agent_ref: AgentRef.key(data.agent_ref),
      subject: Subject.key(data.subject),
      generation: data.generation,
      state_revision: data.state.revision,
      canonical_revision: data.canonical.revision,
      conversations: data.conversations,
      runs: Map.new(data.runs, fn {id, run} -> {id, run_projection(run)} end),
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
        Map.new(all_operation_loops(data), fn {loop, control} ->
          {loop.id, OperationView.from_loop(loop, control)}
        end),
      operation_runners:
        Map.new(data.operation_runners, fn {attempt_id, ownership} ->
          {attempt_id, %{loop_id: ownership.loop_id, operation: ownership.operation}}
        end)
    }
  end

  defp run_projection(%Run{} = run) do
    %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      waiting: waiting_kind(run.waiting),
      ref: run.result && get_in(run.result.metadata, [:run, :ref])
    }
  end

  defp waiting_kind(%Invocation{}), do: :invocation
  defp waiting_kind(%Boundary{kind: kind}), do: kind
  defp waiting_kind(nil), do: nil

  defp control_loop(server, loop, action, payload, opts) do
    GenServer.call(
      server,
      {:operation_control, operation_id(loop), action, payload, opts},
      timeout(opts)
    )
  end

  defp operation_id(%OperationRef{id: id}), do: id
  defp operation_id(id) when is_binary(id) and id != "", do: id

  defp operation_id(value),
    do: raise(ArgumentError, "invalid operational loop reference: #{inspect(value)}")

  defp operation_section(:work), do: :work
  defp operation_section(:vigil), do: :vigil
  defp operation_section(:directive), do: :directive

  defp operation_loop(data, loop_id) do
    Enum.find_value(
      [:work, :vigil, :directive],
      {:error, :operation_loop_not_found},
      fn section ->
        case Map.get(canonical_value!(data, section), loop_id) do
          %OperationLoop{} = loop ->
            controls = canonical_value!(data, :control)
            control = Map.get(controls, loop.id, Control.new(loop.id))
            {:ok, loop, control}

          nil ->
            false
        end
      end
    )
  end

  defp all_operation_loops(data) do
    controls = canonical_value!(data, :control)

    [:work, :vigil, :directive]
    |> Enum.flat_map(fn section -> Map.values(canonical_value!(data, section)) end)
    |> Enum.filter(&match?(%OperationLoop{}, &1))
    |> Enum.sort_by(&{&1.created_at, &1.id})
    |> Enum.map(fn loop -> {loop, Map.get(controls, loop.id, Control.new(loop.id))} end)
  end

  defp canonical_value!(%{canonical: canonical}, section) do
    case Canonical.fetch(canonical, section) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise "invalid canonical section #{inspect(section)}: #{inspect(reason)}"
    end
  end

  defp commit_operational(data, loop, control, event_specs, opts) do
    entry = %{loop: loop, control: control, event_specs: event_specs, opts: opts}
    commit_operational_batch(data, [entry], opts)
  end

  defp commit_operational_batch(data, entries, commit_opts) do
    with :ok <- validate_operational_batch(entries) do
      do_commit_operational_batch(data, entries, commit_opts)
    end
  end

  defp validate_operational_batch(entries) when is_list(entries) and entries != [] do
    ids = Enum.map(entries, & &1.loop.id)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operational_loop_in_transition}
    else
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        with :ok <- OperationLoop.validate(entry.loop),
             :ok <- Control.validate(entry.control) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_operational_batch(_entries), do: {:error, :empty_operational_transition}

  defp do_commit_operational_batch(data, entries, commit_opts) do
    next_revision = data.canonical.revision + 1

    events =
      Enum.flat_map(entries, fn %{loop: loop, event_specs: event_specs, opts: opts} ->
        Enum.map(event_specs, fn spec ->
          OperationEvent.new(loop, Map.fetch!(spec, :type),
            agent_id: AgentRef.key(data.agent_ref),
            revision: next_revision,
            correlation_id: Keyword.get(opts, :correlation_id, loop.correlation_id),
            causation_id: Keyword.get(opts, :causation_id),
            provenance: Keyword.get(opts, :provenance, loop.provenance),
            payload: Map.get(spec, :payload),
            metadata: %{transition: Keyword.get(opts, :transition)}
          )
        end)
      end)

    writes = operational_batch_writes(data, entries, next_revision)

    writes =
      if events == [], do: writes, else: Map.put(writes, :events, append_events(data, events))

    primary = hd(entries).loop

    with :ok <- validate_operation_events(data, events),
         {:ok, next} <-
           commit_canonical_sections(data, writes,
             correlation_id: Keyword.get(commit_opts, :correlation_id, primary.correlation_id),
             causation_id: Keyword.get(commit_opts, :causation_id),
             provenance: Keyword.get(commit_opts, :provenance, primary.provenance),
             metadata: %{
               transition: Keyword.get(commit_opts, :transition),
               loop_id: primary.id,
               loop_ids: Enum.map(entries, & &1.loop.id)
             }
           ) do
      Enum.each(entries, fn %{loop: loop, opts: opts} ->
        _ =
          Spectre.Journal.record(
            data.agent,
            :operational_transition,
            %{
              loop_id: loop.id,
              loop_kind: loop.kind,
              loop_revision: loop.revision,
              canonical_revision: next.canonical.revision,
              transition: Keyword.get(opts, :transition)
            },
            data.base_opts
          )
      end)

      {:ok, route_committed_events(next, events), events}
    end
  end

  defp operational_batch_writes(data, entries, next_revision) do
    section_writes =
      Enum.reduce(entries, %{}, fn %{loop: loop}, acc ->
        section = operation_section(loop.kind)
        current = Map.get(acc, section, canonical_value!(data, section))
        Map.put(acc, section, Map.put(current, loop.id, loop))
      end)

    controls =
      Enum.reduce(entries, canonical_value!(data, :control), fn entry, acc ->
        Map.put(acc, entry.loop.id, entry.control)
      end)

    correlations =
      Enum.reduce(entries, canonical_value!(data, :correlations), fn entry, acc ->
        put_loop_correlation(acc, entry.loop, next_revision, entry.opts)
      end)

    section_writes
    |> Map.put(:control, controls)
    |> Map.put(:correlations, correlations)
  end

  defp validate_operation_events(data, events) do
    existing = Map.get(canonical_value!(data, :events), :records, [])
    ids = Enum.map(events, & &1.id)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operation_event_id}
    else
      Enum.reduce_while(events, :ok, fn event, :ok ->
        previous = Enum.find(existing, &(&1.id == event.id))

        case {OperationEvent.validate(event), previous} do
          {:ok, nil} when event.revision == data.canonical.revision + 1 ->
            {:cont, :ok}

          {:ok, ^event} ->
            {:cont, :ok}

          {:ok, nil} ->
            {:halt, {:error, {:invalid_operation_event_revision, event.revision}}}

          {:ok, _conflict} ->
            {:halt, {:error, {:operation_event_id_conflict, event.id}}}

          {{:error, _reason} = error, _previous} ->
            {:halt, error}
        end
      end)
    end
  end

  defp commit_canonical_sections(data, writes, opts) do
    names = Map.keys(writes)

    with {:ok, snapshot} <-
           Canonical.snapshot(data.canonical,
             read: names,
             write: names,
             correlation_id: Keyword.fetch!(opts, :correlation_id),
             causation_id: Keyword.get(opts, :causation_id)
           ),
         {:ok, change} <-
           Canonical.change(snapshot, writes,
             provenance: Keyword.get(opts, :provenance, %{}),
             metadata: Keyword.get(opts, :metadata, %{})
           ),
         {:ok, canonical, _transition} <- Canonical.commit(data.canonical, change) do
      next = %{data | canonical: canonical}

      case Map.fetch(writes, :flow) do
        {:ok, %State{} = state} -> {:ok, maybe_checkpoint(%{next | state: state})}
        :error -> {:ok, maybe_checkpoint(next)}
      end
    end
  end

  defp commit_flow_state(data, %State{} = state, %Run{} = run) do
    case commit_canonical_sections(data, %{flow: state},
           correlation_id: run.id,
           causation_id: run.trace_id,
           provenance: %{source: :flow, run_id: run.id},
           metadata: %{transition: :flow_state_committed}
         ) do
      {:ok, next} -> next
      {:error, reason} -> raise "canonical Flow commit failed: #{inspect(reason)}"
    end
  end

  defp append_events(data, events) do
    current = canonical_value!(data, :events)
    current_records = Map.get(current, :records, [])
    ids = Map.get(current, :ids, %{})
    existing_ids = MapSet.new(Enum.map(current_records, & &1.id))
    events = Enum.reject(events, &MapSet.member?(existing_ids, &1.id))
    records = Enum.take(events ++ current_records, @operation_event_limit)
    retained = MapSet.new(Enum.map(records, & &1.id))

    ids =
      ids
      |> Map.take(MapSet.to_list(retained))
      |> Map.merge(Map.new(events, &{&1.id, &1.revision}))

    %{records: records, ids: ids}
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
    data = prune_for_new_run(data)

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

            data
            |> Map.put(:runs, Map.put(data.runs, run.id, run))
            |> enqueue(entry)
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

  defp normalize_delivery_consent(%DeliveryConsent{} = consent) do
    with :ok <- DeliveryConsent.validate(consent), do: {:ok, consent}
  end

  defp normalize_delivery_consent(value) when is_map(value) or is_list(value) do
    {:ok, DeliveryConsent.new(value)}
  rescue
    exception -> {:error, {:invalid_delivery_consent, Exception.message(exception)}}
  end

  defp normalize_delivery_consent(value), do: {:error, {:invalid_delivery_consent, value}}

  defp normalize_delivery_policy(%DeliveryPolicy{} = policy) do
    with :ok <- DeliveryPolicy.validate(policy), do: {:ok, policy}
  end

  defp normalize_delivery_policy(value) when is_map(value) or is_list(value) or is_nil(value) do
    {:ok, DeliveryPolicy.new(value)}
  rescue
    exception -> {:error, {:invalid_delivery_policy, Exception.message(exception)}}
  end

  defp normalize_delivery_policy(value), do: {:error, {:invalid_delivery_policy, value}}

  defp validate_delivery_consent_subject(consent, data) do
    if consent.subject_id == data.subject.id,
      do: :ok,
      else: {:error, :delivery_consent_subject_mismatch}
  end

  defp commit_delivery_consent(data, consent, opts, transition) do
    key = delivery_consent_key(consent.id)
    correlations = canonical_value!(data, :correlations)

    with :ok <- DeliveryConsent.validate(consent),
         :ok <-
           validate_delivery_consent_transition(Map.get(correlations, key), consent, transition) do
      if Map.get(correlations, key) == consent do
        {:ok, data}
      else
        correlations = Map.put(correlations, key, consent)

        with {:ok, next} <-
               commit_canonical_sections(data, %{correlations: correlations},
                 correlation_id: Keyword.get(opts, :correlation_id, consent.id),
                 causation_id: Keyword.get(opts, :causation_id),
                 provenance: Keyword.get(opts, :provenance, %{source: :delivery_policy}),
                 metadata: %{transition: transition, consent_id: consent.id}
               ) do
          _ =
            Spectre.Journal.record(
              data.agent,
              transition,
              %{consent_id: consent.id, canonical_revision: next.canonical.revision},
              data.base_opts
            )

          {:ok, next}
        end
      end
    end
  end

  defp validate_delivery_consent_transition(
         nil,
         %DeliveryConsent{revoked_at: nil},
         :delivery_consent_granted
       ),
       do: :ok

  defp validate_delivery_consent_transition(nil, _consent, :delivery_consent_granted),
    do: {:error, :cannot_grant_revoked_delivery_consent}

  defp validate_delivery_consent_transition(
         %DeliveryConsent{} = current,
         next,
         :delivery_consent_revoked
       ) do
    immutable = [
      :id,
      :subject_id,
      :origin,
      :destination,
      :granted_at,
      :expires_at,
      :channels,
      :metadata
    ]

    if Map.take(current, immutable) == Map.take(next, immutable) and
         (current.revoked_at == next.revoked_at or
            (is_nil(current.revoked_at) and is_integer(next.revoked_at))) do
      :ok
    else
      {:error, :invalid_delivery_consent_revocation_transition}
    end
  end

  defp validate_delivery_consent_transition(%DeliveryConsent{} = current, next, _transition) do
    if current == next,
      do: :ok,
      else: {:error, {:delivery_consent_id_conflict, next.id}}
  end

  defp validate_delivery_consent_transition(_invalid, _next, _transition),
    do: {:error, :invalid_existing_delivery_consent}

  defp fetch_delivery_consent(_data, consent_id)
       when not is_binary(consent_id) or consent_id == "",
       do: {:error, :invalid_delivery_consent_id}

  defp fetch_delivery_consent(data, consent_id) do
    case Map.get(canonical_value!(data, :correlations), delivery_consent_key(consent_id)) do
      %DeliveryConsent{} = consent -> {:ok, consent}
      _missing -> {:error, :delivery_consent_not_found}
    end
  end

  defp find_delivery_consent(data, loop, destination, now) do
    data
    |> canonical_value!(:correlations)
    |> Map.values()
    |> Enum.filter(&match?(%DeliveryConsent{}, &1))
    |> Enum.sort_by(& &1.granted_at, :desc)
    |> Enum.find(fn consent ->
      consent.subject_id == loop.subject_id and consent.destination == destination and
        DeliveryConsent.active?(consent, now)
    end)
  end

  defp committed_operation_event(data, event_id) do
    event =
      data
      |> canonical_value!(:events)
      |> Map.get(:records, [])
      |> Enum.find(&(&1.id == event_id))

    if match?(%OperationEvent{}, event),
      do: {:ok, event},
      else: {:error, :operation_event_not_found}
  end

  defp operation_event_visible?(data, %OperationEvent{} = event, opts) do
    case operation_loop(data, event.loop_id) do
      {:ok, loop, _control} -> match?(:ok, authorize_loop(loop, opts))
      {:error, _reason} -> false
    end
  end

  defp committed_delivery_receipts(data) do
    data
    |> canonical_value!(:correlations)
    |> Map.values()
    |> Enum.filter(fn
      %DeliveryReceipt{} = receipt -> match?(:ok, DeliveryReceipt.validate(receipt))
      _other -> false
    end)
  end

  defp delivery_receipt_visible?(data, %DeliveryReceipt{} = receipt, opts) do
    case operation_loop(data, receipt.loop_id) do
      {:ok, loop, _control} ->
        receipt.subject_id == loop.subject_id and match?(:ok, authorize_loop(loop, opts))

      {:error, _reason} ->
        false
    end
  end

  defp fetch_delivery_receipt(_data, receipt_id)
       when not is_binary(receipt_id) or receipt_id == "",
       do: {:error, :invalid_delivery_receipt_id}

  defp fetch_delivery_receipt(data, receipt_id) do
    case Map.get(canonical_value!(data, :correlations), delivery_receipt_key(receipt_id)) do
      %DeliveryReceipt{} = receipt -> {:ok, receipt}
      _missing -> {:error, :delivery_receipt_not_found}
    end
  end

  defp update_delivery_receipt(receipt, :delivered, external_receipt),
    do: Delivery.delivered(receipt, external_receipt)

  defp update_delivery_receipt(receipt, :failed, reason),
    do: Delivery.failed(receipt, reason)

  defp update_delivery_receipt(_receipt, outcome, _detail),
    do: {:error, {:invalid_delivery_outcome, outcome}}

  defp commit_delivery_receipt(data, loop, receipt, opts) do
    correlations = canonical_value!(data, :correlations)
    key = delivery_receipt_key(receipt.id)
    existing = Map.get(correlations, key)

    with :ok <- DeliveryReceipt.validate(receipt),
         :ok <- validate_delivery_receipt_owner(receipt, loop),
         :ok <- validate_delivery_receipt_transition(existing, receipt) do
      if existing == receipt do
        {:ok, data}
      else
        correlations =
          correlations
          |> Map.put(key, receipt)
          |> trim_delivery_receipts()

        revision = data.canonical.revision + 1
        event_type = delivery_event_type(receipt.status)

        event =
          OperationEvent.new(loop, event_type,
            agent_id: AgentRef.key(data.agent_ref),
            revision: revision,
            correlation_id: Keyword.get(opts, :correlation_id, loop.correlation_id),
            causation_id: receipt.event_id,
            provenance: Keyword.get(opts, :provenance, %{source: :delivery_policy}),
            payload: %{receipt_id: receipt.id, status: receipt.status, reason: receipt.reason},
            metadata: %{transition: :delivery_decision}
          )

        writes = %{
          correlations: correlations,
          events: append_events(data, [event])
        }

        with :ok <- validate_operation_events(data, [event]),
             {:ok, next} <-
               commit_canonical_sections(data, writes,
                 correlation_id: event.correlation_id,
                 causation_id: event.causation_id,
                 provenance: event.provenance,
                 metadata: %{transition: :delivery_decision, receipt_id: receipt.id}
               ) do
          _ =
            Spectre.Journal.record(
              data.agent,
              :delivery_decision,
              %{
                receipt_id: receipt.id,
                loop_id: loop.id,
                status: receipt.status,
                canonical_revision: next.canonical.revision
              },
              data.base_opts
            )

          {:ok, route_committed_events(next, [event])}
        end
      end
    end
  end

  defp validate_delivery_receipt_owner(receipt, loop) do
    if receipt.loop_id == loop.id and receipt.subject_id == loop.subject_id,
      do: :ok,
      else: {:error, :delivery_receipt_owner_mismatch}
  end

  defp validate_delivery_receipt_transition(nil, _receipt), do: :ok
  defp validate_delivery_receipt_transition(receipt, receipt), do: :ok

  defp validate_delivery_receipt_transition(
         %DeliveryReceipt{status: :authorized} = current,
         %DeliveryReceipt{status: status} = next
       )
       when status in [:delivered, :failed] do
    immutable = [
      :id,
      :event_id,
      :loop_id,
      :subject_id,
      :destination,
      :channel,
      :consent_id,
      :dedupe_key,
      :decided_at,
      :not_before,
      :metadata
    ]

    if Map.take(current, immutable) == Map.take(next, immutable),
      do: :ok,
      else: {:error, :delivery_receipt_identity_changed}
  end

  defp validate_delivery_receipt_transition(
         %DeliveryReceipt{} = current,
         %DeliveryReceipt{} = next
       ),
       do: {:error, {:invalid_delivery_receipt_transition, current.status, next.status}}

  defp validate_delivery_receipt_transition(_invalid, _next),
    do: {:error, :invalid_existing_delivery_receipt}

  defp trim_delivery_receipts(correlations) do
    receipts =
      correlations
      |> Enum.filter(fn {_key, value} -> match?(%DeliveryReceipt{}, value) end)
      |> Enum.sort_by(fn {_key, receipt} -> receipt.decided_at end, :desc)

    receipts
    |> Enum.drop(@delivery_receipt_limit)
    |> Enum.reduce(correlations, fn {key, _receipt}, acc -> Map.delete(acc, key) end)
  end

  defp delivery_event_type(:authorized), do: :delivery_authorized
  defp delivery_event_type(:deferred), do: :delivery_deferred
  defp delivery_event_type(:digest), do: :delivery_digest_queued
  defp delivery_event_type(:denied), do: :delivery_denied
  defp delivery_event_type(:delivered), do: :delivery_recorded
  defp delivery_event_type(:failed), do: :delivery_failed

  defp delivery_consent_key(id) when is_binary(id), do: "delivery:consent:" <> id
  defp delivery_receipt_key(id) when is_binary(id), do: "delivery:receipt:" <> id

  defp put_loop_correlation(correlations, loop, revision, opts) do
    correlation_id = Keyword.get(opts, :correlation_id, loop.correlation_id)

    Map.put(correlations, correlation_id, %{
      loop_id: loop.id,
      loop_kind: loop.kind,
      revision: revision,
      causation_id: Keyword.get(opts, :causation_id)
    })
  end

  defp same_loop_request?(existing, requested) do
    existing.kind == requested.kind and existing.controller == requested.controller and
      existing.controller_version == requested.controller_version and
      existing.base_input == requested.base_input and
      existing.correlation_id == requested.correlation_id
  end

  defp authorize_loop(loop, opts) do
    supplied_subject = Keyword.get(opts, :subject_id)
    origin = Keyword.get(opts, :origin)

    cond do
      not is_nil(supplied_subject) and supplied_subject != loop.subject_id ->
        {:error, :operation_loop_not_visible}

      is_nil(origin) ->
        :ok

      loop.visibility == :subject ->
        :ok

      origin == loop.origin or origin in loop.authorized_origins ->
        :ok

      true ->
        {:error, :operation_loop_not_visible}
    end
  end

  defp loop_filter?(loop, opts) do
    kind = Keyword.get(opts, :kind)
    controller = Keyword.get(opts, :controller)
    status = Keyword.get(opts, :status)

    (is_nil(kind) or loop.kind == kind) and
      (is_nil(controller) or loop.controller == controller) and
      (is_nil(status) or loop.status in List.wrap(status))
  end

  defp selector_matches?(loop, nil), do: not OperationLoop.terminal?(loop)
  defp selector_matches?(loop, %OperationRef{id: id}), do: loop.id == id
  defp selector_matches?(loop, id) when is_binary(id), do: loop.id == id

  defp selector_matches?(loop, selector) when is_list(selector),
    do: selector_matches?(loop, Map.new(selector))

  defp selector_matches?(loop, selector) when is_map(selector) do
    selector = atomize_selector(selector)

    Enum.all?(selector, fn
      {:id, value} -> loop.id == value
      {:kind, value} -> loop.kind == value
      {:controller, value} -> loop.controller == value or loop.controller_id == value
      {:definition, value} -> loop.controller_id == value
      {:status, value} -> loop.status in List.wrap(value)
      {:phase, value} -> loop.phase == value
      {:origin, value} -> loop.origin == value
      {:turn_id, value} -> loop.source_turn_id == value
      {:correlation_id, value} -> loop.correlation_id == value
      {:active, true} -> not OperationLoop.terminal?(loop)
      {:active, false} -> OperationLoop.terminal?(loop)
      {_unknown, _value} -> false
    end)
  end

  defp selector_matches?(_loop, _selector), do: false

  defp atomize_selector(selector) do
    Map.new(selector, fn {key, value} ->
      normalized =
        case key do
          "id" -> :id
          "kind" -> :kind
          "controller" -> :controller
          "definition" -> :definition
          "status" -> :status
          "phase" -> :phase
          "origin" -> :origin
          "turn_id" -> :turn_id
          "correlation_id" -> :correlation_id
          "active" -> :active
          other -> other
        end

      {normalized, value}
    end)
  end

  defp control_command(loop, action, payload, opts) do
    mode = Keyword.get(opts, :mode, :safe)

    if mode == :immediate and not Keyword.get(opts, :authorize_immediate?, false) do
      {:error, :immediate_loop_interruption_not_authorized}
    else
      command =
        ControlCommand.new(loop.id, action,
          id: Keyword.get(opts, :command_id, Spectre.Identity.uuid7()),
          payload: payload,
          mode: mode,
          desired_state: Keyword.get(opts, :desired_state),
          correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
          causation_id: Keyword.get(opts, :causation_id),
          provenance: Keyword.get(opts, :provenance, %{}),
          base_revision: Keyword.get(opts, :revision),
          metadata: Keyword.get(opts, :metadata, %{})
        )

      case Value.validate(command, [:loop_control, loop.id]) do
        :ok -> {:ok, command}
        {:error, reason} -> {:error, {:nonportable_loop_control, reason}}
      end
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

    if not data.operation_scheduled and not :queue.is_empty(data.operation_ready) and capacity? do
      send(self(), {:spectre, :operation_schedule})
      %{data | operation_scheduled: true}
    else
      data
    end
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
    case operation_loop(data, loop_id) do
      {:ok, loop, control} ->
        cond do
          not is_nil(control.pending) and OperationLoop.quiescent?(loop) ->
            advance_operation_control(data, loop, control)

          loop.status == :evaluating ->
            evaluate_operation(data, loop, control)

          OperationLoop.runnable?(loop) and control.state == :active ->
            prepare_operation(data, loop, control)

          loop.status == :waiting ->
            maybe_schedule_wait_timer(data, loop)

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
           OperationRuntime.advance_control(loop, control, operation_env(data)),
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
      |> maybe_schedule_wait_timer(next_loop)
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
           OperationRuntime.evaluate(loop, control, operation_env(data)),
         {:ok, next, _events} <-
           commit_operational(data, next_loop, next_control, event_specs,
             correlation_id: loop.correlation_id,
             causation_id: loop.last_result && loop.last_result.id,
             provenance: %{source: :completion_reducer},
             transition: :loop_evaluated
           ) do
      next
      |> maybe_queue_after_transition(next_loop, next_control)
      |> maybe_schedule_wait_timer(next_loop)
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
    env = operation_snapshot_env(data, loop)

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
            |> maybe_schedule_wait_timer(next_loop)
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
            |> maybe_schedule_wait_timer(next_loop)

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
          |> schedule_operation_attempt_timeout(loop, attempt)
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
           operation_env(data)
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
            |> maybe_schedule_wait_timer(next_loop)

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

  defp operation_snapshot_env(data, loop) do
    section = operation_section(loop.kind)

    {:ok, snapshot} =
      Canonical.snapshot(data.canonical,
        read: [:flow, :work, :vigil, :directive, :control, :correlations],
        write: [section],
        correlation_id: loop.correlation_id
      )

    operation_env(data,
      snapshot_id: snapshot.id,
      canonical_revision: snapshot.base_revision
    )
  end

  defp operation_env(data, opts \\ []) do
    committed = %{
      work: committed_views(data, :work),
      vigil: committed_views(data, :vigil),
      directive: committed_views(data, :directive)
    }

    %{
      agent: data.agent,
      subject_id: data.subject.id,
      epoch: data.generation,
      snapshot_id: Keyword.get(opts, :snapshot_id, Spectre.Identity.uuid7()),
      canonical_revision: Keyword.get(opts, :canonical_revision, data.canonical.revision),
      committed: committed,
      now: System.system_time(:millisecond)
    }
  end

  defp committed_views(data, section) do
    controls = canonical_value!(data, :control)

    data
    |> canonical_value!(section)
    |> Map.new(fn {id, loop} ->
      {id, OperationView.from_loop(loop, Map.get(controls, id, Control.new(id)))}
    end)
  end

  defp operation_runner_down(data, pid, monitor, attempt_id, reason) do
    case Map.get(data.operation_runners, attempt_id) do
      %{pid: ^pid, monitor: ^monitor} = ownership ->
        data = drop_operation_runner(data, ownership)

        with {:ok, loop, control} <- operation_loop(data, ownership.loop_id),
             %OperationLoop{attempt: %{id: ^attempt_id}} <- loop,
             {:ok, next_loop, next_control, event_specs} <-
               OperationRuntime.runner_down(
                 loop,
                 control,
                 ownership.spec,
                 reason,
                 operation_env(data, snapshot_id: ownership.snapshot_id)
               ),
             {:ok, next, _events} <-
               commit_operational(data, next_loop, next_control, event_specs,
                 correlation_id: loop.correlation_id,
                 provenance: %{source: :runner_monitor, attempt_id: attempt_id},
                 transition: :runner_down
               ) do
          next
          |> maybe_queue_after_transition(next_loop, next_control)
          |> maybe_schedule_wait_timer(next_loop)
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

    with {:ok, loop, control} <- operation_loop(data, result.loop_id),
         %OperationLoop{attempt: %{id: attempt_id}} when attempt_id == ownership.attempt_id <-
           loop,
         {:ok, next_loop, next_control, event_specs} <-
           OperationRuntime.runner_down(
             loop,
             control,
             ownership.spec,
             {:invalid_operation_result, reason},
             operation_env(data, snapshot_id: ownership.snapshot_id)
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
      |> maybe_schedule_wait_timer(next_loop)
      |> maybe_schedule_operations()
    else
      _invalid -> maybe_schedule_operations(data)
    end
  end

  defp drop_operation_runner(data, ownership) do
    data = cancel_operation_attempt_timer(data, ownership.attempt_id)

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
      child_id = Keyword.fetch!(intent.opts, :id)

      case operation_loop(data, child_id) do
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
             operation_env(data)
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
      |> maybe_schedule_wait_timer(child.loop)
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
         {:ok, loop, control} <- operation_loop(data, loop_id),
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
        data

      {:error, reason} ->
        send(
          self(),
          {:spectre, :operation_memory_result, loop.id, result.id,
           {:error, {:memory_task_start_failed, reason}}}
        )

        data
    end
  end

  defp maybe_put_memory_field(payload, key, value, include) do
    if key in List.wrap(include), do: Map.put(payload, key, value), else: payload
  end

  defp operation_result_committed?(data, loop, result_id) do
    match?(%OperationResult{id: ^result_id}, loop.last_result) or
      Enum.any?(Map.get(canonical_value!(data, :events), :records, []), fn event ->
        event.loop_id == loop.id and event.causation_id == result_id
      end)
  end

  defp memory_status(:ok), do: :committed
  defp memory_status({:error, _reason}), do: :failed
  defp memory_status(_outcome), do: :failed

  defp schedule_operation_attempt_timeout(data, loop, attempt) do
    data = cancel_operation_attempt_timer(data, attempt.id)

    reference =
      Process.send_after(
        self(),
        {:spectre, :operation_attempt_timeout, loop.id, attempt.id, attempt.fencing_token},
        attempt.timeout
      )

    timer = %{
      ref: reference,
      loop_id: loop.id,
      attempt_id: attempt.id,
      fencing_token: attempt.fencing_token,
      due_at: attempt.started_at + attempt.timeout
    }

    %{
      data
      | operation_attempt_timers: Map.put(data.operation_attempt_timers, attempt.id, timer)
    }
  end

  defp cancel_operation_attempt_timer(data, attempt_id) do
    case Map.pop(data.operation_attempt_timers, attempt_id) do
      {nil, timers} ->
        %{data | operation_attempt_timers: timers}

      {%{ref: reference}, timers} ->
        if is_reference(reference), do: Process.cancel_timer(reference)
        %{data | operation_attempt_timers: timers}
    end
  end

  defp consume_operation_attempt_timer(data, loop_id, attempt_id, fencing_token) do
    with %{loop_id: ^loop_id, fencing_token: ^fencing_token} <-
           Map.get(data.operation_attempt_timers, attempt_id),
         %{attempt_id: ^attempt_id, loop_id: ^loop_id, fencing_token: ^fencing_token} = ownership <-
           Map.get(data.operation_runners, attempt_id) do
      next = %{
        data
        | operation_attempt_timers: Map.delete(data.operation_attempt_timers, attempt_id)
      }

      {:ok, ownership, next}
    else
      _stale -> :stale
    end
  end

  defp maybe_schedule_wait_timer(
         data,
         %OperationLoop{status: :waiting, wait: %{kind: kind}} = loop
       )
       when kind in [:timer, :retry] do
    due_at = loop.wait.due_at

    if is_integer(due_at) do
      data = cancel_operation_timer(data, loop.id)
      delay = max(due_at - System.system_time(:millisecond), 0)

      reference =
        Process.send_after(
          self(),
          {:spectre, :operation_timer, loop.id, loop.wait.id, loop.trigger_generation},
          delay
        )

      timer = %{
        ref: reference,
        wait_id: loop.wait.id,
        generation: loop.trigger_generation,
        due_at: due_at
      }

      %{data | operation_timers: Map.put(data.operation_timers, loop.id, timer)}
    else
      data
    end
  end

  defp maybe_schedule_wait_timer(data, %OperationLoop{} = loop),
    do: cancel_operation_timer(data, loop.id)

  defp cancel_operation_timer(data, loop_id) do
    case Map.pop(data.operation_timers, loop_id) do
      {nil, timers} ->
        %{data | operation_timers: timers}

      {%{ref: reference}, timers} ->
        if is_reference(reference), do: Process.cancel_timer(reference)
        %{data | operation_timers: timers}
    end
  end

  defp consume_operation_timer(data, loop_id, wait_id, generation) do
    case Map.get(data.operation_timers, loop_id) do
      %{wait_id: ^wait_id, generation: ^generation} ->
        {:ok, %{data | operation_timers: Map.delete(data.operation_timers, loop_id)}}

      _stale ->
        :stale
    end
  end

  defp schedule_restored_timers(data) do
    Enum.reduce(all_operation_loops(data), data, fn {loop, _control}, acc ->
      maybe_schedule_wait_timer(acc, loop)
    end)
  end

  defp recover_operational_state(data) do
    Enum.reduce_while(all_operation_loops(data), {:ok, data}, fn {loop, control}, {:ok, acc} ->
      case OperationRuntime.recover(loop, control, operation_env(acc)) do
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

  defp restore_initial_canonical(opts, state, checkpoint_store, base_opts) do
    case Keyword.fetch(opts, :canonical_checkpoint) do
      {:ok, checkpoint} ->
        with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
             :ok <- validate_canonical_instance(canonical, Keyword.fetch!(opts, :instance_ref)),
             {:ok, %State{} = flow_state} <- Canonical.fetch(canonical, :flow) do
          expected = Keyword.get(opts, :checkpoint_expected_revision, 0)
          {:ok, flow_state, canonical, expected}
        else
          {:ok, value} -> {:error, {:invalid_canonical_flow_state, value}}
          {:error, _reason} = error -> error
        end

      :error ->
        restore_stored_or_new_canonical(opts, state, checkpoint_store, base_opts)
    end
  end

  defp restore_stored_or_new_canonical(opts, state, checkpoint_store, base_opts) do
    instance_ref = Keyword.fetch!(opts, :instance_ref)

    case CheckpointStore.load(checkpoint_store, instance_ref, base_opts) do
      {:ok, checkpoint} ->
        with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
             :ok <- validate_canonical_instance(canonical, instance_ref),
             {:ok, %State{} = flow_state} <- Canonical.fetch(canonical, :flow) do
          {:ok, flow_state, canonical, canonical.revision}
        else
          {:ok, value} -> {:error, {:invalid_canonical_flow_state, value}}
          {:error, _reason} = error -> error
        end

      :not_found ->
        new_canonical_state(instance_ref, state)

      {:error, reason} ->
        {:error, {:canonical_checkpoint_load_failed, reason}}
    end
  end

  defp new_canonical_state(instance_ref, state) do
    Canonical.new(%{
      flow: state,
      work: %{},
      vigil: %{},
      directive: %{},
      control: %{},
      correlations: %{instance_key: instance_ref.key},
      events: %{records: [], ids: %{}}
    })
    |> case do
      {:ok, canonical} -> {:ok, state, canonical, 0}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_store(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    value =
      first_configured([
        {opts, :checkpoint_store},
        {base_opts, :checkpoint_store},
        {config, :checkpoint_store}
      ])

    CheckpointStore.normalize(value)
  end

  defp checkpoint_mode(opts, checkpoint_store) do
    default = if checkpoint_store, do: :async, else: :manual
    value = Keyword.get(opts, :checkpoint_mode, default)

    if value in [:async, :manual],
      do: {:ok, value},
      else: {:error, {:invalid_checkpoint_mode, value}}
  end

  defp maybe_checkpoint(%{checkpoint_store: nil} = data), do: data
  defp maybe_checkpoint(%{checkpoint_mode: :manual} = data), do: data
  defp maybe_checkpoint(data), do: enqueue_checkpoint(data, data.canonical)

  defp force_checkpoint(data), do: enqueue_checkpoint(data, data.canonical, true)

  defp enqueue_checkpoint(data, canonical, force? \\ false) do
    cond do
      canonical.revision <= data.checkpoint_revision ->
        reply_checkpoint_waiters(data)

      not is_nil(data.checkpoint_reconciliation) ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      not is_nil(data.checkpoint_inflight) ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      not force? and data.checkpoint_mode == :manual ->
        %{data | checkpoint_pending: newest_checkpoint(data.checkpoint_pending, canonical)}

      true ->
        start_checkpoint_task(%{data | checkpoint_error: nil}, canonical)
    end
  end

  defp newest_checkpoint(nil, canonical), do: canonical

  defp newest_checkpoint(current, canonical) do
    if current.revision >= canonical.revision, do: current, else: canonical
  end

  defp start_checkpoint_task(data, canonical) do
    owner = self()
    token = Spectre.Identity.uuid7()
    revision = canonical.revision
    expected = data.checkpoint_revision
    store = data.checkpoint_store
    ref = data.ref
    opts = data.base_opts

    callback = fn ->
      result =
        with {:ok, encoded} <- CanonicalCodec.encode_json(canonical) do
          CheckpointStore.persist(store, ref, encoded, expected, revision, opts)
        end

      send(owner, {:spectre, :checkpoint_result, token, revision, result})
    end

    case Task.Supervisor.start_child(Spectre.Instance.CheckpointTaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        %{
          data
          | checkpoint_inflight: %{
              token: token,
              revision: revision,
              expected_revision: expected,
              canonical: canonical,
              pid: pid,
              monitor: monitor
            },
            checkpoint_pending: nil
        }

      {:error, reason} ->
        failure = {:checkpoint_task_start_failed, reason}

        data
        |> Map.put(:checkpoint_error, failure)
        |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, canonical))
        |> fail_checkpoint_waiters(failure)
    end
  end

  defp finish_checkpoint_task(%{checkpoint_inflight: %{monitor: monitor}} = data) do
    Process.demonitor(monitor, [:flush])
    %{data | checkpoint_inflight: nil}
  end

  # A normal task sends its result before terminating. Keep the fence until that
  # message is reduced; an abnormal DOWN has no trustworthy commit outcome.
  defp checkpoint_task_down(data, :normal), do: data

  defp checkpoint_task_down(data, reason) do
    failure = {:checkpoint_task_down, reason}
    inflight = data.checkpoint_inflight

    data
    |> finish_checkpoint_task()
    |> mark_checkpoint_reconciliation(inflight, failure)
    |> arm_idle_timer()
  end

  defp start_pending_checkpoint(%{checkpoint_reconciliation: reconciliation} = data)
       when not is_nil(reconciliation),
       do: data

  defp start_pending_checkpoint(%{checkpoint_pending: nil} = data), do: data

  defp start_pending_checkpoint(data) do
    pending = data.checkpoint_pending

    if pending.revision <= data.checkpoint_revision do
      %{data | checkpoint_pending: nil}
    else
      start_checkpoint_task(data, pending)
    end
  end

  defp reply_checkpoint_waiters(data) do
    {ready, waiting} =
      Enum.split_with(data.checkpoint_waiters, fn {_from, target} ->
        target <= data.checkpoint_revision
      end)

    Enum.each(ready, fn {from, _target} ->
      GenServer.reply(from, {:ok, data.checkpoint_revision})
    end)

    %{data | checkpoint_waiters: waiting}
  end

  defp fail_checkpoint_waiters(data, reason) do
    Enum.each(data.checkpoint_waiters, fn {from, _target} ->
      GenServer.reply(from, {:error, reason})
    end)

    %{data | checkpoint_waiters: []}
  end

  defp checkpoint_persist_failed(data, inflight, reason) do
    if checkpoint_reconciliation_required?(reason) do
      mark_checkpoint_reconciliation(data, inflight, reason)
    else
      data
      |> Map.put(:checkpoint_error, reason)
      |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, data.canonical))
      |> fail_checkpoint_waiters(reason)
    end
  end

  defp mark_checkpoint_reconciliation(data, inflight, reason) do
    reconciliation = %{
      revision: inflight.revision,
      expected_revision: inflight.expected_revision,
      canonical: inflight.canonical,
      base: data.checkpoint_persisted,
      reason: reason
    }

    error = {:checkpoint_reconciliation_required, inflight.revision, reason}

    data
    |> Map.put(:checkpoint_reconciliation, reconciliation)
    |> Map.put(:checkpoint_error, error)
    |> Map.put(:checkpoint_pending, newest_checkpoint(data.checkpoint_pending, data.canonical))
    |> fail_checkpoint_waiters(error)
  end

  defp checkpoint_reconciliation_required?({:ambiguous, _reason}), do: true
  defp checkpoint_reconciliation_required?(:conflict), do: true

  defp checkpoint_reconciliation_required?({kind, _reason})
       when kind in [:conflict, :stale],
       do: true

  defp checkpoint_reconciliation_required?({kind, _a, _b})
       when kind in [:conflict, :stale],
       do: true

  defp checkpoint_reconciliation_required?(_reason), do: false

  defp start_checkpoint_reconciliation(data, from) do
    owner = self()
    token = Spectre.Identity.uuid7()
    store = data.checkpoint_store
    ref = data.ref
    opts = data.base_opts

    callback = fn ->
      result = CheckpointStore.load(store, ref, opts)
      send(owner, {:spectre, :checkpoint_reconcile_result, token, result})
    end

    case Task.Supervisor.start_child(Spectre.Instance.CheckpointTaskSupervisor, callback) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        %{
          data
          | checkpoint_reconcile_inflight: %{
              token: token,
              pid: pid,
              monitor: monitor,
              from: from
            }
        }

      {:error, reason} ->
        failure = {:checkpoint_reconciliation_task_start_failed, reason}
        GenServer.reply(from, {:error, failure})
        %{data | checkpoint_error: failure}
    end
  end

  defp finish_checkpoint_reconciliation_task(
         %{checkpoint_reconcile_inflight: %{monitor: monitor}} = data
       ) do
    Process.demonitor(monitor, [:flush])
    %{data | checkpoint_reconcile_inflight: nil}
  end

  defp checkpoint_reconciliation_task_down(data, :normal), do: data

  defp checkpoint_reconciliation_task_down(data, reason) do
    %{from: from} = data.checkpoint_reconcile_inflight
    failure = {:checkpoint_reconciliation_task_down, reason}
    GenServer.reply(from, {:error, failure})

    data
    |> finish_checkpoint_reconciliation_task()
    |> Map.put(:checkpoint_error, failure)
    |> arm_idle_timer()
  end

  defp reconcile_checkpoint_result(data, result) do
    reconciliation = data.checkpoint_reconciliation

    case decode_reconciled_checkpoint(result, data.ref) do
      :not_found when reconciliation.expected_revision == 0 ->
        checkpoint_not_committed(data)

      {:ok, stored} when stored == reconciliation.canonical ->
        checkpoint_committed(data, stored)

      {:ok, stored} when not is_nil(reconciliation.base) and stored == reconciliation.base ->
        checkpoint_not_committed(data)

      {:ok, stored} ->
        reason =
          {:checkpoint_reconciliation_conflict, reconciliation.expected_revision,
           reconciliation.revision, stored.revision}

        {:error, %{data | checkpoint_error: reason}, reason}

      :not_found ->
        reason = {:checkpoint_reconciliation_missing_base, reconciliation.expected_revision}
        {:error, %{data | checkpoint_error: reason}, reason}

      {:error, reason} ->
        {:error, %{data | checkpoint_error: reason}, reason}
    end
  end

  defp decode_reconciled_checkpoint(:not_found, _instance_ref), do: :not_found

  defp decode_reconciled_checkpoint({:ok, checkpoint}, instance_ref) do
    with {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
         :ok <- validate_canonical_instance(canonical, instance_ref) do
      {:ok, canonical}
    end
  end

  defp decode_reconciled_checkpoint({:error, reason}, _instance_ref),
    do: {:error, {:checkpoint_reconciliation_load_failed, reason}}

  defp checkpoint_committed(data, stored) do
    revision = stored.revision

    next =
      data
      |> Map.put(:checkpoint_revision, revision)
      |> Map.put(:checkpoint_persisted, stored)
      |> Map.put(:checkpoint_reconciliation, nil)
      |> Map.put(:checkpoint_error, nil)
      |> reply_checkpoint_waiters()
      |> start_pending_checkpoint()

    {:ok, next, revision}
  end

  defp checkpoint_not_committed(data) do
    revision = data.checkpoint_revision

    next =
      data
      |> Map.put(:checkpoint_reconciliation, nil)
      |> Map.put(:checkpoint_error, nil)
      |> start_pending_checkpoint()

    {:ok, next, revision}
  end

  defp checkpoint_reconciliation_status(nil), do: nil

  defp checkpoint_reconciliation_status(reconciliation) do
    %{
      revision: reconciliation.revision,
      expected_revision: reconciliation.expected_revision,
      reason: reason_class(reconciliation.reason)
    }
  end

  defp checkpoint_reconciliation_error(data) do
    reconciliation = data.checkpoint_reconciliation

    {:checkpoint_reconciliation_required, reconciliation.revision,
     reason_class(reconciliation.reason)}
  end

  defp validate_canonical_instance(canonical, instance_ref),
    do: CanonicalValidator.validate(canonical, instance_ref, event_limit: @operation_event_limit)

  defp reason_class(%{kind: kind}) when is_atom(kind), do: kind
  defp reason_class({kind, _detail}) when is_atom(kind), do: kind
  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :error

  defp normalize_event_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @operation_event_limit)

  defp normalize_event_limit(_value), do: @operation_event_limit

  defp runtime_opts(data, opts, input) do
    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        input_conversation_id(input)
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
        conversation_ref: conversation_key(input, origin_conversation_id),
        origin_conversation_ref: origin_conversation_key(origin_conversation_id)
      })

    Keyword.put(opts, :run_metadata, metadata)
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

  defp record_conversation(data, %Run{} = run, opts) do
    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        input_conversation_id(run.input)
      ])

    case conversation_key(run.input, origin_conversation_id) do
      nil ->
        data

      key ->
        source = input_source(run.input)
        current = Map.get(data.conversations, key, %{count: 0})

        conversation =
          current
          |> Map.put(:key, key)
          |> Map.put(:channel, source_field(source, :kind))
          |> Map.put(:mount, source_field(source, :mount))
          |> Map.put(:last_run_id, run.id)
          |> Map.update!(:count, &(&1 + 1))

        %{data | conversations: Map.put(data.conversations, key, conversation)}
    end
  end

  defp conversation_key(_input, nil), do: nil

  defp conversation_key(input, conversation_id) do
    source = input_source(input)

    value = {
      source_field(source, :kind),
      source_field(source, :mount),
      conversation_id
    }

    case Value.validate(value, [:instance, :conversation]) do
      :ok -> Value.token("conversation", value)
      {:error, _reason} -> nil
    end
  end

  defp origin_conversation_key(nil), do: nil

  defp origin_conversation_key(conversation_id) do
    case Value.validate(conversation_id, [:instance, :origin_conversation]) do
      :ok -> Value.token("origin-conversation", conversation_id)
      {:error, _reason} -> nil
    end
  end

  defp input_conversation_id(input),
    do: input |> input_source() |> source_field(:conversation_id)

  defp input_source(input) when is_map(input),
    do: Map.get(input, :source, Map.get(input, "source"))

  defp input_source(_input), do: nil

  defp source_field(source, key) when is_map(source),
    do: Map.get(source, key, Map.get(source, Atom.to_string(key)))

  defp source_field(_source, _key), do: nil

  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

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

  defp timeout(opts), do: Keyword.get(opts, :timeout, :timer.minutes(5))

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

  defp emit(event, data, measurements) do
    Spectre.Telemetry.emit(
      [:instance, event],
      measurements,
      %{
        agent: data.agent,
        agent_ref: AgentRef.key(data.agent_ref),
        subject: Subject.key(data.subject),
        generation: data.generation
      },
      data.base_opts
    )
  end

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
