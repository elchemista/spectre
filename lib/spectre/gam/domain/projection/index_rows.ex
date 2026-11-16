defmodule Spectre.GAM.Domain.Projection.IndexRows do
  @moduledoc false

  # Each membership is a row. A frequently used proposition or authority must
  # not turn into a growing serialized MapSet that is rewritten on every append.
  @fields [
    {:batches, [:batches], :set},
    {:evidence_propositions, [:evidence_by_proposition], :members},
    {:attempt_evidence, [:evidence_by_attempt], :members},
    {:approval_propositions, [:approval_propositions], :members},
    {:presentation_shows, [:show_acts], :members},
    {:evidence_revisions, [:evidence_by_revision], :tree},
    {:payload_refs, [:payload_refs], :set},
    {:dispatch_deadlines, [:dispatch_deadlines], :tree},
    {:duty_refs, [:duties, :by_ref], :map},
    {:pending_causes, [:duties, :pending], :map},
    {:duty_deadlines, [:duties, :deadlines], :tree},
    {:evidence_subscriptions, [:duties, :subscriptions], :members},
    {:scope_deadlines, [:duties, :scopes_by_deadline], :members},
    {:attempt_outcomes, [:duties, :outcomes_by_attempt], :members},
    {:act_outcomes, [:duties, :outcomes_by_act], :members},
    {:act_erasures, [:duties, :erasures_by_act], :members},
    {:act_duties, [:duties, :duties_by_act], :members},
    {:holder_mandates, [:authority, :mandates_by_holder], :members},
    {:owner_aliases, [:authority, :aliases_by_owner], :members},
    {:owner_debts, [:authority, :debts_by_owner], :members},
    {:debt_owners, [:authority, :debt_owners], :map},
    {:blocked_effects, [:authority, :effects], :members},
    {:open_duty_causes, [:authority, :open_duty_causes], :set},
    {:erasure_children, [:erasure, :children], :members},
    {:erasure_roots, [:erasure, :roots], :members},
    {:erasure_sources, [:erasure, :sources], :members},
    {:erasure_reached, [:erasure, :reached], :members},
    {:erasure_targets, [:erasure, :targets], :members},
    {:erasure_states, [:erasure, :states], :map},
    {:unavailable_evidence, [:erasure, :unavailable], :set}
  ]

  def collections, do: Enum.map(@fields, &elem(&1, 0))

  def changes(before, next) do
    Stream.flat_map(@fields, fn {collection, path, kind} ->
      old = get_in(before.read_index, Enum.map(path, &Access.key!/1))
      new = get_in(next.read_index, Enum.map(path, &Access.key!/1))
      changes(collection, kind, old, new)
    end)
  end

  @doc false
  def changes(_, _, same, same), do: []

  def changes(collection, :members, old, new) do
    Stream.concat([
      Stream.flat_map(new, fn {group, members} ->
        previous = Map.get(old, group, MapSet.new())
        Stream.map(MapSet.difference(members, previous), &{:put, {collection, {group, &1}}, true})
      end),
      Stream.flat_map(old, fn {group, members} ->
        current = Map.get(new, group, MapSet.new())
        Stream.map(MapSet.difference(members, current), &{:delete, {collection, {group, &1}}})
      end)
    ])
  end

  def changes(collection, :set, old, new) do
    Stream.concat(
      Stream.map(MapSet.difference(new, old), &{:put, {collection, &1}, true}),
      Stream.map(MapSet.difference(old, new), &{:delete, {collection, &1}})
    )
  end

  def changes(collection, :tree, old, new),
    do:
      changes(collection, :map, Map.new(:gb_trees.to_list(old)), Map.new(:gb_trees.to_list(new)))

  def changes(collection, :map, old, new) do
    Stream.concat(
      new
      |> Stream.reject(fn {key, value} -> Map.fetch(old, key) == {:ok, value} end)
      |> Stream.map(fn {key, value} -> {:put, {collection, key}, value} end),
      old
      |> Stream.reject(fn {key, _} -> Map.has_key?(new, key) end)
      |> Stream.map(fn {key, _} -> {:delete, {collection, key}} end)
    )
  end

  def put(state, collection, key, value) do
    {^collection, path, kind} = List.keyfind(@fields, collection, 0)

    update_in(state, [Access.key!(:read_index) | Enum.map(path, &Access.key!/1)], fn current ->
      case kind do
        :map ->
          Map.put(current, key, value)

        :set ->
          MapSet.put(current, key)

        :tree ->
          :gb_trees.enter(key, value, current)

        :members ->
          {group, member} = key
          Map.update(current, group, MapSet.new([member]), &MapSet.put(&1, member))
      end
    end)
  end

  # Used only by the explicit legacy full-projection read, after all pages of
  # every collection and index have been read. Partial selections never set it.
  def restore_counts(state) do
    index = state.read_index

    erasure_counts =
      [:evidence, :presentations, :acts, :attempts, :outcomes, :erasures]
      |> Enum.map(&map_size(Map.fetch!(state, &1)))
      |> List.to_tuple()

    authority_counts =
      [:mandates, :meter_owner_aliases, :duties, :meter_recontainments]
      |> Enum.map(&map_size(Map.fetch!(state, &1)))
      |> List.to_tuple()

    %{
      state
      | read_index: %{
          index
          | selection: nil,
            act_count: map_size(state.acts),
            presentation_count: map_size(state.presentations),
            outcome_count: map_size(state.outcomes),
            erasure: %{index.erasure | counts: erasure_counts, selection: nil},
            authority: %{index.authority | counts: authority_counts, selection: nil}
        }
    }
  end

  def group(:act_declassifications, {group, _}), do: group

  def group(collection, {group, _}) do
    case List.keyfind(@fields, collection, 0) do
      {_, _, :members} -> group
      _ -> nil
    end
  end

  def group(_, _), do: nil

  def position(collection, key) when collection in [:duty_deadlines, :dispatch_deadlines],
    do: elem(key, 0)

  def position(:evidence_revisions, revision), do: revision
  def position(_, _), do: nil
end
