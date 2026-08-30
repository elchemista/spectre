defmodule SpectreSkillStateCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Canonical.Codec

  @fixture Path.expand(
             "fixtures/compatibility/0.2.5/skill-state-canonical-v4.json.base64",
             __DIR__
           )

  test "the retired 0.2.5 checkpoint is rejected instead of trusting old bindings" do
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 4,
             "state_schema_version" => 4
           } = Spectre.JSON.decode!(checkpoint)

    assert {:error, {:unsupported_canonical_checkpoint, 4}} = Codec.decode(checkpoint)
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
