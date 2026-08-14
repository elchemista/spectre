defmodule SpectreObservabilityContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/does-not-exist"

  fail(:agent_failure_reply)
end

defmodule SpectreObservabilityContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spectre.AgentRef
  alias Spectre.Canonical.Value
  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.State
  alias Spectre.Subject

  @agent SpectreObservabilityContractTest.Agent

  test "Instance telemetry keeps numeric measurements and redacted context metadata" do
    test_pid = self()
    raw_run_id = "private-run-id"
    raw_reason = {:adapter_failed, "private-adapter-response", %{attempt: 2}}

    handler = fn event, measurements, metadata ->
      send(test_pid, {:instance_telemetry, event, measurements, metadata})
    end

    data = instance_state(base_opts: [telemetry_handler: handler])

    assert {:noreply, ^data} =
             Instance.handle_info(
               {:spectre, :advance_result, raw_run_id, "dispatch", :advance, :stale},
               data
             )

    assert_receive {:instance_telemetry, [:spectre, :instance, :stale_move_result], measurements,
                    metadata}

    assert Enum.all?(measurements, fn {_key, value} -> is_number(value) end)
    assert measurements == %{count: 1}
    assert metadata.run_id == Value.digest!(raw_run_id)
    assert metadata.instance_id == Value.digest!(data.ref.key)
    assert metadata.generation == data.generation
    refute inspect(metadata) =~ raw_run_id

    monitor = make_ref()

    checkpoint_data = %{
      data
      | checkpoint_inflight: %{
          token: "checkpoint-token",
          revision: data.canonical.revision,
          expected_revision: data.checkpoint_revision,
          canonical: data.canonical,
          pid: self(),
          monitor: monitor
        }
    }

    assert {:noreply, checkpoint_failed} =
             Instance.handle_info({:DOWN, monitor, :process, self(), raw_reason}, checkpoint_data)

    assert checkpoint_failed.checkpoint_inflight == nil

    assert_receive {:instance_telemetry, [:spectre, :instance, :checkpoint_failed], %{count: 1},
                    failed_metadata}

    assert failed_metadata.reason_class == :adapter_failed
    assert failed_metadata.revision == data.canonical.revision
    assert failed_metadata.outcome == :ambiguous
    refute inspect(metadata) =~ "private-adapter-response"
    refute inspect(failed_metadata) =~ "private-adapter-response"
  end

  test "checkpoint telemetry distinguishes terminal failures from ambiguous outcomes" do
    test_pid = self()

    handler = fn event, measurements, metadata ->
      send(test_pid, {:checkpoint_telemetry, event, measurements, metadata})
    end

    data = instance_state(base_opts: [telemetry_handler: handler])
    revision = data.canonical.revision
    terminal_reason = {:checkpoint_store_failed, "private-terminal-reason"}

    terminal = checkpoint_inflight(data, "terminal-checkpoint")

    assert {:noreply, terminal_failed} =
             Instance.handle_info(
               {:spectre, :checkpoint_result, "terminal-checkpoint", revision,
                {:error, terminal_reason}},
               terminal
             )

    assert terminal_failed.checkpoint_reconciliation == nil

    assert_receive {:checkpoint_telemetry, [:spectre, :instance, :checkpoint_failed], %{count: 1},
                    terminal_metadata}

    assert terminal_metadata.outcome == :failed
    assert terminal_metadata.reason_class == :checkpoint_store_failed
    refute inspect(terminal_metadata) =~ "private-terminal-reason"

    ambiguous = checkpoint_inflight(data, "ambiguous-checkpoint")
    ambiguous_reason = {:ambiguous, {:transport_closed, "private-ambiguous-reason"}}

    assert {:noreply, ambiguous_failed} =
             Instance.handle_info(
               {:spectre, :checkpoint_result, "ambiguous-checkpoint", revision,
                {:error, ambiguous_reason}},
               ambiguous
             )

    assert not is_nil(ambiguous_failed.checkpoint_reconciliation)

    assert_receive {:checkpoint_telemetry, [:spectre, :instance, :checkpoint_failed], %{count: 1},
                    ambiguous_metadata}

    assert ambiguous_metadata.outcome == :ambiguous
    assert ambiguous_metadata.reason_class == :ambiguous
    refute inspect(ambiguous_metadata) =~ "private-ambiguous-reason"
  end

  test "info and checkpoint status are passive reads and checkpoint errors expose only a class" do
    timer = Process.send_after(self(), :observability_idle_timeout, 60_000)
    on_exit(fn -> Process.cancel_timer(timer) end)

    raw_reason = {:checkpoint_store_failed, "private-store-response", %{retry: false}}

    data =
      instance_state(
        checkpoint_error: raw_reason,
        idle_timeout: 60_000,
        idle_timer: timer,
        idle_generation: 7
      )

    assert {:reply, info, ^data} =
             Instance.handle_call(:instance_info, {self(), make_ref()}, data)

    assert info.canonical_revision == data.canonical.revision

    assert {:reply, status, ^data} =
             Instance.handle_call(:canonical_checkpoint_status, {self(), make_ref()}, data)

    assert status.error == :checkpoint_store_failed
    refute inspect(status) =~ "private-store-response"
  end

  test "healthy checkpoint status preserves nil instead of fabricating an error class" do
    data = instance_state(checkpoint_error: nil)

    assert {:reply, status, ^data} =
             Instance.handle_call(:canonical_checkpoint_status, {self(), make_ref()}, data)

    assert status.error == nil
  end

  test "host state reads remain activity and re-arm the idle timer" do
    original_timer = Process.send_after(self(), :original_idle_timeout, 60_000)

    data =
      instance_state(
        idle_timeout: 60_000,
        idle_timer: original_timer,
        idle_generation: 7
      )

    assert {:reply, state, next} =
             Instance.handle_call(:state, {self(), make_ref()}, data)

    assert state == data.state
    assert next.idle_generation == 8
    assert is_reference(next.idle_timer)
    assert next.idle_timer != original_timer
    assert Process.read_timer(original_timer) == false

    Process.cancel_timer(next.idle_timer)
  end

  test "custom and standard telemetry handlers fail independently" do
    setup_standard_telemetry_stub()

    assert :ok =
             Spectre.Telemetry.emit(
               [:handler_isolation],
               %{count: 1},
               %{contract_pid: self()},
               telemetry_handler: fn _event, _measurements, _metadata ->
                 raise "custom handler failed"
               end
             )

    assert_receive {:standard_telemetry, [:spectre, :handler_isolation], %{count: 1}}

    test_pid = self()

    assert :ok =
             Spectre.Telemetry.emit(
               [:standard_isolation],
               %{count: 1},
               %{contract_pid: self(), raise_standard?: true},
               telemetry_handler: fn event, measurements, _metadata ->
                 send(test_pid, {:custom_telemetry, event, measurements})
               end
             )

    assert_receive {:custom_telemetry, [:spectre, :standard_isolation], %{count: 1}}
  end

  test "Monitor logs contain only digested identifiers and reason classes" do
    raw_conversation_id = "private-conversation-id"
    raw_message_id = "private-message-id"
    raw_user_id = "private-user-id"
    raw_chat_id = "private-chat-id"
    raw_channel = "private-channel"
    raw_reason = "private-adapter-response"
    raw_outbound_id = "private-outbound-id"

    context = %{
      conversation_id: raw_conversation_id,
      message_id: raw_message_id,
      user_id: raw_user_id,
      external_chat_id: raw_chat_id,
      channel: raw_channel
    }

    log =
      capture_log(fn ->
        assert {:ok, result} =
                 Spectre.Monitor.dispatch(@agent, context,
                   run: fn -> {:error, {:adapter_failed, raw_reason}} end,
                   fallback_exists?: fn _context -> :not_found end,
                   create_fallback: fn _context, _text, _reason ->
                     {:ok,
                      %{
                        status: "private-status",
                        delivery: {:sent, raw_reason},
                        outbound_id: raw_outbound_id,
                        conversation_id: raw_conversation_id,
                        message_id: raw_message_id
                      }}
                   end
                 )

        assert result.outbound_id == raw_outbound_id
      end)

    assert log =~ "reason=adapter_failed"
    assert log =~ Value.digest!(raw_conversation_id)
    assert log =~ "result=%{"
    assert log =~ "delivery: :sent"
    assert log =~ "status: :present"

    for private <- [
          raw_conversation_id,
          raw_message_id,
          raw_user_id,
          raw_chat_id,
          raw_channel,
          raw_reason,
          raw_outbound_id
        ] do
      refute log =~ private
    end
  end

  defp instance_state(overrides) do
    agent_ref = AgentRef.new(@agent)
    subject = Subject.new("observability-contract-subject")
    ref = InstanceRef.new(agent_ref, subject)
    state = %State{conversation_id: ref.key}

    {:ok, canonical} =
      Canonical.new(%{
        flow: state,
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key},
        events: %{records: [], ids: %{}}
      })

    lease =
      Lease.new!(
        owner_id: "observability-contract-owner",
        fencing_token: 1,
        issued_at: 0,
        metadata: %{instance_key: ref.key, scope: :single_owner_local}
      )

    defaults = %{
      agent: @agent,
      agent_ref: agent_ref,
      subject: subject,
      ref: ref,
      state: state,
      canonical: canonical,
      owner_lease: lease,
      base_opts: [],
      idle_timeout: false,
      max_runs: 16,
      max_tombstones: 16,
      max_operation_runners: 1,
      generation: "observability-contract-generation",
      checkpoint_mode: :manual,
      checkpoint_revision: 0
    }

    struct!(InstanceState, Map.merge(defaults, Map.new(overrides)))
  end

  defp checkpoint_inflight(data, token) do
    monitor = make_ref()

    %{
      data
      | checkpoint_inflight: %{
          token: token,
          revision: data.canonical.revision,
          expected_revision: data.checkpoint_revision,
          canonical: data.canonical,
          pid: self(),
          monitor: monitor
        }
    }
  end

  defp setup_standard_telemetry_stub do
    refute Code.ensure_loaded?(:telemetry)

    {:module, :telemetry, _binary, _term} =
      Module.create(
        :telemetry,
        quote do
          def execute(event, measurements, metadata) do
            if Map.get(metadata, :raise_standard?) do
              raise "standard telemetry handler failed"
            end

            send(Map.fetch!(metadata, :contract_pid), {:standard_telemetry, event, measurements})
            :ok
          end
        end,
        Macro.Env.location(__ENV__)
      )

    on_exit(fn ->
      :code.purge(:telemetry)
      :code.delete(:telemetry)
    end)
  end
end
