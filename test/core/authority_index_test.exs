defmodule Spectre.Core.AuthorityIndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.{Act, Candidate, Duty, Mandate, Row}
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{AuthorityIndex, Class, Execution, ReadIndex, State}
  alias Spectre.Kernel.Authority
  alias Spectre.Kernel.Authority.{Facts, Status}
  alias Spectre.Mandate.{Ancestry, Revocation}

  # Index algebra is exercised independently of admission. Real committed
  # prefixes are additionally checked by DutyFrontierAssertions.
  setup do
    root = mandate("root", "controller")
    child = mandate("child", "worker", root.ref)
    state = State.new("domain") |> issue(root) |> issue(child)
    candidate = candidate(child.ref)
    %{state: state, root: root, child: child, candidate: candidate}
  end

  test "a requested branch includes foreign-held ancestors but no unrelated authority", c do
    state =
      Enum.reduce(1..100, c.state, fn n, state ->
        issue(state, mandate("other-#{n}", "someone-else"))
      end)

    facts = Facts.for_candidate(state, c.candidate)
    assert Map.keys(facts.mandates) |> Enum.sort() === Enum.sort([c.root.ref, c.child.ref])
    assert_resolution(state, c.candidate)
    assert {:ok, _} = Authority.resolve(c.candidate, context(), facts, 100)

    # The returned value cannot retain the unrelated tables via a hidden State.
    assert :erts_debug.flat_size(facts) < div(:erts_debug.flat_size(Facts.from_state(state)), 10)
  end

  test "implicit resolution retains two independently eligible Mandates and reports ambiguity",
       c do
    other = mandate("second", "worker")
    state = issue(c.state, other)
    candidate = %{c.candidate | requested_mandate_ref: nil}
    facts = Facts.for_candidate(state, candidate)
    assert_resolution(state, candidate)
    assert {:ambiguous, authorities} = Authority.resolve(candidate, context(), facts, 100)

    assert Enum.map(authorities, & &1.mandate.ref) |> Enum.sort() ===
             Enum.sort([c.child.ref, other.ref])
  end

  test "a missing requested Mandate never falls back to a different eligible one", c do
    candidate = %{c.candidate | requested_mandate_ref: "missing"}
    facts = Facts.for_candidate(c.state, candidate)
    assert facts.mandates === %{}
    assert_resolution(c.state, candidate)
    assert Authority.resolve(candidate, context(), facts, 100) === :none
  end

  test "a foreign proposer's claim cannot select authority using authenticated context alone",
       c do
    candidate = %{c.candidate | requested_mandate_ref: nil, proposer_ref: "controller"}
    facts = Facts.for_candidate(c.state, candidate)
    assert_resolution(c.state, candidate)
    assert Authority.resolve(candidate, context(), facts, 100) === :none
  end

  test "revocation of a foreign-held ancestor is preserved by a targeted read", c do
    revoked = struct(Revocation, mandate_ref: c.root.ref, effective_at: 100)
    state = %{c.state | revocations: %{c.root.ref => revoked}}
    facts = Facts.for_candidate(state, c.candidate)
    assert facts.revocations === state.revocations
    assert Status.not_revoked(c.child, facts, 100) === {:error, :mandate_ancestor_revoked}
    assert_resolution(state, c.candidate)
  end

  test "an ancestor's supersession remains visible without loading its unrelated successor", c do
    successor = mandate("root-successor", "controller")
    state = restrict(c.state, c.root, successor)
    facts = Facts.for_candidate(state, c.candidate)

    refute Map.has_key?(facts.mandates, successor.ref)
    assert facts.mandate_successors === %{c.root.ref => successor.ref}
    assert Status.standing(c.child, facts) === {:error, :mandate_ancestor_superseded}
    assert_resolution(state, c.candidate)
  end

  test "a retained controller can request its foreign-held target but cannot inherit its powers",
       c do
    target = %{
      c.child
      | revocation: %{"mode" => :retained_controller, "controller_refs" => ["controller"]}
    }

    state = %{c.state | mandates: Map.put(c.state.mandates, target.ref, target)}

    {:ok, candidate} =
      Candidate.new(
        identity_key: "revoke",
        class: "mandate.revoke",
        row: %{govern: true},
        proposer_ref: "controller",
        executor_ref: Execution.kernel_executor_ref(),
        executor_contract_ref: Execution.kernel_contract_ref(),
        accountable_ref: "owner",
        scope_ref: "scope",
        purpose_ref: Class.retained_revocation_purpose_ref(),
        target_refs: [target.ref],
        requested_mandate_ref: target.ref,
        consequence: %{"mandate_revoke" => %{"mandate_ref" => target.ref}},
        observation_window_ms: 0
      )

    context = %{context() | authenticated_principal_ref: "controller"}
    full = Facts.from_state(state)
    selected = Facts.for_candidate(state, candidate)
    assert Map.has_key?(selected.mandates, target.ref)

    assert Authority.resolve(candidate, context, selected, 100) ===
             Authority.resolve(candidate, context, full, 100)

    assert {:ok, authority} = Authority.resolve(candidate, context, selected, 100)
    assert authority.mode === :retained_revocation

    # The same explicit selection does not confer ordinary read power on the controller.
    read = %{c.candidate | proposer_ref: "controller"}
    assert Authority.resolve(read, context, Facts.for_candidate(state, read), 100) === :none
  end

  test "ancestry selection preserves a cycle rather than turning it into a root", c do
    root = %{c.root | parent_ref: c.child.ref}
    state = %{c.state | mandates: Map.put(c.state.mandates, root.ref, root)}
    facts = Facts.for_candidate(state, c.candidate)
    assert Status.standing(c.child, facts) === {:error, :mandate_ancestry_cycle}
    assert_resolution(state, c.candidate)
  end

  test "missing and malformed ancestors remain errors in a narrowed read", c do
    for parent <- [:missing, :malformed] do
      mandates =
        if parent === :missing,
          do: Map.delete(c.state.mandates, c.root.ref),
          else: Map.put(c.state.mandates, c.root.ref, :invalid)

      state = %{c.state | mandates: mandates}
      facts = Facts.for_candidate(state, c.candidate)
      assert Ancestry.lineage(facts.mandates, c.child) === Ancestry.lineage(mandates, c.child)
      assert {:error, _} = Status.standing(c.child, facts)
    end
  end

  test "expiry is evaluated at the supplied time, not hidden by an index built later", c do
    facts = Facts.for_candidate(c.state, c.candidate)
    assert {:ok, _} = Authority.resolve(c.candidate, context(), facts, 199)
    assert Authority.resolve(c.candidate, context(), facts, 200) === :none
    assert_resolution(c.state, c.candidate, 200)
  end

  test "two Duties containing the same effect require two independent dispositions", c do
    {:ok, digest} = Candidate.effect_digest(c.candidate)
    state = c.state |> open_duty("first", digest) |> open_duty("second", digest)
    assert Facts.for_candidate(state, c.candidate).blocked_effect_digests === MapSet.new([digest])
    state = dispose_duty(state, "first")
    assert Map.has_key?(state.read_index.authority.effects, digest)
    assert_resolution(state, c.candidate)
    assert Authority.resolve(c.candidate, context(), Facts.current(state), 100) === :none
    state = dispose_duty(state, "second")
    assert state.read_index.authority.effects === %{}
    assert {:ok, _} = Authority.resolve(c.candidate, context(), Facts.current(state), 100)
  end

  test "unrelated containment does not enter the facts for this Candidate", c do
    state = open_duty(c.state, "unrelated", "other-consequence")
    facts = Facts.for_candidate(state, c.candidate)
    assert facts.blocked_effect_digests === MapSet.new()
    assert_resolution(state, c.candidate)
  end

  test "an unresolved ancestor debt blocks descendants and is removed only by resolution", c do
    state = debt(c.state, c.root, "debt", %{"meter" => 1})
    facts = Facts.for_candidate(state, c.candidate)
    assert facts.blocked_mandate_refs === MapSet.new([c.root.ref])
    assert Status.standing(c.child, facts) === {:error, :mandate_ancestor_meter_debt}
    assert_resolution(state, c.candidate)
    state = resolve_debt(state, "debt")
    assert Facts.current(state).blocked_mandate_refs === MapSet.new()
    assert state.read_index.authority.debt_owners === %{}
    assert state.read_index.authority.debts_by_owner === %{}
  end

  test "two debts on one physical owner do not unblock its successor after only one resolution",
       c do
    successor = mandate("successor", "worker", c.root.ref)
    state = restrict(c.state, c.child, successor)
    state = state |> debt(c.child, "a", %{"meter" => 1}) |> debt(successor, "b", %{"meter" => 2})
    assert Facts.current(state).blocked_mandate_refs === MapSet.new([c.child.ref, successor.ref])
    state = resolve_debt(state, "a")
    assert Facts.current(state).blocked_mandate_refs === MapSet.new([c.child.ref, successor.ref])
    candidate = %{c.candidate | requested_mandate_ref: successor.ref}
    assert_resolution(state, candidate)
    state = resolve_debt(state, "b")
    assert Facts.for_candidate(state, candidate).blocked_mandate_refs === MapSet.new()
    assert state.read_index.authority.debts_by_owner === %{}
  end

  test "a successor registered after a debt inherits the same owner block", c do
    state = debt(c.state, c.child, "a", %{"meter" => 1})
    successor = mandate("successor", "worker", c.root.ref)
    state = restrict(state, c.child, successor)
    candidate = %{c.candidate | requested_mandate_ref: successor.ref}

    assert Facts.for_candidate(state, candidate).blocked_mandate_refs ===
             MapSet.new([successor.ref])

    assert_resolution(state, candidate)
  end

  test "fully recontained amounts without a deficit do not create a Meter debt block", c do
    state = debt(c.state, c.child, "a", %{})
    assert Facts.current(state).blocked_mandate_refs === MapSet.new()
    assert state.read_index.authority.debts_by_owner === %{}
    assert_resolution(state, c.candidate)
  end

  test "a State with an incomplete index uses exhaustive blockers and remains incomplete", c do
    {:ok, digest} = Candidate.effect_digest(c.candidate)
    state = open_duty(c.state, "first", digest)
    state = %{state | read_index: %ReadIndex{}}
    assert Facts.current(state) === Facts.from_state(state)
    assert_resolution(state, c.candidate)
    mandate = mandate("new", "other")
    state = %{state | mandates: Map.put(state.mandates, mandate.ref, mandate)}
    event = %Event{type: "mandate_issued", identity: mandate.ref, data: %{}}
    state = AuthorityIndex.record(state, event)
    refute AuthorityIndex.complete?(state.read_index.authority, state)
    assert Facts.current(state) === Facts.from_state(state)
  end

  property "disposing interleaved causes preserves the remaining independent effect blocks" do
    check all(digests <- list_of(member_of(["a", "b", "c"]), min_length: 1, max_length: 40)) do
      causes = Enum.with_index(digests)

      state =
        Enum.reduce(causes, State.new("domain"), fn {digest, n}, state ->
          open_duty(state, Integer.to_string(n), digest)
        end)

      state =
        Enum.reduce(Enum.reverse(causes), state, fn {_digest, n}, state ->
          dispose_duty(state, Integer.to_string(n))
        end)

      assert state.read_index.authority.effects === %{}
      assert map_size(state.duties) === length(digests)
    end
  end

  property "mixed-holder ancestry preserves resolution across revocation and debt boundaries" do
    node =
      tuple({member_of(["worker", "foreign"]), integer(0..100), boolean(), boolean()})

    check all(nodes <- list_of(node, min_length: 1, max_length: 25)) do
      state =
        nodes
        |> Enum.with_index()
        |> Enum.reduce(State.new("domain"), fn {node, n}, state ->
          issue_branch(state, node, n)
        end)

      # Nil must retain ambiguity; an explicit foreign target must not borrow
      # the authenticated worker's other powers. Revocation starts at 100,
      # expiry at 200; neither is a cache-time decision.
      for ref <- [nil, "node:#{length(nodes) - 1}", "missing"], time <- [99, 100, 200] do
        assert_resolution(state, candidate(ref), time)
      end
    end
  end

  defp issue_branch(state, {holder, parent_seed, revoked?, debt?}, n) do
    parent_index = rem(parent_seed, n + 1)
    parent = if parent_index === 0, do: nil, else: "node:#{parent_index - 1}"
    mandate = mandate("node:#{n}", holder, parent)
    state = issue(state, mandate)
    state = if debt?, do: debt(state, mandate, "debt:#{n}", %{"meter" => 1}), else: state

    if revoked? do
      revocation = struct(Revocation, mandate_ref: mandate.ref, effective_at: 100)
      %{state | revocations: Map.put(state.revocations, mandate.ref, revocation)}
    else
      state
    end
  end

  defp assert_resolution(state, candidate, time \\ 100) do
    assert Authority.resolve(candidate, context(), Facts.for_candidate(state, candidate), time) ===
             Authority.resolve(candidate, context(), Facts.from_state(state), time)
  end

  defp issue(state, mandate) do
    %{state | mandates: Map.put(state.mandates, mandate.ref, mandate)}
    |> record("mandate_issued", mandate.ref)
  end

  defp restrict(state, previous, successor) do
    owner = Map.get(state.meter_owner_aliases, previous.ref, previous.ref)

    %{
      state
      | mandates: Map.put(state.mandates, successor.ref, successor),
        mandate_successors: Map.put(state.mandate_successors, previous.ref, successor.ref),
        meter_owner_aliases: Map.put(state.meter_owner_aliases, successor.ref, owner)
    }
    |> record("mandate_restricted", successor.ref)
  end

  defp open_duty(state, ref, digest) do
    {:ok, duty} =
      Duty.new(
        class: "app.review",
        cause_key: {:review, ref},
        accountable: "owner",
        opened_at: 100,
        containment: %{
          "dispatch" => :blocked,
          "retry" => :forbidden,
          "consequence_digest" => digest
        }
      )

    state = %{state | duties: Map.put(state.duties, duty.cause_key, duty)}
    state = put_in(state.read_index.duties.by_ref[duty.ref], duty.cause_key)
    record(state, "duty_opened", duty.ref)
  end

  defp dispose_duty(state, ref) do
    cause = {:review, ref}
    duty = Map.fetch!(state.duties, cause)
    state = %{state | duties: Map.put(state.duties, cause, %{duty | status: :disposed})}
    record(state, "duty_disposed", "disposition:#{ref}", %{"cause_key" => cause})
  end

  defp debt(state, mandate, ref, deficits) do
    owner = Map.get(state.meter_owner_aliases, mandate.ref, mandate.ref)
    act = struct(Act, ref: ref, mandate_ref: mandate.ref, reservations: %{"meter" => 1})
    debt = %{disposition_act_ref: nil, deficits: deficits}

    state = %{
      state
      | acts: Map.put(state.acts, ref, act),
        meters: Map.put_new(state.meters, owner, %{}),
        meter_reservations: Map.put(state.meter_reservations, ref, :suspended),
        meter_recontainments: Map.put(state.meter_recontainments, ref, debt)
    }

    record(state, "meter_recontained", ref, %{"act_ref" => ref})
  end

  defp resolve_debt(state, ref) do
    record = Map.fetch!(state.meter_recontainments, ref)

    state = %{
      state
      | meter_recontainments:
          Map.put(state.meter_recontainments, ref, %{
            record
            | disposition_act_ref: "resolved:#{ref}"
          })
    }

    record(state, "meter_duty_resolved", ref, %{"act_ref" => ref})
  end

  defp record(state, type, identity, data \\ %{}) do
    state = AuthorityIndex.record(state, %Event{type: type, identity: identity, data: data})
    assert AuthorityIndex.complete?(state.read_index.authority, state)
    assert Facts.current(state) === Facts.from_state(state)
    state
  end

  defp mandate(ref, holder, parent \\ nil) do
    # Minimal typed authority fixture; canonical admission is tested separately.
    struct(Mandate,
      ref: ref,
      holder_ref: holder,
      parent_ref: parent,
      grantor_ref: "controller",
      accountable_ref: "owner",
      executor_refs: ["executor"],
      executor_contract_refs: ["contract"],
      scope_refs: ["scope"],
      classes: ["app.read"],
      ceiling: %Row{read: true},
      purpose_ref: "purpose",
      not_before: 90,
      expires_at: 200
    )
  end

  defp candidate(mandate) do
    {:ok, candidate} =
      Candidate.new(
        identity_key: "read",
        class: "app.read",
        row: %{read: true},
        proposer_ref: "worker",
        executor_ref: "executor",
        executor_contract_ref: "contract",
        accountable_ref: "owner",
        scope_ref: "scope",
        purpose_ref: "purpose",
        requested_mandate_ref: mandate,
        consequence: %{}
      )

    candidate
  end

  defp context do
    %{
      domain_ref: "domain",
      scope_ref: "scope",
      authenticated_principal_ref: "worker",
      authentication_ref: "auth",
      ingress_ref: "ingress",
      host_generation: 1
    }
  end
end
