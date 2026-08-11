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
  @fixture Path.expand("fixtures/compatibility/0.2.0/canonical-v1.json.base64", __DIR__)

  test "the retired 0.2.0 checkpoint is rejected instead of silently migrated" do
    assert {:error, {:unsupported_canonical_checkpoint, 1}} = Codec.decode(read_fixture!())
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
