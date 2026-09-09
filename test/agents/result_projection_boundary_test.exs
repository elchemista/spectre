defmodule Spectre.AgentResultProjectionBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Agent.Result
  alias Spectre.Attempt.Runner
  alias Spectre.Proposal.Result, as: Proposal
  alias Spectre.V04Test.Fixture

  test "human result statuses preserve every durable Outcome distinction", c do
    {:ok, scope} =
      Spectre.Scope.new(Spectre.Domain.handle(c.f.server, c.f.refs.domain), Fixture.context(c.f))

    for {status, expected} <- [
          succeeded: :done,
          failed: :failed,
          definitive_no_effect: :no_effect,
          ambiguous: :unclear
        ] do
      outcome = Fixture.outcome(c.f, c.act, c.attempt, status, [c.receipt.ref])
      primary = runner(c, outcome)
      proposal = %Proposal{primary: primary, fallback: :not_applicable}

      assert {:ok, %{status: ^expected, reason: reason, fallback: :not_applicable}} =
               Result.from_proposal(proposal, scope)

      assert reason == outcome.details_ref
    end

    refused = runner(c, nil, %{c.decision | outcome: :refused, reasons: [:policy]}, nil)

    assert {:ok, %{status: :refused, reason: [:policy]}} =
             Result.from_proposal(%Proposal{primary: refused, fallback: :silence}, scope)

    invalid = %Runner.Result{
      decision: c.decision,
      act: nil,
      attempt: nil,
      evidence: [],
      outcome: nil
    }

    assert {:error, :invalid_proposal_lifecycle} =
             Result.from_proposal(%Proposal{primary: invalid, fallback: :not_applicable}, scope)
  end

  test "payload projection returns a single attestation only, inline or referenced", c do
    {:ok, scope} =
      Spectre.Scope.new(Spectre.Domain.handle(c.f.server, c.f.refs.domain), Fixture.context(c.f))

    outcome = Fixture.outcome(c.f, c.act, c.attempt, :succeeded, [c.receipt.ref])

    assert {:ok, %{data: payload}} =
             Result.from_proposal(
               %Proposal{primary: runner(c, outcome), fallback: :not_applicable},
               scope
             )

    assert payload == c.receipt.payload
    payload_ref = "payload:" <> String.duplicate("a", 64)

    {:ok, referenced} =
      Spectre.Evidence.new(%{c.receipt | ref: nil, payload: nil, payload_ref: payload_ref})

    outcome = %{outcome | evidence_refs: [referenced.ref]}

    assert {:ok, %{data: %{"payload_ref" => ^payload_ref}}} =
             Result.from_proposal(
               %Proposal{
                 primary: runner(c, outcome, c.decision, [referenced]),
                 fallback: :not_applicable
               },
               scope
             )

    fallback = %{mode: :candidate_template, result: runner(c, outcome, c.decision, [referenced])}

    assert {:ok, %{fallback: %{mode: :candidate_template, result: %{status: :done}}}} =
             Result.from_proposal(
               %Proposal{
                 primary: runner(c, outcome, c.decision, [referenced]),
                 fallback: fallback
               },
               scope
             )
  end

  defp runner(c, outcome, decision \\ nil, evidence \\ nil) do
    %Runner.Result{
      decision: decision || c.decision,
      act: c.act,
      attempt: if(outcome, do: c.attempt),
      evidence: evidence || [c.receipt],
      outcome: outcome
    }
  end
end
