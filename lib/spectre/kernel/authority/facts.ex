defmodule Spectre.Kernel.Authority.Facts do
  @moduledoc """
  Minimal immutable input consumed by authority resolution.

  The container is derived from `Spectre.GovernedAct.State` and deliberately
  omits Evidence, Meter balances and executor handles. It is therefore possible
  to inspect lineage, revocation, restriction and containment without allowing
  facts about the world to manufacture or select authority.

  All values are already-restored structs or exact read-model indexes. The
  resolver never performs atom/string fallback or decodes ledger records.
  """

  alias Spectre.GovernedAct.State
  alias Spectre.Mandate
  alias Spectre.Mandate.Revocation

  @enforce_keys [
    :mandates,
    :mandate_successors,
    :revocations,
    :blocked_mandate_refs,
    :blocked_effect_digests,
    :revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mandates: %{optional(String.t()) => Mandate.t()},
          mandate_successors: %{optional(String.t()) => String.t()},
          revocations: %{optional(String.t()) => Revocation.t()},
          blocked_mandate_refs: MapSet.t(String.t()),
          blocked_effect_digests: MapSet.t(String.t()),
          revision: non_neg_integer()
        }

  @doc "Builds the closed authority-only view of a folded Domain state."
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      mandates: state.mandates,
      mandate_successors: state.mandate_successors,
      revocations: state.revocations,
      blocked_mandate_refs: blocked_mandate_refs(state),
      blocked_effect_digests: blocked_effect_digests(state),
      revision: state.revision
    }
  end

  @doc "Returns Mandates blocked by unresolved Meter recontainment deficits."
  @spec blocked_mandate_refs(State.t()) :: MapSet.t(String.t())
  def blocked_mandate_refs(%State{} = state) do
    blocked_owners =
      state.meter_recontainments
      |> Map.values()
      |> Enum.filter(&(&1.status == :open and map_size(&1.deficits) > 0))
      |> Enum.map(&Map.get(state.meter_owners, &1.mandate_ref))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    state.meter_owners
    |> Enum.reduce(MapSet.new(), fn {mandate_ref, owner_ref}, blocked ->
      if MapSet.member?(blocked_owners, owner_ref),
        do: MapSet.put(blocked, mandate_ref),
        else: blocked
    end)
  end

  @doc "Returns consequence digests held by unresolved containment Duties."
  @spec blocked_effect_digests(State.t()) :: MapSet.t(String.t())
  def blocked_effect_digests(%State{} = state) do
    Enum.reduce(state.duties, MapSet.new(), fn
      {_cause_key,
       %Spectre.Duty{
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
