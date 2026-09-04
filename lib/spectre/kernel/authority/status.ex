defmodule Spectre.Kernel.Authority.Status do
  @moduledoc """
  Interprets the dynamic status of one pinned Mandate lineage.

  This is the stateful half of authority eligibility: it verifies the exact
  Mandate snapshot, then derives revocation, supersession and unresolved Meter
  debt from the closed `Authority.Facts` indexes. Candidate coverage remains in
  `Spectre.Kernel.Authority`.
  """

  alias Spectre.Kernel.Authority.Facts
  alias Spectre.Mandate
  alias Spectre.Mandate.Ancestry

  @type blocker ::
          :not_yet_valid
          | :expired
          | :revoked
          | :ancestor_revoked
          | :superseded
          | :ancestor_superseded
          | :meter_debt
          | :ancestor_meter_debt

  @type direct_blocker :: :not_yet_valid | :expired | :already_revoked

  @doc false
  @spec exact_snapshot(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def exact_snapshot(%Mandate{} = mandate, %Facts{} = facts) do
    case Map.fetch(facts.mandates, mandate.ref) do
      {:ok, ^mandate} -> :ok
      {:ok, _other} -> {:error, :mandate_snapshot_not_pinned}
      :error -> {:error, :mandate_not_in_authority_view}
    end
  end

  @doc false
  @spec current_at(Mandate.t(), integer()) :: :ok | {:error, term()}
  def current_at(%Mandate{} = mandate, time) when is_integer(time) do
    cond do
      time < mandate.not_before -> {:error, :mandate_not_yet_valid}
      time >= mandate.expires_at -> {:error, :mandate_expired}
      true -> :ok
    end
  end

  @doc false
  @spec blockers(Mandate.t(), Facts.t(), integer()) ::
          {:ok, [blocker()]} | {:error, term()}
  def blockers(%Mandate{} = mandate, %Facts{} = facts, time) when is_integer(time) do
    with {:ok, lineage} <- lineage(mandate, facts),
         {:ok, revocation_status} <-
           Ancestry.status_in_lineage(lineage, facts.revocations, time) do
      {:ok,
       time_blockers(mandate, time) ++
         revocation_blockers(revocation_status) ++
         restriction_blockers(lineage, facts) ++ meter_debt_blockers(lineage, facts)}
    end
  end

  @doc false
  @spec direct_blockers(Mandate.t(), Facts.t(), integer()) ::
          {:ok, [direct_blocker()]} | {:error, term()}
  def direct_blockers(%Mandate{} = mandate, %Facts{} = facts, time) when is_integer(time) do
    with {:ok, revoked?} <- Ancestry.directly_revoked?(facts.revocations, mandate, time) do
      blockers =
        mandate
        |> time_blockers(time)
        |> maybe_add(revoked?, :already_revoked)

      {:ok, blockers}
    end
  end

  @doc false
  @spec not_revoked(Mandate.t(), Facts.t(), integer()) :: :ok | {:error, term()}
  def not_revoked(%Mandate{} = mandate, %Facts{} = facts, time) when is_integer(time) do
    with {:ok, status} <- Ancestry.status(facts.mandates, facts.revocations, mandate, time) do
      case status do
        :current -> :ok
        {:revoked, :direct, _ref} -> {:error, :mandate_revoked}
        {:revoked, :ancestor, _ref} -> {:error, :mandate_ancestor_revoked}
      end
    end
  end

  @doc false
  @spec not_directly_revoked(Mandate.t(), Facts.t(), integer()) :: :ok | {:error, term()}
  def not_directly_revoked(%Mandate{} = mandate, %Facts{} = facts, time)
      when is_integer(time) do
    with {:ok, revoked?} <- Ancestry.directly_revoked?(facts.revocations, mandate, time) do
      if revoked?, do: {:error, :mandate_revoked}, else: :ok
    end
  end

  @doc false
  @spec standing(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def standing(%Mandate{} = mandate, %Facts{} = facts) do
    with {:ok, lineage} <- lineage(mandate, facts),
         :ok <- restriction_in(lineage, facts) do
      meter_debt_in(lineage, facts)
    end
  end

  @doc false
  @spec meter_debt(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def meter_debt(%Mandate{} = mandate, %Facts{} = facts) do
    with {:ok, lineage} <- lineage(mandate, facts) do
      meter_debt_in(lineage, facts)
    end
  end

  @doc false
  @spec restriction(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def restriction(%Mandate{} = mandate, %Facts{} = facts) do
    with {:ok, lineage} <- lineage(mandate, facts) do
      restriction_in(lineage, facts)
    end
  end

  @doc false
  @spec lineage(Mandate.t(), Facts.t()) :: {:ok, [Mandate.t()]} | {:error, term()}
  def lineage(%Mandate{} = mandate, %Facts{} = facts) do
    case Ancestry.lineage(facts.mandates, mandate) do
      {:error, {:mandate_ancestry_cycle, _ref}} -> {:error, :mandate_ancestry_cycle}
      result -> result
    end
  end

  defp meter_debt_in(lineage, facts) do
    case Enum.find_index(lineage, &MapSet.member?(facts.blocked_mandate_refs, &1.ref)) do
      nil -> :ok
      0 -> {:error, :mandate_meter_debt}
      _ancestor -> {:error, :mandate_ancestor_meter_debt}
    end
  end

  defp time_blockers(%Mandate{} = mandate, time) do
    []
    |> maybe_add(time < mandate.not_before, :not_yet_valid)
    |> maybe_add(time >= mandate.expires_at, :expired)
  end

  defp revocation_blockers(:current), do: []
  defp revocation_blockers({:revoked, :direct, _ref}), do: [:revoked]
  defp revocation_blockers({:revoked, :ancestor, _ref}), do: [:ancestor_revoked]

  defp restriction_blockers(lineage, facts) do
    case restriction_in(lineage, facts) do
      :ok -> []
      {:error, :mandate_superseded} -> [:superseded]
      {:error, :mandate_ancestor_superseded} -> [:ancestor_superseded]
    end
  end

  defp meter_debt_blockers(lineage, facts) do
    case meter_debt_in(lineage, facts) do
      :ok -> []
      {:error, :mandate_meter_debt} -> [:meter_debt]
      {:error, :mandate_ancestor_meter_debt} -> [:ancestor_meter_debt]
    end
  end

  defp restriction_in(lineage, facts) do
    case Enum.find_index(lineage, &Map.has_key?(facts.mandate_successors, &1.ref)) do
      nil -> :ok
      0 -> {:error, :mandate_superseded}
      _ancestor -> {:error, :mandate_ancestor_superseded}
    end
  end

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values
end
