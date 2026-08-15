defmodule SpectreEventLifecycleCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Canonical.Codec

  @fixture Path.expand(
             "fixtures/compatibility/0.2.4/event-lifecycle-canonical-v3.json.base64",
             __DIR__
           )
  test "the retired 0.2.4 checkpoint is rejected instead of partially restored" do
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 3,
             "state_schema_version" => 3
           } = Jason.decode!(checkpoint)

    assert {:error, {:invalid_canonical_checkpoint_format, nil}} = Codec.decode(checkpoint)
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
