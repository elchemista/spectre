Code.require_file("support/fixture.ex", __DIR__)

defmodule Spectre.V04Test.RecordingExecutor do
  @moduledoc false
  @behaviour Spectre.Attempt.Executor

  alias Spectre.Domain.Sequencer

  @impl true
  def execute(act, attempt, capability, opts) do
    projection = opts |> Keyword.fetch!(:sequencer) |> Sequencer.projection()

    send(Keyword.fetch!(opts, :observer), {
      :executor_called,
      %{
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        attempt_durable: Map.get(projection.attempts, attempt.ref) == attempt,
        dispatch_ready: MapSet.member?(projection.dispatch_ready, act.ref),
        capability: capability
      }
    })

    case Keyword.fetch!(opts, :behavior) do
      {:return, reply} -> reply
      {:raise, message} -> raise message
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
    fixture = start_domain("runner-success")
    admission = admit_refund(fixture, 2_500)
    receipt = Fixture.receipt_evidence(fixture, admission.act.ref)
    capability = {:payment_session, make_ref()}

    reply = {:ok, %{evidence: receipt, details_ref: fixture.refs.outcome_details <> ":success"}}

    assert {:ok, %Result{} = result} =
             run(fixture, admission, capability, {:return, reply})

    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _facts}

    assert result.decision == admission.decision
    assert result.act == admission.act
    assert result.evidence == [receipt]
    assert result.outcome.status == :succeeded
    assert result.outcome.attempt_ref == result.attempt.ref
    assert_result_has_no_capability(result, admission.grant, capability)

    projection = Sequencer.projection(fixture.server)
    assert projection.attempts[result.attempt.ref] == result.attempt
    assert projection.outcomes[result.outcome.ref] == result.outcome
    assert projection.duties == %{}

    assert %{available: 7_500, reserved: 0, suspended: 0, spent: 2_500} =
             meter_account(fixture)
  end

  test "definitive no-effect releases the reservation after one execution" do
    fixture = start_domain("runner-no-effect")
    admission = admit_refund(fixture, 3_000)
    capability = {:payment_session, make_ref()}
    evidence = no_effect_evidence(fixture, admission.act.ref)

    reply =
      {:error, :definitive_no_effect,
       %{evidence: [evidence], details_ref: fixture.refs.outcome_details <> ":not-applied"}}

    assert {:ok, %Result{} = result} =
             run(fixture, admission, capability, {:return, reply})

    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _facts}

    assert result.evidence == [evidence]
    assert result.outcome.status == :definitive_no_effect
    assert_result_has_no_capability(result, admission.grant, capability)

    projection = Sequencer.projection(fixture.server)
    assert projection.reservation_states[result.act.ref] == :released
    assert projection.duties == %{}

    assert %{available: 10_000, reserved: 0, suspended: 0, spent: 0} =
             meter_account(fixture)
  end

  test "executor crash becomes ambiguity, suspends resources, and is never retried" do
    fixture = start_domain("runner-crash")
    admission = admit_refund(fixture, 4_000)
    capability = {:payment_session, make_ref()}
    secret_failure = "provider credential leaked in crash"

    assert {:ok, %Result{} = result} =
             run(fixture, admission, capability, {:raise, secret_failure})

    assert_executor_saw_committed_attempt(result, capability)
    refute_received {:executor_called, _facts}

    assert result.evidence == []
    assert result.outcome.status == :ambiguous
    assert result.outcome.details_ref == "spectre:attempt-boundary:executor:exception:v1"
    assert_result_has_no_capability(result, admission.grant, capability)

    projection = Sequencer.projection(fixture.server)
    assert projection.reservation_states[result.act.ref] == :suspended
    assert map_size(projection.attempts) == 1
    assert map_size(projection.outcomes) == 1
    assert map_size(projection.duties) == 1

    assert %{available: 6_000, reserved: 0, suspended: 4_000, spent: 0} =
             meter_account(fixture)

    act_ref = admission.act.ref

    assert {:error, {:grant_consumption_failed, {:act_not_dispatch_ready, ^act_ref}}} =
             run(fixture, admission, capability, {:raise, "must not execute again"})

    refute_received {:executor_called, _facts}
    assert map_size(Sequencer.projection(fixture.server).attempts) == 1

    durable_payloads = fixture |> Fixture.snapshot() |> Map.fetch!(:entries) |> inspect()
    refute durable_payloads =~ secret_failure
    refute durable_payloads =~ inspect(capability)
  end

  defp start_domain(namespace) do
    fixture = Fixture.start_domain(namespace: namespace)
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp admit_refund(fixture, amount) do
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Sequencer.record_evidence(fixture.server, payment)

    assert {:ok, admission} =
             Sequencer.submit(
               fixture.server,
               Fixture.context(fixture),
               Fixture.refund_candidate(fixture, amount, evidence_refs: [payment.ref])
             )

    admission
  end

  defp run(fixture, admission, capability, behavior) do
    Runner.run(fixture.server, {:ok, admission}, RecordingExecutor,
      capability: capability,
      observed_at: Runtime.now(),
      executor_opts: [
        observer: self(),
        sequencer: fixture.server,
        behavior: behavior
      ]
    )
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
    assert Map.keys(Map.from_struct(result)) |> Enum.sort() ==
             [:act, :attempt, :decision, :evidence, :outcome]

    refute Map.has_key?(result, :grant)
    refute Map.has_key?(result, :capability)
    refute inspect(result) =~ grant.nonce
    refute inspect(result) =~ inspect(capability)
  end

  defp no_effect_evidence(fixture, act_ref) do
    {:ok, evidence} =
      Spectre.Evidence.new(%{
        proposition: "refund_definitively_not_applied",
        issuer_ref: fixture.refs.payment_provider,
        source_ref: fixture.refs.payment_provider,
        provenance: :observed,
        observed_at: Runtime.now(),
        bindings: %{"act_ref" => act_ref},
        labels: ["financial"],
        payload_ref: fixture.refs.receipt_payload <> ":not-applied",
        provisional: false
      })

    evidence
  end

  defp meter_account(fixture) do
    fixture.server
    |> Sequencer.projection()
    |> Map.fetch!(:meters)
    |> Map.fetch!(fixture.mandate.ref)
    |> Map.fetch!(fixture.refs.meter)
  end
end
