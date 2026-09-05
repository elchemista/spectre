Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.RecordingExecutor do
  @moduledoc false
  @behaviour Spectre.Attempt.Executor

  alias Spectre.Attempt.Executor
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.Runtime

  @impl true
  defdelegate executor_ref(), to: Spectre.V04Test.Executor
  @impl true
  defdelegate contract_ref(), to: Spectre.V04Test.Executor

  @impl true
  def execute(act, attempt, capability, opts) do
    projection = opts |> Keyword.fetch!(:sequencer) |> Sequencer.projection()

    send(
      Keyword.fetch!(opts, :observer),
      {:executor_called,
       %{
         act_ref: act.ref,
         attempt_ref: attempt.ref,
         attempt_durable: projection.attempts[attempt.ref] == attempt,
         dispatch_ready: MapSet.member?(projection.pending_dispatches, act.ref),
         capability: capability
       }}
    )

    case Keyword.fetch!(opts, :behavior) do
      {:raise, message} ->
        raise message

      status ->
        {:ok, evidence} =
          Executor.outcome_evidence(act, attempt, status, Runtime.now(),
            payload: %{"receipt" => Atom.to_string(status)}
          )

        metadata = %{evidence: [evidence], details_ref: "test:executor:receipt"}
        if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end
end

defmodule Spectre.V04Test.RunnerTest do
  use ExUnit.Case, async: false

  alias Spectre.Attempt.Runner
  alias Spectre.Attempt.Runner.Result
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.{Fixture, RecordingExecutor, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    :ok
  end

  test "success consumes the Grant before one execution and returns only durable records" do
    {fixture, capability} = start_domain("success", :succeeded)
    admission = admit_refund(fixture, 2_500)
    assert {:ok, %Result{} = result} = Runner.run(fixture.server, {:ok, admission})
    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _}

    assert result.decision == admission.decision
    assert result.act == admission.act
    assert [receipt] = result.evidence

    assert receipt.proposition ==
             Spectre.Outcome.proposition(
               :succeeded,
               result.act.ref,
               result.attempt.ref,
               result.act.executor_contract_ref
             )

    assert result.outcome.status == :succeeded
    assert result.outcome.evidence_refs == [receipt.ref]
    assert_result_has_no_capability(result, admission.grant, capability)
    projection = Sequencer.projection(fixture.server)
    assert projection.attempts[result.attempt.ref] == result.attempt
    assert projection.outcomes[result.outcome.ref] == result.outcome
    assert projection.duties == %{}
    assert %{available: 7_500, reserved: 0, suspended: 0, spent: 2_500} = meter_account(fixture)
  end

  test "definitive no-effect releases the reservation after one execution" do
    {fixture, capability} = start_domain("no-effect", :definitive_no_effect)
    admission = admit_refund(fixture, 3_000)
    assert {:ok, %Result{} = result} = Runner.run(fixture.server, {:ok, admission})
    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _}
    assert [_evidence] = result.evidence
    assert result.outcome.status == :definitive_no_effect
    assert_result_has_no_capability(result, admission.grant, capability)
    projection = Sequencer.projection(fixture.server)
    assert projection.meter_reservations[result.act.ref] == :released
    assert projection.duties == %{}
    assert %{available: 10_000, reserved: 0, suspended: 0, spent: 0} = meter_account(fixture)
  end

  test "executor crash becomes ambiguity, suspends resources, and is never retried" do
    secret_failure = "provider credential leaked in crash"
    {fixture, capability} = start_domain("crash", {:raise, secret_failure})
    admission = admit_refund(fixture, 4_000)
    assert {:ok, %Result{} = result} = Runner.run(fixture.server, {:ok, admission})
    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _}
    assert result.evidence == []
    assert result.outcome.status == :ambiguous
    assert result.outcome.details_ref == "spectre:attempt-boundary:executor:exception:v1"
    assert_result_has_no_capability(result, admission.grant, capability)
    projection = Sequencer.projection(fixture.server)
    assert projection.meter_reservations[result.act.ref] == :suspended
    assert map_size(projection.attempts) == 1
    assert map_size(projection.outcomes) == 1
    assert map_size(projection.duties) == 1
    assert %{available: 6_000, reserved: 0, suspended: 4_000, spent: 0} = meter_account(fixture)

    # A repeated invocation recovers the durable result; it never calls Zone X again.
    assert {:ok, ^result} = Runner.run(fixture.server, {:ok, admission})
    refute_received {:executor_called, _}
    durable_payloads = fixture |> Fixture.snapshot() |> Map.fetch!(:entries) |> inspect()
    refute durable_payloads =~ secret_failure
    refute durable_payloads =~ inspect(capability)
  end

  test "a caller cannot replace the configured executor or inject a capability" do
    {fixture, _capability} = start_domain("options", :succeeded)
    admission = admit_refund(fixture, 1_000)
    assert {:error, _} = Runner.run(fixture.server, {:ok, admission}, capability: :forged)
    assert Sequencer.projection(fixture.server).attempts == %{}
    refute_received {:executor_called, _}
  end

  defp start_domain(namespace, behavior) do
    capability = {:payment_session, make_ref()}
    name = :spectre_test_runner_domain

    fixture =
      Fixture.start_domain(
        namespace: "runner-" <> namespace,
        name: name,
        capability: capability,
        executors: [{RecordingExecutor, sequencer: name, observer: self(), behavior: behavior}]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {fixture, capability}
  end

  defp admit_refund(fixture, amount) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    assert {:ok, admission} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, amount, evidence_refs: [payment.ref])
             )

    assert admission.decision.outcome == :admitted
    admission
  end

  defp assert_executor_saw_committed_attempt(result, capability) do
    act_ref = result.act.ref
    attempt_ref = result.attempt.ref

    assert_received {:executor_called,
                     %{
                       act_ref: ^act_ref,
                       attempt_ref: ^attempt_ref,
                       attempt_durable: true,
                       dispatch_ready: false,
                       capability: ^capability
                     }}
  end

  defp assert_result_has_no_capability(result, grant, capability) do
    assert Enum.sort(Map.keys(Map.from_struct(result))) == [
             :act,
             :attempt,
             :decision,
             :evidence,
             :outcome
           ]

    refute inspect(result) =~ grant.nonce
    refute inspect(result) =~ inspect(capability)
  end

  defp meter_account(fixture) do
    Sequencer.projection(fixture.server).meters[fixture.mandate.ref][fixture.refs.meter]
  end
end
