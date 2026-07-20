defmodule SpectreHardeningCompletionTest.Actions do
  @moduledoc false

  def perform(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:hardening_action, args})
    {:ok, {:performed, args}}
  end
end

defmodule SpectreHardeningCompletionTest.Agent do
  @moduledoc false
  use Spectre.Agent

  actions(SpectreHardeningCompletionTest.Actions)

  interrupt :HELP, regex: ~r/^help$/ do
    run(:show_help)
  end

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{safe: true})
    end
  end

  def show_help(_input, _ctx), do: "interrupt help"
end

defmodule SpectreHardeningCompletionTest.Store do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl true
  def append(record, opts) do
    send(Keyword.fetch!(opts, :pid), {:hardening_journal, record})
    :ok
  end
end

defmodule SpectreHardeningCompletionTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Journal.Record
  alias Spectre.Journal.Recorder
  alias Spectre.Lifecycle
  alias Spectre.Policy
  alias Spectre.Policy.Matcher
  alias Spectre.Policy.Resolution
  alias Spectre.Result
  alias Spectre.Router.Arbitration
  alias Spectre.Router.Arbitrators.Default
  alias Spectre.Router.Candidate
  alias Spectre.State

  @agent SpectreHardeningCompletionTest.Agent

  describe "canonical lifecycle command surface" do
    test "legal action transitions are command-driven and repeat-safe" do
      effect = action_effect()

      assert {:ok, staged} = Lifecycle.apply(%State{}, {:stage_effect, effect, nil})
      assert staged.event == :effect_staged
      assert staged.effect.status == :pending

      assert {:ok, completed} =
               Lifecycle.apply(staged.to, {:complete_effect, effect.id, :done})

      assert completed.effect.status == :completed

      assert {:ok, replayed} =
               Lifecycle.apply(completed.to, {:complete_effect, effect.id, :other})

      assert replayed.replayed?
      assert replayed.effect.result == :done
    end

    test "policy accept and reject are atomic transitions" do
      for {kind, label, expected_status, pending_count} <- [
            {:accept, :yes, :approved, 1},
            {:reject, :no, :cancelled, 0}
          ] do
        {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})
        assert {:ok, resolved} = Lifecycle.apply(opened.to, {:resolve_policy, kind, label})
        assert resolved.effect.status == expected_status
        assert length(resolved.to.pending_effects) == pending_count
        assert resolved.awaitable.status == if(kind == :accept, do: :accepted, else: :rejected)
      end
    end

    test "every executable command rejects a waiting-policy effect" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})
      id = opened.effect.id

      for command <- [{:complete_effect, id, :done}, {:fail_effect, id, :failed}] do
        assert {:error, {:invalid_effect_transition, ^id, :waiting_policy, _target}} =
                 Lifecycle.apply(opened.to, command)
      end
    end

    test "policy attempts are explicit and terminal attempts cannot be incremented" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})
      awaitable = opened.awaitable

      assert {:ok, attempted} = Lifecycle.apply(opened.to, {:policy_attempt, awaitable.id})
      assert attempted.awaitable.attempts == 1

      assert {:ok, resolved} = Lifecycle.apply(attempted.to, {:resolve_policy, :reject, :no})

      assert {:error, {:invalid_awaitable_transition, _, :rejected, :attempted}} =
               Lifecycle.apply(resolved.to, {:policy_attempt, awaitable.id})
    end

    test "policy expiration cancels only its gated effect" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})
      assert {:ok, expired} = Lifecycle.apply(opened.to, {:expire_policy, opened.awaitable.id})
      assert expired.event == :policy_expired
      assert expired.awaitable.status == :expired
      assert Effect.outcome(expired.effect) == {:cancelled, :policy_expired}
      assert expired.to.pending_effects == []
    end

    test "unknown commands cannot mutate state" do
      state = %State{revision: 4}
      assert {:error, {:unknown_lifecycle_command, :invented}} = Lifecycle.apply(state, :invented)
      assert state == %State{revision: 4}
    end

    test "next decision and result projection use the same lifecycle kernel" do
      result = %Result{reply_text: "ready"}
      assert {:reply, ^result} = Lifecycle.next(result)
      assert Result.lifecycle(result) == Lifecycle.projection(result)
    end
  end

  describe "pure policy matcher" do
    test "accept, reject, and no-match produce canonical results without state" do
      policy = policy()

      assert {:ok, %Resolution{kind: :accept, label: :yes, source: :user}} =
               Matcher.match(policy, "yes")

      assert {:ok, %Resolution{kind: :reject, label: :no, source: :user}} =
               Matcher.match(policy, "no")

      assert :no_match = Matcher.match(policy, "maybe")
      assert Policy.decide(policy, "yes") == {:accept, :yes}
    end

    test "accept evidence has stable precedence when patterns overlap" do
      policy = %Policy{
        accepts: [%{label: :accept_first, regex: [~r/^same$/]}],
        rejects: [%{label: :reject_second, regex: [~r/^same$/]}]
      }

      assert {:ok, %Resolution{kind: :accept, label: :accept_first}} =
               Matcher.match(policy, "same")
    end

    test "trusted and user resolutions share one validated value type" do
      assert {:ok, user} = Resolution.new(:accept, :yes, :user)
      assert {:ok, host} = Resolution.new(:accept, :yes, :host, %{proof: :durable})
      assert Resolution.to_tuple(user) == Resolution.to_tuple(host)

      assert {:error, {:invalid_policy_resolution, :maybe, _, _, _}} =
               Resolution.new(:maybe, :yes, :host)
    end

    test "global interrupts are opt-in while a policy is open" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})

      assert {:ok, result} =
               Spectre.ask(@agent, "help",
                 state: opened.to,
                 policy_global_interrupts?: true,
                 policy_interrupt_via: [:regex]
               )

      assert result.reply_text == "interrupt help"
      assert result.route.label == :HELP
      assert %Awaitable{status: :open} = Result.open_awaitable(result)
    end

    test "strict journal configuration errors are not swallowed by policy interrupt probing" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})

      assert {:error, {:invalid_journal_configuration, :async_journal_cannot_fail_turn}} =
               Spectre.ask(@agent, "help",
                 state: opened.to,
                 policy_global_interrupts?: true,
                 journal:
                   {SpectreHardeningCompletionTest.Store,
                    [mode: :async, on_error: :error, store_opts: [pid: self()]]}
               )
    end
  end

  describe "dispatch and execution separation" do
    test "dispatcher returns capability outcome and never receives lifecycle state" do
      effect = action_effect(%{value: 7})
      ctx = %{agent: @agent, input: Input.new(""), opts: [test_pid: self()]}

      assert {:ok, {:performed, %{value: 7}}} =
               Spectre.ActionDispatcher.dispatch(effect, ctx)

      assert_receive {:hardening_action, %{value: 7}}
    end

    test "execution applies the dispatcher outcome through lifecycle" do
      effect = action_effect(%{value: 8})
      {:ok, staged} = Lifecycle.apply(%State{}, {:stage_effect, effect, nil})
      ctx = %{agent: @agent, input: Input.new(""), opts: [test_pid: self()]}

      assert {:ok, result} = Spectre.Execution.execute_pending(staged.to, ctx)
      assert [%Effect{status: :completed}] = result.effects
      assert result.state.pending_effects == []

      assert match?(
               %Spectre.Transition{event: :effect_completed},
               result.metadata.execution_transition
             )
    end

    test "waiting effects are rejected before the dispatcher is invoked" do
      {:ok, opened} = Lifecycle.apply(%State{}, {:stage_effect, action_effect(), :confirm})
      ctx = %{agent: @agent, input: Input.new(""), opts: [test_pid: self()]}

      assert {:error, {:effect_not_approved, _id}} =
               Spectre.Execution.execute_pending(opened.to, ctx)

      refute_received {:hardening_action, _args}
    end

    test "durable continuation commands retain trace identity without reusing turn identity" do
      assert {:ok, turn} = Spectre.turn(@agent, "perform")
      assert {:needs, _effect, staged} = turn.decision

      assert {:ok, completed} = Spectre.execute(@agent, staged)

      first = staged.metadata.runtime_identity
      second = completed.metadata.runtime_identity
      assert first.trace_id == second.trace_id
      assert first.turn_id != second.turn_id
    end
  end

  describe "journal, explanations, and telemetry" do
    test "runtime journal records are privacy-safe, redacted, and retention-aware" do
      redactor = fn record -> %{record | reason: %{code: :redacted}} end

      opts = [
        turn_id: "journal-turn",
        trace_id: "journal-trace",
        journal:
          {SpectreHardeningCompletionTest.Store,
           [
             events: [:execution],
             mode: :sync,
             redact: redactor,
             retention: [days: 14],
             store_opts: [pid: self()]
           ]}
      ]

      effect = action_effect(%{secret: "not-recorded"}) |> Effect.complete(%{private: true})

      result = %Result{
        input: Input.new("sensitive input"),
        state: %State{},
        reply_text: "sensitive reply",
        effects: [effect],
        events: [
          %{
            type: :effect_completed,
            kind: :action,
            name: :perform,
            effect_id: effect.id,
            effect: effect,
            result: effect.result
          }
        ]
      }

      assert {:ok, ^result} = Recorder.record_result(result, %{agent: @agent, opts: opts})
      assert_receive {:hardening_journal, %Record{} = record}
      assert record.phase == :execution
      assert record.reason == %{code: :redacted}
      assert record.metadata.retention == %{days: 14}
      assert record.input == nil
      assert record.reply == nil
      refute inspect(record) =~ "not-recorded"
      refute inspect(record) =~ "private"
    end

    test "journal schema restores legacy and string-keyed records" do
      assert {:ok, %Record{schema_version: 1, phase: :policy, turn_id: "legacy"} = record} =
               Record.restore(%{"phase" => :policy, "turn_id" => "legacy"})

      assert is_binary(record.id)
      assert %DateTime{} = record.occurred_at

      assert {:error, {:unsupported_journal_schema, 99}} =
               Record.restore(%{schema_version: 99})
    end

    test "arbitration explains eligibility, thresholds, and winning precedence" do
      local = candidate(:LOCAL, :local_classifier, 0.99, 0.2)
      rejected = candidate(:EMBED, :embedding, 0.70, 0.01)
      payload = %Arbitration{candidates: [rejected, local], labels: [:LOCAL, :EMBED]}

      {{:ok, route}, explanation} = Default.explain(payload, [])
      assert route.label == :LOCAL
      assert explanation.reason == :classifier_precedence
      assert explanation.thresholds.classifier_accept == 0.93
      assert Enum.find(explanation.candidates, & &1.winner?).label == :LOCAL

      excluded = Enum.find(explanation.candidates, &(&1.label == :EMBED))
      refute excluded.eligible?
      assert excluded.rejection_reason == :score_below_threshold
    end

    test "telemetry callback is observational and privacy-safe" do
      handler = fn event, measurements, metadata ->
        send(self(), {:hardening_telemetry, event, measurements, metadata})
      end

      assert :ok =
               Spectre.Telemetry.emit(
                 [:session, :stale_command],
                 %{count: 1},
                 %{reason: :stale_execution_result},
                 telemetry_handler: handler
               )

      assert_receive {:hardening_telemetry, [:spectre, :session, :stale_command], %{count: 1},
                      %{reason: :stale_execution_result}}
    end
  end

  defp action_effect(args \\ %{}) do
    Effect.stage_action(
      %{name: :perform, args: args},
      @agent,
      :agent
    )
  end

  defp policy do
    %Policy{
      accepts: [%{label: :yes, regex: [~r/^yes$/]}],
      rejects: [%{label: :no, regex: [~r/^no$/]}]
    }
  end

  defp candidate(label, provider, score, margin) do
    %Candidate{
      label: label,
      scope: :agent,
      provider: provider,
      handler: {:reply, :ok, []},
      score: score,
      margin: margin,
      strength: :weak,
      accepted?: true
    }
  end
end
