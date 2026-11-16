defmodule Spectre.GAM.Domain.Projection.Rows do
  @moduledoc """
  Portable per-record representation of a verified Domain projection.

  The read model contains every governed collection, current Meter/dispatch
  state, consumed nonces, acquisition metadata and the Domain foundation. The
  redundant operational `read_index` is rebuilt by the fold, not serialized as
  an opaque growing blob. Runtime process state is never accepted here.
  """
  alias Spectre.GAM.Canonical.Value
  alias Spectre.GAM.Domain.Projection.IndexRows
  alias Spectre.GAM.GovernedAct.{Catalog, State}

  @maps ~w(event_metadata mandates mandate_successors revocations declassifications
    declassifications_by_evidence evidence presentations erasures decisions admissions
    acts attempts outcomes terminal_dispatches meters meter_owner_aliases
    meter_reservations meter_recontainments duties)a
  @sets ~w(pending_dispatches consumed_nonces duty_meter_resolutions meter_devolutions)a
  @catalog ~w(principals host_profiles surfaces definitions definition_heads scopes)a
  @records [
    Spectre.GAM.Act,
    Spectre.GAM.Attempt,
    Spectre.GAM.Decision,
    Spectre.GAM.Declassification,
    Spectre.GAM.Definition,
    Spectre.GAM.Duty,
    Spectre.GAM.Erasure,
    Spectre.GAM.Evidence,
    Spectre.GAM.Genesis,
    Spectre.GAM.HostProfile,
    Spectre.GAM.Mandate,
    Spectre.GAM.Mandate.Revocation,
    Spectre.GAM.Outcome,
    Spectre.GAM.Presentation,
    Spectre.GAM.Principal,
    Spectre.GAM.Surface,
    Spectre.GAM.Scope.Opening,
    Spectre.GAM.Condition,
    Spectre.GAM.Consequence.Contract,
    Spectre.GAM.Disclosure,
    Spectre.GAM.Label,
    Spectre.GAM.Row,
    Spectre.GAM.Domain.Event.Metadata,
    Spectre.GAM.Kernel.Meter.Account,
    Spectre.GAM.Fallback.Policy
  ]

  def collections,
    do:
      [:domain, :record_refs, :act_declassifications | @maps ++ @sets ++ @catalog] ++
        IndexRows.collections()

  def map_collections, do: @maps ++ @catalog
  def encode(value), do: Value.encode(value, allowed_structs: @records)
  def decode(bytes), do: Value.decode(bytes, allowed_structs: @records)
  def cursor(projection), do: Map.take(projection, [:revision, :head_digest])

  @doc "Streams row changes; unchanged collections keep their shared map without encoding."
  def changes(%State{} = before, %State{} = next) do
    maps = for key <- @maps, do: {key, Map.fetch!(before, key), Map.fetch!(next, key)}

    catalog =
      for key <- @catalog,
          do: {key, Map.fetch!(before.catalog, key), Map.fetch!(next.catalog, key)}

    changed_maps =
      Stream.flat_map(maps ++ catalog, fn {collection, old, new} ->
        IndexRows.changes(collection, :map, old, new)
      end)

    changed_sets =
      Stream.flat_map(@sets, fn collection ->
        IndexRows.changes(
          collection,
          :set,
          Map.fetch!(before, collection),
          Map.fetch!(next, collection)
        )
      end)

    Stream.concat([
      [{:put, {:domain, :metadata}, metadata(next)}],
      changed_maps,
      changed_sets,
      IndexRows.changes(before, next),
      Stream.flat_map(maps ++ catalog, &new_references/1),
      Stream.flat_map(next.declassifications, fn {ref, record} ->
        if Map.has_key?(before.declassifications, ref),
          do: [],
          else: [{:put, {:act_declassifications, {record.source_act_ref, ref}}, true}]
      end)
    ])
  end

  defp new_references({_collection, same, same}), do: []

  defp new_references({collection, old, new}) do
    new
    |> Stream.filter(fn {key, _} -> is_binary(key) and not Map.has_key?(old, key) end)
    |> Stream.map(fn {key, _} -> {:put, {:record_refs, {key, collection}}, true} end)
  end

  @doc false
  def empty(%State{} = state) do
    %{
      State.new(state.domain_ref, state.constitution)
      | revision: state.revision,
        head_digest: state.head_digest,
        recorded_at: state.recorded_at,
        catalog:
          struct!(Catalog, Map.take(state.catalog, [:genesis, :host_profile_ref, :surface_ref]))
    }
  end

  @doc false
  def put(state, {:domain, :metadata}, data) do
    state = struct!(state, Map.delete(data, :catalog))
    %{state | catalog: struct!(state.catalog, data.catalog)}
  end

  def put(state, {collection, key}, value) when collection in @maps,
    do: Map.update!(state, collection, &Map.put(&1, key, value))

  def put(state, {collection, key}, _value) when collection in @sets,
    do: Map.update!(state, collection, &MapSet.put(&1, key))

  def put(state, {collection, key}, value) when collection in @catalog,
    do: %{state | catalog: Map.update!(state.catalog, collection, &Map.put(&1, key, value))}

  def put(state, {:act_declassifications, _}, _), do: state

  def put(state, {collection, key}, value), do: IndexRows.put(state, collection, key, value)

  defp metadata(%State{catalog: %Catalog{} = catalog} = state) do
    state
    |> Map.take([:domain_ref, :constitution, :revision, :head_digest, :recorded_at])
    |> Map.put(:catalog, Map.take(catalog, [:genesis, :host_profile_ref, :surface_ref]))
  end
end
