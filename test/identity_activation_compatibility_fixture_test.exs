defmodule SpectreIdentityActivationCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Run

  @fixture Path.expand(
             "fixtures/compatibility/0.2.3/identity-activation-canonical-v2.json.base64",
             __DIR__
           )

  test "the permanent 0.2.3 checkpoint restores Activation and its pinned Run" do
    _fixture_atoms = [:instance_key, :records, :ids]
    Code.ensure_loaded!(Activation)
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 2,
             "state_schema_version" => 2
           } = encoded = Jason.decode!(checkpoint)

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 3
    definition_ref_string = "sha256:" <> String.duplicate("a", 64)

    assert {:ok, %{^definition_ref_string => lifecycle}} =
             Canonical.fetch(canonical, :lifecycles)

    assert lifecycle.activation == :active
    assert lifecycle.authority_epoch == 7

    assert {:ok,
            %Activation{
              generation: 3,
              authority_epoch: 7,
              owner_fencing_token: 11,
              publication_id: "publication-0.2.3-fixture"
            } = activation} = Canonical.fetch(canonical, :activation)

    assert DefinitionRef.to_string(activation.definition_ref) == definition_ref_string

    assert CandidateRef.to_string(activation.candidate_ref) ==
             "candidate:sha256:" <> String.duplicate("b", 64)

    assert {:ok, %{"run-0.2.3-pinned" => run_checkpoint}} =
             Canonical.fetch(canonical, :runs)

    assert {:ok,
            %Run{
              run_version: 2,
              id: "run-0.2.3-pinned",
              status: :ready,
              activation_generation: 3,
              authority_epoch: 7,
              definition_ref: definition_ref,
              closure_digest: closure_digest
            } = run} = Run.restore(run_checkpoint)

    assert definition_ref == activation.definition_ref
    assert closure_digest == activation.closure_digest
    assert run.input.raw == nil
    assert run.input.meta == %{"locale" => "it"}
    assert run.state.data == %{"checkpoint" => "activation-pinned"}

    assert {:ok, reencoded} = Codec.encode(canonical)
    assert reencoded["checkpoint_version"] == 3
    refute reencoded["checkpoint_version"] == encoded["checkpoint_version"]
    assert {:ok, ^canonical} = reencoded |> Jason.encode!() |> Codec.decode()
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
