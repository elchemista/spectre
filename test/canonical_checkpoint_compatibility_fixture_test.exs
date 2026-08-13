defmodule SpectreCanonicalCheckpointCompatibilityFixture.Agent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreCanonicalCheckpointCompatibilityFixture.WaitingWork do
  @moduledoc false

  use Spectre.Work,
    id: :compatibility_waiting_work,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external]

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: wait(:external)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreCanonicalCheckpointCompatibilityFixture.WaitingVigil do
  @moduledoc false

  use Spectre.Vigil,
    id: :compatibility_waiting_vigil,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external],
    triggers: [:external]

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: wait(:external)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}
end

defmodule SpectreCanonicalCheckpointCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Canonical.Codec
  @retired_fixture Path.expand("fixtures/compatibility/0.2.0/canonical-v1.json.base64", __DIR__)
  @v030_fixture Path.expand("fixtures/compatibility/0.3.0/instance-v2.json", __DIR__)

  test "the retired 0.2.0 checkpoint is rejected instead of silently migrated" do
    assert {:error, {:unsupported_canonical_checkpoint, 1}} =
             Codec.decode(read_base64_fixture!(@retired_fixture))
  end

  test "the 0.3.0 checkpoint migrates to schema 3 with an empty record outbox" do
    checkpoint = File.read!(@v030_fixture)

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 3

    assert {:ok, %{schema_version: 1, next_sequence: 1, head_digest: nil, pending: []}} =
             Spectre.Instance.Canonical.fetch(canonical, :record_outbox)

    assert {:ok, current} = Codec.encode(canonical)
    assert current["checkpoint_version"] == 3
    assert current["state_schema_version"] == 3
    assert Map.has_key?(current["sections"], "record_outbox")
  end

  defp read_base64_fixture!(path) do
    path
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
