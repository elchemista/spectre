defmodule Spectre.Supervisor do
  @moduledoc """
  Dynamic supervisor for conversation-scoped Spectre sessions.

  Add it to your application supervision tree:

      children = [
        {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
      ]

  Then start sessions as conversations arrive:

      {:ok, pid} =
        Spectre.Supervisor.summon(
          MyApp.SpectreSupervisor,
          MyApp.Agents.ProjectAgent,
          conversation_id: conversation.id,
          opts: [model: &MyApp.LLM.complete/2]
        )
  """

  use DynamicSupervisor

  @type session_option :: Spectre.Session.option()

  @doc """
  Starts the dynamic supervisor for Spectre sessions.

      {:ok, pid} = Spectre.Supervisor.start_link(name: MyApp.SpectreSupervisor)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a supervised Spectre session under `supervisor`.

      {:ok, pid} = Spectre.Supervisor.summon(MySupervisor, MyAgent, conversation_id: "123")
  """
  @spec summon(GenServer.server(), module(), [session_option()]) ::
          DynamicSupervisor.on_start_child()
  def summon(supervisor \\ __MODULE__, agent, opts \\ []) when is_atom(agent) do
    opts = Keyword.put(opts, :agent, agent)
    DynamicSupervisor.start_child(supervisor, {Spectre.Session, opts})
  end

  @doc """
  Stops a supervised Spectre session.

      :ok = Spectre.Supervisor.dismiss(MySupervisor, pid)
  """
  @spec dismiss(GenServer.server(), pid()) :: :ok | {:error, term()}
  def dismiss(supervisor \\ __MODULE__, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end
end
