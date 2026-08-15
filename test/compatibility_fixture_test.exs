defmodule SpectreCompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Run
  alias Spectre.State
  alias Spectre.State.Codec

  @fixtures Path.expand("fixtures/compatibility/0.1.6", __DIR__)

  @state_fixture_atoms [
    :baseline,
    :beam,
    :captured_at,
    :checkpoint,
    :confirm_publish,
    :created_at,
    :dsl,
    :event,
    :fixture,
    :local,
    :locale,
    :memory,
    :policy_opened,
    :prompt,
    :publish,
    :publishing,
    :run_id,
    :skill,
    :source,
    :telegram,
    :via,
    :waiting
  ]

  @run_fixture_atoms [
    :authenticated?,
    :baseline,
    :beam,
    :checkpoint,
    :compatibility,
    :fixture,
    :locale,
    :ready,
    :request,
    :role,
    :telegram
  ]

  test "the permanent State v5 fixture restores its lifecycle ownership" do
    _loaded_atoms = @state_fixture_atoms
    fixture = File.read!(Path.join(@fixtures, "state-v5.json"))

    assert {:ok,
            %State{
              state_version: 5,
              revision: 12,
              conversation_id: {:beam, :telegram, "chat-42"},
              current_flow: :publishing,
              current_scope: {:skill, :baseline},
              data: %{
                checkpoint: :waiting,
                locale: "it",
                captured_at: ~U[2026-07-31 08:15:00Z]
              },
              memory_refs: [{:memory, "note-7"}]
            } = state} = Codec.decode(fixture)

    assert [
             %Effect{
               id: "effect-state-v5-001",
               name: :publish,
               owner: Spectre,
               scope: {:skill, :baseline},
               run_id: "run-compat-001",
               status: :waiting_policy,
               policy: :confirm_publish
             }
           ] = state.pending_effects

    assert [
             %Awaitable{
               id: "awaitable-state-v5-001",
               subject_id: "effect-state-v5-001",
               run_id: "run-compat-001",
               status: :open,
               attempts: 1
             }
           ] = state.awaitables

    assert [%{event: :policy_opened, run_id: "run-compat-001"}] = state.trace
  end

  test "the permanent Run v1 checkpoint restores through the public codec" do
    _loaded_atoms = @run_fixture_atoms
    checkpoint = read_base64_fixture("run-v1.checkpoint.base64")

    assert {:ok,
            %Run{
              run_version: 3,
              id: "run-0.1.6-ready",
              agent: Spectre,
              status: :ready,
              cursor: :turn,
              revision: 0,
              trace_id: "trace-0.1.6-ready",
              causation_id: "cause-0.1.6",
              correlation_id: "correlation-0.1.6"
            } = run} = Run.restore(checkpoint)

    assert %Spectre.Definition.Ref{} = run.definition_ref
    assert run.activation_generation == 0
    assert run.authority_epoch == 0
    assert is_binary(run.closure_digest)

    assert run.input.text == "resume the 0.1.6 baseline"
    assert run.input.raw == nil
    assert run.input.meta == %{locale: "it", request: {:compatibility, 16}}
    assert run.input.source.mount == :telegram
    assert run.state.state_version == 5
    assert run.state.revision == 7
    assert run.state.data == %{checkpoint: :ready}
    assert run.metadata == %{fixture: "0.1.6", role: :baseline}
    refute run.start_continuation.recoverable?
    assert run.start_continuation.reason == :legacy_ready_run_without_start_continuation

    assert {:ok, reencoded} = Run.checkpoint(run)
    assert {:ok, ^run} = Run.restore(reencoded)
  end

  defp read_base64_fixture(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
