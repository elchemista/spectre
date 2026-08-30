defmodule SpectreIdentityActivationCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Canonical.Codec

  @fixture Path.expand(
             "fixtures/compatibility/0.2.3/identity-activation-canonical-v2.json.base64",
             __DIR__
           )

  test "the retired 0.2.3 schema collision is rejected without fallback" do
    checkpoint = read_fixture!()

    assert %{
             "checkpoint_version" => 2,
             "state_schema_version" => 2
           } = Spectre.JSON.decode!(checkpoint)

    assert {:error, {:invalid_canonical_checkpoint_format, nil}} = Codec.decode(checkpoint)
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
