defmodule Spectre.GAM.Core.DutyTargetAuthorityTest do
  use ExUnit.Case, async: true

  alias Spectre.GAM.{Domain, Duty, Governance, Mandate, Scope, SubmissionContext}
  alias Spectre.GAM.Duty.Disposition
  alias Spectre.GAM.GovernedAct.{AuthorityIndex, State}
  alias Spectre.GAM.Kernel.Authority
  alias Spectre.GAM.Kernel.Authority.{Coverage, DutyTargets, Facts}

  setup do
    operation =
      mandate(%{holder_ref: "actor", grantor_ref: "business", accountable_ref: "business"})

    review =
      mandate(%{
        holder_ref: "reviewer",
        grantor_ref: "reviewer",
        accountable_ref: "reviewer",
        classes: ["duty.dispose"],
        executor_refs: [Governance.kernel_executor_ref()],
        executor_contract_refs: [Governance.kernel_contract_ref()],
        target_refs: [operation.ref],
        scope_refs: ["scope:review"],
        ceiling: %{govern: true},
        delegation: %{"allowed" => false, "max_depth" => 0}
      })

    duty = duty(operation.ref, [review.holder_ref])
    state = state([operation, review], duty)

    {:ok, context} =
      SubmissionContext.new(%{
        domain_ref: state.domain_ref,
        scope_ref: "scope:review",
        authenticated_principal_ref: "reviewer",
        authentication_ref: "auth:reviewer",
        ingress_ref: "ingress",
        host_generation: 1
      })

    {:ok, scope} = Scope.new(Domain.handle(self(), state.domain_ref), context)
    candidate = candidate(scope, review, duty)

    %{
      operation: operation,
      review: review,
      duty: duty,
      state: state,
      scope: scope,
      context: Map.from_struct(context),
      candidate: candidate
    }
  end

  test "a named reviewer can cover an exact future Duty of its declared causal mandate", c do
    refute c.duty.ref in c.review.target_refs
    facts = Facts.for_candidate(c.state, c.candidate)
    assert :ok = Coverage.covered_values(:targets, c.candidate, c.review, facts)
    assert {:ok, _} = Authority.resolve(c.candidate, c.context, facts, 100)

    assert Map.keys(facts.disposition_duties[c.duty.ref]) |> Enum.sort() ==
             Enum.sort([
               :ref,
               :cause_key,
               :status,
               :mandate_ref,
               :disposition_authority_refs,
               :causal_refs
             ])

    assert Map.keys(facts.mandates) == [c.review.ref]
    assert facts.disposition_duties[c.duty.ref].causal_refs == MapSet.new([c.operation.ref])
  end

  test "exhaustive and indexed selection preserve the same authority", c do
    indexed = indexed(c.state)
    assert AuthorityIndex.complete?(indexed.read_index.authority, indexed)
    assert Facts.for_candidate(c.state, c.candidate) == Facts.for_candidate(indexed, c.candidate)

    assert Authority.resolve(c.candidate, c.context, Facts.from_state(c.state), 100) ==
             Authority.resolve(
               c.candidate,
               c.context,
               Facts.for_candidate(indexed, c.candidate),
               100
             )
  end

  test "a legacy in-memory index falls back to complete authority facts", c do
    state = indexed(c.state)
    old_index = Map.drop(state.read_index.authority, [:version, :open_duty_causes])
    state = put_in(state.read_index.authority, old_index)
    refute AuthorityIndex.complete?(old_index, state)
    assert Facts.current(state) == Facts.from_state(state)
    assert Map.has_key?(Facts.current(state).disposition_duties, c.duty.ref)

    # Recording an unrelated event must not certify this incomplete index.
    state = AuthorityIndex.record(state, %{type: "scope_opened"})
    refute AuthorityIndex.complete?(state.read_index.authority, state)
    assert Facts.current(state) == Facts.from_state(state)
  end

  test "a Duty without a causal mandate never acquires authority from its named reviewer", c do
    duty = %{c.duty | mandate_ref: nil}
    state = %{c.state | duties: %{duty.cause_key => duty}}
    assert {:error, :duty_causal_mandate_missing} = DutyTargets.causal_refs(state, duty)
    assert :none = Authority.resolve(c.candidate, c.context, Facts.current(state), 100)
  end

  test "the full indexed authority view drops disposed Duty envelopes", c do
    state = indexed(c.state)
    assert state.read_index.authority.open_duty_causes == MapSet.new([c.duty.cause_key])
    assert Facts.current(state) == Facts.from_state(state)
    assert Map.has_key?(Facts.current(state).disposition_duties, c.duty.ref)

    state = put_in(state.duties[c.duty.cause_key].status, :disposed)

    state =
      AuthorityIndex.record(state, %{
        type: "duty_disposed",
        data: %{"cause_key" => c.duty.cause_key}
      })

    assert state.read_index.authority.open_duty_causes == MapSet.new()
    assert Facts.current(state) == Facts.from_state(state)
    assert Facts.current(state).disposition_duties == %{}
    assert :none = Authority.resolve(c.candidate, c.context, Facts.current(state), 100)
  end

  test "a mismatched cause key is refused identically by exhaustive and indexed facts", c do
    candidate = %{
      c.candidate
      | consequence:
          put_in(c.candidate.consequence, ["duty_disposition", "cause_key"], {:fake, "cause"})
    }

    for facts <- [Facts.from_state(c.state), Facts.for_candidate(indexed(c.state), candidate)] do
      assert :none = Authority.resolve(candidate, c.context, facts, 100)
    end
  end

  test "only an exact singleton Duty target is covered", c do
    for targets <- [[], [c.operation.ref], [c.duty.ref, "extra"], ["other-duty"]] do
      candidate = %{c.candidate | target_refs: targets}
      facts = Facts.for_candidate(c.state, candidate)
      # Existing exact-target coverage remains ordinary authority, so this
      # assertion exercises only shapes outside the original target list.
      if targets not in [[], [c.operation.ref]] do
        assert {:error, {:targets, :outside_mandate}} =
                 Coverage.covered_values(:targets, candidate, c.review, facts)
      else
        refute targets == [c.duty.ref]
      end
    end

    changed = %{
      c.candidate
      | consequence:
          put_in(c.candidate.consequence, ["duty_disposition", "duty_ref"], "other-duty")
    }

    assert {:error, {:targets, :outside_mandate}} =
             Coverage.covered_values(
               :targets,
               changed,
               c.review,
               Facts.for_candidate(c.state, changed)
             )
  end

  test "missing closed or unnamed Duty never receives causal target coverage", c do
    for duty <- [nil, %{c.duty | status: :disposed}, %{c.duty | disposition_authority_refs: []}] do
      state = %{c.state | duties: if(duty, do: %{duty.cause_key => duty}, else: %{})}

      assert {:error, {:targets, :outside_mandate}} =
               Coverage.covered_values(
                 :targets,
                 c.candidate,
                 c.review,
                 Facts.for_candidate(state, c.candidate)
               )
    end
  end

  test "naming a different mandate or using mixed governance classes does not expand targets",
       c do
    for review <- [
          %{c.review | target_refs: ["another-mandate"]},
          %{c.review | classes: ["duty.dispose", "mandate.revoke"]}
        ] do
      assert {:error, {:targets, :outside_mandate}} =
               Coverage.covered_values(
                 :targets,
                 c.candidate,
                 review,
                 Facts.for_candidate(c.state, c.candidate)
               )
    end

    candidate = %{c.candidate | class: "mandate.revoke"}

    assert {:error, {:targets, :outside_mandate}} =
             Coverage.covered_values(
               :targets,
               candidate,
               c.review,
               Facts.for_candidate(c.state, candidate)
             )
  end

  test "proposer matching revocation and expiry remain ordinary authority checks", c do
    facts = Facts.for_candidate(c.state, c.candidate)

    assert :none =
             Authority.resolve(
               c.candidate,
               %{c.context | authenticated_principal_ref: "actor"},
               facts,
               100
             )

    assert :none = Authority.resolve(c.candidate, c.context, facts, c.review.expires_at)

    revocation =
      struct(Spectre.GAM.Mandate.Revocation, %{
        mandate_ref: c.review.ref,
        effective_at: 99,
        mode: :cascade,
        act_ref: "act:revoke"
      })

    state = %{c.state | revocations: %{c.review.ref => revocation}}

    assert :none =
             Authority.resolve(
               c.candidate,
               c.context,
               Facts.for_candidate(state, c.candidate),
               100
             )

    facts = %{facts | blocked_mandate_refs: MapSet.new([c.review.ref])}
    assert :none = Authority.resolve(c.candidate, c.context, facts, 100)
  end

  test "a verified subtractive delegation keeps Duties within the declared original branch", c do
    child =
      mandate(
        c.operation
        |> Map.from_struct()
        |> Map.drop([:ref])
        |> Map.merge(%{
          parent_ref: c.operation.ref,
          grantor_ref: c.operation.holder_ref,
          holder_ref: "child",
          delegation: %{"allowed" => false, "max_depth" => 0}
        })
      )

    assert :ok = Authority.delegation_within?(c.operation, child, 100)
    duty = duty(child.ref, [c.review.holder_ref])
    state = state([c.operation, child, c.review], duty)
    candidate = candidate(c.scope, c.review, duty)

    assert :ok =
             Coverage.covered_values(
               :targets,
               candidate,
               c.review,
               Facts.for_candidate(state, candidate)
             )

    assert {:ok, refs} = DutyTargets.causal_refs(state, duty)
    assert refs == MapSet.new([c.operation.ref, child.ref])

    expanded = %{child | classes: ["ungranted.operation"]}
    state = %{state | mandates: Map.put(state.mandates, child.ref, expanded)}
    assert {:error, _} = DutyTargets.causal_refs(state, duty)
  end

  test "strict recorded successors remain covered and forged predecessor links do not", c do
    successor =
      mandate(
        c.operation
        |> Map.from_struct()
        |> Map.drop([:ref])
        |> Map.merge(%{
          revision: 2,
          expires_at: c.operation.expires_at - 1
        })
      )

    assert :ok = Authority.restriction_within?(c.operation, successor, 100)
    duty = duty(successor.ref, [c.review.holder_ref])
    state = state([c.operation, successor, c.review], duty)
    state = %{state | mandate_successors: %{c.operation.ref => successor.ref}}
    candidate = candidate(c.scope, c.review, duty)

    assert :ok =
             Coverage.covered_values(
               :targets,
               candidate,
               c.review,
               Facts.for_candidate(state, candidate)
             )

    forged = %{successor | expires_at: c.operation.expires_at + 100}
    state = %{state | mandates: Map.put(state.mandates, successor.ref, forged)}
    assert {:error, _} = DutyTargets.causal_refs(state, duty)
  end

  test "causal ancestry fails closed for missing parents and cycles", c do
    for changed <- [
          %{c.operation | parent_ref: "missing"},
          %{c.operation | parent_ref: c.operation.ref}
        ] do
      state = %{c.state | mandates: Map.put(c.state.mandates, c.operation.ref, changed)}
      assert {:error, _} = DutyTargets.causal_refs(state, c.duty)
    end
  end

  defp mandate(attrs) do
    {:ok, mandate} =
      Mandate.new(
        Map.merge(
          %{
            revision: 1,
            grantor_ref: "owner",
            holder_ref: "actor",
            accountable_ref: "owner",
            executor_refs: ["executor"],
            executor_contract_refs: ["contract"],
            scope_refs: ["scope:work"],
            classes: ["app.send"],
            ceiling: %{write: true},
            purpose_ref: "purpose",
            not_before: 10,
            expires_at: 1_000,
            delegation: %{"allowed" => true, "max_depth" => 2},
            source_ref: "genesis"
          },
          attrs
        )
      )

    mandate
  end

  defp duty(mandate, authorities) do
    {:ok, duty} =
      Duty.new(%{
        class: "app.review",
        cause_key: {:case, mandate},
        accountable: "business",
        mandate_ref: mandate,
        opened_at: 90,
        disposition_authority_refs: authorities
      })

    duty
  end

  defp candidate(scope, review, duty) do
    {:ok, disposition} = Disposition.for_duty(duty, :accept_loss, ["evidence:review"])

    {:ok, candidate} =
      Governance.dispose_duty(scope, disposition, %{
        identity_key: "review-case",
        requested_mandate_ref: review.ref,
        accountable_ref: review.accountable_ref,
        purpose_ref: review.purpose_ref,
        evidence_refs: ["evidence:review"]
      })

    candidate
  end

  defp state(mandates, duty),
    do: %{
      State.new("domain")
      | mandates: Map.new(mandates, &{&1.ref, &1}),
        duties: %{duty.cause_key => duty}
    }

  defp indexed(state) do
    Enum.reduce(Map.values(state.mandates), State.new(state.domain_ref), fn mandate, acc ->
      acc = %{acc | mandates: Map.put(acc.mandates, mandate.ref, mandate)}
      AuthorityIndex.record(acc, %{type: "mandate_issued", identity: mandate.ref})
    end)
    |> then(fn acc ->
      [duty] = Map.values(state.duties)
      acc = %{acc | duties: state.duties}
      acc = put_in(acc.read_index.duties.by_ref[duty.ref], duty.cause_key)
      AuthorityIndex.record(acc, %{type: "duty_opened", identity: duty.ref})
    end)
  end
end
