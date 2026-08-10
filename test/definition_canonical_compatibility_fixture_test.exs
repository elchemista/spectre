defmodule SpectreDefinitionCanonicalCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref

  @fixture "test/fixtures/compatibility/0.2.1/definition-canonical-v1.base64"
  @definition_ref "sha256:a71534616de5e1f8da459d2fd6c8e63d76412fa3a765e4329a9a8b5aba0ecdb1"

  test "canonical Definition v1 fixture is byte-stable across supported OTP releases" do
    encoded = @fixture |> File.read!() |> String.trim() |> Base.decode64!()

    assert {:ok, canonical} = Canonical.decode(encoded)
    assert canonical.kind == :skill
    assert canonical.id == {:fixture, "0.2.1"}
    assert canonical.origin == :runtime
    assert canonical.declared_version == "2026-08"

    assert [component] = canonical.components
    assert component.component_type == :fixture
    assert component.criticality == :advisory

    assert component.payload == %{
             zeta: {:ok, <<0, 255>>},
             alpha: [1, -2, 3.5],
             nested: %{a: nil, b: true}
           }

    assert Canonical.encode!(canonical) == encoded
    assert canonical |> Canonical.ref() |> Ref.to_string() == @definition_ref
  end
end
