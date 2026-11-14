defmodule Spectre.GAM.Kernel.Authority.Facts do
  @moduledoc """
  Minimal immutable input consumed by authority resolution.

  The container is derived from `Spectre.GAM.GovernedAct.State` and deliberately
  omits Evidence, Meter balances and executor handles. It is therefore possible
  to inspect lineage, revocation, restriction and containment without allowing
  facts about the world to manufacture or select authority.

  All values are already-restored structs or exact read-model indexes. The
  resolver never performs atom/string fallback or decodes ledger records.
  """

  alias Spectre.GAM.{Act, Candidate, Duty}
  alias Spectre.GAM.Duty.Disposition
  alias Spectre.GAM.GovernedAct.{AuthorityIndex, MeterState}
  alias Spectre.GAM.GovernedAct.State
  alias Spectre.GAM.Kernel.Authority.DutyTargets
  alias Spectre.GAM.Mandate
  alias Spectre.GAM.Mandate.Ancestry
  alias Spectre.GAM.Mandate.Revocation

  @enforce_keys [
    :mandates,
    :mandate_successors,
    :revocations,
    :blocked_mandate_refs,
    :blocked_effect_digests
  ]
  defstruct @enforce_keys ++ [disposition_duties: %{}]

  @type t :: %__MODULE__{
          mandates: %{optional(String.t()) => Mandate.t()},
          mandate_successors: %{optional(String.t()) => String.t()},
          revocations: %{optional(String.t()) => Revocation.t()},
          blocked_mandate_refs: MapSet.t(String.t()),
          blocked_effect_digests: MapSet.t(String.t()),
          disposition_duties: %{optional(binary()) => map()}
        }

  @doc "Builds the exhaustive authority-only view, independent of operational indexes."
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      mandates: state.mandates,
      mandate_successors: state.mandate_successors,
      revocations: state.revocations,
      blocked_mandate_refs: blocked_mandate_refs(state),
      blocked_effect_digests: blocked_effect_digests(state),
      disposition_duties: all_dispositions(state)
    }
  end

  @doc "Builds the current full authority view without scanning terminal Duty history."
  @spec current(State.t()) :: t()
  def current(%State{} = state) do
    index = state.read_index.authority

    if AuthorityIndex.complete?(index, state) do
      blocked =
        Enum.reduce(index.debts_by_owner, MapSet.new(), fn {owner, _causes}, refs ->
          index.aliases_by_owner
          |> Map.get(owner, MapSet.new())
          |> MapSet.union(MapSet.put(refs, owner))
        end)

      %__MODULE__{
        mandates: state.mandates,
        mandate_successors: state.mandate_successors,
        revocations: state.revocations,
        blocked_mandate_refs: blocked,
        blocked_effect_digests: MapSet.new(Map.keys(index.effects)),
        disposition_duties: indexed_dispositions(state, index.open_duty_causes)
      }
    else
      from_state(state)
    end
  end

  @doc """
  Selects complete authority facts for one Candidate, without choosing its Mandate.

  An explicit request includes that Mandate and every ancestor. Otherwise every
  Mandate held by the proposer is retained, so ambiguity cannot be hidden by
  selecting a first match. Ancestors belonging to other principals remain in
  the view for revocation, restriction, debt and disclosure-owner checks.

  This is a pure read of a fold-owned prefix, not a last-N history window or
  permission supplied by a host callback. Missing operational indexes use the
  exhaustive path. Persisted indexes must be verified/rebuilt before use.
  """
  @spec for_candidate(State.t(), Candidate.t()) :: t()
  def for_candidate(%State{} = state, %Candidate{} = candidate) do
    index = state.read_index.authority
    indexed? = AuthorityIndex.complete?(index, state)
    roots = candidate_roots(state, candidate, indexed?)
    select(state, roots, candidate, indexed?)
  end

  @doc "Selects the exact admitted branch for dispatch, including current blockers."
  @spec for_act(State.t(), Act.t()) :: t()
  def for_act(%State{} = state, %Act{} = act) do
    select(
      state,
      [act.mandate_ref],
      act,
      AuthorityIndex.complete?(state.read_index.authority, state)
    )
  end

  defp select(state, roots, occurrence, indexed?) do
    mandates = Ancestry.select(state.mandates, roots)
    refs = Map.keys(mandates)

    facts = %__MODULE__{
      mandates: mandates,
      mandate_successors: Map.take(state.mandate_successors, refs),
      revocations: Map.take(state.revocations, refs),
      blocked_mandate_refs: selected_debts(state, refs, indexed?),
      blocked_effect_digests: selected_containment(state, occurrence, indexed?)
    }

    select_disposition(facts, state, occurrence)
  end

  @spec all_dispositions(State.t()) :: %{optional(binary()) => map()}
  defp all_dispositions(state) do
    disposition_entries(state, Map.values(state.duties))
  end

  @spec indexed_dispositions(State.t(), MapSet.t()) :: %{optional(binary()) => map()}
  defp indexed_dispositions(state, causes) do
    disposition_entries(state, Enum.map(causes, &Map.fetch!(state.duties, &1)))
  end

  @spec disposition_entries(State.t(), [Duty.t()]) :: %{optional(binary()) => map()}
  defp disposition_entries(state, duties) do
    predecessors = DutyTargets.predecessors(state)

    Enum.reduce(duties, %{}, fn duty, selected ->
      Map.merge(selected, disposition_entry(state, duty, predecessors))
    end)
  end

  @spec select_disposition(t(), State.t(), Candidate.t() | Act.t()) :: t()
  defp select_disposition(facts, state, %{class: "duty.dispose", consequence: consequence}) do
    selected =
      with {:ok, disposition} <- Disposition.from_consequence(consequence),
           %Duty{} = duty <- Map.get(state.duties, disposition.cause_key),
           true <- duty.ref == disposition.duty_ref do
        disposition_entry(state, duty, DutyTargets.predecessors(state))
      else
        _ -> %{}
      end

    %{facts | disposition_duties: selected}
  end

  defp select_disposition(facts, _state, _occurrence), do: %{facts | disposition_duties: %{}}

  @spec disposition_entry(State.t(), Duty.t(), map()) :: %{optional(binary()) => map()}
  defp disposition_entry(state, %Duty{status: :open} = duty, predecessors) do
    case DutyTargets.causal_refs(state, duty, predecessors) do
      {:ok, refs} ->
        envelope =
          duty
          |> Map.take([:ref, :cause_key, :mandate_ref, :status, :disposition_authority_refs])
          |> Map.put(:causal_refs, refs)

        %{duty.ref => envelope}

      {:error, _} ->
        %{}
    end
  end

  defp disposition_entry(_state, _duty, _predecessors), do: %{}

  defp candidate_roots(_state, %Candidate{requested_mandate_ref: ref}, _indexed?)
       when not is_nil(ref),
       do: [ref]

  defp candidate_roots(state, candidate, true) do
    state.read_index.authority.mandates_by_holder
    |> Map.get(candidate.proposer_ref, MapSet.new())
    |> MapSet.to_list()
  end

  defp candidate_roots(state, candidate, false) do
    for {ref, %Mandate{holder_ref: holder}} <- state.mandates,
        holder === candidate.proposer_ref,
        do: ref
  end

  defp selected_debts(state, refs, true) do
    MapSet.new(
      Enum.filter(refs, fn ref ->
        owner = Map.get(state.meter_owner_aliases, ref, ref)
        Map.has_key?(state.read_index.authority.debts_by_owner, owner)
      end)
    )
  end

  defp selected_debts(state, refs, false),
    do: MapSet.intersection(blocked_mandate_refs(state), MapSet.new(refs))

  # Most prefixes have no active consequence containment. Avoid canonicalizing
  # the occurrence twice (selection, then authority) when none can match.
  defp selected_containment(
         %{read_index: %{authority: %{effects: effects}}},
         _candidate,
         true
       )
       when map_size(effects) === 0,
       do: MapSet.new()

  defp selected_containment(state, candidate, indexed?) do
    with {:ok, digest} <- Candidate.effect_digest(candidate),
         true <- effect_blocked?(state, digest, indexed?) do
      MapSet.new([digest])
    else
      _not_blocked -> MapSet.new()
    end
  end

  defp effect_blocked?(state, digest, true),
    do: Map.has_key?(state.read_index.authority.effects, digest)

  defp effect_blocked?(state, digest, false),
    do: MapSet.member?(blocked_effect_digests(state), digest)

  @doc "Returns Mandates blocked by unresolved Meter recontainment deficits."
  @spec blocked_mandate_refs(State.t()) :: MapSet.t(String.t())
  def blocked_mandate_refs(%State{} = state) do
    blocked_owners =
      state.meter_recontainments
      |> Enum.reduce(MapSet.new(), fn {act_ref, recontainment}, blocked ->
        if is_nil(recontainment.disposition_act_ref) and map_size(recontainment.deficits) > 0 do
          block_reservation_owner(state, act_ref, blocked)
        else
          blocked
        end
      end)

    Enum.reduce(state.meter_owner_aliases, blocked_owners, fn {mandate_ref, owner_ref}, blocked ->
      if MapSet.member?(blocked_owners, owner_ref),
        do: MapSet.put(blocked, mandate_ref),
        else: blocked
    end)
  end

  defp block_reservation_owner(state, act_ref, blocked) do
    with {:ok, %{mandate_ref: mandate_ref}} <- MeterState.reservation(state, act_ref),
         {:ok, owner_ref} <- MeterState.owner(state, mandate_ref) do
      MapSet.put(blocked, owner_ref)
    else
      _missing_or_invalid -> blocked
    end
  end

  @doc "Returns consequence digests held by unresolved containment Duties."
  @spec blocked_effect_digests(State.t()) :: MapSet.t(String.t())
  def blocked_effect_digests(%State{} = state) do
    Enum.reduce(state.duties, MapSet.new(), fn
      {_cause_key,
       %Spectre.GAM.Duty{
         status: :open,
         containment: %{
           "dispatch" => :blocked,
           "retry" => :forbidden,
           "consequence_digest" => digest
         }
       }},
      blocked
      when is_binary(digest) and digest != "" ->
        MapSet.put(blocked, digest)

      _duty, blocked ->
        blocked
    end)
  end
end
