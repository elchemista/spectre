defmodule SpectreSkillStateCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.SkillStates
  alias Spectre.Skill.StateBinding

  @fixture Path.expand(
             "fixtures/compatibility/0.2.5/skill-state-canonical-v4.json.base64",
             __DIR__
           )

  test "the permanent 0.2.5 checkpoint restores selected and dormant Skill branches" do
    _fixture_atoms = [:active_branch, :branches]
    Code.ensure_loaded!(Activation)
    Code.ensure_loaded!(StateBinding)
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 4,
             "state_schema_version" => 4
           } = Jason.decode!(checkpoint)

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 4

    assert {:ok,
            %Activation{
              generation: 2,
              authority_epoch: 4,
              owner_fencing_token: 9
            } = activation} = Canonical.fetch(canonical, :activation)

    assert {:ok,
            %{
              "planner" => %{
                active_branch: "fixture-branch-b",
                branches: %{
                  "fixture-branch-a" =>
                    %StateBinding{
                      status: :dormant,
                      state_generation: 1,
                      state: %{"owner" => "A", "value" => 2}
                    } = branch_a,
                  "fixture-branch-b" =>
                    %StateBinding{
                      status: :active,
                      state_generation: 2,
                      parent_branch_id: "fixture-branch-a",
                      state: %{"owner" => "B", "value" => 10}
                    } = branch_b
                }
              }
            } = skill_states} = Canonical.fetch(canonical, :skill_states)

    assert DefinitionRef.to_string(branch_a.owning_definition_ref) ==
             "sha256:" <> String.duplicate("a", 64)

    assert DefinitionRef.to_string(branch_b.owning_definition_ref) ==
             "sha256:" <> String.duplicate("b", 64)

    assert branch_a.state != branch_b.state
    assert activation.state_bindings["planner"] == StateBinding.activation_pointer(branch_b)
    assert :ok = SkillStates.validate_activation(skill_states, activation)
    assert {:ok, encoded} = Codec.encode_json(canonical)
    assert {:ok, ^canonical} = Codec.decode(encoded)
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
