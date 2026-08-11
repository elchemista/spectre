defmodule Spectre.Morph.Surface.MountIndex do
  @moduledoc """
  Indexes canonical Skill mounts and derives their parent-to-candidate diff.

  Compiled mount identifiers may be atoms while JSON-authored identifiers are
  strings. This module normalizes existing atom identifiers to strings without
  ever converting runtime strings into atoms.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Morph.StableName
  alias Spectre.Morph.Surface.Mutation

  @type mount_id :: StableName.t()
  @type index :: %{optional(mount_id()) => map()}

  @doc false
  @spec build(Canonical.t()) :: {:ok, index()} | {:error, term()}
  def build(%Canonical{} = canonical) do
    with {:ok, component} <- Canonical.fetch_component(canonical, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- value(payload, :mounts, []) do
      index_mounts(mounts)
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_morph_surface_skill_component}
    end
  end

  @doc false
  @spec mutations(Canonical.t(), Canonical.t()) ::
          {:ok, [Mutation.t()]} | {:error, term()}
  def mutations(%Canonical{} = parent, %Canonical{} = candidate) do
    with {:ok, parent_mounts} <- build(parent),
         {:ok, candidate_mounts} <- build(candidate) do
      {:ok, mutation_diff(parent_mounts, candidate_mounts)}
    end
  end

  @doc false
  @spec fetch(index(), term()) :: {:ok, map()} | :error
  def fetch(index, mount_id) when is_map(index) do
    case StableName.normalize(mount_id) do
      {:ok, normalized} -> Map.fetch(index, normalized)
      {:error, :invalid_stable_name} -> :error
    end
  end

  @spec index_mounts([map()]) :: {:ok, index()} | {:error, term()}
  defp index_mounts(mounts) do
    Enum.reduce_while(mounts, {:ok, %{}}, &index_mount/2)
  end

  @spec index_mount(map(), {:ok, index()}) ::
          {:cont, {:ok, index()}} | {:halt, {:error, term()}}
  defp index_mount(mount, {:ok, mounts}) when is_map(mount) do
    raw_mount_id = value(mount, :id)

    with {:ok, mount_id} <- canonical_mount_id(raw_mount_id),
         false <- Map.has_key?(mounts, mount_id) do
      {:cont, {:ok, Map.put(mounts, mount_id, mount)}}
    else
      true -> {:halt, {:error, {:duplicate_morph_surface_mount, raw_mount_id}}}
      {:error, _reason} -> {:halt, {:error, {:invalid_morph_surface_mount, raw_mount_id}}}
    end
  end

  defp index_mount(_mount, {:ok, _mounts}),
    do: {:halt, {:error, {:invalid_morph_surface_mount, nil}}}

  @spec mutation_diff(index(), index()) :: [Mutation.t()]
  defp mutation_diff(parent_mounts, candidate_mounts) do
    parent_mounts
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(MapSet.new(Map.keys(candidate_mounts)))
    |> Enum.sort()
    |> Enum.reduce([], fn mount_id, mutations ->
      case mount_mutation(mount_id, parent_mounts, candidate_mounts) do
        nil -> mutations
        mutation -> [mutation | mutations]
      end
    end)
    |> Enum.reverse()
  end

  @spec mount_mutation(mount_id(), index(), index()) :: Mutation.t() | nil
  defp mount_mutation(mount_id, parent_mounts, candidate_mounts) do
    parent = Map.get(parent_mounts, mount_id)
    candidate = Map.get(candidate_mounts, mount_id)

    mutation(mount_id, parent, candidate)
  end

  @spec mutation(mount_id(), map() | nil, map() | nil) :: Mutation.t() | nil
  defp mutation(_mount_id, nil, nil), do: nil
  defp mutation(_mount_id, same, same), do: nil

  defp mutation(mount_id, nil, candidate) do
    %Mutation{
      mount_id: mount_id,
      operation: :mount_skill,
      parent: nil,
      candidate: candidate
    }
  end

  defp mutation(mount_id, parent, nil) do
    %Mutation{
      mount_id: mount_id,
      operation: :disable_skill,
      parent: parent,
      candidate: nil
    }
  end

  defp mutation(mount_id, parent, candidate) do
    %Mutation{
      mount_id: mount_id,
      operation: :replace_skill,
      parent: parent,
      candidate: candidate
    }
  end

  @spec canonical_mount_id(term()) :: {:ok, mount_id()} | {:error, :invalid_mount_id}
  defp canonical_mount_id(value) do
    case StableName.normalize(value) do
      {:ok, mount_id} -> {:ok, mount_id}
      {:error, :invalid_stable_name} -> {:error, :invalid_mount_id}
    end
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
