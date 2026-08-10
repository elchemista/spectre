defmodule SpectreDefinitionManifestV2CompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest

  @definition_fixture "test/fixtures/compatibility/0.2.1/definition-canonical-v1.base64"
  @manifest_fixture "test/fixtures/compatibility/0.2.2/definition-manifest-v2.base64"
  @manifest_digest "81e47611eb9a9a607040b96b0788ad8b4e50629e7a8b7e23b4eb71d2bb02b4db"

  test "Manifest V2 fixture is byte-stable across supported OTP releases" do
    # These atoms are part of the older Definition fixture and must already
    # exist before the atom-safe canonical decoder restores them.
    _fixture_atoms = [
      :fixture,
      :zeta,
      :alpha,
      :nested,
      :a,
      :b,
      :advisory,
      :skill,
      :runtime,
      :ok,
      :sha256
    ]

    definition_encoded = read_fixture(@definition_fixture)
    manifest_encoded = read_fixture(@manifest_fixture)

    assert {:ok, canonical} = Canonical.decode(definition_encoded)
    assert {:ok, manifest} = Manifest.decode(manifest_encoded)
    assert :ok = Manifest.verify(manifest, canonical)

    assert manifest.contract_version == 2
    assert manifest.publisher_ref == "publisher:fixture"
    assert manifest.provenance_refs == ["git:59277c4"]
    assert manifest.execution_closure.compatibility_mode == :adapted_v1
    assert Manifest.digest(manifest) == @manifest_digest
    assert Manifest.encode!(manifest) == manifest_encoded
  end

  defp read_fixture(path), do: path |> File.read!() |> String.trim() |> Base.decode64!()
end
