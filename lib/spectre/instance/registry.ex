defmodule Spectre.Instance.Registry do
  @moduledoc """
  Race-safe local lookup for Agent Instances.

  Registry entries are keyed only by `Spectre.Instance.Ref`; process names,
  channel identities, and conversation ids are never used as identity proof.
  """

  alias Spectre.Instance
  alias Spectre.Instance.Ref

  @doc """
  Returns the live local Instance for an Agent and Subject.
  """
  @spec lookup(module() | Spectre.AgentRef.t(), Spectre.Subject.t() | term(), atom()) ::
          {:ok, pid()} | {:error, :instance_not_found | :instance_in_maintenance}
  def lookup(agent, subject, registry \\ __MODULE__) do
    ref = Ref.new(agent, subject)

    case Registry.lookup(registry, ref.key) do
      [{_pid, {:instance_maintenance, _purpose, _token}}] ->
        {:error, :instance_in_maintenance}

      [{pid, _value}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        {:error, :instance_not_found}
    end
  end

  @doc """
  Returns the `:via` name for a logical Instance reference.
  """
  @spec via(Ref.t(), atom()) :: {:via, Registry, {atom(), String.t(), Ref.t()}}
  def via(%Ref{} = ref, registry \\ __MODULE__) do
    {:via, Registry, {registry, ref.key, ref}}
  end

  @doc """
  Starts or returns the unique supervised Instance for an Agent and Subject.
  """
  @spec ensure_started(
          GenServer.server(),
          module() | Spectre.AgentRef.t(),
          Spectre.Subject.t() | term(),
          keyword()
        ) :: DynamicSupervisor.on_start_child()
  def ensure_started(supervisor, agent, subject, opts \\ []) do
    registry = Keyword.get(opts, :registry, __MODULE__)
    ref = Ref.new(agent, subject, Keyword.take(opts, [:agent_id]))

    case lookup_ref(ref, registry) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :instance_not_found} ->
        child_opts =
          opts
          |> Keyword.put(:agent, ref.agent_ref.definition)
          |> Keyword.put(:agent_ref, ref.agent_ref)
          |> Keyword.put(:subject, ref.subject)
          |> Keyword.put(:registry, registry)

        case DynamicSupervisor.start_child(supervisor, {Instance, child_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:ok, pid, info} -> {:ok, pid, info}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = error -> resolve_start_race(ref, registry, error)
          :ignore -> :ignore
        end

      {:error, :instance_in_maintenance} = error ->
        error
    end
  end

  @doc false
  @spec lookup_ref(Ref.t(), atom()) ::
          {:ok, pid()} | {:error, :instance_not_found | :instance_in_maintenance}
  def lookup_ref(%Ref{} = ref, registry \\ __MODULE__) do
    case Registry.lookup(registry, ref.key) do
      [{_pid, {:instance_maintenance, _purpose, _token}}] ->
        {:error, :instance_in_maintenance}

      [{pid, _value}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        {:error, :instance_not_found}
    end
  end

  @doc false
  @spec reserve(Ref.t(), atom(), atom()) :: {:ok, reference()} | {:error, term()}
  def reserve(%Ref{} = ref, purpose, registry \\ __MODULE__) when is_atom(purpose) do
    token = make_ref()

    case Registry.register(registry, ref.key, {:instance_maintenance, purpose, token}) do
      {:ok, _owner} ->
        {:ok, token}

      {:error, {:already_registered, _pid}} ->
        case lookup_ref(ref, registry) do
          {:ok, _pid} -> {:error, :instance_active}
          {:error, :instance_in_maintenance} -> {:error, :instance_in_maintenance}
          {:error, :instance_not_found} -> {:error, :instance_registry_race}
        end
    end
  rescue
    ArgumentError -> {:error, :instance_registry_unavailable}
  catch
    :exit, _reason -> {:error, :instance_registry_unavailable}
  end

  @doc false
  @spec release_reservation(Ref.t(), reference(), atom()) :: :ok | {:error, term()}
  def release_reservation(%Ref{} = ref, token, registry \\ __MODULE__)
      when is_reference(token) do
    case Registry.lookup(registry, ref.key) do
      [{pid, {:instance_maintenance, _purpose, ^token}}] when pid == self() ->
        Registry.unregister(registry, ref.key)

      _other ->
        {:error, :instance_maintenance_reservation_lost}
    end
  rescue
    ArgumentError -> {:error, :instance_registry_unavailable}
  catch
    :exit, _reason -> {:error, :instance_registry_unavailable}
  end

  defp resolve_start_race(ref, registry, original_error) do
    case lookup_ref(ref, registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, :instance_not_found} -> original_error
      {:error, :instance_in_maintenance} = error -> error
    end
  end
end
