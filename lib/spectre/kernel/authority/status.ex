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
  @spec meter_debt(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def meter_debt(%Mandate{} = mandate, %Facts{} = facts) do
    with {:ok, lineage} <- lineage(mandate, facts) do
      case Enum.find_index(lineage, &MapSet.member?(facts.blocked_mandate_refs, &1.ref)) do
        nil -> :ok
        0 -> {:error, :mandate_meter_debt}
        _ancestor -> {:error, :mandate_ancestor_meter_debt}
      end
    end
  end

  @doc false
  @spec restriction(Mandate.t(), Facts.t()) :: :ok | {:error, term()}
  def restriction(%Mandate{} = mandate, %Facts{} = facts) do
    with {:ok, lineage} <- lineage(mandate, facts) do
      case Enum.find_index(lineage, &Map.has_key?(facts.mandate_successors, &1.ref)) do
        nil -> :ok
        0 -> {:error, :mandate_superseded}
        _ancestor -> {:error, :mandate_ancestor_superseded}
      end
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
end
