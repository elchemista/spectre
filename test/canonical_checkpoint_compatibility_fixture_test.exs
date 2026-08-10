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

  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Operation.Control
  alias Spectre.Operation.Event
  alias Spectre.Operation.Loop
  alias Spectre.Operation.View
  alias Spectre.Operation.Wait
  alias Spectre.State
  alias Spectre.Subject

  @agent SpectreCanonicalCheckpointCompatibilityFixture.Agent
  @fixture Path.expand("fixtures/compatibility/0.2.0/canonical-v1.json.base64", __DIR__)
  @subject "compatibility-canonical-0.2.0"
  @work_id "compatibility-work-v1"
  @vigil_id "compatibility-vigil-v1"

  test "the permanent 0.2.0 canonical checkpoint restores Flow, Work, Vigil and events" do
    # Canonical atoms are decoded with String.to_existing_atom/1. Load the
    # producer before decoding so the fixture does not depend on test order.
    Code.ensure_loaded!(Instance)

    checkpoint = read_fixture!()

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 2
    assert {:ok, nil} = Canonical.fetch(canonical, :activation)
    assert canonical.revision > 0

    assert {:ok, %State{} = flow} = Canonical.fetch(canonical, :flow)
    assert flow.state_version == 5

    assert {:ok,
            %{
              @work_id => %Loop{
                kind: :work,
                status: :waiting,
                wait: %Wait{kind: :external}
              }
            }} = Canonical.fetch(canonical, :work)

    assert {:ok,
            %{
              @vigil_id => %Loop{
                kind: :vigil,
                status: :waiting,
                wait: %Wait{kind: :external}
              }
            }} = Canonical.fetch(canonical, :vigil)

    assert {:ok,
            %{
              @work_id => %Control{state: :active},
              @vigil_id => %Control{state: :active}
            }} = Canonical.fetch(canonical, :control)

    assert {:ok, %{records: records}} = Canonical.fetch(canonical, :events)
    assert_event_lifecycle(records, @work_id, :work)
    assert_event_lifecycle(records, @vigil_id, :vigil)

    instance =
      start_supervised!(
        {Instance,
         agent: @agent,
         subject: Subject.new(@subject),
         canonical_checkpoint: checkpoint,
         idle: false}
      )

    assert {:ok, %View{kind: :work, status: :waiting, wait_ref: %{kind: :external}}} =
             Spectre.loop(instance, @work_id)

    assert {:ok, %View{kind: :vigil, status: :waiting, wait_ref: %{kind: :external}}} =
             Spectre.loop(instance, @vigil_id)

    assert {:ok, restored_checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, restored} = Codec.decode(restored_checkpoint)
    assert restored.revision == canonical.revision + 1

    assert {:ok, %{instance_key_migration: migration}} =
             Canonical.fetch(restored, :correlations)

    assert migration.legacy_instance_key != migration.stable_instance_key
  end

  defp assert_event_lifecycle(records, loop_id, kind) do
    events = Enum.filter(records, &match?(%Event{loop_id: ^loop_id, loop_kind: ^kind}, &1))

    assert Enum.any?(events, &(&1.type == :started))
    assert Enum.any?(events, &(&1.type == :waiting))
  end

  defp read_fixture! do
    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
