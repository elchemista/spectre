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
      restart: Keyword.get(opts, :restart, :temporary),
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
  Returns the current in-memory Spectre state.

      %Spectre.State{} = Spectre.Session.state(session)
  """
  @spec state(GenServer.server()) :: State.t()
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Replaces the current in-memory state.

      :ok = Spectre.Session.reset(session, %Spectre.State{})
  """
  @spec reset(GenServer.server(), State.t() | map() | keyword()) :: :ok
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

    state = restore_initial_state(agent, opts, base_opts)
    idle_timeout = idle_timeout(agent, opts, base_opts)

    data = %{
      agent: agent,
      base_opts: base_opts,
      state: state,
      last_result: nil,
      idle_timeout: idle_timeout,
      idle_timer: nil
    }

    {:ok, arm_idle_timer(data)}
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
        {:reply, {:error, reason}, arm_idle_timer(data)}
    end
  end

  def handle_call(:state, _from, data), do: {:reply, data.state, arm_idle_timer(data)}

  def handle_call({:reset, state}, _from, data) do
    data = data |> Map.merge(%{state: State.new(state), last_result: nil}) |> arm_idle_timer()
    {:reply, :ok, data}
  end

  @impl GenServer
  def handle_info(:idle_shutdown, data), do: {:stop, :normal, %{data | idle_timer: nil}}

  @spec restore_initial_state(module(), keyword(), keyword()) :: State.t()
  defp restore_initial_state(agent, opts, base_opts) do
    if Keyword.has_key?(opts, :state) do
      opts
      |> Keyword.get(:state)
      |> State.new()
      |> maybe_put_conversation_id(Keyword.get(base_opts, :conversation_id))
    else
      case Spectre.Runtime.restore_state(agent, base_opts) do
        {:ok, %State{} = state} ->
          state

        {:error, _reason} ->
          maybe_put_conversation_id(%State{}, Keyword.get(base_opts, :conversation_id))
      end
    end
  end

  @spec idle_timeout(module(), keyword(), keyword()) :: timeout() | false | nil
  defp idle_timeout(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    Keyword.get(opts, :idle) ||
      Keyword.get(opts, :shutdown) ||
      Keyword.get(base_opts, :idle) ||
      Keyword.get(base_opts, :shutdown) ||
      Keyword.get(config, :idle) ||
      Keyword.get(config, :shutdown)
  end

  @spec arm_idle_timer(map()) :: map()
  defp arm_idle_timer(%{idle_timer: ref} = data) when is_reference(ref) do
    Process.cancel_timer(ref)
    arm_idle_timer(%{data | idle_timer: nil})
  end

  defp arm_idle_timer(%{idle_timeout: timeout} = data) when is_integer(timeout) and timeout > 0 do
    %{data | idle_timer: Process.send_after(self(), :idle_shutdown, timeout)}
  end

  defp arm_idle_timer(data), do: data

  @spec maybe_put_conversation_id(State.t(), term()) :: State.t()
  defp maybe_put_conversation_id(%State{} = state, nil), do: state

  defp maybe_put_conversation_id(%State{} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}
end
