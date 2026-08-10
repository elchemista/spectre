defmodule SpectreEventLifecycleCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Event.Envelope
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Lifecycle

  @fixture Path.expand(
             "fixtures/compatibility/0.2.4/event-lifecycle-canonical-v3.json.base64",
             __DIR__
           )
  @definition_ref "sha256:" <> String.duplicate("d", 64)

  test "the permanent 0.2.4 checkpoint restores event ownership and lifecycle fences" do
    _fixture_atoms = [:records, :ids]
    Code.ensure_loaded!(Envelope)
    Code.ensure_loaded!(Lifecycle)
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 3,
             "state_schema_version" => 3
           } = Jason.decode!(checkpoint)

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 4
    assert canonical.revision == 1
    assert {:ok, %{}} = Canonical.fetch(canonical, :skill_states)

    assert {:ok,
            %{
              @definition_ref =>
                %Lifecycle{
                  admission: :draining,
                  authority: :granted,
                  retention: :retained,
                  activation: :active,
                  authority_epoch: 9,
                  revision: 1
                } = lifecycle
            }} = Canonical.fetch(canonical, :lifecycles)

    assert DefinitionRef.to_string(lifecycle.definition_ref) == @definition_ref

    assert {:ok,
            %{
              records: [
                %Envelope{
                  id: "event-0.2.4-admitted",
                  status: :admitted,
                  admission_revision: 1,
                  authority_epoch: 9,
                  owner_fencing_token: 13
                } = admitted
              ]
            }} = Canonical.fetch(canonical, :event_admissions)

    assert DefinitionRef.to_string(admitted.owner_definition_ref) == @definition_ref
    assert is_binary(admitted.admission_receipt)

    assert {:ok,
            %{
              records: [
                %Envelope{
                  id: "event-0.2.4-quarantined",
                  status: :quarantined,
                  owner_definition_ref: nil,
                  quarantine_reason: %{"kind" => "missing_continuation"}
                } = quarantined
              ]
            }} = Canonical.fetch(canonical, :event_quarantine)

    assert is_binary(quarantined.admission_receipt)
    assert {:ok, encoded} = Codec.encode_json(canonical)
    assert %{"checkpoint_version" => 4, "state_schema_version" => 4} = Jason.decode!(encoded)
    assert {:ok, ^canonical} = Codec.decode(encoded)
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
