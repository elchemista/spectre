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
          {:ok, pid()} | {:error, :instance_not_found}
  def lookup(agent, subject, registry \\ __MODULE__) do
    ref = Ref.new(agent, subject)

    case Registry.lookup(registry, ref.key) do
      [{pid, _value}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :instance_not_found}
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
    end
  end

  @doc false
  @spec lookup_ref(Ref.t(), atom()) :: {:ok, pid()} | {:error, :instance_not_found}
  def lookup_ref(%Ref{} = ref, registry \\ __MODULE__) do
    case Registry.lookup(registry, ref.key) do
      [{pid, _value}] when is_pid(pid) -> {:ok, pid}
      [] -> {:error, :instance_not_found}
    end
  end

  defp resolve_start_race(ref, registry, original_error) do
    case lookup_ref(ref, registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, :instance_not_found} -> original_error
    end
  end
end
