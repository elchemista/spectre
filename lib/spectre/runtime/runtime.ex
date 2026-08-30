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
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Inference.Prepared, as: PreparedInference
  alias Spectre.Inference.Response, as: InferenceResponse
  alias Spectre.Invocation
  alias Spectre.Journal.Recorder
  alias Spectre.Policy
  alias Spectre.Result
  alias Spectre.Router
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.InferenceContinuation
  alias Spectre.Run.StartContinuation
  alias Spectre.Run.Value
  alias Spectre.Runtime.Persistence
  alias Spectre.Runtime.SkillDispatch
  alias Spectre.State
  alias Spectre.Turn.Handlers

  @type step_result ::
          {:continue, Run.t()}
          | {:dispatch, Invocation.t(), Run.t(), PreparedInference.t()}
          | {:await, Invocation.t(), Run.t()}
          | {:boundary, Boundary.t(), Run.t()}
          | {:complete, Result.t(), Run.t()}
          | {:error, term(), Run.t()}

  @doc false
  @spec admit(
          module(),
          Input.t() | String.t() | map() | term(),
          State.t(),
          keyword(),
          keyword()
        ) ::
          {:ok, Run.t()} | {:error, term()}
  def admit(agent, input, %State{} = state, opts \\ [], admission_opts \\ [])
      when is_atom(agent) and not is_nil(agent) and is_list(opts) and is_list(admission_opts) do
    with :ok <- Run.validate_options(opts),
         input <- Input.new(input) do
      # Admission runs in the owning Instance and therefore must remain a
      # bounded, mailbox-safe reservation. Input plugs and state loading run in
      # the first worker move (`start/3`); recovery can replay that move from
      # this transport-neutral logical input.
      logical = Spectre.Run.Codec.logical_input(input)
      continuation = StartContinuation.new(logical, admission_opts)

      {:ok,
       agent
       |> Run.new(logical, state, opts)
       |> Map.put(:start_continuation, continuation)}
    end
  rescue
    exception -> {:error, {:run_admission_failed, exception.__struct__}}
  catch
    kind, reason -> {:error, {:run_admission_failed, kind, reason}}
  end

  @doc false
  @spec admit_inference(
          module(),
          InferenceRequest.t(),
          Input.t() | String.t() | map() | term(),
          State.t(),
          keyword(),
          keyword()
        ) :: {:ok, Run.t()} | {:error, term()}
  def admit_inference(agent, request, input, state, opts \\ [], admission_opts \\ [])

  def admit_inference(
        agent,
        %InferenceRequest{} = request,
        input,
        %State{} = state,
        opts,
        admission_opts
      )
      when is_atom(agent) and not is_nil(agent) and is_list(opts) and
             is_list(admission_opts) do
    with :ok <- Run.validate_options(opts) do
      # Cognitive operations already run after input admission. Preserve that
      # normalized logical view instead of executing the host input pipeline a
      # second time for the nested, state-neutral Run.
      logical = input |> Input.new() |> Spectre.Run.Codec.logical_input()
      continuation = StartContinuation.for_inference(logical, request, admission_opts)

      {:ok,
       agent
       |> Run.new(logical, state, opts)
       |> Map.put(:start_continuation, continuation)}
    end
  rescue
    exception -> {:error, {:inference_run_admission_failed, exception.__struct__}}
  catch
    kind, reason -> {:error, {:inference_run_admission_failed, kind, reason}}
  end

  @doc false
  @spec prepare_inference(Run.t(), InferenceRequest.t(), keyword()) :: step_result()
  def prepare_inference(
        %Run{
          status: :ready,
          cursor: :turn,
          start_continuation: %StartContinuation{entrypoint: :inference}
        } = run,
        %InferenceRequest{} = request,
        opts
      )
      when is_list(opts) do
    opts = run.agent |> runtime_opts(opts) |> put_run_identity(run) |> put_turn_identity()

    ctx = %Context{
      agent: run.agent,
      input: run.input,
      state: run.state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{})
    }

    case Spectre.Inference.prepare(run.agent, request, ctx) do
      {:ok, %PreparedInference{} = prepared} ->
        stage_inference(run, prepared, opts, :cognitive_operation)

      {:error, reason} ->
        fail_run_step(run, reason, opts, :run_advance_failed)
    end
  rescue
    exception ->
      fail_run_step(
        run,
        {:inference_run_prepare_failed, exception.__struct__},
        put_run_identity(opts, run),
        :run_advance_failed
      )
  catch
    kind, reason ->
      fail_run_step(
        run,
        {:inference_run_prepare_failed, kind, reason},
        put_run_identity(opts, run),
        :run_advance_failed
      )
  end

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
        case Persistence.load_state(seed.agent, normalized, runtime_opts) do
          {:ok, state} ->
            # Keep the live normalized input (including request-local `raw`)
            # for this process, but persist the same logical projection that
            # recovery will receive. The continuation is committed before a
            # caller can checkpoint the newly started Run.
            logical = Spectre.Run.Codec.logical_input(normalized)
            continuation = StartContinuation.new(logical, opts)
            run = %{seed | input: normalized, state: state, start_continuation: continuation}
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

    case Persistence.load_memory(run.agent, run.input, run.state, opts) do
      {:ok, memory} ->
        ctx = %{ctx | memory: memory}

        case run_turn(ctx) do
          {:ok, %Result{} = result} ->
            finish_turn_result(run, result, ctx, opts)

          {:inference, %PreparedInference{} = prepared} ->
            stage_inference(run, prepared, opts)

          {:error, reason} ->
            fail_run_step(run, reason, opts, :run_advance_failed)
        end

      {:error, reason} ->
        fail_run_step(run, reason, opts, :run_advance_failed)
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
    resume_policy_boundary(run, boundary, supplied_ref, nil, resolution, opts)
  end

  defp do_resume(
         %Run{status: :boundary, cursor: :policy, waiting: %Boundary{} = boundary} = run,
         {:policy, supplied_ref, awaitable_id, resolution},
         opts
       ) do
    resume_policy_boundary(run, boundary, supplied_ref, awaitable_id, resolution, opts)
  end

  defp do_resume(
         %Run{
           status: :awaiting,
           cursor: :inference,
           waiting: %Invocation{kind: :inference} = invocation,
           inference_continuation: %InferenceContinuation{} = continuation
         } = run,
         {:inference, supplied, %InferenceResponse{} = response},
         opts
       ) do
    case validate_invocation_fence(invocation, supplied) do
      :ok ->
        opts = run.agent |> runtime_opts(opts) |> put_run_identity(run) |> put_turn_identity()

        ctx = %Context{
          agent: run.agent,
          input: run.input,
          state: run.state,
          opts: opts,
          assigns: Keyword.get(opts, :assigns, %{}),
          route: continuation.descriptor.route
        }

        case Persistence.load_memory(run.agent, run.input, run.state, opts) do
          {:ok, memory} ->
            resume_inference_postprocessor(
              run,
              continuation,
              response,
              %{ctx | memory: memory},
              opts
            )

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

  @spec resume_policy_boundary(
          Run.t(),
          Boundary.t(),
          term(),
          term() | nil,
          Policy.resolution(),
          keyword()
        ) :: step_result()
  defp resume_policy_boundary(run, boundary, supplied_ref, awaitable_id, resolution, opts) do
    case validate_boundary_fence(boundary, supplied_ref) do
      :ok ->
        opts =
          run.agent
          |> runtime_opts(opts)
          |> put_run_identity(run)
          |> Keyword.put(:input, run.input)

        run.agent
        |> resolve_policy_result(run.result, awaitable_id, resolution, opts)
        |> finish_policy_resume(run, opts)

      {:error, reason} ->
        reject_run_resume(run, reason, opts)
    end
  end

  defp finish_policy_resume({:ok, %Result{} = result}, run, opts),
    do: finish_run_step(run, result, opts, :run_resumed)

  defp finish_policy_resume({:error, reason}, run, opts) do
    if policy_resolution_rejection?(reason),
      do: reject_run_resume(run, reason, opts),
      else: fail_run_step(run, reason, opts, :run_resume_failed)
  end

  @doc """
  Restores initial session state from the configured state adapter.

      {:ok, state} = Spectre.Runtime.restore_state(MyApp.Agent, conversation_id: "conv-123")
  """
  @spec restore_state(module(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def restore_state(agent, opts) do
    opts = runtime_opts(agent, opts)
    input = Input.new(%{text: "", meta: Map.take(Map.new(opts), [:conversation_id])})
    result = Persistence.load_state(agent, input, opts)

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
  or invoke the memory adapter. Passing `{:awaitable, id}` loads current state
  before applying the host decision.

      {:ok, approved} =
        Spectre.Runtime.resolve_policy(
          MyApp.Agent,
          awaiting_result,
          {:accept, :terms_accepted},
          assigns: %{user: user}
        )
  """
  @spec resolve_policy(
          module(),
          Result.t() | {:awaitable, term()},
          Policy.resolution(),
          keyword()
        ) ::
          {:ok, Result.t()} | {:error, term()}
  def resolve_policy(agent, result_or_awaitable, resolution, opts \\ [])

  def resolve_policy(agent, {:awaitable, awaitable_id}, resolution, opts)
      when is_atom(agent) and is_list(opts) do
    opts = agent |> runtime_opts(opts) |> put_turn_identity()
    input = addressed_policy_resolution_input(opts)

    with {:ok, %State{} = state} <- Persistence.load_state(agent, input, opts) do
      ctx = %Context{
        agent: agent,
        input: input,
        state: state,
        opts: opts,
        assigns: Keyword.get(opts, :assigns, %{}),
        route: Keyword.get(opts, :route)
      }

      with {:ok, %Result{} = resolved} <-
             Policy.resolve(awaitable_id, resolution, input, ctx),
           resolved = put_runtime_identity(resolved, opts),
           {:ok, %Result{} = resolved} <- Recorder.record_result(resolved, ctx),
           {:ok, %Result{} = persisted} <- Persistence.persist_state(resolved, ctx) do
        {:ok, persisted}
      end
    end
  end

  def resolve_policy(agent, %Result{} = result, resolution, opts)
      when is_atom(agent) and is_list(opts) do
    resolve_policy_result(agent, result, nil, resolution, opts)
  end

  @spec resolve_policy_result(module(), Result.t(), term() | nil, Policy.resolution(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp resolve_policy_result(agent, result, awaitable_id, resolution, opts) do
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

    policy_result =
      case awaitable_id do
        nil -> Policy.resolve(resolution, input, ctx)
        id -> Policy.resolve(id, resolution, input, ctx)
      end

    with {:ok, %Result{} = resolved} <- policy_result,
         resolved = put_runtime_identity(resolved, opts),
         resolved = advance_run_lineage(resolved, result),
         {:ok, %Result{} = resolved} <- Recorder.record_result(resolved, ctx),
         {:ok, %Result{} = persisted} <- Persistence.persist_state(resolved, ctx) do
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

    if terminal_execution_result?(result, instance_lifecycle_run_id(opts)) do
      {:ok, result}
    else
      execute_pending_result(result, ctx, opts)
    end
  end

  @spec execute_pending_result(Result.t(), Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp execute_pending_result(%Result{} = result, %Context{} = ctx, opts) do
    with {:ok, prepared} <- Persistence.ensure_execution_state_persisted(result, ctx),
         execution_ctx = %{ctx | state: prepared.state},
         {:ok, executed} <- Spectre.Execution.execute_pending(prepared.state, execution_ctx, opts),
         executed <- inherit_execution_context(executed, prepared),
         executed = put_runtime_identity(executed, opts),
         executed = advance_run_lineage(executed, prepared),
         {:ok, executed} <- Recorder.record_result(executed, execution_ctx) do
      Persistence.persist_state(executed, execution_ctx)
    end
  end

  @spec terminal_execution_result?(Result.t(), String.t() | nil) :: boolean()
  defp terminal_execution_result?(
         %Result{state: %State{} = state, effects: effects},
         run_id
       ) do
    is_nil(State.pending_effect(state, run_id)) and
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
    with {:ok, state} <- Persistence.load_state(agent, input, opts),
         {:ok, memory} <- Persistence.load_memory(agent, input, state, opts) do
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

  @spec run_turn(Context.t()) ::
          {:ok, Result.t()} | {:inference, PreparedInference.t()} | {:error, term()}
  defp run_turn(%Context{state: state} = ctx) do
    if Policy.captures_conversation?(state, instance_lifecycle_run_id(ctx.opts)) do
      run_policy_turn(ctx)
    else
      case Handlers.dispatch(ctx) do
        :cont -> run_skill_or_routed_turn(ctx)
        {:reply, %Result{} = result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp finish_turn_result(run, result, ctx, opts) do
    result = put_runtime_identity(result, opts)
    result = record_history(result, ctx)

    with {:ok, result} <- Recorder.record_result(result, ctx),
         {:ok, result} <- Persistence.persist(result, ctx) do
      finish_run_step(run, result, opts, :run_advanced)
    else
      {:error, reason} -> fail_run_step(run, reason, opts, :run_advance_failed)
    end
  end

  defp stage_inference(
         %Run{} = run,
         %PreparedInference{} = prepared,
         opts,
         postprocessor \\ nil
       ) do
    revision = run.revision + 1
    step_id = Value.token("inference-step", {run.id, revision, prepared.descriptor.id})

    continuation =
      InferenceContinuation.new(prepared.descriptor,
        frozen_selection: prepared.frozen_selection,
        postprocessor: postprocessor || inference_postprocessor(prepared.descriptor),
        recoverable?: prepared.descriptor.recoverable?
      )

    staged = %{
      run
      | status: :awaiting,
        cursor: :inference,
        revision: revision,
        step_id: step_id,
        start_continuation: nil,
        result: nil,
        waiting: nil,
        inference_continuation: continuation,
        last_error: nil
    }

    invocation =
      Invocation.from_inference(staged, continuation,
        streaming?:
          Keyword.get(opts, :streaming?, false) and
            continuation.postprocessor == :response_generation
      )

    continuation = %{
      continuation
      | invocation: invocation,
        stream_epoch: invocation.stream_epoch,
        provider_request_digest: nil,
        provider_status: :selected
    }

    staged = %{staged | waiting: invocation, inference_continuation: continuation}

    record_run_step(
      {:dispatch, invocation, staged, prepared},
      :run_awaiting,
      put_run_identity(opts, staged)
    )
  end

  defp inference_postprocessor(%{purpose: :route_classification}),
    do: :route_classification

  defp inference_postprocessor(%{purpose: :policy_interrupt_classification}),
    do: :policy_interrupt_classification

  defp inference_postprocessor(_descriptor), do: :response_generation

  defp resume_inference_postprocessor(
         run,
         %{postprocessor: :cognitive_operation, descriptor: descriptor},
         response,
         _ctx,
         opts
       ) do
    # The operational loop owns validation and domain handling. This Run only
    # commits the nondeterministic inference boundary and returns its portable
    # response without recording chat history or mutating Agent state.
    result = %Result{
      input: run.input,
      route: descriptor.route,
      state: run.state,
      metadata: %{
        cognitive_inference: %{
          inference_id: descriptor.id,
          purpose: descriptor.purpose,
          response: response
        }
      }
    }

    finish_run_step(run, result, opts, :run_resumed)
  end

  defp resume_inference_postprocessor(
         run,
         %{postprocessor: :response_generation, descriptor: descriptor},
         response,
         ctx,
         opts
       ) do
    case Spectre.Runner.resume_inference(descriptor, response, run.input, ctx) do
      {:ok, result} ->
        finish_turn_result(run, result, ctx, opts)

      {:inference, %PreparedInference{} = prepared} ->
        stage_chained_inference(run, prepared, opts)

      {:error, reason} ->
        fail_run_step(run, reason, opts, :run_resume_failed)
    end
  end

  defp resume_inference_postprocessor(
         run,
         %{
           postprocessor: postprocessor,
           inference_id: inference_id,
           descriptor: descriptor
         },
         response,
         ctx,
         opts
       )
       when postprocessor in [:route_classification, :policy_interrupt_classification] do
    opts =
      opts
      |> Keyword.put(:inference_classifier_response, response)
      |> Keyword.put(:inference_classifier_descriptor, descriptor)
      |> Keyword.put(:inference_request_id, inference_id)

    ctx = %{ctx | opts: opts}

    result =
      case postprocessor do
        :route_classification -> run_routed_turn(ctx)
        :policy_interrupt_classification -> run_policy_interrupt_or_resume(ctx)
      end

    downstream_opts = drop_classifier_resume_opts(opts)
    downstream_ctx = %{ctx | opts: downstream_opts}

    case result do
      {:ok, %Result{} = result} ->
        finish_turn_result(run, result, downstream_ctx, downstream_opts)

      {:inference, %PreparedInference{} = prepared} ->
        stage_inference(run, prepared, downstream_opts)

      {:error, reason} ->
        fail_run_step(run, reason, downstream_opts, :run_resume_failed)
    end
  end

  # A response-generation continuation may stage an effect and open its policy
  # before asking for the policy prompt. That is the only inference handoff
  # allowed to advance the authoritative Run state. Router classifiers prepare
  # inference from their own state-neutral context and must never replace it.
  defp stage_chained_inference(
         %Run{} = run,
         %PreparedInference{state: %State{} = state} = prepared,
         opts
       ) do
    stage_inference(%{run | state: state}, prepared, opts)
  end

  defp stage_chained_inference(%Run{} = run, %PreparedInference{} = prepared, opts) do
    stage_inference(run, prepared, opts)
  end

  @spec run_skill_or_routed_turn(Context.t()) ::
          {:ok, Result.t()} | {:inference, PreparedInference.t()} | {:error, term()}
  defp run_skill_or_routed_turn(%Context{} = ctx) do
    case SkillDispatch.dispatch(ctx) do
      :cont -> run_routed_turn(ctx)
      {:reply, %Result{} = result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_routed_turn(Context.t()) ::
          {:ok, Result.t()} | {:inference, PreparedInference.t()} | {:error, term()}
  defp run_routed_turn(%Context{} = ctx) do
    with {:ok, router_context} <- Router.route_context(ctx.input, ctx),
         {:ok, route} <- Router.route_from_context(router_context) do
      # Router plugs may enrich the input before a handler runs, so the runner
      # receives the router context input rather than the original input.
      Spectre.Runner.run(route, %{
        ctx
        | input: router_context.input,
          route: route,
          opts: drop_classifier_resume_opts(ctx.opts)
      })
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
      |> Keyword.put(:classifier_inference_purpose, :policy_interrupt_classification)

    interrupt_ctx = %{ctx | opts: interrupt_opts}
    downstream_ctx = %{ctx | opts: drop_classifier_resume_opts(ctx.opts)}

    with {:ok, router_context} <- Router.route_context(ctx.input, interrupt_ctx),
         {:ok, %Spectre.Route{rule: %Spectre.Rule{global?: true}} = route} <-
           Router.route_from_context(router_context) do
      Spectre.Runner.run(route, %{
        downstream_ctx
        | input: router_context.input,
          route: route
      })
    else
      {:inference, %PreparedInference{} = prepared} -> {:inference, prepared}
      {:error, {:journal_append_failed, _reason} = failure} -> {:error, failure}
      {:error, {:invalid_journal_configuration, _reason} = failure} -> {:error, failure}
      _no_interrupt -> Policy.resume(downstream_ctx.input, downstream_ctx)
    end
  end

  defp drop_classifier_resume_opts(opts) do
    Keyword.drop(opts, [
      :inference_classifier_response,
      :inference_classifier_descriptor,
      :inference_request_id
    ])
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

    result =
      result
      |> Map.put(:input, input)
      |> put_instance_lifecycle_run_id(opts, run.id)

    step_id =
      get_in(result.metadata, [:runtime_identity, :turn_id])
      |> then(&(&1 || Keyword.get(opts, :turn_id)))
      |> Value.logical_id("step")
      |> Kernel.||(Spectre.Identity.uuid7())

    base = %{
      run
      | input: input,
        start_continuation: nil,
        inference_continuation: nil,
        result: result,
        state: State.new(result.state),
        revision: revision,
        step_id: step_id,
        waiting: nil,
        last_error: nil
    }

    awaitable = Result.boundary_awaitable(result)
    effect = Result.executable_effect(result)

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
      definition_ref: run.definition_ref,
      activation_generation: run.activation_generation,
      authority_epoch: run.authority_epoch,
      closure_digest: run.closure_digest,
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
    |> Keyword.put(:definition_ref, run.definition_ref)
    |> Keyword.put(:activation_generation, run.activation_generation)
    |> Keyword.put(:authority_epoch, run.authority_epoch)
    |> Keyword.put(:closure_digest, run.closure_digest)
  end

  @spec fail_run_step(Run.t(), term(), keyword(), atom()) :: step_result()
  defp fail_run_step(%Run{} = run, reason, opts, event) do
    result = committed_result(reason) || run.result

    failed = %{
      run
      | status: :failed,
        cursor: :complete,
        start_continuation: nil,
        inference_continuation: nil,
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

  defp legacy_result({:dispatch, %Invocation{}, %Run{}, _binding}),
    do: {:error, :inference_dispatch_requires_agent_instance}

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
        step_id: run.step_id,
        definition_ref: run.definition_ref,
        activation_generation: run.activation_generation,
        authority_epoch: run.authority_epoch,
        closure_digest: run.closure_digest
      },
      journal_opts
    )
  end

  @spec step_run(step_result()) :: Run.t()
  defp step_run({:continue, %Run{} = run}), do: run
  defp step_run({:dispatch, %Invocation{}, %Run{} = run, %PreparedInference{}}), do: run
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

  defp outcome_event({:dispatch, %Invocation{}, %Run{}, %PreparedInference{}}),
    do: :run_awaiting

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

  @spec policy_resolution_rejection?(term()) :: boolean()
  defp policy_resolution_rejection?(:no_open_policy), do: true
  defp policy_resolution_rejection?({:unknown_policy, _name}), do: true

  defp policy_resolution_rejection?({:unknown_policy_resolution_label, _name, _kind, _label}),
    do: true

  defp policy_resolution_rejection?({:invalid_policy_resolution, _resolution}), do: true
  defp policy_resolution_rejection?({:invalid_policy_resolution, _id, _resolution}), do: true

  defp policy_resolution_rejection?({:policy_resolution_source_not_allowed, _id, _to, _from}),
    do: true

  defp policy_resolution_rejection?({:external_policy_requires_awaitable_id, _id}), do: true

  defp policy_resolution_rejection?({:policy_awaitable_not_found, _id}), do: true
  defp policy_resolution_rejection?({:policy_awaitable_kind_mismatch, _id, _kind}), do: true
  defp policy_resolution_rejection?({:policy_awaitable_not_open, _id, _status}), do: true
  defp policy_resolution_rejection?({:policy_awaitable_not_owned, _id, _run_id}), do: true
  defp policy_resolution_rejection?({:invalid_policy_resolver, _id, _resolver}), do: true
  defp policy_resolution_rejection?(_reason), do: false

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
  defp command_kind({kind, _value, _more, _last}) when is_atom(kind), do: kind
  defp command_kind(_command), do: :unknown

  @spec definition_config(module()) :: keyword()
  defp definition_config(agent), do: Definition.fetch!(agent).config

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
    |> maybe_put_config(config, :approval_pending_reply)
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
         :ok <- Input.validate(input),
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

  @spec instance_lifecycle_run_id(keyword()) :: String.t() | nil
  defp instance_lifecycle_run_id(opts) when is_list(opts) do
    if Keyword.get(opts, :instance_run_lifecycle?, false),
      do: Keyword.get(opts, :run_id),
      else: nil
  end

  @spec put_instance_lifecycle_run_id(Result.t(), keyword(), String.t()) :: Result.t()
  defp put_instance_lifecycle_run_id(%Result{} = result, opts, run_id) do
    if Keyword.get(opts, :instance_run_lifecycle?, false) do
      %{result | metadata: Map.put(result.metadata, :lifecycle_run_id, run_id)}
    else
      result
    end
  end

  @spec record_history(Result.t(), Context.t()) :: Result.t()
  defp record_history(%Result{} = result, %Context{agent: agent, opts: opts}) do
    configured_limit = Keyword.get(definition_config(agent), :history, 50)

    limit =
      opts
      |> Keyword.get(:chat_history_limit, configured_limit)
      |> normalize_history_limit(configured_limit)

    summarizer =
      Keyword.get(
        opts,
        :history_summary,
        Keyword.get(opts, :chat_summary, Keyword.get(definition_config(agent), :history_summary))
      )

    state =
      result.state
      |> summarize_evicted_history(limit, summarizer)
      |> State.record_turn(result.input, result, limit)

    %{result | state: state}
  end

  defp normalize_history_limit(value, _fallback) when value in [nil, false, 0], do: value
  defp normalize_history_limit(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_history_limit(_invalid, fallback)
       when fallback in [nil, false, 0],
       do: fallback

  defp normalize_history_limit(_invalid, fallback)
       when is_integer(fallback) and fallback > 0,
       do: fallback

  defp normalize_history_limit(_invalid, _fallback), do: 50

  # Folds the entries about to fall out of the history window into a rolling
  # summary before `State.record_turn/4` drops them. A failing summarizer keeps
  # the previous summary so history recording never blocks the turn.
  @spec summarize_evicted_history(State.t(), pos_integer() | false | nil, term()) :: State.t()
  defp summarize_evicted_history(%State{} = state, limit, summarizer)
       when is_integer(limit) and limit > 0 and not is_nil(summarizer) do
    history = Map.get(state.data, :chat_history, [])
    evicted_count = max(length(history) + 1 - limit, 0)

    case Enum.take(history, evicted_count) do
      [] ->
        state

      evicted ->
        current = Map.get(state.data, :chat_summary)

        case run_summarizer(summarizer, current, evicted) do
          {:ok, summary} when is_binary(summary) ->
            %{state | data: Map.put(state.data, :chat_summary, summary)}

          _error_or_invalid ->
            state
        end
    end
  end

  defp summarize_evicted_history(%State{} = state, _limit, _summarizer), do: state

  @spec run_summarizer(term(), String.t() | nil, [map()]) :: {:ok, String.t()} | :error
  defp run_summarizer({module, function}, current, evicted)
       when is_atom(module) and is_atom(function) do
    normalize_summary(apply(module, function, [current, evicted]))
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp run_summarizer(fun, current, evicted) when is_function(fun, 2) do
    normalize_summary(fun.(current, evicted))
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp run_summarizer(_summarizer, _current, _evicted), do: :error

  @spec normalize_summary(term()) :: {:ok, String.t()} | :error
  defp normalize_summary(summary) when is_binary(summary), do: {:ok, summary}
  defp normalize_summary({:ok, summary}) when is_binary(summary), do: {:ok, summary}
  defp normalize_summary(_other), do: :error

  @spec policy_resolution_input(Result.t(), keyword()) :: Input.t()
  defp policy_resolution_input(%Result{} = result, opts) do
    case Keyword.get(opts, :input, result.input) do
      %Input{} = input -> input
      nil -> Input.new("")
      input -> Input.new(input)
    end
  end

  @spec addressed_policy_resolution_input(keyword()) :: Input.t()
  defp addressed_policy_resolution_input(opts) do
    case Keyword.get(opts, :input) do
      %Input{} = input ->
        input

      nil ->
        Input.new(%{
          text: "",
          meta: Map.take(Map.new(opts), [:conversation_id])
        })

      input ->
        Input.new(input)
    end
  end

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
end
