defmodule Spectre.Mandate.Ancestry do
  @moduledoc false

  @doc "Checks direct and cascading revocation without guessing through an invalid lineage."
  @spec revoked?(map(), map(), map(), integer()) :: {:ok, boolean()} | {:error, term()}
  def revoked?(mandates, revocations, mandate, time)
      when is_map(mandates) and is_map(revocations) and is_map(mandate) and is_integer(time) do
    with {:ok, status} <- status(mandates, revocations, mandate, time) do
      {:ok, status != :current}
    end
  end

  def revoked?(_mandates, _revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @type status :: :current | {:revoked, :direct | :ancestor, String.t()}

  @doc "Returns the exact Mandate in the lineage whose recorded revocation applies."
  @spec status(map(), map(), map(), integer()) :: {:ok, status()} | {:error, term()}
  def status(mandates, revocations, mandate, time)
      when is_map(mandates) and is_map(revocations) and is_map(mandate) and is_integer(time) do
    with {:ok, ref} <- required_ref(mandate, :ref),
         {:ok, direct?} <- local_revoked?(Map.get(revocations, ref), ref, time) do
      if direct? do
        {:ok, {:revoked, :direct, ref}}
      else
        cascade_status(
          mandates,
          revocations,
          field(mandate, :parent_ref),
          time,
          MapSet.new([ref])
        )
      end
    end
  end

  def status(_mandates, _revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Checks only the Mandate's own revocation record, excluding ancestors."
  @spec directly_revoked?(map(), map(), integer()) :: {:ok, boolean()} | {:error, term()}
  def directly_revoked?(revocations, mandate, time)
      when is_map(revocations) and is_map(mandate) and is_integer(time) do
    with {:ok, ref} <- required_ref(mandate, :ref),
         do: local_revoked?(Map.get(revocations, ref), ref, time)
  end

  def directly_revoked?(_revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  defp cascade_status(_mandates, _revocations, nil, _time, _visited), do: {:ok, :current}

  defp cascade_status(mandates, revocations, parent_ref, time, visited) do
    cond do
      not present_ref?(parent_ref) ->
        {:error, {:invalid_mandate_parent_ref, parent_ref}}

      MapSet.member?(visited, parent_ref) ->
        {:error, {:mandate_ancestry_cycle, parent_ref}}

      true ->
        with {:ok, parent} <- fetch_parent(mandates, parent_ref),
             {:ok, parent_ref} <- required_ref(parent, :ref),
             {:ok, revoked?} <- local_revoked?(Map.get(revocations, parent_ref), parent_ref, time),
             {:ok, cascade?} <- cascade_mode(parent) do
          if revoked? and cascade? do
            {:ok, {:revoked, :ancestor, parent_ref}}
          else
            cascade_status(
              mandates,
              revocations,
              field(parent, :parent_ref),
              time,
              MapSet.put(visited, parent_ref)
            )
          end
        end
    end
  end

  defp fetch_parent(mandates, ref) do
    case Map.fetch(mandates, ref) do
      {:ok, parent} when is_map(parent) -> {:ok, parent}
      {:ok, _invalid} -> {:error, {:invalid_mandate_ancestor, ref}}
      :error -> {:error, {:mandate_ancestor_missing, ref}}
    end
  end

  defp local_revoked?(nil, _ref, _time), do: {:ok, false}

  defp local_revoked?(revocation, ref, time) when is_map(revocation) do
    case field(revocation, :effective_at) do
      effective_at when is_integer(effective_at) -> {:ok, time >= effective_at}
      _invalid -> {:error, {:invalid_mandate_revocation, ref}}
    end
  end

  defp local_revoked?(_revocation, ref, _time),
    do: {:error, {:invalid_mandate_revocation, ref}}

  defp cascade_mode(mandate) do
    mode = mandate |> field(:revocation, %{}) |> field(:mode)

    case mode do
      :cascade -> {:ok, true}
      "cascade" -> {:ok, true}
      :retained_controller -> {:ok, false}
      "retained_controller" -> {:ok, false}
      _invalid -> {:error, {:invalid_mandate_revocation_mode, field(mandate, :ref)}}
    end
  end

  defp required_ref(record, key) do
    case field(record, key) do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _invalid -> {:error, {:invalid_mandate_ref, key}}
    end
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp field(_value, _key, default), do: default

  defp present_ref?(ref), do: is_binary(ref) and ref != ""
end
