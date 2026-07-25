defmodule SpectreJournalRecoveryContractTest.Store do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl true
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid) do
      send(pid, {:journal_contract_append, record})
    end

    case Keyword.get(opts, :reply, :ok) do
      {:error_on_sequence, sequence, reason} ->
        if record.sequence == sequence, do: {:error, reason}, else: :ok

      reply ->
        reply
    end
  end
end

defmodule SpectreJournalRecoveryContractTest.Redactor do
  @moduledoc false

  def deny(_record), do: {:error, :privacy_policy_unavailable}
end

defmodule SpectreJournalRecoveryContractTest.Agent do
  @moduledoc false
  use Spectre.Agent

  router(semantic_cache?: false, classification_log?: false)

  flow :journal do
    on :HELLO, regex: ~r/^hello$/ do
      reply("hello")
    end
  end
end

defmodule SpectreJournalRecoveryContractTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Spectre.Input
  alias Spectre.Journal.Buffer
  alias Spectre.Journal.Recorder
  alias Spectre.Result
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context, as: RouterContext
  alias Spectre.State

  @agent SpectreJournalRecoveryContractTest.Agent
  @store SpectreJournalRecoveryContractTest.Store

  test "a synchronous runtime journal stops at the first failed record" do
    result =
      runtime_result([
        %{type: :custom_lifecycle, subject_id: "first"},
        %{type: :effect_completed, effect_id: "must-not-be-written"}
      ])

    config =
      journal(
        mode: :sync,
        on_error: :error,
        events: :all,
        store_opts: [
          pid: self(),
          reply: {:error_on_sequence, 10, :journal_database_down}
        ]
      )

    assert {:error, {:journal_append_failed, :journal_database_down}} =
             Recorder.record_result(result, runtime_context(config))

    assert_receive {:journal_contract_append, %{sequence: 10}}
    refute_receive {:journal_contract_append, %{sequence: 11}}
  end

  test "runtime redaction failures obey error, warning, and ignore contracts" do
    result = runtime_result([%{type: :custom_lifecycle}])
    redact = {SpectreJournalRecoveryContractTest.Redactor, :deny}

    strict = journal(mode: :sync, on_error: :error, events: :all, redact: redact)

    assert {:error,
            {:journal_append_failed, {:journal_redaction_failed, :privacy_policy_unavailable}}} =
             Recorder.record_result(result, runtime_context(strict))

    warning =
      capture_log(fn ->
        tolerant = journal(mode: :sync, on_error: :warn, events: :all, redact: redact)
        assert {:ok, ^result} = Recorder.record_result(result, runtime_context(tolerant))
      end)

    assert warning =~ "spectre_journal append_failed"
    assert warning =~ "record_id=nil"

    ignored = journal(mode: :sync, on_error: :ignore, events: :all, redact: redact)
    assert {:ok, ^result} = Recorder.record_result(result, runtime_context(ignored))
  end

  test "asynchronous runtime delivery returns immediately and isolates store failures" do
    before = Buffer.stats()
    result = runtime_result([%{type: :custom_lifecycle, subject_id: "async"}])

    config =
      journal(
        mode: :async,
        on_error: :warn,
        events: :all,
        store_opts: [pid: self(), reply: {:error, :temporarily_unavailable}]
      )

    assert {:ok, ^result} = Recorder.record_result(result, runtime_context(config))
    assert_receive {:journal_contract_append, %{phase: :lifecycle, sequence: 10}}

    after_stats =
      eventually(fn ->
        stats = Buffer.stats()
        if stats.failed > before.failed, do: stats
      end)

    assert after_stats.failed == before.failed + 1

    ignored =
      journal(
        mode: :async,
        on_error: :ignore,
        events: :all,
        store_opts: [pid: self(), reply: {:error, :still_unavailable}]
      )

    assert {:ok, ^result} = Recorder.record_result(result, runtime_context(ignored))
    assert_receive {:journal_contract_append, %{phase: :lifecycle}}
  end

  test "records defensive routing evidence, configured thresholds, and retention metadata" do
    candidate =
      Candidate.new(%{
        label: :HELLO,
        provider: :regex,
        score: 1.0,
        scope: :agent,
        accepted?: true
      })

    context =
      routing_context(
        journal(
          mode: :sync,
          store_opts: [pid: self()],
          sample_rate: 0.5
        )
      )
      |> Map.put(:candidates, [candidate])
      |> Map.put(:arbitration, %{thresholds: nil})
      |> Map.put(:traces, [{:unknown_router_trace, :safe_detail}])
      |> Map.update!(:opts, fn opts ->
        Keyword.put(
          opts,
          :arbitrator,
          {Spectre.Router.Arbitrators.Default, [classifier_accept: 0.91]}
        )
      end)

    assert {:ok, ^context} = Recorder.record_routing(context)

    result = runtime_result([%{type: :custom_lifecycle}])

    retained =
      journal(
        mode: :sync,
        events: :all,
        retention: %{days: 30, tier: :audit},
        store_opts: [pid: self()]
      )

    assert {:ok, ^result} = Recorder.record_result(result, runtime_context(retained))

    assert_receive {:journal_contract_append,
                    %{metadata: %{retention: %{days: 30, tier: :audit}}}}
  end

  test "invalid scalar configuration is rejected at routing and runtime boundaries" do
    assert {:error, {:invalid_journal_configuration, 123}} =
             Recorder.record_routing(routing_context(123))

    result = runtime_result([%{type: :custom_lifecycle}])

    assert {:error, {:invalid_journal_configuration, 123}} =
             Recorder.record_result(result, runtime_context(123))
  end

  test "buffer overflow remains observational and never fails the routed turn" do
    assert_buffer_idle()
    parent = self()

    assert :ok =
             Buffer.enqueue(
               fn ->
                 send(parent, {:journal_blocker_started, self()})

                 receive do
                   :release -> :ok
                 end
               end,
               buffer_size: 1,
               partition: @store
             )

    assert_receive {:journal_blocker_started, blocker}

    context =
      routing_context(
        journal(
          mode: :async,
          on_error: :warn,
          buffer_size: 1,
          overflow: :drop_newest
        )
      )

    log =
      capture_log(fn ->
        assert {:ok, ^context} = Recorder.record_routing(context)
      end)

    assert log =~ "journal_buffer_full"
    send(blocker, :release)
    assert eventually(fn -> if Buffer.stats().running? == false, do: :idle end) == :idle
  end

  test "dropping an old queued record and a missing buffer are both contained" do
    assert_buffer_idle()
    parent = self()

    assert :ok =
             Buffer.enqueue(
               fn ->
                 send(parent, {:oldest_blocker_started, self()})

                 receive do
                   :release -> :ok
                 end
               end,
               buffer_size: 2,
               partition: @store
             )

    assert_receive {:oldest_blocker_started, blocker}

    assert :ok =
             Buffer.enqueue(fn -> send(parent, :oldest_record_should_be_dropped) end,
               buffer_size: 2,
               partition: @store
             )

    context =
      routing_context(
        journal(
          mode: :async,
          on_error: :warn,
          buffer_size: 2,
          overflow: :drop_oldest
        )
      )

    dropped_log =
      capture_log(fn ->
        assert {:ok, ^context} = Recorder.record_routing(context)
      end)

    assert dropped_log =~ "journal_buffer_dropped_oldest"
    send(blocker, :release)
    refute_receive :oldest_record_should_be_dropped
    assert eventually(fn -> if Buffer.stats().running? == false, do: :idle end) == :idle

    supervisor = Process.whereis(Spectre.ApplicationSupervisor)
    assert :ok = Supervisor.terminate_child(supervisor, Buffer)

    on_exit(fn ->
      case Supervisor.restart_child(supervisor, Buffer) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end)

    missing_log =
      capture_log(fn ->
        assert {:ok, ^context} = Recorder.record_routing(context)
      end)

    assert missing_log =~ "journal_buffer_exit"
  end

  defp routing_context(journal) do
    %RouterContext{
      input: Input.new(%{text: "hello", meta: %{conversation_id: "from-input"}}),
      host_context: %{state: %State{conversation_id: "journal-contract", revision: 4}},
      opts: [
        journal: journal,
        spectre_agent: @agent,
        turn_id: "journal-turn",
        trace_id: "journal-trace"
      ],
      labels: [:HELLO],
      rules: [],
      candidates: [],
      traces: [],
      errors: []
    }
  end

  defp runtime_result(events) do
    %Result{
      input: Input.new("runtime input"),
      reply_text: "runtime reply",
      state: %State{conversation_id: "journal-contract", revision: 5},
      events: events
    }
  end

  defp runtime_context(journal) do
    %{
      agent: @agent,
      opts: [
        journal: journal,
        turn_id: "journal-turn",
        trace_id: "journal-trace"
      ]
    }
  end

  defp journal(opts), do: {@store, opts}

  defp assert_buffer_idle do
    assert eventually(fn ->
             stats = Buffer.stats()

             if stats.queue_depth == 0 and stats.running? == false do
               :idle
             end
           end) == :idle
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      false ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(fun, 0), do: fun.()
end
