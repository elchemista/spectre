defmodule Spectre.Session do
  @moduledoc """
  Conversation-scoped GenServer for running a Spectre agent under supervision.

  The session keeps the latest `%Spectre.State{}` in process memory and delegates
  each turn to `Spectre.ask/3`. Applications that prefer durable state can
  use a `state MyApp.Store` adapter in the agent DSL; sessions restore from that
  adapter on start when no explicit state is supplied.
  """

  use GenServer

  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.State

  @type option ::
          {:agent, module()}
          | {:state, State.t() | map() | keyword()}
          | {:opts, keyword()}
          | {:name, GenServer.name()}
          | {:conversation_id, term()}
          | {:idle, timeout() | false | nil}
          | {:shutdown, timeout() | false | nil}

  @doc """
  Returns a child spec for a supervised session.

      children = [
        {Spectre.Session,
         agent: MyApp.Agents.ProjectAgent,
         name: MyApp.ProjectAgentSession,
         shutdown: :timer.minutes(10)}
      ]
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, {__MODULE__, Keyword.get(opts, :agent), Keyword.get(opts, :name)})

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }
  end

  @doc """
  Starts a conversation-scoped session process.

      {:ok, pid} = Spectre.Session.start_link(agent: MyApp.Agent)
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Handles one turn through a supervised session.

      {:ok, result} = Spectre.Session.ask(session, "hello")
  """
  @spec ask(GenServer.server(), Input.t() | String.t() | map(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def ask(server, input, opts \\ []) do
    GenServer.call(server, {:handle, input, opts}, Keyword.get(opts, :timeout, :timer.minutes(5)))
  end

  @doc """
  Handles one turn through a supervised session and returns a `%Spectre.Turn{}`.
  """
  @spec turn(GenServer.server(), Input.t() | String.t() | map(), keyword()) ::
          {:ok, Spectre.Turn.t()} | {:error, term()}
  def turn(server, input, opts \\ []) do
    GenServer.call(server, {:turn, input, opts}, Keyword.get(opts, :timeout, :timer.minutes(5)))
  end

  @doc """
  Resolves the session's currently open policy from a trusted host decision.

  The session uses its current state rather than trusting a potentially stale
  state embedded in the supplied result.
  """
  @spec resolve_policy(
          GenServer.server(),
          Result.t(),
          Spectre.Policy.resolution(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  def resolve_policy(server, %Result{} = result, resolution, opts \\ []) do
    GenServer.call(
      server,
      {:resolve_policy, result, resolution, Keyword.drop(opts, [:timeout])},
      Keyword.get(opts, :timeout, :timer.minutes(5))
    )
  end

  @doc """
  Executes the session's current pending effect and commits its terminal state.

  The state embedded in the supplied result is treated as a reference only;
  the Session's current state remains authoritative.
  """
  @spec execute(GenServer.server(), Result.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def execute(server, %Result{} = result, opts \\ []) do
    GenServer.call(
      server,
      {:execute, result, Keyword.drop(opts, [:timeout])},
      Keyword.get(opts, :timeout, :timer.minutes(5))
    )
  end

  @doc """
  Returns the current in-memory Spectre state.

      %Spectre.State{} = Spectre.Session.state(session)
  """
  @spec state(GenServer.server()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Returns the Agent module owned by a supervised session.
  """
  @spec agent(GenServer.server()) :: module()
  def agent(server), do: GenServer.call(server, :agent)

  @doc """
  Replaces the current in-memory state.

      :ok = Spectre.Session.reset(session, %Spectre.State{})
  """
  @spec reset(GenServer.server(), State.t() | map() | keyword()) ::
          :ok | {:error, :instance_busy}
  def reset(server, state \\ %State{}) do
    GenServer.call(server, {:reset, state})
  end

  @impl GenServer
  def init(opts) do
    agent = Keyword.fetch!(opts, :agent)
    conversation_id = Keyword.get(opts, :conversation_id)

    base_opts =
      opts
      |> Keyword.get(:opts, [])
      |> Keyword.put_new(:conversation_id, conversation_id)

    case restore_initial_state(agent, opts, base_opts) do
      {:ok, state} ->
        idle_timeout = idle_timeout(agent, opts, base_opts)

        data = %{
          agent: agent,
          base_opts: base_opts,
          state: state,
          last_result: nil,
          idle_timeout: idle_timeout,
          idle_timer: nil,
          idle_generation: 0
        }

        {:ok, arm_idle_timer(data)}

      {:error, reason} ->
        {:stop, {:state_restore_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:handle, input, opts}, _from, data) do
    runtime_opts =
      data.base_opts
      |> Keyword.merge(Keyword.drop(opts, [:timeout]))
      |> Keyword.put(:state, data.state)

    case Spectre.ask(data.agent, input, runtime_opts) do
      {:ok, %Result{} = result} ->
        state = State.new(result.state)
        data = data |> Map.merge(%{state: state, last_result: result}) |> arm_idle_timer()
        {:reply, {:ok, result}, data}

      {:error, reason} ->
        data = data |> retain_failure_result(reason) |> arm_idle_timer()
        {:reply, {:error, reason}, data}
    end
  end

  def handle_call({:turn, input, opts}, _from, data) do
    runtime_opts =
      data.base_opts
      |> Keyword.merge(Keyword.drop(opts, [:timeout]))
      |> Keyword.put(:state, data.state)

    case Spectre.Turn.run(data.agent, input, runtime_opts) do
      {:ok, %Spectre.Turn{result: %Result{} = result} = turn} ->
        state = State.new(result.state)
        data = data |> Map.merge(%{state: state, last_result: result}) |> arm_idle_timer()
        {:reply, {:ok, turn}, data}

      {:error, reason} ->
        data = data |> retain_failure_result(reason) |> arm_idle_timer()
        {:reply, {:error, reason}, data}
    end
  end

  def handle_call({:resolve_policy, %Result{} = result, resolution, opts}, _from, data) do
    runtime_opts =
      data.base_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:state, data.state)

    result = %{result | state: data.state}

    case Spectre.Runtime.resolve_policy(data.agent, result, resolution, runtime_opts) do
      {:ok, %Result{} = resolved} ->
        data = data |> retain_committed_result(resolved) |> arm_idle_timer()
        {:reply, {:ok, resolved}, data}

      {:error, reason} ->
        data = data |> retain_failure_result(reason) |> arm_idle_timer()
        {:reply, {:error, reason}, data}
    end
  end

  def handle_call({:execute, %Result{} = supplied, opts}, _from, data) do
    runtime_opts = data.base_opts |> Keyword.merge(opts) |> Keyword.put(:state, data.state)

    case prepare_session_execution(supplied, data) do
      {:replay, %Result{} = replayed} ->
        {:reply, {:ok, replayed}, arm_idle_timer(data)}

      {:ok, %Result{} = current} ->
        case Spectre.Runtime.execute(data.agent, current, runtime_opts) do
          {:ok, %Result{} = completed} ->
            data = data |> retain_committed_result(completed) |> arm_idle_timer()
            {:reply, {:ok, completed}, data}

          {:error, reason} ->
            emit_stale_command(reason, data)
            data = data |> retain_failure_result(reason) |> arm_idle_timer()
            {:reply, {:error, reason}, data}
        end

      {:error, reason} ->
        emit_stale_command(reason, data)
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:state, _from, data), do: {:reply, data.state, arm_idle_timer(data)}
  def handle_call(:agent, _from, data), do: {:reply, data.agent, arm_idle_timer(data)}

  def handle_call({:reset, state}, _from, data) do
    data = data |> Map.merge(%{state: State.new(state), last_result: nil}) |> arm_idle_timer()
    {:reply, :ok, data}
  end

  @impl GenServer
  def handle_info({:idle_shutdown, generation}, %{idle_generation: generation} = data) do
    Spectre.Telemetry.emit(
      [:session, :idle_shutdown],
      %{count: 1},
      %{agent: data.agent, generation: generation},
      data.base_opts
    )

    {:stop, :normal, %{data | idle_timer: nil}}
  end

  def handle_info({:idle_shutdown, _stale_generation}, data), do: {:noreply, data}

  # Compatibility with stale messages emitted by pre-generation Session code.
  def handle_info(:idle_shutdown, data), do: {:noreply, data}

  @spec retain_committed_result(map(), Result.t()) :: map()
  defp retain_committed_result(data, %Result{} = result) do
    %{data | state: State.new(result.state), last_result: result}
  end

  @spec retain_failure_result(map(), term()) :: map()
  defp retain_failure_result(data, reason) do
    case failure_result(reason) do
      %Result{} = result -> retain_committed_result(data, result)
      nil -> data
    end
  end

  @spec failure_result(term()) :: Result.t() | nil
  defp failure_result({:memory_persist_failed, _reason, %Result{} = result}), do: result
  defp failure_result({:persistence_ambiguous, _reason, %Result{} = result}), do: result
  defp failure_result({:persistence_journal_failed, _reason, %Result{} = result}), do: result

  defp failure_result({:run_journal_failed, _event, _reason, %Result{} = result}),
    do: result

  defp failure_result(_reason), do: nil

  @spec prepare_session_execution(Result.t(), map()) ::
          {:ok, Result.t()} | {:replay, Result.t()} | {:error, term()}
  defp prepare_session_execution(%Result{} = supplied, data) do
    submitted = Result.pending_effect(supplied)
    current = State.pending_effect(data.state)

    cond do
      is_nil(submitted) and is_nil(current) ->
        {:error, :no_pending_effect}

      is_nil(submitted) ->
        {:error, {:stale_execution_result, :missing_effect}}

      resolved = State.resolved_effect(data.state, submitted.id) ->
        {:replay, replay_result(supplied, data.state, resolved)}

      is_nil(current) ->
        {:error, {:stale_execution_result, submitted.id}}

      current.id != submitted.id ->
        {:error, {:stale_execution_result, submitted.id, current.id}}

      true ->
        metadata = current_persistence_metadata(data, supplied)
        {:ok, %{supplied | state: data.state, metadata: metadata}}
    end
  end

  defp emit_stale_command(reason, data) do
    case reason do
      {:stale_execution_result, _detail} -> emit_stale(data)
      {:stale_execution_result, _submitted, _current} -> emit_stale(data)
      _other -> :ok
    end
  end

  defp emit_stale(data) do
    Spectre.Telemetry.emit(
      [:session, :stale_command],
      %{count: 1},
      %{agent: data.agent, reason: :stale_execution_result, revision: data.state.revision},
      data.base_opts
    )
  end

  @spec current_persistence_metadata(map(), Result.t()) :: map()
  defp current_persistence_metadata(%{last_result: %Result{} = last}, supplied) do
    case get_in(last.metadata, [:state_persistence, :revision]) do
      revision when revision == last.state.revision and revision == supplied.state.revision ->
        Map.put(supplied.metadata, :state_persistence, last.metadata.state_persistence)

      revision when revision == last.state.revision ->
        Map.put(supplied.metadata, :state_persistence, last.metadata.state_persistence)

      _other ->
        supplied.metadata
    end
  end

  defp current_persistence_metadata(_data, supplied), do: supplied.metadata

  @spec replay_result(Result.t(), State.t(), Spectre.Effect.t()) :: Result.t()
  defp replay_result(%Result{} = supplied, %State{} = state, effect) do
    %Result{
      input: supplied.input,
      route: supplied.route,
      state: state,
      effects: [effect],
      reply_text: replay_text(effect),
      events: [
        %{
          type: :effect_already_resolved,
          kind: effect.kind,
          name: effect.name,
          effect_id: effect.id,
          effect: effect
        }
      ],
      metadata: supplied.metadata
    }
  end

  @spec replay_text(Spectre.Effect.t()) :: String.t()
  defp replay_text(effect) do
    case Spectre.Effect.outcome(effect) do
      {:ok, value} when is_binary(value) -> value
      {:ok, value} -> inspect(value)
      _outcome -> ""
    end
  end

  @spec restore_initial_state(module(), keyword(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  defp restore_initial_state(agent, opts, base_opts) do
    if Keyword.has_key?(opts, :state) do
      state =
        opts
        |> Keyword.get(:state)
        |> State.new()
        |> maybe_put_conversation_id(Keyword.get(base_opts, :conversation_id))

      {:ok, state}
    else
      Spectre.Runtime.restore_state(agent, base_opts)
    end
  end

  @spec idle_timeout(module(), keyword(), keyword()) :: timeout() | false | nil
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

  @spec first_configured([{keyword(), atom()}]) :: term()
  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  @spec arm_idle_timer(map()) :: map()
  defp arm_idle_timer(data) do
    if is_reference(data.idle_timer), do: Process.cancel_timer(data.idle_timer)

    generation = data.idle_generation + 1

    timer =
      case data.idle_timeout do
        timeout when is_integer(timeout) and timeout > 0 ->
          Process.send_after(self(), {:idle_shutdown, generation}, timeout)

        _other ->
          nil
      end

    %{data | idle_timer: timer, idle_generation: generation}
  end

  @spec maybe_put_conversation_id(State.t(), term()) :: State.t()
  defp maybe_put_conversation_id(%State{} = state, nil), do: state

  defp maybe_put_conversation_id(%State{} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}
end
