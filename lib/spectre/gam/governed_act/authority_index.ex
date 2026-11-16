defmodule Spectre.GAM.GovernedAct.AuthorityIndex do
  @moduledoc """
  Rebuildable indexes for authority reads at one folded prefix.

  The index keeps references, not a second copy of governed records. Terminal
  Duties and resolved Meter debts leave its active sets; unrelated admissions
  need not scan those histories again. Several independent causes may block
  the same consequence or Meter owner, so disposing one never clears the rest.

  This is a fold-owned read model, not a cache supplied by a persistence adapter
  or a permission matrix. Resolution still checks the exact Mandate lineage.
  """

  alias Spectre.GAM.Duty

  @version 2

  defstruct version: @version,
            selection: nil,
            mandates_by_holder: %{},
            aliases_by_owner: %{},
            debts_by_owner: %{},
            debt_owners: %{},
            effects: %{},
            open_duty_causes: MapSet.new(),
            counts: {0, 0, 0, 0}

  @type t :: %__MODULE__{
          version: pos_integer(),
          mandates_by_holder: map(),
          aliases_by_owner: map(),
          debts_by_owner: map(),
          debt_owners: map(),
          effects: map(),
          open_duty_causes: MapSet.t(),
          counts:
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
        }

  @doc false
  @spec complete?(t(), Spectre.GAM.GovernedAct.State.t()) :: boolean()
  def complete?(index, state),
    do:
      index.selection == nil and Map.get(index, :version) === @version and
        index.counts === counts(state)

  @doc false
  def usable?(%{selection: nil} = index, state), do: complete?(index, state)

  def usable?(index, _state) do
    for collection <- [
          :mandates,
          :mandate_successors,
          :revocations,
          :meters,
          :meter_owner_aliases,
          :owner_debts,
          :debt_owners,
          :blocked_effects,
          :open_duty_causes
        ] do
      Spectre.GAM.GovernedAct.Reads.ensure(index.selection, {:page, collection, []})
    end

    true
  end

  @doc false
  def selected?(%{selection: nil} = index, state), do: complete?(index, state)

  def selected?(index, _state) do
    for collection <- [:owner_debts, :debt_owners, :blocked_effects, :open_duty_causes] do
      Spectre.GAM.GovernedAct.Reads.ensure(index.selection, {:page, collection, []})
    end

    true
  end

  @doc false
  @spec record(Spectre.GAM.GovernedAct.State.t(), Spectre.GAM.Domain.Event.t()) ::
          Spectre.GAM.GovernedAct.State.t()
  def record(state, event) do
    index = state.read_index.authority
    counts = counts(state)

    # A partial, hand-built State must not acquire a complete index by recording
    # just one new event. Counts check coverage, not authenticity of host memory.
    index =
      if Map.get(index, :version) === @version and
           (index.selection != nil or index.counts === previous_counts(counts, event.type)),
         do: %{update(index, state, event) | counts: if(index.selection, do: nil, else: counts)},
         else: %{index | counts: nil}

    %{state | read_index: %{state.read_index | authority: index}}
  end

  defp previous_counts({mandates, aliases, duties, debts}, "mandate_issued"),
    do: {mandates - 1, aliases, duties, debts}

  defp previous_counts({mandates, aliases, duties, debts}, "mandate_restricted"),
    do: {mandates - 1, aliases - 1, duties, debts}

  defp previous_counts({mandates, aliases, duties, debts}, "duty_opened"),
    do: {mandates, aliases, duties - 1, debts}

  defp previous_counts({mandates, aliases, duties, debts}, "meter_recontained"),
    do: {mandates, aliases, duties, debts - 1}

  defp previous_counts(counts, _type), do: counts

  defp update(index, state, %{type: type, identity: ref})
       when type in ["mandate_issued", "mandate_restricted"] do
    mandate = Map.fetch!(state.mandates, ref)

    index = %{
      index
      | mandates_by_holder: put(index.mandates_by_holder, mandate.holder_ref, ref)
    }

    case Map.fetch(state.meter_owner_aliases, ref) do
      {:ok, owner} -> %{index | aliases_by_owner: put(index.aliases_by_owner, owner, ref)}
      :error -> index
    end
  end

  defp update(index, state, %{type: "duty_opened", identity: ref}) do
    cause = Map.fetch!(state.read_index.duties.by_ref, ref)
    duty = Map.fetch!(state.duties, cause)

    index = %{index | open_duty_causes: MapSet.put(index.open_duty_causes, cause)}

    case blocked_effect(duty) do
      nil -> index
      digest -> %{index | effects: put(index.effects, digest, cause)}
    end
  end

  defp update(index, state, %{type: "duty_disposed", data: %{"cause_key" => cause}}) do
    duty = Map.fetch!(state.duties, cause)

    index = %{index | open_duty_causes: MapSet.delete(index.open_duty_causes, cause)}

    # Disposition changes status, not the recorded containment of the cause.
    case blocked_effect(%{duty | status: :open}) do
      nil -> index
      digest -> %{index | effects: delete(index.effects, digest, cause)}
    end
  end

  defp update(index, state, %{type: "meter_recontained", data: %{"act_ref" => ref}}) do
    record = Map.fetch!(state.meter_recontainments, ref)

    if is_nil(record.disposition_act_ref) and map_size(record.deficits) > 0 do
      mandate = Map.fetch!(state.acts, ref).mandate_ref
      owner = Map.get(state.meter_owner_aliases, mandate, mandate)

      %{
        index
        | debt_owners: Map.put(index.debt_owners, ref, owner),
          debts_by_owner: put(index.debts_by_owner, owner, ref)
      }
    else
      index
    end
  end

  defp update(index, state, %{type: "meter_duty_resolved", data: %{"act_ref" => ref}}) do
    case {Map.fetch(index.debt_owners, ref), Map.get(state.meter_recontainments, ref)} do
      {{:ok, owner}, %{disposition_act_ref: disposition}} when is_binary(disposition) ->
        %{
          index
          | debt_owners: Map.delete(index.debt_owners, ref),
            debts_by_owner: delete(index.debts_by_owner, owner, ref)
        }

      _no_resolved_debt ->
        index
    end
  end

  defp update(index, _state, _event), do: index

  @doc false
  @spec blocked_effect(Duty.t()) :: String.t() | nil
  def blocked_effect(%Duty{
        status: :open,
        containment: %{
          "dispatch" => :blocked,
          "retry" => :forbidden,
          "consequence_digest" => digest
        }
      })
      when is_binary(digest) and digest != "",
      do: digest

  def blocked_effect(_duty), do: nil

  defp put(index, key, ref),
    do: Map.update(index, key, MapSet.new([ref]), &MapSet.put(&1, ref))

  defp delete(index, key, ref) do
    remaining = index |> Map.get(key, MapSet.new()) |> MapSet.delete(ref)

    if MapSet.size(remaining) === 0,
      do: Map.delete(index, key),
      else: Map.put(index, key, remaining)
  end

  defp counts(state),
    do:
      {map_size(state.mandates), map_size(state.meter_owner_aliases), map_size(state.duties),
       map_size(state.meter_recontainments)}
end
