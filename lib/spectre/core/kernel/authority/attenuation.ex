defmodule Spectre.Kernel.Authority.Attenuation do
  @moduledoc """
  Pure non-amplification checks for Mandate descendants and successors.

  Delegation may only subtract authority and quantitative ceilings. Restriction
  may only narrow a Mandate in place and therefore keeps lineage, roles, Meter
  allocation and revocation policy fixed. Inputs are restored through
  `Spectre.Mandate` once at this boundary; every comparison after that point is
  between typed fields rather than storage-shaped maps.
  """

  alias Spectre.{Condition, Mandate, Row}

  @list_boundaries [
    :executor_refs,
    :executor_contract_refs,
    :scope_refs,
    :subject_refs,
    :target_refs,
    :classes
  ]

  @doc "Verifies that a child Mandate is a subtractive delegation of its parent."
  @spec delegation_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  def delegation_within?(parent, child, time) when is_integer(time) do
    with {:ok, parent} <- normalize(parent, :delegation, :parent),
         {:ok, child} <- normalize(child, :delegation, :child),
         :ok <- delegation_depth_within(parent, child),
         :ok <- current_at(parent, time),
         :ok <- child_parent_matches(parent, child),
         :ok <- child_grantor_matches(parent, child),
         :ok <- child_accountable_matches(parent, child),
         :ok <- list_boundaries_within(parent, child),
         :ok <- child_labels_within(parent, child),
         :ok <- child_row_within(parent, child),
         :ok <- child_purpose_within(parent, child),
         :ok <- child_conditions_within(parent, child),
         :ok <- child_time_within(parent, child),
         :ok <- child_meters_within(parent, child) do
      child_revocation_within(parent, child)
    end
  end

  def delegation_within?(_parent, _child, _time), do: {:error, :invalid_delegation}

  @doc "Verifies that a successor is a strict, non-quantitative restriction."
  @spec restriction_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  def restriction_within?(predecessor, successor, time) when is_integer(time) do
    with {:ok, predecessor} <- normalize(predecessor, :restriction, :predecessor),
         {:ok, successor} <- normalize(successor, :restriction, :successor),
         :ok <- current_at(predecessor, time),
         :ok <- current_at(successor, time),
         :ok <- restriction_revision(predecessor, successor),
         :ok <- restriction_lineage(predecessor, successor),
         :ok <- restriction_roles(predecessor, successor),
         :ok <- list_boundaries_within(predecessor, successor),
         :ok <- child_labels_within(predecessor, successor),
         :ok <- child_row_within(predecessor, successor),
         :ok <- child_purpose_within(predecessor, successor),
         :ok <- child_conditions_within(predecessor, successor),
         :ok <- child_time_within(predecessor, successor),
         :ok <- restriction_delegation_within(predecessor, successor),
         :ok <- restriction_fixed_policy(predecessor, successor) do
      strict_restriction(predecessor, successor)
    end
  end

  def restriction_within?(_predecessor, _successor, _time),
    do: {:error, :invalid_mandate_restriction}

  defp normalize(value, operation, side) do
    case Mandate.new(value) do
      {:ok, mandate} ->
        {:ok, mandate}

      {:error, reason} ->
        tag =
          if operation == :delegation,
            do: :invalid_delegation_mandate,
            else: :invalid_restriction_mandate

        {:error, {tag, side, reason}}
    end
  end

  defp current_at(mandate, time) do
    cond do
      time < mandate.not_before -> {:error, :mandate_not_yet_valid}
      time >= mandate.expires_at -> {:error, :mandate_expired}
      true -> :ok
    end
  end

  defp delegation_depth_within(parent, child) do
    parent_allowed = parent.delegation["allowed"]
    parent_depth = parent.delegation["max_depth"]
    child_depth = child.delegation["max_depth"]

    cond do
      not parent_allowed -> {:error, :delegation_not_allowed}
      parent_depth <= 0 -> {:error, :delegation_depth_exhausted}
      child_depth > parent_depth - 1 -> {:error, :delegation_depth_expanded}
      true -> :ok
    end
  end

  defp child_parent_matches(parent, child) do
    if child.parent_ref == parent.ref,
      do: :ok,
      else: {:error, :delegation_parent_mismatch}
  end

  defp child_grantor_matches(parent, child) do
    if child.grantor_ref == parent.holder_ref,
      do: :ok,
      else: {:error, :delegation_grantor_mismatch}
  end

  defp child_accountable_matches(parent, child) do
    if child.accountable_ref == parent.accountable_ref,
      do: :ok,
      else: {:error, :delegation_accountable_expanded}
  end

  defp list_boundaries_within(parent, child) do
    Enum.reduce_while(@list_boundaries, :ok, fn field, :ok ->
      allowed = Map.fetch!(parent, field) |> MapSet.new()
      requested = Map.fetch!(child, field)

      if Enum.all?(requested, &MapSet.member?(allowed, &1)),
        do: {:cont, :ok},
        else: {:halt, {:error, {:delegation_expanded, field}}}
    end)
  end

  defp child_labels_within(parent, child) do
    parent_refs = MapSet.new(parent.disclosable_labels, & &1.ref)

    if Enum.all?(child.disclosable_labels, &MapSet.member?(parent_refs, &1.ref)),
      do: :ok,
      else: {:error, {:delegation_expanded, :disclosable_labels}}
  end

  defp child_row_within(parent, child) do
    if Row.subset?(child.ceiling, parent.ceiling),
      do: :ok,
      else: {:error, {:delegation_expanded, :ceiling}}
  end

  defp child_purpose_within(parent, child) do
    if child.purpose_ref == parent.purpose_ref and child.purpose_params === parent.purpose_params,
      do: :ok,
      else: {:error, {:delegation_expanded, :purpose}}
  end

  defp child_conditions_within(parent, child) do
    Enum.reduce_while(parent.conditions, :ok, fn parent_condition, :ok ->
      case matching_child_condition(parent_condition, child.conditions) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp matching_child_condition(parent_condition, child_conditions) do
    results =
      child_conditions
      |> Enum.filter(&(&1.proposition == parent_condition.proposition))
      |> Enum.map(&Condition.attenuation(parent_condition, &1))

    cond do
      :ok in results ->
        :ok

      results == [] ->
        {:error, {:delegation_expanded, :conditions, parent_condition.ref}}

      true ->
        {:error,
         {:delegation_expanded, :conditions, parent_condition.ref,
          first_condition_reason(results)}}
    end
  end

  defp first_condition_reason(results) do
    Enum.find_value(results, :condition_not_preserved, fn
      {:error, reason} -> reason
      :ok -> nil
    end)
  end

  defp child_time_within(parent, child) do
    if child.not_before >= parent.not_before and child.expires_at <= parent.expires_at,
      do: :ok,
      else: {:error, {:delegation_expanded, :time_window}}
  end

  defp child_meters_within(parent, child) do
    invalid =
      Enum.find(child.meters, fn {ref, quantity} ->
        case Map.fetch(parent.meters, ref) do
          {:ok, parent_quantity} -> quantity > parent_quantity
          :error -> true
        end
      end)

    if is_nil(invalid),
      do: :ok,
      else: {:error, {:delegation_expanded, :meters, invalid}}
  end

  # Revocation is authority in its own right. Without a declared policy order,
  # equality is the only closed relation that proves no controller was lost or
  # invented by a descendant.
  defp child_revocation_within(parent, child) do
    if child.revocation == parent.revocation,
      do: :ok,
      else: {:error, {:delegation_expanded, :revocation}}
  end

  defp restriction_revision(predecessor, successor) do
    if successor.revision == predecessor.revision + 1,
      do: :ok,
      else: {:error, :restriction_revision_not_sequential}
  end

  defp restriction_lineage(predecessor, successor) do
    if successor.parent_ref == predecessor.parent_ref,
      do: :ok,
      else: {:error, :restriction_lineage_changed}
  end

  defp restriction_roles(predecessor, successor) do
    fields = [:grantor_ref, :holder_ref, :accountable_ref]

    case Enum.find(fields, &(Map.fetch!(predecessor, &1) != Map.fetch!(successor, &1))) do
      nil -> :ok
      field -> {:error, {:restriction_role_changed, field}}
    end
  end

  defp restriction_delegation_within(predecessor, successor) do
    parent = predecessor.delegation
    child = successor.delegation

    allowed? =
      case {parent, child} do
        {%{"allowed" => false, "max_depth" => 0}, %{"allowed" => false, "max_depth" => 0}} ->
          true

        {%{"allowed" => true, "max_depth" => parent_depth},
         %{"allowed" => false, "max_depth" => 0}} ->
          parent_depth > 0

        {%{"allowed" => true, "max_depth" => parent_depth},
         %{"allowed" => true, "max_depth" => child_depth}} ->
          child_depth > 0 and child_depth <= parent_depth

        _other ->
          false
      end

    if allowed?, do: :ok, else: {:error, {:delegation_expanded, :delegation}}
  end

  defp restriction_fixed_policy(predecessor, successor) do
    cond do
      successor.meters != predecessor.meters ->
        {:error, {:restriction_changed, :meters}}

      successor.revocation != predecessor.revocation ->
        {:error, {:restriction_changed, :revocation}}

      true ->
        :ok
    end
  end

  defp strict_restriction(predecessor, successor) do
    fields = [
      :executor_refs,
      :executor_contract_refs,
      :scope_refs,
      :subject_refs,
      :target_refs,
      :disclosable_labels,
      :classes,
      :ceiling,
      :conditions,
      :not_before,
      :expires_at,
      :delegation
    ]

    if Enum.any?(fields, &(Map.fetch!(predecessor, &1) != Map.fetch!(successor, &1))),
      do: :ok,
      else: {:error, :mandate_restriction_must_be_strict}
  end
end
