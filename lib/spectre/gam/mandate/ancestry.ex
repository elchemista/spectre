defmodule Spectre.GAM.Mandate.Ancestry do
  @moduledoc """
  Pure traversal of the current typed Mandate lineage.

  The caller supplies the exact indexes derived by the governed-act fold. This
  module neither decodes records nor tolerates alternate key shapes: a missing
  ancestor, malformed index entry or cycle is a history error, never an
  implicit revocation decision.
  """

  alias Spectre.GAM.Mandate
  alias Spectre.GAM.Mandate.Revocation

  @type mandates :: %{optional(String.t()) => Mandate.t()}
  @type revocations :: %{optional(String.t()) => Revocation.t()}
  @type status :: :current | {:revoked, :direct | :ancestor, String.t()}

  @doc "Checks direct and cascading revocation without guessing through an invalid lineage."
  @spec revoked?(mandates(), revocations(), Mandate.t(), integer()) ::
          {:ok, boolean()} | {:error, term()}
  def revoked?(mandates, revocations, %Mandate{} = mandate, time)
      when is_map(mandates) and is_map(revocations) and is_integer(time) do
    with {:ok, status} <- status(mandates, revocations, mandate, time) do
      {:ok, status != :current}
    end
  end

  def revoked?(_mandates, _revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Returns the exact Mandate in the lineage whose recorded revocation applies."
  @spec status(mandates(), revocations(), Mandate.t(), integer()) ::
          {:ok, status()} | {:error, term()}
  def status(mandates, revocations, %Mandate{} = mandate, time)
      when is_map(mandates) and is_map(revocations) and is_integer(time) do
    with {:ok, lineage} <- lineage(mandates, mandate) do
      status_in_lineage(lineage, revocations, time)
    end
  end

  def status(_mandates, _revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc false
  @spec status_in_lineage([Mandate.t(), ...], revocations(), integer()) ::
          {:ok, status()} | {:error, term()}
  def status_in_lineage([%Mandate{} = mandate | ancestors], revocations, time)
      when is_map(revocations) and is_integer(time) do
    with {:ok, direct?} <- local_revoked?(Map.get(revocations, mandate.ref), mandate.ref, time) do
      if direct?,
        do: {:ok, {:revoked, :direct, mandate.ref}},
        else: cascade_status_in_lineage(ancestors, revocations, time)
    end
  end

  def status_in_lineage(_lineage, _revocations, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Checks only the Mandate's own revocation record, excluding ancestors."
  @spec directly_revoked?(revocations(), Mandate.t(), integer()) ::
          {:ok, boolean()} | {:error, term()}
  def directly_revoked?(revocations, %Mandate{} = mandate, time)
      when is_map(revocations) and is_integer(time),
      do: local_revoked?(Map.get(revocations, mandate.ref), mandate.ref, time)

  def directly_revoked?(_revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Returns whether a Mandate is expired or revoked at the supplied trusted time."
  @spec terminal?(mandates(), revocations(), Mandate.t(), integer()) ::
          {:ok, boolean()} | {:error, term()}
  def terminal?(mandates, revocations, %Mandate{} = mandate, time)
      when is_map(mandates) and is_map(revocations) and is_integer(time) do
    if time >= mandate.expires_at,
      do: {:ok, true},
      else: revoked?(mandates, revocations, mandate, time)
  end

  def terminal?(_mandates, _revocations, _mandate, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Checks whether a Mandate is the target or descends from it."
  @spec descendant?(mandates(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def descendant?(mandates, mandate_ref, ancestor_ref)
      when is_map(mandates) and is_binary(mandate_ref) and mandate_ref != "" and
             is_binary(ancestor_ref) and ancestor_ref != "" do
    descendant?(mandates, mandate_ref, ancestor_ref, %{})
  end

  def descendant?(_mandates, _mandate_ref, _ancestor_ref),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Checks whether an authority change affects a Mandate."
  @spec affected_by?(mandates(), String.t(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, term()}
  def affected_by?(_mandates, mandate_ref, mandate_ref, _cascade?), do: {:ok, true}
  def affected_by?(_mandates, _mandate_ref, _target_ref, false), do: {:ok, false}

  def affected_by?(mandates, mandate_ref, target_ref, true),
    do: descendant?(mandates, mandate_ref, target_ref)

  def affected_by?(_mandates, _mandate_ref, _target_ref, _cascade?),
    do: {:error, :invalid_mandate_ancestry_input}

  @doc "Returns the Mandate and each typed ancestor in leaf-to-root order."
  @spec lineage(mandates(), Mandate.t()) :: {:ok, [Mandate.t()]} | {:error, term()}
  def lineage(mandates, %Mandate{} = mandate) when is_map(mandates) do
    collect_lineage(mandates, mandate, %{}, [])
  end

  def lineage(_mandates, _mandate), do: {:error, :invalid_mandate_ancestry_input}

  @doc """
  Selects named Mandates and their complete ancestry without unrelated branches.

  Selection does not validate or repair the graph. Cycles and malformed records
  remain visible to `lineage/2`; a missing parent remains missing. This prevents
  a narrowed read from accidentally turning invalid ancestry into a new root.
  """
  @spec select(mandates(), [String.t()]) :: mandates()
  def select(mandates, refs) when is_map(mandates) and is_list(refs),
    do: select(mandates, refs, %{}, %{})

  # These maps track visits only; they are not an authority index. Missing and
  # malformed nodes must still count as visited so narrowing always terminates.

  defp select(_mandates, [], _seen, selected), do: selected

  defp select(mandates, [ref | rest], seen, selected) do
    if Map.has_key?(seen, ref) do
      select(mandates, rest, seen, selected)
    else
      seen = Map.put(seen, ref, true)

      case Map.fetch(mandates, ref) do
        {:ok, %Mandate{parent_ref: parent} = mandate} ->
          select(mandates, List.wrap(parent) ++ rest, seen, Map.put(selected, ref, mandate))

        {:ok, invalid} ->
          select(mandates, rest, seen, Map.put(selected, ref, invalid))

        :error ->
          select(mandates, rest, seen, selected)
      end
    end
  end

  defp cascade_status_in_lineage([], _revocations, _time), do: {:ok, :current}

  defp cascade_status_in_lineage([%Mandate{} = parent | ancestors], revocations, time) do
    with {:ok, revoked?} <-
           local_revoked?(Map.get(revocations, parent.ref), parent.ref, time) do
      if revoked? and parent.revocation["mode"] == :cascade,
        do: {:ok, {:revoked, :ancestor, parent.ref}},
        else: cascade_status_in_lineage(ancestors, revocations, time)
    end
  end

  defp cascade_status_in_lineage(_invalid, _revocations, _time),
    do: {:error, :invalid_mandate_ancestry_input}

  defp descendant?(_mandates, target_ref, target_ref, _visited), do: {:ok, true}

  defp descendant?(mandates, mandate_ref, ancestor_ref, visited) do
    if Map.has_key?(visited, mandate_ref) do
      {:error, {:mandate_ancestry_cycle, mandate_ref}}
    else
      case Map.fetch(mandates, mandate_ref) do
        {:ok, %Mandate{ref: ^mandate_ref, parent_ref: nil}} ->
          {:ok, false}

        {:ok, %Mandate{ref: ^mandate_ref, parent_ref: parent_ref}}
        when is_binary(parent_ref) and parent_ref != "" ->
          descendant?(
            mandates,
            parent_ref,
            ancestor_ref,
            Map.put(visited, mandate_ref, true)
          )

        {:ok, %Mandate{ref: ^mandate_ref, parent_ref: invalid}} ->
          {:error, {:invalid_mandate_parent_ref, invalid}}

        {:ok, _invalid} ->
          {:error, {:invalid_mandate_ancestor, mandate_ref}}

        :error ->
          {:error, {:mandate_not_found, mandate_ref}}
      end
    end
  end

  defp fetch_parent(mandates, ref) do
    case Map.fetch(mandates, ref) do
      {:ok, %Mandate{ref: ^ref} = parent} -> {:ok, parent}
      {:ok, _invalid} -> {:error, {:invalid_mandate_ancestor, ref}}
      :error -> {:error, {:mandate_ancestor_missing, ref}}
    end
  end

  defp collect_lineage(mandates, %Mandate{} = mandate, visited, lineage) do
    cond do
      Map.has_key?(visited, mandate.ref) ->
        {:error, {:mandate_ancestry_cycle, mandate.ref}}

      is_nil(mandate.parent_ref) ->
        {:ok, Enum.reverse([mandate | lineage])}

      not present_ref?(mandate.parent_ref) ->
        {:error, {:invalid_mandate_parent_ref, mandate.parent_ref}}

      true ->
        with {:ok, parent} <- fetch_parent(mandates, mandate.parent_ref) do
          collect_lineage(
            mandates,
            parent,
            Map.put(visited, mandate.ref, true),
            [mandate | lineage]
          )
        end
    end
  end

  defp local_revoked?(nil, _ref, _time), do: {:ok, false}

  defp local_revoked?(%Revocation{effective_at: effective_at}, _ref, time),
    do: {:ok, time >= effective_at}

  defp local_revoked?(_revocation, ref, _time),
    do: {:error, {:invalid_mandate_revocation, ref}}

  defp present_ref?(ref), do: is_binary(ref) and ref != ""
end
