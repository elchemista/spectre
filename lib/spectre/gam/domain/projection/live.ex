defmodule Spectre.GAM.Domain.Projection.Live do
  @moduledoc false
  alias Spectre.GAM.Domain.Projection.Rows
  alias Spectre.GAM.GovernedAct.Reads, as: Selection

  # These are current authority and active frontiers, not execution history.
  # Keeping them avoids re-reading the foundation for every observation.
  @maps ~w(mandates mandate_successors revocations meters meter_owner_aliases)a
  @catalog ~w(principals definition_heads)a
  @active ~w(pending_causes open_duty_causes blocked_effects owner_debts debt_owners)a

  def retain(projection) do
    empty = Rows.empty(projection)
    roots = projection.catalog.genesis.root_mandate_refs
    retained = Map.new(@maps, &{&1, Map.take(Map.fetch!(projection, &1), roots)})
    live = struct!(empty, retained)

    catalog = %{
      live.catalog
      | definition_heads: projection.catalog.definition_heads,
        principals:
          Map.take(projection.catalog.principals, projection.catalog.genesis.principal_refs)
    }

    authority = %{
      projection.read_index.authority
      | selection: nil,
        mandates_by_holder:
          retain_members(projection.read_index.authority.mandates_by_holder, roots),
        aliases_by_owner: retain_members(projection.read_index.authority.aliases_by_owner, roots)
    }

    duties = %{empty.read_index.duties | pending: projection.read_index.duties.pending}
    index = %{empty.read_index | authority: authority, duties: duties}

    retained =
      (projection.read_index.selection || MapSet.new())
      |> Enum.filter(fn
        {:page, collection, []} when collection in @active ->
          true

        {:page, collection, []} when collection in @maps ->
          Map.fetch!(live, collection) == Map.fetch!(projection, collection)

        {:page, collection, []} when collection in @catalog ->
          Map.fetch!(catalog, collection) == Map.fetch!(projection.catalog, collection)

        _ ->
          false
      end)
      |> MapSet.new()

    Selection.mark(%{live | catalog: catalog, read_index: index}, retained)
  end

  defp retain_members(groups, refs) do
    allowed = MapSet.new(refs)

    for {key, values} <- groups,
        retained = MapSet.intersection(values, allowed),
        MapSet.size(retained) > 0,
        into: %{},
        do: {key, retained}
  end
end
