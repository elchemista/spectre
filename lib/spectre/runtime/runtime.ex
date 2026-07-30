defmodule Spectre.Runtime do
  @moduledoc """
  Turn-level orchestration for Spectre agents.

  Runtime owns the per-turn workflow, but it deliberately does not own the
  domain decisions inside an agent. It coordinates boundaries in this order:

    1. Merge agent/runtime options.
    2. Normalize input through the configured input pipeline.
    3. Load state and memory adapters.
    4. Resume an active policy, or consult ordered turn handlers.
    5. Route unclaimed input and run the selected handler.
    6. Record chat history and persist state/memory.

  Keeping this flow centralized makes individual adapters simpler and keeps
  policy gates from being accidentally skipped.
  """

  alias Spectre.Context
  alias Spectre.Definition
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Invocation
  alias Spectre.Journal.Recorder
  alias Spectre.Policy
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.Router
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.Value
  alias Spectre.State
  alias Spectre.State.Codec
  alias Spectre.Turn.Handlers

  @type step_result ::
          {:continue, Run.t()}
          | {:await, Invocation.t(), Run.t()}
          | {:boundary, Boundary.t(), Run.t()}
          | {:complete, Result.t(), Run.t()}
          | {:error, term(), Run.t()}

  @doc """
  Handles one normalized input turn for an agent module.

      {:ok, result} =
        Spectre.Runtime.handle(
          MyApp.Agent,
          Spectre.Input.new("delete my account"),
          conversation_id: "conv-123"
        )
  """
  @spec handle(module(), Input.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def handle(agent, %Input{} = input, opts) do
    case start(agent, input, opts) do
      {:continue, %Run{} = run} ->
        run
        |> advance(opts)
        |> legacy_result()

      {:error, reason, %Run{}} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a resumable Run and loads only its logical input and state.

  Runtime options and memory are intentionally not stored on the Run. They are
  re-resolved on every subsequent step.
  """
  @spec start(module(), Input.t() | String.t() | map() | term(), keyword()) :: step_result()
  def start(agent, input, opts \\ [])
      when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    fallback = Run.new(agent, %Input{}, %State{})

    case Run.validate_options(opts) do
      :ok ->
        start_validated(Run.new(agent, %Input{}, %State{}, opts), input, opts)

      {:error, reason} ->
        fail_run_step(
          fallback,
          reason,
          put_run_identity(opts, fallback),
          :run_start_failed
        )
    end
  end

  defp start_validated(%Run{} = seed, input, opts) do
    input = Input.new(input)
    seed = %{seed | input: input}
    runtime_opts = seed.agent |> runtime_opts(opts) |> put_run_identity(seed)

    case normalize_input(seed.agent, input, runtime_opts) do
      {:ok, normalized} ->
        case load_state(seed.agent, normalized, runtime_opts) do
          {:ok, state} ->
            run = %{seed | input: normalized, state: state}
            record_run_step({:continue, run}, :run_started, runtime_opts)

          {:error, reason} ->
            fail_run_step(seed, reason, runtime_opts, :run_start_failed)
        end

      {:error, reason} ->
        fail_run_step(seed, reason, runtime_opts, :run_start_failed)
    end
  rescue
    exception ->
      fail_run_step(
        seed,
        {:run_start_failed, exception.__struct__},
        put_run_identity(opts, seed),
        :run_start_failed
      )
  catch
    kind, reason ->
      fail_run_step(
        seed,
        {:run_start_failed, kind, reason},
        put_run_identity(opts, seed),
        :run_start_failed
      )
  end

  @doc """
  Advances a Run until it must await work, exposes a public boundary, or
  completes.

  The return vocabulary is closed:

      {:continue, run}
      {:await, invocation, run}
      {:boundary, observable, run}
      {:complete, result, run}
      {:error, reason, run}
  """
  @spec advance(Run.t(), keyword()) :: step_result()
  def advance(run, opts \\ [])

  def advance(%Run{} = run, opts) when is_list(opts) do
    do_advance(run, opts)
  rescue
    exception ->
      fail_run_step(
        run,
        {:run_advance_failed, exception.__struct__},
        put_run_identity(opts, run),
        :run_advance_failed
      )
  catch
    kind, reason ->
      fail_run_step(
        run,
        {:run_advance_failed, kind, reason},
        put_run_identity(opts, run),
        :run_advance_failed
      )
  end

  defp do_advance(%Run{status: :ready, cursor: :turn} = run, opts) do
    opts = run.agent |> runtime_opts(opts) |> put_run_identity(run) |> put_turn_identity()

    ctx = %Context{
      agent: run.agent,
      input: run.input,
      state: run.state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{})
    }

    with {:ok, memory} <- load_memory(run.agent, run.input, run.state, opts),
         ctx = %{ctx | memory: memory},
         {:ok, result} <- run_turn(ctx),
         result = put_runtime_identity(result, opts),
         result = record_history(result, ctx),
         {:ok, result} <- Recorder.record_result(result, ctx),
         {:ok, result} <- persist(result, ctx) do
      finish_run_step(run, result, opts, :run_advanced)
    else
      {:error, reason} -> fail_run_step(run, reason, opts, :run_advance_failed)
    end
  end

  defp do_advance(%Run{status: :boundary, cursor: :complete} = run, opts) do
    opts = run.agent |> runtime_opts(opts) |> put_run_identity(run) |> put_turn_identity()
    revision = run.revision + 1
    completed = %{run | status: :complete, revision: revision, waiting: nil}
    result = put_run_identity(completed.result, completed, complete_ref(completed))
    completed = %{completed | result: result, state: result.state}
    record_run_step({:complete, result, completed}, :run_completed, opts)
  end

  defp do_advance(%Run{status: :complete, result: %Result{} = result} = run, _opts),
    do: {:complete, result, run}

  defp do_advance(%Run{status: :failed} = run, _opts),
    do: {:error, run.last_error || :run_failed, run}

  defp do_advance(%Run{} = run, _opts),
    do: {:error, {:run_requires_resume, run.id, run.revision, run.cursor}, run}

  @doc """
  Resumes a revision-fenced policy boundary or effect invocation.

  Policy responses use `{:policy, ref, resolution}`. Effect work uses
  `{:execute, invocation}` (or `{:execute, invocation_id}`). Stale, foreign,
  and already-consumed references are rejected before lifecycle state changes.
  """
  @spec resume(Run.t(), term(), keyword()) :: step_result()
  def resume(run, command, opts \\ [])

  def resume(%Run{} = run, command, opts) when is_list(opts) do
    do_resume(run, command, opts)
  rescue
    exception ->
      fail_run_step(
        run,
        {:run_resume_failed, exception.__struct__},
        put_run_identity(opts, run),
        :run_resume_failed
      )
  catch
    kind, reason ->
      fail_run_step(
        run,
        {:run_resume_failed, kind, reason},
        put_run_identity(opts, run),
        :run_resume_failed
      )
  end

  defp do_resume(
         %Run{status: :boundary, cursor: :policy, waiting: %Boundary{} = boundary} = run,
         {:policy, supplied_ref, resolution},
         opts
       ) do
    case validate_boundary_fence(boundary, supplied_ref) do
      :ok ->
        opts =
          run.agent
          |> runtime_opts(opts)
          |> put_run_identity(run)
          |> Keyword.put(:input, run.input)

        case resolve_policy(run.agent, run.result, resolution, opts) do
          {:ok, %Result{} = result} ->
            finish_run_step(run, result, opts, :run_resumed)

          {:error, reason} ->
            fail_run_step(run, reason, opts, :run_resume_failed)
        end

      {:error, reason} ->
        reject_run_resume(run, reason, opts)
    end
  end

  defp do_resume(
         %Run{status: :boundary, cursor: :policy, waiting: %Boundary{}} = run,
         {:input, input},
         opts
       ) do
    runtime_opts = run.agent |> runtime_opts(opts) |> put_run_identity(run)

    case normalize_resume_input(run.agent, input, runtime_opts) do
      {:ok, normalized} ->
        run
        |> Map.merge(%{
          input: normalized,
          status: :ready,
          cursor: :turn,
          waiting: nil
        })
        |> do_advance(runtime_opts)

      {:error, reason} ->
        reject_run_resume(run, reason, runtime_opts)
    end
  end

  defp do_resume(
         %Run{status: :awaiting, cursor: :effect, waiting: %Invocation{} = invocation} = run,
         {:execute, supplied},
         opts
       ) do
    case validate_invocation_fence(invocation, supplied) do
      :ok ->
        opts = run.agent |> runtime_opts(opts) |> put_run_identity(run)

        case execute(run.agent, run.result, opts) do
          {:ok, %Result{} = result} ->
            finish_run_step(run, result, opts, :run_resumed)

          {:error, reason} ->
            fail_run_step(run, reason, opts, :run_resume_failed)
        end

      {:error, reason} ->
        reject_run_resume(run, reason, opts)
    end
  end

  defp do_resume(%Run{status: :complete} = run, _command, _opts),
    do: {:error, {:run_already_complete, run.id, run.revision}, run}

  defp do_resume(%Run{status: :failed} = run, _command, _opts),
    do: {:error, {:run_failed, run.id, run.revision, run.last_error}, run}

  defp do_resume(%Run{} = run, command, _opts),
    do:
      {:error, {:invalid_run_resume, run.id, run.revision, run.cursor, command_kind(command)},
       run}

  @doc """
  Restores initial session state from the configured state adapter.

      {:ok, state} = Spectre.Runtime.restore_state(MyApp.Agent, conversation_id: "conv-123")
  """
  @spec restore_state(module(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def restore_state(agent, opts) do
    opts = runtime_opts(agent, opts)
    input = Input.new(%{text: "", meta: Map.take(Map.new(opts), [:conversation_id])})
    result = load_state(agent, input, opts)

    Spectre.Telemetry.emit(
      [:session, :restore],
      %{count: 1},
      %{agent: agent, outcome: if(match?({:ok, _}, result), do: :ok, else: :error)},
      opts
    )

    result
  end

  @doc """
  Resolves a currently open policy from a trusted host decision and persists
  the state transition before returning it.

  Unlike a user turn, this does not route synthetic text, append chat history,
  or invoke the memory adapter.

      {:ok, approved} =
        Spectre.Runtime.resolve_policy(
          MyApp.Agent,
          awaiting_result,
          {:accept, :terms_accepted},
          assigns: %{user: user}
        )
  """
  @spec resolve_policy(module(), Result.t(), Policy.resolution(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def resolve_policy(agent, %Result{} = result, resolution, opts \\ [])
      when is_atom(agent) and is_list(opts) do
    opts = continuation_runtime_opts(agent, result, opts)
    input = policy_resolution_input(result, opts)
    state = State.new(result.state)

    ctx = %Context{
      agent: agent,
      input: input,
      state: state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{}),
      route: result.route
    }

    with {:ok, %Result{} = resolved} <- Policy.resolve(resolution, input, ctx),
         resolved = put_runtime_identity(resolved, opts),
         resolved = advance_run_lineage(resolved, result),
         {:ok, %Result{} = resolved} <- Recorder.record_result(resolved, ctx),
         {:ok, %Result{} = persisted} <- persist_state(resolved, ctx) do
      {:ok, persisted}
    end
  end

  @doc """
  Executes a staged effect using the durable two-commit workflow.

  The executable state is persisted before the capability is invoked, and the
  completed/failed state is persisted before the terminal result is returned.
  Adapters receive the effect idempotency key through the action context.
  """
  @spec execute(module(), Result.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def execute(agent, %Result{} = result, opts \\ []) when is_atom(agent) and is_list(opts) do
    opts = continuation_runtime_opts(agent, result, opts)
    input = policy_resolution_input(result, opts)
    state = State.new(result.state)

    ctx = %Context{
      agent: agent,
      input: input,
      state: state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{}),
      route: result.route
    }

    result = %{result | state: state}

    if terminal_execution_result?(result) do
      {:ok, result}
    else
      execute_pending_result(result, ctx, opts)
    end
  end

  @spec execute_pending_result(Result.t(), Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp execute_pending_result(%Result{} = result, %Context{} = ctx, opts) do
    with {:ok, prepared} <- ensure_execution_state_persisted(result, ctx),
         execution_ctx = %{ctx | state: prepared.state},
         {:ok, executed} <- Spectre.Execution.execute_pending(prepared.state, execution_ctx, opts),
         executed <- inherit_execution_context(executed, prepared),
         executed = put_runtime_identity(executed, opts),
         executed = advance_run_lineage(executed, prepared),
         {:ok, executed} <- Recorder.record_result(executed, execution_ctx) do
      persist_state(executed, execution_ctx)
    end
  end

  @spec terminal_execution_result?(Result.t()) :: boolean()
  defp terminal_execution_result?(%Result{state: %State{} = state, effects: effects}) do
    is_nil(State.pending_effect(state)) and
      Enum.any?(effects, fn
        %Effect{id: id} = effect ->
          Effect.terminal?(effect) and
            Enum.any?(state.planned_effects, &(&1.id == id and &1.status == effect.status))

        _effect ->
          false
      end)
  end

  @doc """
  Builds the per-turn context by loading state and memory adapters.

      {:ok, ctx} = Spectre.Runtime.load_context(MyApp.Agent, input, [])
  """
  @spec load_context(module(), Input.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def load_context(agent, %Input{} = input, opts) do
    with {:ok, state} <- load_state(agent, input, opts),
         {:ok, memory} <- load_memory(agent, input, state, opts) do
      {:ok,
       %Context{
         agent: agent,
         input: input,
         state: state,
         opts: opts,
         memory: memory,
         assigns: Keyword.get(opts, :assigns, %{})
       }}
    end
  end

  @spec run_turn(Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp run_turn(%Context{state: state} = ctx) do
    if Policy.awaiting?(state) do
      run_policy_turn(ctx)
    else
      case Handlers.dispatch(ctx) do
        :cont -> run_routed_turn(ctx)
        {:reply, %Result{} = result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec run_routed_turn(Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp run_routed_turn(%Context{} = ctx) do
    with {:ok, router_context} <- Router.route_context(ctx.input, ctx),
         {:ok, route} <- Router.route_from_context(router_context) do
      # Router plugs may enrich the input before a handler runs, so the runner
      # receives the router context input rather than the original input.
      Spectre.Runner.run(route, %{ctx | input: router_context.input, route: route})
    end
  end

  defp run_policy_turn(%Context{} = ctx) do
    if Keyword.get(ctx.opts, :policy_global_interrupts?, false) do
      run_policy_interrupt_or_resume(ctx)
    else
      # Closed by default: short policy answers never enter normal routing.
      Policy.resume(ctx.input, ctx)
    end
  end

  defp run_policy_interrupt_or_resume(%Context{} = ctx) do
    interrupt_opts =
      ctx.opts
      |> Keyword.put(:policy_interrupt_only?, true)
      |> Keyword.put(:via, Keyword.get(ctx.opts, :policy_interrupt_via, [:regex]))

    interrupt_ctx = %{ctx | opts: interrupt_opts}

    with {:ok, router_context} <- Router.route_context(ctx.input, interrupt_ctx),
         {:ok, %Spectre.Route{rule: %Spectre.Rule{global?: true}} = route} <-
           Router.route_from_context(router_context) do
      Spectre.Runner.run(route, %{ctx | input: router_context.input, route: route})
    else
      {:error, {:journal_append_failed, _reason} = failure} -> {:error, failure}
      {:error, {:invalid_journal_configuration, _reason} = failure} -> {:error, failure}
      _no_interrupt -> Policy.resume(ctx.input, ctx)
    end
  end

  @spec load_state(module(), Input.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defp load_state(agent, input, opts) do
    config = definition_config(agent)
    state_module = Keyword.get(config, :state)
    conversation_id = Keyword.get(opts, :conversation_id)

    cond do
      Keyword.has_key?(opts, :state) ->
        # Explicit state is a test and host-app escape hatch; it wins over the
        # adapter so callers can replay a turn deterministically.
        {:ok, opts |> Keyword.get(:state) |> State.new() |> put_conversation_id(conversation_id)}

      is_atom(state_module) && function_exported?(state_module, :load, 3) ->
        load_state_adapter(state_module, :load, [input, agent, opts], conversation_id, opts)

      is_atom(state_module) && function_exported?(state_module, :load, 2) ->
        load_state_adapter(state_module, :load, [input, opts], conversation_id, opts)

      true ->
        {:ok, put_conversation_id(%State{}, conversation_id)}
    end
  end

  @spec load_memory(module(), Input.t(), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp load_memory(agent, input, state, opts) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    result =
      cond do
        Keyword.has_key?(opts, :memory) ->
          # Memory can be injected for tests or for host applications that have
          # already performed retrieval before calling Spectre.
          {:ok, Keyword.get(opts, :memory)}

        is_nil(memory_module) ->
          {:ok, nil}

        not is_atom(memory_module) ->
          {:error, {:invalid_memory_adapter, memory_module}}

        not Code.ensure_loaded?(memory_module) ->
          {:error, {:memory_adapter_unavailable, memory_module}}

        function_exported?(memory_module, :recall, 2) ->
          memory_opts =
            opts
            |> Keyword.put(:state, state)
            |> Keyword.put(:input, input)
            |> Keyword.put(:agent, agent)

          Call.run(
            :memory,
            fn ->
              normalize_provider_reply(memory_module.recall(input.text, memory_opts))
            end,
            Keyword.put(opts, :purpose, :memory_recall)
          )

        true ->
          {:ok, nil}
      end

    with {:ok, memory} <- result,
         :ok <- validate_term_size(memory, :memory_recall, opts, :memory_max_bytes, 1_000_000) do
      {:ok, memory}
    end
  end

  @spec persist(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist(%Result{} = result, %Context{} = ctx) do
    with {:ok, %Result{} = result} <- persist_state(result, ctx) do
      case persist_memory(result, ctx) do
        :ok -> {:ok, result}
        {:error, reason} -> memory_persist_failure(result, ctx, reason)
      end
    end
  end

  @spec memory_persist_failure(Result.t(), Context.t(), term()) ::
          {:ok, Result.t()} | {:error, term()}
  defp memory_persist_failure(%Result{} = result, %Context{} = ctx, reason) do
    case Keyword.get(ctx.opts, :memory_persist_failure, :warn) do
      :warn ->
        warning = %{type: :memory_persist_failed, error: reason}

        metadata = result.metadata

        warnings =
          metadata
          |> Map.get(:persistence_warnings, [])
          |> List.wrap()
          |> Kernel.++([warning])

        result =
          %{
            result
            | events: result.events ++ [warning],
              metadata: Map.put(metadata, :persistence_warnings, warnings)
          }

        {:ok, result}

      :error ->
        # The state write is already committed. Carry the committed result so a
        # session can advance its in-memory state even while reporting strict
        # memory failure to the host.
        {:error, {:memory_persist_failed, reason, result}}

      other ->
        {:error, {:invalid_memory_persist_failure, other}}
    end
  end

  @spec persist_state(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist_state(
         %Result{} = result,
         %Context{agent: agent, input: input, opts: opts, state: current_state} = ctx
       ) do
    state_module = agent |> definition_config() |> Keyword.get(:state)
    expected_revision = current_state.revision

    with :ok <- validate_result_revision(result, expected_revision) do
      next = %{result | state: State.bump_revision(result.state)}

      persisted =
        case persistence_callback(state_module, next.state, expected_revision, input, agent, opts) do
          nil ->
            {:ok, mark_state_persisted(next, expected_revision, :in_memory)}

          {module, function, args, mode} ->
            persist_with_adapter(module, function, args, mode, next, expected_revision, opts)
        end

      case persisted do
        {:ok, %Result{} = committed} ->
          emit_persistence(:committed, committed, ctx)
          record_committed_persistence(committed, ctx)

        {:error, {:persistence_ambiguous, reason, %Result{} = ambiguous}} ->
          emit_persistence(:ambiguous, ambiguous, ctx)
          _ = Recorder.record_persistence(ambiguous, ctx)
          {:error, {:persistence_ambiguous, reason, ambiguous}}

        {:error, reason} = error
        when is_tuple(reason) and tuple_size(reason) > 0 and elem(reason, 0) == :stale_state ->
          emit_persistence_conflict(ctx, expected_revision)
          error

        {:error, _reason} = error ->
          error
      end
    end
  end

  @spec record_committed_persistence(Result.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp record_committed_persistence(%Result{} = committed, %Context{} = ctx) do
    case Recorder.record_persistence(committed, ctx) do
      {:ok, %Result{} = recorded} ->
        {:ok, recorded}

      {:error, reason} ->
        # State has already crossed its commit boundary. Preserve that fact for
        # sessions and hosts even when a strict persistence-journal append
        # fails afterward.
        {:error, {:persistence_journal_failed, reason, committed}}
    end
  end

  defp emit_persistence(outcome, result, ctx) do
    Spectre.Telemetry.emit(
      [:persistence, :stop],
      %{count: 1},
      %{
        agent: ctx.agent,
        outcome: outcome,
        revision: result.state.revision,
        mode: get_in(result.metadata, [:state_persistence, :mode])
      },
      ctx.opts
    )
  end

  defp emit_persistence_conflict(ctx, expected_revision) do
    Spectre.Telemetry.emit(
      [:persistence, :conflict],
      %{count: 1},
      %{agent: ctx.agent, reason: :stale_state, expected_revision: expected_revision},
      ctx.opts
    )
  end

  @spec persist_memory(Result.t(), Context.t()) :: :ok | {:error, term()}
  defp persist_memory(%Result{} = result, %Context{agent: agent, input: input, opts: opts}) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    case memory_callback(memory_module) do
      {:ok, callback} ->
        persist_memory_callback(callback, input, result, agent, opts)

      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persist_memory_callback(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: :ok | {:error, term()}
  defp persist_memory_callback(callback, input, result, agent, opts) do
    with :ok <-
           validate_term_size(
             memory_payload(input, result, agent),
             :memory_persist,
             opts,
             :memory_persist_max_bytes,
             2_000_000
           ) do
      call_memory_persist(callback, input, result, agent, opts)
    end
  end

  @spec call_memory_persist(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: :ok | {:error, term()}
  defp call_memory_persist(callback, input, result, agent, opts) do
    result =
      Call.run(
        :memory,
        fn ->
          callback
          |> call_memory_callback(input, result, agent, opts)
          |> normalize_memory_provider_reply()
        end,
        Keyword.put(opts, :purpose, :memory_persist)
      )

    case result do
      {:ok, :persisted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_memory_persist_reply(term()) :: :ok | {:error, term()}
  defp normalize_memory_persist_reply(:ok), do: :ok
  defp normalize_memory_persist_reply({:ok, _reply}), do: :ok
  defp normalize_memory_persist_reply({:error, reason}), do: {:error, reason}

  defp normalize_memory_persist_reply(other),
    do: {:error, Failure.invalid_reply(:memory, other)}

  @spec normalize_memory_provider_reply(term()) :: {:ok, :persisted} | {:error, term()}
  defp normalize_memory_provider_reply(reply) do
    case normalize_memory_persist_reply(reply) do
      :ok -> {:ok, :persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_state_adapter(module(), atom(), list(), term(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  defp load_state_adapter(module, function, args, conversation_id, opts) do
    case Call.run(
           :state,
           fn -> module |> apply(function, args) |> normalize_provider_reply() end,
           Keyword.put(opts, :purpose, :state_load)
         ) do
      {:ok, payload} -> normalize_loaded_state(payload, conversation_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_provider_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_provider_reply({:ok, value}), do: {:ok, value}
  defp normalize_provider_reply({:error, reason}), do: {:error, reason}
  defp normalize_provider_reply(value), do: {:ok, value}

  @spec normalize_loaded_state(term(), term()) :: {:ok, State.t()} | {:error, term()}
  defp normalize_loaded_state(%State{} = state, conversation_id),
    do: {:ok, put_conversation_id(state, conversation_id)}

  defp normalize_loaded_state(payload, conversation_id)
       when is_map(payload) or is_binary(payload) do
    case Codec.decode(payload) do
      {:ok, state} -> {:ok, put_conversation_id(state, conversation_id)}
      {:error, reason} -> {:error, {:invalid_persisted_state, reason}}
    end
  end

  defp normalize_loaded_state(other, _conversation_id),
    do: {:error, {:invalid_state_reply, reply_shape(other)}}

  @spec persistence_callback(
          module() | term(),
          State.t(),
          non_neg_integer(),
          Input.t(),
          module(),
          keyword()
        ) ::
          {module(), atom(), list(), :cas | :legacy} | nil
  defp persistence_callback(module, state, expected, input, agent, opts) when is_atom(module) do
    adapter_opts = Call.adapter_opts(opts)

    cond do
      function_exported?(module, :compare_and_swap, 5) ->
        {module, :compare_and_swap, [state, expected, input, agent, adapter_opts], :cas}

      function_exported?(module, :persist, 5) ->
        {module, :persist, [state, expected, input, agent, adapter_opts], :cas}

      function_exported?(module, :persist, 4) ->
        {module, :persist, [state, input, agent, adapter_opts], :legacy}

      function_exported?(module, :persist, 2) ->
        {module, :persist, [state, input], :legacy}

      true ->
        nil
    end
  end

  defp persistence_callback(_module, _state, _expected, _input, _agent, _opts), do: nil

  @spec persist_with_adapter(
          module(),
          atom(),
          list(),
          :cas | :legacy,
          Result.t(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp persist_with_adapter(module, function, args, mode, result, expected, opts) do
    run_state_persist(
      module,
      function,
      args,
      Keyword.put(opts, :purpose, :state_persist)
    )
    |> handle_persist_reply(mode, result, expected)
  end

  @spec handle_persist_reply(term(), :cas | :legacy, Result.t(), non_neg_integer()) ::
          {:ok, Result.t()} | {:error, term()}
  defp handle_persist_reply({:ok, :persisted}, mode, result, expected) do
    {:ok, mark_state_persisted(result, expected, mode)}
  end

  defp handle_persist_reply({:ok, {:state, payload}}, mode, result, expected) do
    case normalize_persisted_state(payload, result) do
      {:ok, %Result{} = persisted_result} ->
        {:ok, mark_state_persisted(persisted_result, expected, mode)}

      {:error, reason} ->
        ambiguous_persistence(result, expected, reason)
    end
  end

  defp handle_persist_reply({:error, :stale_state}, _mode, _result, expected) do
    {:error, {:stale_state, expected}}
  end

  defp handle_persist_reply({:error, {:stale_state, actual}}, _mode, _result, expected) do
    {:error, {:stale_state, expected, actual}}
  end

  defp handle_persist_reply({:error, {:ambiguous, reason}}, _mode, result, expected) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply(
         {:error, {:persistence_ambiguous, reason}},
         _mode,
         result,
         expected
       ) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply(
         {:error, %Failure{provider: :state, kind: kind} = failure},
         _mode,
         result,
         expected
       )
       when kind != :configuration do
    # The adapter worker was invoked. An exception, exit, crash, timeout, or
    # invalid provider reply can happen after the durable write, so treating it
    # as a definite failure would make a blind retry unsafe.
    ambiguous_persistence(result, expected, failure)
  end

  defp handle_persist_reply(
         {:error, {:invalid_persist_reply, _shape} = reason},
         _mode,
         result,
         expected
       ) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply({:error, reason}, _mode, _result, _expected), do: {:error, reason}

  defp run_state_persist(module, function, args, opts) do
    Call.run(
      :state,
      fn -> module |> apply(function, args) |> normalize_persist_provider_reply() end,
      opts
    )
  end

  @spec normalize_persisted_state(term(), Result.t()) :: {:ok, Result.t()} | {:error, term()}
  defp normalize_persisted_state(payload, %Result{} = result) do
    with {:ok, state} <- normalize_loaded_state(payload, result.state.conversation_id),
         :ok <- validate_persisted_revision(state, result.state.revision) do
      {:ok, %{result | state: state}}
    end
  end

  @spec ambiguous_persistence(Result.t(), non_neg_integer(), term()) ::
          {:error, {:persistence_ambiguous, term(), Result.t()}}
  defp ambiguous_persistence(%Result{} = result, expected, reason) do
    ambiguous = mark_state_persisted(result, expected, :ambiguous)
    {:error, {:persistence_ambiguous, reason, ambiguous}}
  end

  @spec normalize_persist_provider_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_persist_provider_reply(:ok), do: {:ok, :persisted}
  defp normalize_persist_provider_reply({:ok, %State{} = state}), do: {:ok, {:state, state}}

  defp normalize_persist_provider_reply({:ok, state}) when is_map(state) or is_binary(state),
    do: {:ok, {:state, state}}

  defp normalize_persist_provider_reply({:error, reason}), do: {:error, reason}

  defp normalize_persist_provider_reply(other),
    do: {:error, {:invalid_persist_reply, reply_shape(other)}}

  @spec validate_result_revision(Result.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_result_revision(%Result{state: %State{revision: revision}}, expected)
       when revision == expected,
       do: :ok

  defp validate_result_revision(%Result{state: %State{revision: revision}}, expected),
    do: {:error, {:invalid_state_revision_transition, expected, revision}}

  @spec validate_persisted_revision(State.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_persisted_revision(%State{revision: revision}, expected)
       when revision == expected,
       do: :ok

  defp validate_persisted_revision(%State{revision: revision}, expected),
    do: {:error, {:invalid_persisted_revision, expected, revision}}

  @spec mark_state_persisted(Result.t(), non_neg_integer(), atom()) :: Result.t()
  defp mark_state_persisted(%Result{} = result, expected, mode) do
    persistence = %{
      status: if(mode == :ambiguous, do: :ambiguous, else: :committed),
      mode: mode,
      expected_revision: expected,
      revision: result.state.revision
    }

    %{result | metadata: Map.put(result.metadata, :state_persistence, persistence)}
  end

  @spec ensure_execution_state_persisted(Result.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp ensure_execution_state_persisted(%Result{} = result, %Context{} = ctx) do
    case get_in(result.metadata, [:state_persistence, :revision]) do
      revision when revision == result.state.revision ->
        {:ok, result}

      nil ->
        persist_state(result, ctx)

      revision ->
        {:error, {:stale_execution_result, revision, result.state.revision}}
    end
  end

  @spec inherit_execution_context(Result.t(), Result.t()) :: Result.t()
  defp inherit_execution_context(%Result{} = executed, %Result{} = prepared) do
    %{
      executed
      | route: prepared.route,
        metadata: Map.merge(prepared.metadata, executed.metadata)
    }
  end

  defp continuation_runtime_opts(agent, result, opts) do
    trace_id = get_in(result.metadata, [:runtime_identity, :trace_id])

    agent
    |> runtime_opts(opts)
    |> maybe_put_trace_id(trace_id)
    |> put_turn_identity()
  end

  defp maybe_put_trace_id(opts, nil), do: opts
  defp maybe_put_trace_id(opts, trace_id), do: Keyword.put_new(opts, :trace_id, trace_id)

  defp put_runtime_identity(%Result{} = result, opts) do
    identity = %{
      turn_id: Keyword.get(opts, :turn_id),
      trace_id: Keyword.get(opts, :trace_id)
    }

    %{result | metadata: Map.put(result.metadata, :runtime_identity, identity)}
  end

  @spec advance_run_lineage(Result.t(), Result.t()) :: Result.t()
  defp advance_run_lineage(%Result{} = result, %Result{} = previous) do
    case get_in(previous.metadata, [:run]) do
      %{id: id, revision: revision} = prior
      when is_binary(id) and is_integer(revision) and revision >= 0 ->
        lineage =
          prior
          |> Map.take([:id, :trace_id])
          |> Map.merge(%{
            id: id,
            revision: revision + 1,
            step_id: get_in(result.metadata, [:runtime_identity, :turn_id])
          })

        %{result | metadata: Map.put(result.metadata, :run, lineage)}

      _missing ->
        result
    end
  end

  @spec finish_run_step(Run.t(), Result.t(), keyword(), atom()) :: step_result()
  defp finish_run_step(%Run{} = run, %Result{} = result, opts, event) do
    revision = run.revision + 1
    input = if match?(%Input{}, result.input), do: result.input, else: run.input
    result = %{result | input: input}

    step_id =
      get_in(result.metadata, [:runtime_identity, :turn_id])
      |> then(&(&1 || Keyword.get(opts, :turn_id)))
      |> Value.logical_id("step")
      |> Kernel.||(Spectre.Identity.uuid7())

    base = %{
      run
      | input: input,
        result: result,
        state: State.new(result.state),
        revision: revision,
        step_id: step_id,
        waiting: nil,
        last_error: nil
    }

    awaitable = Result.open_awaitable(result)
    effect = Result.pending_effect(result)

    step =
      cond do
        match?(%Spectre.Awaitable{}, awaitable) ->
          policy_boundary(base, result, awaitable)

        match?(%Effect{}, effect) ->
          effect_invocation(base, result, effect)

        Result.visible_reply?(result) ->
          reply_boundary(base, result)

        true ->
          complete_run(base, result)
      end

    record_run_step(step, step_event(step, event), opts)
  end

  @spec policy_boundary(Run.t(), Result.t(), Spectre.Awaitable.t()) :: step_result()
  defp policy_boundary(%Run{} = run, %Result{} = result, awaitable) do
    run = %{run | status: :boundary, cursor: :policy}
    id = boundary_id(run, :policy, awaitable.id)
    ref = Run.ref(run, :policy, id, awaitable.id)

    boundary = %Boundary{
      id: id,
      kind: :needs,
      ref: ref,
      output: result.reply_text,
      request: Request.from_awaitable(awaitable),
      metadata: %{request_kind: :policy}
    }

    result = put_run_identity(result, run, ref)
    run = %{run | result: result, waiting: boundary}
    {:boundary, boundary, run}
  end

  @spec effect_invocation(Run.t(), Result.t(), Effect.t()) :: step_result()
  defp effect_invocation(%Run{} = run, %Result{} = result, %Effect{} = effect) do
    run = %{run | status: :awaiting, cursor: :effect}
    id = boundary_id(run, :invocation, effect.id)
    invocation = Invocation.from_effect(run, effect, id)
    result = put_run_identity(result, run, invocation.ref)
    run = %{run | result: result, waiting: invocation}
    {:await, invocation, run}
  end

  @spec reply_boundary(Run.t(), Result.t()) :: step_result()
  defp reply_boundary(%Run{} = run, %Result{} = result) do
    run = %{run | status: :boundary, cursor: :complete}
    id = boundary_id(run, :reply, nil)
    ref = Run.ref(run, :reply, id)

    boundary = %Boundary{
      id: id,
      kind: :reply,
      ref: ref,
      output: result.reply_text,
      metadata: %{content_type: :text}
    }

    result = put_run_identity(result, run, ref)
    run = %{run | result: result, waiting: boundary}
    {:boundary, boundary, run}
  end

  @spec complete_run(Run.t(), Result.t()) :: step_result()
  defp complete_run(%Run{} = run, %Result{} = result) do
    run = %{run | status: :complete, cursor: :complete}
    ref = complete_ref(run)
    result = put_run_identity(result, run, ref)
    run = %{run | result: result, waiting: nil}
    {:complete, result, run}
  end

  @spec complete_ref(Run.t()) :: Ref.t()
  defp complete_ref(%Run{} = run) do
    id = boundary_id(run, :complete, nil)
    Run.ref(run, :complete, id)
  end

  @spec put_run_identity(Result.t(), Run.t(), Ref.t()) :: Result.t()
  defp put_run_identity(%Result{} = result, %Run{} = run, %Ref{} = ref) do
    identity = %{
      id: run.id,
      revision: run.revision,
      status: run.status,
      cursor: run.cursor,
      step_id: run.step_id,
      trace_id: run.trace_id,
      ref: ref
    }

    %{result | metadata: Map.put(result.metadata, :run, identity)}
  end

  @spec put_run_identity(keyword(), Run.t()) :: keyword()
  defp put_run_identity(opts, %Run{} = run) when is_list(opts) do
    opts
    |> Keyword.put(:trace_id, run.trace_id)
    |> Keyword.put(:run_id, run.id)
    |> Keyword.put(:run_revision, run.revision)
  end

  @spec fail_run_step(Run.t(), term(), keyword(), atom()) :: step_result()
  defp fail_run_step(%Run{} = run, reason, opts, event) do
    result = committed_result(reason) || run.result

    failed = %{
      run
      | status: :failed,
        cursor: :complete,
        revision: run.revision + 1,
        waiting: nil,
        last_error: reason,
        result: result,
        state: if(match?(%Result{}, result), do: State.new(result.state), else: run.state)
    }

    failed =
      case result do
        %Result{} ->
          ref = Run.ref(failed, :error, boundary_id(failed, :error, failure_code(reason)))
          %{failed | result: put_run_identity(result, failed, ref)}

        nil ->
          failed
      end

    _ = record_run_event(failed, event, opts)
    {:error, reason, failed}
  end

  @spec committed_result(term()) :: Result.t() | nil
  defp committed_result({_kind, _reason, %Result{} = result}), do: result
  defp committed_result({_kind, _reason, _detail, %Result{} = result}), do: result
  defp committed_result(_reason), do: nil

  @spec legacy_result(step_result()) :: {:ok, Result.t()} | {:error, term()}
  defp legacy_result({:await, %Invocation{}, %Run{result: %Result{} = result}}),
    do: {:ok, result}

  defp legacy_result({:boundary, %Boundary{}, %Run{result: %Result{} = result}}),
    do: {:ok, result}

  defp legacy_result({:complete, %Result{} = result, %Run{}}), do: {:ok, result}
  defp legacy_result({:error, reason, %Run{}}), do: {:error, reason}
  defp legacy_result({:continue, %Run{} = run}), do: run |> advance() |> legacy_result()

  @spec validate_boundary_fence(Boundary.t(), term()) :: :ok | {:error, term()}
  defp validate_boundary_fence(%Boundary{ref: expected}, %Boundary{ref: supplied}),
    do: validate_ref(expected, supplied)

  defp validate_boundary_fence(%Boundary{ref: expected}, %Ref{} = supplied),
    do: validate_ref(expected, supplied)

  defp validate_boundary_fence(%Boundary{id: id}, id), do: :ok

  defp validate_boundary_fence(%Boundary{ref: expected}, supplied),
    do: {:error, {:invalid_run_reference, expected, supplied}}

  @spec validate_invocation_fence(Invocation.t(), term()) :: :ok | {:error, term()}
  defp validate_invocation_fence(%Invocation{} = expected, %Invocation{} = supplied) do
    if expected.id == supplied.id and expected.run_id == supplied.run_id and
         expected.run_revision == supplied.run_revision and
         expected.subject_id == supplied.subject_id do
      :ok
    else
      {:error, {:stale_invocation, supplied.id, expected.id}}
    end
  end

  defp validate_invocation_fence(%Invocation{ref: expected}, %Ref{} = supplied),
    do: validate_ref(expected, supplied)

  defp validate_invocation_fence(%Invocation{id: id}, id), do: :ok

  defp validate_invocation_fence(%Invocation{id: expected}, supplied),
    do: {:error, {:invalid_invocation_reference, supplied, expected}}

  @spec validate_ref(Ref.t(), Ref.t()) :: :ok | {:error, term()}
  defp validate_ref(%Ref{} = expected, %Ref{} = supplied) do
    if expected == supplied do
      :ok
    else
      {:error,
       {:stale_run_reference, supplied.run_id, supplied.revision, expected.run_id,
        expected.revision}}
    end
  end

  @spec record_run_step(step_result(), atom(), keyword()) :: step_result()
  defp record_run_step(step, event, opts) do
    run = step_run(step)

    result =
      step
      |> run_step_events(event)
      |> Enum.reduce_while(:ok, fn current_event, :ok ->
        case record_run_event(run, current_event, opts) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, current_event, reason}}
        end
      end)

    case result do
      :ok ->
        step

      {:error, _event, {:invalid_journal_configuration, _detail} = reason} ->
        {:error, reason, run}

      {:error, failed_event, reason} ->
        failure =
          case run.result do
            %Result{} = result -> {:run_journal_failed, failed_event, reason, result}
            nil -> {:run_journal_failed, failed_event, reason}
          end

        {:error, failure, run}
    end
  end

  @spec record_run_event(Run.t(), atom(), keyword()) :: :ok | {:error, term()}
  defp record_run_event(%Run{} = run, event, opts) do
    journal_opts =
      opts
      |> put_run_identity(run)
      |> Keyword.put(:turn_id, Value.token("run-event", {run.id, run.revision, event}))
      |> Keyword.put(:journal_sequence, run_event_sequence(event))

    Recorder.record_extension(
      run.agent,
      event,
      %{
        run_id: run.id,
        run_revision: run.revision,
        run_status: run.status,
        run_cursor: run.cursor,
        step_id: run.step_id
      },
      journal_opts
    )
  end

  @spec step_run(step_result()) :: Run.t()
  defp step_run({:continue, %Run{} = run}), do: run
  defp step_run({:await, %Invocation{}, %Run{} = run}), do: run
  defp step_run({:boundary, %Boundary{}, %Run{} = run}), do: run
  defp step_run({:complete, %Result{}, %Run{} = run}), do: run

  @spec step_event(step_result(), atom()) :: atom()
  defp step_event(_step, :run_resumed), do: :run_resumed
  defp step_event({:await, %Invocation{}, %Run{}}, :run_advanced), do: :run_awaiting
  defp step_event({:boundary, %Boundary{}, %Run{}}, :run_advanced), do: :run_boundary
  defp step_event({:complete, %Result{}, %Run{}}, :run_advanced), do: :run_completed

  defp run_step_events(step, :run_resumed), do: [:run_resumed, outcome_event(step)]
  defp run_step_events(_step, event), do: [event]

  defp outcome_event({:await, %Invocation{}, %Run{}}), do: :run_awaiting
  defp outcome_event({:boundary, %Boundary{}, %Run{}}), do: :run_boundary
  defp outcome_event({:complete, %Result{}, %Run{}}), do: :run_completed

  defp run_event_sequence(:run_started), do: 0
  defp run_event_sequence(:run_start_failed), do: 1
  defp run_event_sequence(:run_resumed), do: 94
  defp run_event_sequence(:run_awaiting), do: 95
  defp run_event_sequence(:run_boundary), do: 95
  defp run_event_sequence(:run_completed), do: 96
  defp run_event_sequence(:run_resume_rejected), do: 97
  defp run_event_sequence(_event), do: 98

  defp reject_run_resume(%Run{} = run, reason, opts) do
    runtime_opts = run.agent |> runtime_opts(opts) |> put_run_identity(run)
    _ = record_run_event(run, :run_resume_rejected, runtime_opts)
    {:error, reason, run}
  end

  @spec boundary_id(Run.t(), atom(), term()) :: String.t()
  defp boundary_id(%Run{} = run, kind, subject_id) do
    digest =
      {run.id, run.revision, kind, subject_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Atom.to_string(kind) <> ":" <> binary_part(digest, 0, 32)
  end

  @spec failure_code(term()) :: term()
  defp failure_code({code, _detail}) when is_atom(code), do: code
  defp failure_code({code, _detail, _more}) when is_atom(code), do: code
  defp failure_code(code) when is_atom(code), do: code
  defp failure_code(_reason), do: :run_failed

  @spec command_kind(term()) :: atom()
  defp command_kind({kind, _value}) when is_atom(kind), do: kind
  defp command_kind({kind, _value, _more}) when is_atom(kind), do: kind
  defp command_kind(_command), do: :unknown

  @spec definition_config(module()) :: keyword()
  defp definition_config(agent), do: Definition.fetch!(agent).config

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_nil(value), do: nil
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(%{__struct__: module}), do: {:struct, module}
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other

  @spec memory_callback(module() | term()) ::
          {:ok, {:remember | :persist, 2 | 4, module()}}
          | :ok
          | {:error, term()}
  defp memory_callback(nil), do: :ok

  defp memory_callback(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      loaded_memory_callback(module)
    else
      {:error, {:memory_adapter_unavailable, module}}
    end
  end

  defp memory_callback(module), do: {:error, {:invalid_memory_adapter, module}}

  defp loaded_memory_callback(module) do
    cond do
      function_exported?(module, :remember, 4) -> {:ok, {:remember, 4, module}}
      function_exported?(module, :persist, 4) -> {:ok, {:persist, 4, module}}
      function_exported?(module, :remember, 2) -> {:ok, {:remember, 2, module}}
      function_exported?(module, :persist, 2) -> {:ok, {:persist, 2, module}}
      true -> :ok
    end
  end

  @spec call_memory_callback(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: term()
  defp call_memory_callback({function, 4, module}, input, result, agent, opts) do
    apply(module, function, [input, result, agent, opts])
  end

  defp call_memory_callback({function, 2, module}, input, result, agent, opts) do
    payload = memory_payload(input, result, agent)

    memory_opts =
      Keyword.merge(opts, input: input, state: result.state, result: result, agent: agent)

    apply(module, function, [payload, memory_opts])
  end

  @spec runtime_opts(module(), keyword()) :: keyword()
  defp runtime_opts(agent, opts) do
    agent
    |> agent_runtime_opts()
    |> Keyword.merge(opts)
  end

  @spec agent_runtime_opts(module()) :: keyword()
  defp agent_runtime_opts(agent) do
    config = definition_config(agent)

    []
    |> maybe_put_config(config, :model)
    |> maybe_put_config(config, :classifier)
    |> maybe_put_config(config, :adapter)
    |> maybe_put_config(config, :embedding)
    |> maybe_put_config(config, :input_pipeline)
    |> maybe_put_config(config, :turn_handlers)
    |> maybe_put_config(config, :journal)
    |> maybe_put_config(config, :history)
    |> maybe_put_config(config, :chat_history_limit)
    |> maybe_put_config(config, :state_timeout)
    |> maybe_put_config(config, :memory_timeout)
    |> maybe_put_config(config, :run_timeout)
    |> maybe_put_config(config, :renderer_timeout)
    |> maybe_put_config(config, :hook_timeout)
    |> maybe_put_config(config, :prompt_timeout)
    |> maybe_put_config(config, :input_timeout)
    |> maybe_put_config(config, :router_timeout)
    |> maybe_put_config(config, :monitor_timeout)
    |> maybe_put_config(config, :callback_timeout)
    |> maybe_put_config(config, :turn_handler_timeout)
    |> maybe_put_config(config, :effect_timeout)
    |> maybe_put_config(config, :effect_payload_max_bytes)
    |> maybe_put_config(config, :effect_result_max_bytes)
    |> maybe_put_config(config, :input_max_bytes)
    |> maybe_put_config(config, :memory_max_bytes)
    |> maybe_put_config(config, :memory_persist_max_bytes)
  end

  @spec normalize_input(module(), Input.t(), keyword()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(agent, %Input{} = input, opts) do
    normalized =
      case Keyword.get(opts, :input_pipeline, []) do
        [] ->
          {:ok, input}

        specs when is_list(specs) ->
          Pipeline.run(input, %{agent: agent, opts: opts}, specs)

        other ->
          {:error, {:invalid_input_pipeline, other}}
      end

    with {:ok, input} <- normalized,
         :ok <- validate_binary_size(input.text, :input, opts, :input_max_bytes, 64_000) do
      {:ok, input}
    end
  end

  defp normalize_resume_input(agent, input, opts) do
    normalize_input(agent, Input.new(input), opts)
  rescue
    exception -> {:error, {:run_input_failed, exception.__struct__}}
  catch
    kind, reason -> {:error, {:run_input_failed, kind, reason}}
  end

  @spec maybe_put_config(keyword(), keyword(), atom()) :: keyword()
  defp maybe_put_config(opts, config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  @spec put_turn_identity(keyword()) :: keyword()
  defp put_turn_identity(opts) do
    turn_id = Value.logical_id(Keyword.get(opts, :turn_id), "turn") || Spectre.Identity.uuid7()
    trace_id = Value.logical_id(Keyword.get(opts, :trace_id), "trace") || turn_id

    opts
    |> Keyword.put(:turn_id, turn_id)
    |> Keyword.put(:trace_id, trace_id)
  end

  @spec record_history(Result.t(), Context.t()) :: Result.t()
  defp record_history(%Result{} = result, %Context{agent: agent, opts: opts}) do
    limit =
      Keyword.get(
        opts,
        :chat_history_limit,
        Keyword.get(definition_config(agent), :history, 20)
      )

    %{result | state: State.record_turn(result.state, result.input, result, limit)}
  end

  @spec memory_payload(Input.t(), Result.t(), module()) :: map()
  defp memory_payload(%Input{} = input, %Result{} = result, agent) do
    %{
      agent: agent,
      input: input,
      reply_text: result.reply_text,
      route: result.route,
      state: result.state,
      effects: result.effects,
      awaitables: result.awaitables,
      events: result.events
    }
  end

  @spec policy_resolution_input(Result.t(), keyword()) :: Input.t()
  defp policy_resolution_input(%Result{} = result, opts) do
    case Keyword.get(opts, :input, result.input) do
      %Input{} = input -> input
      nil -> Input.new("")
      input -> Input.new(input)
    end
  end

  @spec put_conversation_id(State.t(), term()) :: State.t()
  defp put_conversation_id(%State{} = state, nil), do: state

  defp put_conversation_id(%State{conversation_id: nil} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}

  defp put_conversation_id(%State{} = state, _conversation_id), do: state

  @spec validate_binary_size(binary(), atom(), keyword(), atom(), pos_integer()) ::
          :ok | {:error, term()}
  defp validate_binary_size(value, boundary, opts, key, default) when is_binary(value) do
    max_bytes = Keyword.get(opts, key, default)

    if is_integer(max_bytes) and max_bytes > 0 and byte_size(value) <= max_bytes do
      :ok
    else
      {:error, {:payload_too_large, boundary, byte_size(value), max_bytes}}
    end
  end

  @spec validate_term_size(term(), atom(), keyword(), atom(), pos_integer()) ::
          :ok | {:error, term()}
  defp validate_term_size(value, boundary, opts, key, default) do
    max_bytes = Keyword.get(opts, key, default)
    bytes = :erlang.external_size(value)

    if is_integer(max_bytes) and max_bytes > 0 and bytes <= max_bytes do
      :ok
    else
      {:error, {:payload_too_large, boundary, bytes, max_bytes}}
    end
  rescue
    exception -> {:error, {:payload_size_failed, boundary, exception.__struct__}}
  end
end
