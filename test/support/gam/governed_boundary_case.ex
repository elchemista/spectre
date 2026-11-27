defmodule Spectre.Test.GAM.GovernedBoundaryCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias ExGAM.Attempt.Executor
  alias ExGAM.Domain.Sequencer
  alias Spectre.Test.GAM.{Fixture, Runtime}

  # Capture real prefixes, rather than manufacturing an authorized Act. Tests
  # may corrupt a copy to exercise recovery, never the live Domain's state.
  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "boundary-#{System.unique_integer([:positive])}")
    on_exit(fn -> Fixture.stop_domain(f) end)
    payment = Fixture.paid_evidence(f)
    {:ok, ^payment} = Fixture.observe_payment(f, payment)
    before = Sequencer.projection(f.server)

    {:ok, candidate} =
      f
      |> Fixture.refund_candidate(100, evidence_refs: [payment.ref])
      |> ExGAM.Candidate.new()

    {:ok, %{act: act, decision: decision, grant: grant}} =
      Sequencer.submit(f.server, Fixture.context(f), candidate)

    pending = Sequencer.projection(f.server)
    {:ok, ^act, attempt, _checkout} = Sequencer.consume_grant(f.server, grant)
    attempted = Sequencer.projection(f.server)

    {:ok, receipt} =
      Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
        payload: %{"provider_receipt" => "refund-100", "amount" => 100}
      )

    %{
      f: f,
      payment: payment,
      before: before,
      candidate: candidate,
      act: act,
      decision: decision,
      grant: grant,
      attempt: attempt,
      receipt: receipt,
      pending: pending,
      attempted: attempted
    }
  end
end
