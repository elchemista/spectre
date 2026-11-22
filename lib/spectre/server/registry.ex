defmodule Spectre.Server.Registry do
  @moduledoc """
  Race-safe local ownership for a declarative Agent and canonical Subject.

  The host supervises `{Registry, keys: :unique, name: Spectre.Server.Registry}`.
  A subject-scoped Server uses this registry as its process name, so concurrent
  summons share one OTP owner. The key identifies ownership; it is not proof of
  the user's authentication or permission to act for the Subject.
  """
  alias Spectre.AgentRef
  alias Spectre.Subject

  @type key :: {String.t(), String.t()}

  @doc "Returns the stable Agent/Subject ownership key, independent of code version."
  @spec key(module() | AgentRef.t(), term()) :: key()
  def key(agent, subject) do
    {agent |> AgentRef.new() |> AgentRef.key(), subject |> Subject.new() |> Subject.key()}
  end

  @doc "Returns the canonical OTP name for the subject-scoped Server."
  @spec via(module() | AgentRef.t(), term(), atom()) :: {:via, Registry, {atom(), key()}}
  def via(agent, subject, registry \\ __MODULE__),
    do: {:via, Registry, {registry, key(agent, subject)}}

  @doc "Looks up the live local owner without starting a conversation."
  @spec lookup(module() | AgentRef.t(), term(), atom()) ::
          {:ok, pid()} | {:error, :server_not_found | :server_registry_unavailable}
  def lookup(agent, subject, registry \\ __MODULE__),
    do: lookup_key(registry, key(agent, subject))

  defp lookup_key(registry, key) do
    case Registry.lookup(registry, key) do
      [{pid, _}] -> live_owner(pid)
      [] -> {:error, :server_not_found}
    end
  rescue
    ArgumentError -> {:error, :server_registry_unavailable}
  end

  defp live_owner(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :server_not_found}
  end

  @doc """
  Starts or returns the unique supervised Server for an Agent and Subject.

  `supervisor` is the running DynamicSupervisor. Additional options are passed
  to `Spectre.Server.start_link/1`. Set `:server_registry` to use a custom
  local Registry. An explicit `:name` must match `via/3` for the same owner.
  """
  @spec ensure_started(Supervisor.supervisor(), module(), term(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(supervisor, agent, subject, opts \\ []) do
    registry = Keyword.get(opts, :server_registry, __MODULE__)
    subject = Subject.new(subject)
    name = via(agent, subject, registry)

    case Keyword.get(opts, :name, name) do
      ^name -> ensure_owner(supervisor, agent, subject, name, registry, opts)
      _ -> {:error, :subject_server_name_conflict}
    end
  end

  defp ensure_owner(supervisor, agent, subject, name, registry, opts) do
    case lookup(agent, subject, registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, :server_not_found} -> start_owner(supervisor, agent, subject, name, registry, opts)
      error -> error
    end
  end

  defp start_owner(supervisor, agent, subject, name, registry, opts) do
    opts =
      opts
      |> Keyword.put(:agent, agent)
      |> Keyword.put(:subject, subject)
      |> Keyword.put(:name, name)

    case DynamicSupervisor.start_child(supervisor, {Spectre.Server, opts}) do
      {:ok, pid} -> {:ok, pid}
      error -> resolve_race(agent, subject, registry, error)
    end
  end

  defp resolve_race(agent, subject, registry, error) do
    case lookup(agent, subject, registry) do
      {:ok, pid} -> {:ok, pid}
      _ -> error
    end
  end
end
