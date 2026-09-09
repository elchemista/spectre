defmodule Spectre.Core.RunnerAcknowledgementTest.Executor do
  @behaviour Spectre.Attempt.Executor
  alias Spectre.Attempt.Executor, as: EvidenceBuilder
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.Runtime
  @impl true
  defdelegate executor_ref(), to: Spectre.V04Test.Executor
  @impl true
  defdelegate contract_ref(), to: Spectre.V04Test.Executor
  @impl true
  def execute(act, attempt, _capability, opts) do
    state = Sequencer.projection(Keyword.fetch!(opts, :domain))

    send(
      Keyword.fetch!(opts, :observer),
      {:executed, act.ref, state.attempts[attempt.ref] === attempt}
    )

    case Keyword.get(opts, :mode, :success) do
      :success ->
        {:ok, receipt} =
          EvidenceBuilder.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
            payload: "refund receipt"
          )

        {:ok, %{evidence: [receipt], details_ref: "provider:refund-receipt"}}

      :invalid_reply ->
        {:executed_without, :outcome_attestation}

      :exception ->
        raise "private executor failure"

      :exit ->
        exit({:private, :executor_failure})

      :throw ->
        throw({:private, :executor_failure})
    end
  end
end

defmodule Spectre.Core.RunnerAcknowledgementTest.BoundaryBroker do
  use Spectre.Secret.Broker, ref: "broker:runner-boundary", profile: :development

  @impl true
  def checkout(_receipt, _act, _attempt, opts) do
    case Keyword.get(opts, :mode, :success) do
      :success -> {:ok, :private_capability}
      :ambiguous -> {:error, :ambiguous, %{evidence: [], details_ref: "broker:uncertain"}}
      :invalid_reply -> {:credential, :must_not_escape}
      :exception -> raise "private broker failure"
      :exit -> exit({:private, :broker_failure})
      :throw -> throw({:private, :broker_failure})
    end
  end
end

defmodule Spectre.Core.RunnerAcknowledgementTest.Proxy do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts), do: {:ok, Map.new(opts)}
  @impl true
  def handle_call(request, _from, state) do
    if elem(request, 0) == state.stage do
      reply =
        case state.fault do
          {:reply, value} -> value
          {:after, transform} -> transform.(GenServer.call(state.domain, request))
          :crash -> raise "private sequencer proxy failure"
        end

      {:reply, reply, state}
    else
      {:reply, GenServer.call(state.domain, request), state}
    end
  end
end

defmodule Spectre.Core.RunnerAcknowledgementTest.FaultyVia do
  @moduledoc false

  def whereis_name(:exception), do: raise("private via registry failure")
  def whereis_name(:exit), do: exit({:private, :registry_failure})
  def whereis_name(:throw), do: throw({:private, :registry_failure})
  def register_name(_name, _pid), do: :no
  def unregister_name(_name), do: :ok
  def send(_name, _message), do: exit(:badarg)
end

defmodule Spectre.Core.RunnerAcknowledgementTest do
  use ExUnit.Case, async: false

  alias Spectre.{Act, Decision, Outcome}
  alias Spectre.Attempt.Runner
  alias Spectre.Core.RunnerAcknowledgementTest.{BoundaryBroker, Executor, FaultyVia, Proxy}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  setup context do
    Runtime.reset(Fixture.default_now())
    domain = :spectre_acknowledgement_test_domain

    f =
      Fixture.start_domain(
        namespace: "runner-acknowledgement",
        name: domain,
        executors: [
          {Executor,
           domain: domain, observer: self(), mode: Map.get(context, :executor_mode, :success)}
        ],
        broker: {BoundaryBroker, mode: Map.get(context, :broker_mode, :success)}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, payment} = Fixture.observe_payment(f, Fixture.paid_evidence(f))

    {:ok, admission} =
      Sequencer.submit(
        f.server,
        Fixture.context(f),
        Fixture.refund_candidate(f, 100, evidence_refs: [payment.ref])
      )

    %{f: f, admission: admission, prefix: Sequencer.projection(f.server)}
  end

  for mode <- [:ambiguous, :invalid_reply, :exception, :exit, :throw] do
    @tag broker_mode: mode
    test "a #{mode} broker result becomes one durable ambiguity without executor access", c do
      assert {:ok, result} = Runner.run(c.f.server, {:ok, c.admission})
      assert result.outcome.status == :ambiguous
      assert result.outcome.evidence_refs == []
      assert result.outcome.details_ref != nil
      assert map_size(Sequencer.projection(c.f.server).attempts) == 1
      refute_received {:executed, _, _}
      assert_replay(c)
    end
  end

  for mode <- [:invalid_reply, :exception, :exit, :throw] do
    @tag executor_mode: mode
    test "a #{mode} executor result is attempted once and durably becomes ambiguous", c do
      assert {:ok, result} = Runner.run(c.f.server, {:ok, c.admission})
      assert result.outcome.status == :ambiguous
      assert result.outcome.evidence_refs == []
      assert_received {:executed, _, true}
      refute_received {:executed, _, _}
      assert map_size(Sequencer.projection(c.f.server).attempts) == 1
      assert_replay(c)
    end
  end

  for {stage, reply, reason} <- [
        {:execution_route, {:error, :unavailable}, {:execution_route_unavailable, :unavailable}},
        {:execution_route, :unexpected, :invalid_execution_route_response},
        {:consume_grant, {:error, :unavailable}, {:grant_consumption_failed, :unavailable}},
        {:consume_grant, :unexpected, :invalid_grant_consumption_response}
      ] do
    test "#{stage} rejects #{inspect(reply)} without invoking the executor", c do
      proxy = proxy(c, unquote(stage), {:reply, unquote(Macro.escape(reply))})
      assert {:error, unquote(Macro.escape(reason))} = Runner.run(proxy, {:ok, c.admission})
      refute_received {:executed, _, _}
      assert Sequencer.projection(c.f.server) === c.prefix
    end
  end

  for {name, reply} <- [
        missing: {:error, :clock_unavailable},
        early: {:ok, 0},
        malformed: :unknown
      ] do
    test "#{name} observation time preserves the Attempt and records ambiguity, not success", c do
      proxy = proxy(c, :trusted_time, {:reply, unquote(Macro.escape(reply))})
      assert {:ok, result} = Runner.run(proxy, {:ok, c.admission})
      assert_once(c)
      assert result.outcome.status == :ambiguous
      assert result.outcome.observed_at == result.attempt.started_at

      assert result.outcome.details_ref ==
               "spectre:attempt-boundary:clock:unusable-observation-time:v1"

      assert map_size(Sequencer.projection(c.f.server).duties) == 1
      assert_replay(c)
    end
  end

  for {name, reply} <- [unavailable: {:error, :unavailable}, malformed: :unknown] do
    test "#{name} Evidence acknowledgement cannot be upgraded into an attested success", c do
      proxy = proxy(c, :record_executor_evidence, {:reply, unquote(Macro.escape(reply))})
      assert {:ok, result} = Runner.run(proxy, {:ok, c.admission})
      assert_once(c)
      assert result.outcome.status == :ambiguous
      assert result.outcome.evidence_refs == []

      assert result.outcome.details_ref ==
               "spectre:attempt-boundary:ledger:evidence-unacknowledged:v1"

      assert_replay(c)
    end
  end

  for change <- [:missing, :invalid] do
    test "#{change} facts in a successful Evidence acknowledgement are not accepted", c do
      transform = fn {:ok, [evidence]} ->
        case unquote(change) do
          :missing -> {:ok, []}
          :invalid -> {:ok, [%{evidence | observed_at: -1}]}
        end
      end

      proxy = proxy(c, :record_executor_evidence, {:after, transform})
      assert {:ok, result} = Runner.run(proxy, {:ok, c.admission})
      assert_once(c)
      assert result.outcome.status == :ambiguous
      assert result.evidence == []
      assert_replay(c)
    end
  end

  for change <- [:malformed, :changed, :invalid] do
    test "#{change} Outcome acknowledgement recovers the actual durable fact without repeating execution",
         c do
      transform = fn {:ok, outcome} ->
        case unquote(change) do
          :malformed -> :ok
          :changed -> Outcome.new(%{outcome | ref: nil, details_ref: "other-receipt"})
          :invalid -> {:ok, %{outcome | observed_at: -1}}
        end
      end

      proxy = proxy(c, :record_outcome, {:after, transform})
      assert {:ok, result} = Runner.run(proxy, {:ok, c.admission})
      assert_once(c)
      assert result.outcome.status == :succeeded
      assert result.outcome.details_ref == "provider:refund-receipt"
      assert {:ok, ^result} = Runner.run(c.f.server, {:ok, %{c.admission | grant: nil}})
      refute_received {:executed, _, _}
      assert_replay(c)
    end
  end

  test "an Outcome write failure recovers an unresolved Attempt, not a no-effect claim", c do
    proxy = proxy(c, :record_outcome, {:reply, {:error, :unavailable}})
    assert {:ok, result} = Runner.run(proxy, {:ok, c.admission})
    assert_once(c)
    assert result.attempt != nil
    assert result.outcome == nil
    assert {:ok, recovered} = Runner.run(c.f.server, {:ok, %{c.admission | grant: nil}})
    assert recovered === result
    refute_received {:executed, _, _}
    assert_replay(c)
  end

  test "durable recovery rejects adapter errors and malformed read replies", c do
    admission = %{c.admission | grant: nil}

    error_proxy = proxy(c, :attempt_result, {:reply, {:error, :store_unavailable}})
    assert {:error, :store_unavailable} = Runner.run(error_proxy, {:ok, admission})

    invalid_proxy = proxy(c, :attempt_result, {:reply, :invented_state})

    assert {:error, :invalid_attempt_result_response} =
             Runner.run(invalid_proxy, {:ok, admission})

    refute_received {:executed, _, _}
  end

  test "sequencer boundary exceptions, exits and throws stay typed and never execute the Act",
       c do
    for kind <- [:exception, :exit, :throw] do
      server = {:via, FaultyVia, kind}

      assert {:error, {:execution_route_boundary_failure, ^kind}} =
               Runner.run(server, {:ok, c.admission})
    end

    refute_received {:executed, _, _}
    assert Sequencer.projection(c.f.server) === c.prefix
  end

  @tag capture_log: true
  test "a sequencer disappearing after dispatch never causes a second execution", c do
    consume_proxy = proxy(c, :consume_grant, :crash)

    assert {:error, {:grant_consumption_boundary_failure, :exit}} =
             Runner.run(consume_proxy, {:ok, c.admission})

    refute_received {:executed, _, _}
    assert Sequencer.projection(c.f.server) === c.prefix

    clock_proxy = proxy(c, :trusted_time, :crash)

    assert {:error, {:outcome_record_boundary_failure, :exit}} =
             Runner.run(clock_proxy, {:ok, c.admission})

    assert_received {:executed, _, true}
    refute_received {:executed, _, _}
    assert map_size(Sequencer.projection(c.f.server).attempts) == 1
    assert map_size(Sequencer.projection(c.f.server).outcomes) == 0
    assert_replay(c)
  end

  test "an acknowledged Attempt with changed bindings cannot cross into the executor", c do
    proxy =
      proxy(
        c,
        :consume_grant,
        {:after,
         fn {:ok, act, attempt, receipt} ->
           {:ok, act, %{attempt | generation: attempt.generation + 1}, receipt}
         end}
      )

    assert {:ok, recovered} = Runner.run(proxy, {:ok, c.admission})
    assert recovered.attempt.generation == Fixture.generation(c.f)
    assert recovered.outcome == nil
    refute_received {:executed, _, _}
    assert_replay(c)
  end

  test "a replaced checkout receipt cannot authorize execution after durable consumption", c do
    proxy =
      proxy(
        c,
        :consume_grant,
        {:after,
         fn {:ok, act, attempt, receipt} ->
           {:ok, act, attempt, %{receipt | broker_ref: "foreign-broker"}}
         end}
      )

    assert {:ok, recovered} = Runner.run(proxy, {:ok, c.admission})
    assert recovered.attempt != nil
    assert recovered.outcome == nil
    refute_received {:executed, _, _}
    assert_replay(c)
  end

  test "malformed admission and options never contact the execution route", c do
    assert {:error, :original} = Runner.run(c.f.server, {:error, :original})
    assert {:error, :invalid_admission_response} = Runner.run(c.f.server, :ok)

    assert {:error, :invalid_admission_response} =
             Runner.run(c.f.server, {:ok, Map.put(c.admission, :capability, "forged")})

    assert {:error, {:invalid_keyword_options, :runner_opts}} =
             Runner.run(c.f.server, {:ok, c.admission}, %{})

    assert {:error, {:invalid_keyword_options, :sequencer_opts}} =
             Runner.run(c.f.server, {:ok, c.admission}, sequencer_opts: %{})

    assert {:error, :admitted_response_missing_act} =
             Runner.run(c.f.server, {:ok, %{c.admission | act: nil}})

    assert {:error, :executor_mediated_act_missing_grant} =
             Runner.run(c.f.server, {:ok, %{c.admission | grant: nil}})

    assert {:error, :executor_mediated_act_missing_grant} =
             Runner.run(c.f.server, {:ok, %{c.admission | grant: :forged}})

    {:ok, refused} =
      Decision.new(%{
        c.admission.decision
        | ref: nil,
          outcome: :refused,
          reasons: [:mandate_absent],
          reservations: %{}
      })

    assert {:error, :non_admitted_response_contains_capability} =
             Runner.run(c.f.server, {:ok, %{c.admission | decision: refused}})

    for {changes, reason} <- [
          {%{decision_ref: "other"}, :act_decision_ref_mismatch},
          {%{candidate_identity_key: "other"},
           {:decision_act_field_mismatch, :candidate_identity_key}}
        ] do
      {:ok, act} =
        c.admission.act
        |> Map.from_struct()
        |> Map.merge(changes)
        |> Map.put(:ref, nil)
        |> Act.new()

      assert {:error, ^reason} = Runner.run(c.f.server, {:ok, %{c.admission | act: act}})
    end

    assert Sequencer.projection(c.f.server) === c.prefix
    refute_received {:executed, _, _}
  end

  test "late observation normalization rejects mismatched causes and malformed evidence", c do
    {:ok, act, attempt, _receipt} = Sequencer.consume_grant(c.f.server, c.admission.grant)

    {:ok, evidence} =
      Spectre.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
        payload: "receipt"
      )

    metadata = %{evidence: evidence, details_ref: "receipt"}

    assert {:ok, _} =
             Runner.normalize_late_observation(:succeeded, metadata, act, attempt, Runtime.now())

    assert {:error, :late_observation_cause_mismatch} =
             Runner.normalize_late_observation(
               :succeeded,
               metadata,
               act,
               attempt,
               attempt.started_at - 1
             )

    assert {:error, :late_observation_cause_mismatch} =
             Runner.normalize_late_observation(
               :succeeded,
               metadata,
               act,
               %{attempt | executor_ref: "other"},
               Runtime.now()
             )

    assert {:error, :invalid_late_observation} =
             Runner.normalize_late_observation(:unknown, metadata, act, attempt, Runtime.now())

    for invalid <- [nil, [nil], [%{evidence | observed_at: -1}], [evidence, evidence]] do
      assert {:error, _} =
               Runner.normalize_late_observation(
                 :succeeded,
                 %{metadata | evidence: invalid},
                 act,
                 attempt,
                 Runtime.now()
               )
    end
  end

  defp proxy(c, stage, fault) do
    opts = [domain: c.f.server, stage: stage, fault: fault]

    start_supervised!(%{
      id: make_ref(),
      start: {Proxy, :start_link, [opts]}
    })
  end

  defp assert_once(c) do
    ref = c.admission.act.ref
    assert_received {:executed, ^ref, true}
    refute_received {:executed, _, _}
    assert map_size(Sequencer.projection(c.f.server).attempts) == 1
  end

  defp assert_replay(c) do
    assert {:ok, recovered} = Projection.replay(Fixture.snapshot(c.f), c.f.constitution)
    assert recovered === Sequencer.projection(c.f.server)
  end
end
