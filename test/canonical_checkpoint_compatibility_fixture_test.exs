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

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  @retired_fixture Path.expand("fixtures/compatibility/0.2.0/canonical-v1.json.base64", __DIR__)
  @v030_fixture Path.expand("fixtures/compatibility/0.3.0/instance-v2.json", __DIR__)

  @v030_advanced_fixture Path.expand(
                           "fixtures/compatibility/0.3.0/instance-v2-advanced.json",
                           __DIR__
                         )

  @v030_advanced_sha256 "df82780db44d93011f3064e0132263396c6a1e2c1481d08e4419fc9cfe68bfe9"

  test "the retired 0.2.0 checkpoint is rejected instead of silently migrated" do
    assert {:error, {:unsupported_canonical_checkpoint, 1}} =
             Codec.decode(read_base64_fixture!(@retired_fixture))
  end

  test "the 0.3.0 checkpoint remains readable by the schema-2 writer" do
    checkpoint = File.read!(@v030_fixture)

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 2
    assert canonical.revision == 0

    assert {:ok, encoded} = Codec.encode(canonical)
    assert encoded["checkpoint_version"] == 2
    assert encoded["state_schema_version"] == 2

    assert Map.keys(encoded["sections"]) |> Enum.sort() ==
             ~w(activation control correlations directive event_admissions event_quarantine events flow lifecycles runs skill_states vigil work)
  end

  test "the advanced 0.3.0 checkpoint preserves a real waiting Work semantically" do
    # Values introduced by the 0.3.0 operational scenario are deliberately
    # pre-existing atoms; decoding an untrusted checkpoint never creates them.
    _fixture_atoms = [
      SpectreCanonicalCheckpointCompatibilityFixture.WaitingWork,
      :advanced,
      :compatibility_waiting_work,
      :definition,
      :fixture,
      :instance_key,
      :legacy,
      :loop_boundary,
      :loop_ids,
      :loop_started,
      :operation_scheduler,
      :owner_fencing_token,
      :publication,
      :publish_artifacts,
      :publish_blocker,
      :publish_progress,
      :publish_results,
      :spectre_activation_generation,
      :spectre_authority_epoch,
      :spectre_closure_digest,
      :spectre_definition_ref,
      :trigger_correlation,
      :wait_id
    ]

    checkpoint = File.read!(@v030_advanced_fixture)

    assert Base.encode16(:crypto.hash(:sha256, checkpoint), case: :lower) ==
             @v030_advanced_sha256

    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert canonical.schema_version == 2
    assert canonical.revision == 2
    assert Enum.map(canonical.journal, & &1.to_revision) == [2, 1]

    assert {:ok, work} = Canonical.fetch(canonical, :work)

    assert %Spectre.Operation.Loop{
             id: "advanced-work",
             kind: :work,
             status: :waiting,
             revision: 1,
             state: %{fixture: :advanced},
             correlation_id: "advanced-correlation"
           } = work["advanced-work"]

    assert {:ok, %{records: [waiting, started]}} = Canonical.fetch(canonical, :events)
    assert {waiting.type, waiting.revision} == {:waiting, 2}
    assert {started.type, started.revision} == {:started, 1}

    assert {:ok, reencoded} = Codec.encode_json(canonical)
    assert {:ok, ^canonical} = Codec.decode(reencoded)
  end

  defp read_base64_fixture!(path) do
    path
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
