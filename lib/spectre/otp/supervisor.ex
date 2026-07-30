defmodule Spectre.Supervisor do
  @moduledoc """
  Dynamic supervisor for Spectre Sessions and Agent Instances.

  Add it to your application supervision tree:

      children = [
        {Spectre.Supervisor, name: MyApp.SpectreSupervisor}
      ]

  Then start a subject-scoped Agent Instance:

      {:ok, pid} =
        Spectre.Supervisor.summon(
          MyApp.SpectreSupervisor,
          MyApp.Agents.ProjectAgent,
          subject: account.id,
          opts: [model: &MyApp.LLM.complete/2]
        )

  Calls without `:subject` retain the legacy conversation-scoped
  `Spectre.Session` behaviour.
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
  Starts a supervised Spectre Instance or legacy Session under `supervisor`.

      {:ok, pid} = Spectre.Supervisor.summon(MySupervisor, MyAgent, subject: account.id)
  """
  @spec summon(GenServer.server(), module(), [session_option() | Spectre.Instance.option()]) ::
          DynamicSupervisor.on_start_child()
  def summon(supervisor \\ __MODULE__, agent, opts \\ []) when is_atom(agent) do
    case Keyword.fetch(opts, :subject) do
      {:ok, subject} ->
        Spectre.Instance.Registry.ensure_started(supervisor, agent, subject, opts)

      :error ->
        opts = Keyword.put(opts, :agent, agent)
        DynamicSupervisor.start_child(supervisor, {Spectre.Session, opts})
    end
  end

  @doc """
  Starts or returns the unique Instance for `agent + subject`.
  """
  @spec instance(
          GenServer.server(),
          module() | Spectre.AgentRef.t(),
          Spectre.Subject.t() | term(),
          keyword()
        ) :: DynamicSupervisor.on_start_child()
  def instance(supervisor \\ __MODULE__, agent, subject, opts \\ []) do
    Spectre.Instance.Registry.ensure_started(supervisor, agent, subject, opts)
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
