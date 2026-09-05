defmodule Spectre.Core.CatalogTest do
  use ExUnit.Case, async: true

  alias Spectre.{Definition, HostProfile, Surface}
  alias Spectre.GovernedAct.{Catalog, State}

  test "advancing foundation heads retains exact historical records and other declarations" do
    assert {:ok, first_profile} =
             HostProfile.new(mode: :development, attestation_ref: "host-1", declared_at: 1)

    assert {:ok, second_profile} =
             HostProfile.new(
               revision: 2,
               mode: :mediated,
               attestation_ref: "host-2",
               declared_at: 2
             )

    assert {:ok, first_surface} = Surface.new(revision: 1)
    assert {:ok, second_surface} = Surface.new(revision: 2)

    initial = State.new("domain")
    assert State.host_profile(initial) == nil
    assert State.surface(initial) == nil

    catalog =
      initial.catalog
      |> Catalog.put_host_profile(first_profile)
      |> Catalog.put_surface(first_surface)

    first = %{initial | catalog: catalog}
    assert State.host_profile(first) == first_profile
    assert State.surface(first) == first_surface

    revised =
      catalog
      |> Catalog.put_host_profile(second_profile)
      |> Catalog.put_surface(second_surface)

    second = %{first | catalog: revised}
    assert State.host_profile(second) == second_profile
    assert State.surface(second) == second_surface
    assert second.catalog.host_profiles[first_profile.ref] == first_profile
    assert second.catalog.surfaces[first_surface.ref] == first_surface
    assert map_size(second.catalog.host_profiles) == 2
    assert map_size(second.catalog.surfaces) == 2

    # Catalog updates are materialization only, not commits or authority.
    assert Map.delete(Map.from_struct(first), :catalog) ==
             Map.delete(Map.from_struct(second), :catalog)

    assert State.host_profile(first) == first_profile
    assert State.surface(first) == first_surface
  end

  test "a Definition head is local to its namespace/name, while all revisions remain addressable" do
    first = definition("team-a", "agent", 1)
    second = definition("team-a", "agent", 2, first.ref)
    other_namespace = definition("team-b", "agent", 1)
    other_name = definition("team-a", "worker", 1)

    catalog =
      Enum.reduce([first, other_namespace, other_name, second], %Catalog{}, fn record, catalog ->
        Catalog.put_definition(catalog, record)
      end)

    assert catalog.definition_heads == %{
             Definition.key(first) => second.ref,
             Definition.key(other_namespace) => other_namespace.ref,
             Definition.key(other_name) => other_name.ref
           }

    for record <- [first, second, other_namespace, other_name] do
      assert catalog.definitions[record.ref] == record
      assert {:ok, ^record} = record |> Definition.canonical() |> Definition.from_canonical()
    end

    assert Catalog.put_definition(catalog, second) == catalog
  end

  defp definition(namespace, name, revision, previous_ref \\ nil) do
    assert {:ok, definition} =
             Definition.new(
               namespace: namespace,
               name: name,
               revision: revision,
               previous_ref: previous_ref,
               declared_at: revision
             )

    definition
  end
end
