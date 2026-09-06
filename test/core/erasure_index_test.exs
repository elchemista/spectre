defmodule Spectre.Core.ErasureIndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.{Act, Attempt, Disclosure, Erasure, Evidence, Outcome, Portable, Presentation}
  alias Spectre.Erasure.Analysis
  alias Spectre.Erasure.Analysis.{Closure, Execution, Facts}
  alias Spectre.Erasure.Index
  alias Spectre.GovernedAct.{DispatchState, ReadIndex, State}

  setup do
    target = Portable.content_ref!(:payload, "erasable root")
    state = new_state() |> evidence("root", [], target) |> evidence("child", ["root"])
    %{state: state, target: target}
  end

  test "request alone is live; Attempt conservatively masks the existing descendants", c do
    requested = request(c.state, c.target, "delete")
    assert requested.read_index.erasure.unavailable === MapSet.new()
    attempted = attempt(requested, "delete")
    assert unavailable(attempted) === MapSet.new(["root", "child"])
    assert {:ok, :possibly_absent} = Analysis.execution_state(attempted, c.target)
  end

  test "new descendants and shared payload holders extend an already active closure", c do
    state = c.state |> request(c.target, "delete") |> attempt("delete")
    state = state |> evidence("late child", ["child"]) |> evidence("shared holder", [], c.target)
    state = evidence(state, "unrelated", [])
    assert unavailable(state) === MapSet.new(["root", "child", "late child", "shared holder"])
    assert Analysis.validate_evidence_available(state, ["unrelated"]) === :ok

    assert {:error, {:evidence_unavailable_after_erasure, "late child"}} =
             Analysis.validate_evidence_available(state, ["late child"])
  end

  test "a late receipt can connect an old independent branch to an active erasure", c do
    state = c.state |> evidence("receipt", []) |> evidence("receipt child", ["receipt"])
    state = state |> act("dependent", ["child"]) |> attempt("dependent")
    state = state |> request(c.target, "delete") |> attempt("delete")
    refute MapSet.member?(unavailable(state), "receipt")
    state = outcome(state, "dependent", :succeeded, ["receipt"])
    assert unavailable(state) === MapSet.new(["root", "child", "receipt", "receipt child"])
  end

  test "Outcome receipt cycles converge without leaking to an unrelated branch", c do
    state =
      c.state |> evidence("other", []) |> act("dependent", ["child"]) |> attempt("dependent")

    state = outcome(state, "dependent", :succeeded, ["root"])
    state = state |> request(c.target, "delete") |> attempt("delete")
    assert unavailable(state) === MapSet.new(["root", "child"])
  end

  test "no-effect removes only its target's coverage when erasures overlap", c do
    other = Portable.content_ref!(:payload, "second payload")
    state = c.state |> evidence("second", [], other) |> evidence("join", ["child", "second"])
    state = state |> request(c.target, "delete-a") |> request(other, "delete-b")
    state = state |> attempt("delete-a") |> attempt("delete-b")
    assert unavailable(state) === MapSet.new(["root", "child", "second", "join"])
    state = outcome(state, "delete-a", :definitive_no_effect)
    assert unavailable(state) === MapSet.new(["second", "join"])
    assert {:ok, :live} = Analysis.execution_state(state, c.target)
    state = outcome(state, "delete-b", :definitive_no_effect)
    assert unavailable(state) === MapSet.new()
    assert state.read_index.erasure.sources === %{}
    assert state.read_index.erasure.reached === %{}
  end

  test "correction after no-effect reactivates the closure including intervening descendants",
       c do
    state = c.state |> request(c.target, "delete") |> attempt("delete")
    state = outcome(state, "delete", :definitive_no_effect)
    state = evidence(state, "between receipts", ["child"])
    assert unavailable(state) === MapSet.new()
    state = outcome(state, "delete", :succeeded, [], "outcome:delete:definitive_no_effect")
    assert unavailable(state) === MapSet.new(["root", "child", "between receipts"])
    assert {:ok, :erased} = Analysis.execution_state(state, c.target)
  end

  test "a later no-effect request cannot undo an earlier successful deletion of the same target",
       c do
    state =
      c.state |> request(c.target, "first") |> attempt("first") |> outcome("first", :succeeded)

    state =
      state
      |> request(c.target, "second")
      |> attempt("second")
      |> outcome("second", :definitive_no_effect)

    assert unavailable(state) === MapSet.new(["root", "child"])
    assert {:ok, :erased} = Analysis.execution_state(state, c.target)
  end

  test "rendered payload flows through the show Act and its receipt to Evidence", c do
    presentation =
      struct(Presentation,
        ref: "presentation",
        rendered_payload_ref: c.target,
        disclosure: struct(Disclosure, source_evidence_refs: [])
      )

    state = new_state() |> record(:presentations, presentation) |> evidence("show receipt", [])

    show =
      struct(Act,
        ref: "show",
        evidence_refs: [],
        mandate_ref: "mandate",
        consequence: Presentation.show_consequence(presentation)
      )

    state =
      state
      |> record(:acts, show)
      |> attempt("show")
      |> outcome("show", :succeeded, ["show receipt"])

    state = state |> request(c.target, "delete") |> attempt("delete")
    assert unavailable(state) === MapSet.new(["show receipt"])
  end

  test "disclosure and presentation bindings both connect an Act to erased Evidence", c do
    presentation =
      struct(Presentation,
        ref: "presentation",
        disclosure: struct(Disclosure, source_evidence_refs: ["child"])
      )

    state = record(c.state, :presentations, presentation)

    disclosed =
      struct(Act,
        ref: "disclosed",
        evidence_refs: [],
        consequence: %{},
        mandate_ref: "mandate",
        disclosure: struct(Disclosure, source_evidence_refs: ["child"])
      )

    bound =
      struct(Act,
        ref: "bound",
        evidence_refs: [],
        consequence: %{},
        mandate_ref: "mandate",
        presentation_ref: presentation.ref
      )

    state = state |> record(:acts, disclosed) |> record(:acts, bound)
    state = state |> evidence("receipt-a", []) |> evidence("receipt-b", [])
    state = state |> attempt("disclosed") |> outcome("disclosed", :succeeded, ["receipt-a"])
    state = state |> attempt("bound") |> outcome("bound", :succeeded, ["receipt-b"])
    state = state |> request(c.target, "delete") |> attempt("delete")
    assert unavailable(state) === MapSet.new(["root", "child", "receipt-a", "receipt-b"])
  end

  test "incomplete hand-built input falls back instead of blessing a partial index", c do
    indexed = c.state |> request(c.target, "delete") |> attempt("delete")
    unindexed = %{indexed | read_index: %ReadIndex{}}
    refute Index.complete?(unindexed.read_index.erasure, unindexed)
    assert Analysis.unavailable_evidence_refs(unindexed) === unavailable(indexed)
    state = record(unindexed, :evidence, evidence_record("new", ["child"], nil))
    refute Index.complete?(state.read_index.erasure, state)
    assert Analysis.unavailable_evidence_refs(state) === MapSet.new(["root", "child", "new"])
  end

  property "incremental availability equals the exhaustive closure at every generated prefix" do
    check all(
            parents <- list_of(integer(0..100), min_length: 1, max_length: 35),
            activate_after <- integer(0..35)
          ) do
      target = Portable.content_ref!(:payload, "generated graph")
      state = new_state() |> evidence("0", [], target) |> request(target, "delete")
      state = if activate_after === 0, do: attempt(state, "delete"), else: state

      {state, active?} =
        parents
        |> Enum.with_index(1)
        |> Enum.reduce(
          {state, activate_after === 0},
          fn {choice, n}, {state, active?} ->
            parent = Integer.to_string(rem(choice, n))
            state = evidence(state, Integer.to_string(n), [parent])

            if not active? and n >= activate_after,
              do: {attempt(state, "delete"), true},
              else: {state, active?}
          end
        )

      state = if active?, do: state, else: attempt(state, "delete")
      assert MapSet.size(unavailable(state)) === length(parents) + 1
      state = outcome(state, "delete", :definitive_no_effect)
      assert unavailable(state) === MapSet.new()
    end
  end

  # These are graph-algebra fixtures, not forged ledgers or admission tests.
  # Real governed prefixes are checked separately by DutyFrontierAssertions.
  defp new_state do
    %{State.new("index-domain") | mandates: %{"mandate" => %{expires_at: 10_000}}}
  end

  defp evidence(state, ref, parents, payload \\ nil),
    do: record(state, :evidence, evidence_record(ref, parents, payload))

  defp evidence_record(ref, parents, payload),
    do:
      struct(Evidence,
        ref: ref,
        parent_refs: parents,
        payload_ref: payload,
        proposition: ref,
        assumptions: [],
        bindings: %{}
      )

  defp act(state, ref, evidence),
    do:
      record(
        state,
        :acts,
        struct(Act, ref: ref, evidence_refs: evidence, consequence: %{}, mandate_ref: "mandate")
      )

  defp request(state, target, id) do
    state
    |> act(id, [])
    |> record(
      :erasures,
      struct(Erasure, ref: "erasure:#{id}", target_ref: target, source_act_ref: id)
    )
  end

  defp attempt(state, act_ref) do
    ref = "attempt:#{act_ref}"

    state
    |> DispatchState.mark_attempted(act_ref, ref)
    |> record(:attempts, struct(Attempt, ref: ref, act_ref: act_ref))
  end

  defp outcome(state, act, status, evidence \\ [], correction \\ nil),
    do:
      record(
        state,
        :outcomes,
        struct(Outcome,
          ref: "outcome:#{act}:#{status}",
          act_ref: act,
          attempt_ref: "attempt:#{act}",
          status: status,
          evidence_refs: evidence,
          observed_at: state.revision,
          contradicts_outcome_ref: correction
        )
      )

  defp record(state, collection, record) do
    type =
      %{
        evidence: "evidence_recorded",
        presentations: "presentation_recorded",
        acts: "act_committed",
        attempts: "attempt_started",
        outcomes: "outcome_recorded",
        erasures: "erasure_requested"
      }[collection]

    state = Map.update!(state, collection, &Map.put(&1, record.ref, record))
    state = %{state | revision: state.revision + 1}
    state = ReadIndex.record(state, %{type: type, identity: record.ref, revision: state.revision})
    if Index.complete?(state.read_index.erasure, state), do: assert_reference(state)
    state
  end

  defp assert_reference(state) do
    facts = Facts.from_state(state)
    assert unavailable(state) === Closure.unavailable_evidence_refs(facts)

    for {target, status} <- state.read_index.erasure.states do
      assert status === Execution.state(facts, target)
    end
  end

  defp unavailable(state), do: state.read_index.erasure.unavailable
end
