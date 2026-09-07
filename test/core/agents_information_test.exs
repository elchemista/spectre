defmodule Spectre.Core.AgentsInformationTest do
  use Spectre.Test.FullAgentCase, async: false

  alias Spectre.{Evidence, Instance, Label, Mind}
  alias Spectre.Mind.Turn
  alias Spectre.Test.FullAgentCase.StatefulMind
  alias Spectre.V04Test.Runtime

  for provenance <- [:derived, :generated] do
    test "a full agent records #{provenance} Evidence with exact Turn lineage and no authority",
         c do
      assert {:ok, %{turn: turn, candidates: []}} = turn(c, "idle")
      before = projection(c)

      assert {:ok, evidence} =
               Mind.evidence(turn, Runtime.now(),
                 proposition: "agent.finding",
                 provenance: unquote(provenance),
                 payload: "finding"
               )

      assert evidence.source_ref == StatefulMind.ref()
      assert evidence.issuer_ref == StatefulMind.ref()
      assert evidence.parent_refs == Turn.evidence_refs(turn)
      assert evidence.provenance == unquote(provenance)
      assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
      assert projection(c).evidence[evidence.ref] == evidence
      assert projection(c).acts == before.acts
      assert projection(c).mandates == before.mandates
      assert projection(c).meters == before.meters
      refute_received {:execution, _}
      assert_replay(c)
    end
  end

  test "a Mind cannot relabel its generated conclusion as an observed fact", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")
    before = projection(c)

    assert {:error, {:invalid_mind_evidence_provenance, :observed}} =
             Mind.evidence(turn, Runtime.now(),
               proposition: "agent.finding",
               provenance: :observed
             )

    assert projection(c) == before
    assert_replay(c)
  end

  test "recording the same Mind derivation twice is idempotent", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, evidence} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    before = projection(c)
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    assert projection(c) == before
    assert_replay(c)
  end

  for {field, value} <- [
        source_ref: "foreign:mind",
        issuer_ref: "foreign:issuer",
        parent_refs: ["evidence:outside-turn"]
      ] do
    test "recomputing a derivation ref cannot forge its #{field} binding", c do
      assert {:ok, %{turn: turn}} = turn(c, "idle")

      assert {:ok, original} =
               Mind.evidence(turn, Runtime.now(),
                 proposition: "agent.finding",
                 payload: "finding"
               )

      assert {:ok, forged} = replace_evidence(original, unquote(field), unquote(value))
      refute forged.ref == original.ref
      before = projection(c)
      assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
      assert projection(c) == before
      assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
      assert_replay(c)
    end
  end

  test "a generated result cannot discard labels inherited from private input", c do
    assert {:ok, label} = Label.new(owner_ref: "owner:customer", value: "private")
    private_input = Map.put(input(c, "idle"), :labels, [label])

    assert {:ok, %{turn: turn, candidates: []}} =
             Instance.turn(c.instance, private_input, mind_opts: mind_options(c, []))

    assert {:ok, original} =
             Mind.evidence(turn, Runtime.now(),
               proposition: "private.finding",
               payload: "private"
             )

    assert original.labels == [label]
    assert {:ok, forged} = replace_evidence(original, :labels, [])
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
    assert projection(c) == before
    assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
    assert_replay(c)
  end

  test "a derivation cannot replace its authenticated Scope binding", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, original} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    bindings = Map.put(original.bindings, "scope_ref", "foreign:scope")
    assert {:ok, forged} = replace_evidence(original, :bindings, bindings)
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, turn, forged)
    assert projection(c) == before
    assert {:ok, ^original} = Spectre.record_derivation(c.scope, turn, original)
    assert_replay(c)
  end

  test "a conclusion cannot claim observation before its generating Turn", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:error, {:mind_derivation_precedes_turn, _}} =
             Mind.evidence(turn, turn.opened_at - 1,
               proposition: "agent.finding",
               payload: "finding"
             )

    assert_replay(c)
  end

  test "a future-dated Mind conclusion cannot be recorded using host-supplied time", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, future} =
             Mind.evidence(turn, Runtime.now() + 1,
               proposition: "agent.finding",
               payload: "finding"
             )

    before = projection(c)

    assert {:error, {:mind_derivation_from_future, _}} =
             Spectre.record_derivation(c.scope, turn, future)

    assert projection(c) == before
    assert_replay(c)
  end

  test "a mutated Turn cannot authenticate a Mind derivation", c do
    assert {:ok, %{turn: turn}} = turn(c, "idle")

    assert {:ok, evidence} =
             Mind.evidence(turn, Runtime.now(), proposition: "agent.finding", payload: "finding")

    forged_turn = %{turn | mind_ref: "foreign:mind"}
    before = projection(c)
    assert {:error, _} = Spectre.record_derivation(c.scope, forged_turn, evidence)
    assert projection(c) == before
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    assert_replay(c)
  end

  defp replace_evidence(evidence, field, value),
    do:
      evidence
      |> Map.from_struct()
      |> Map.put(:ref, nil)
      |> Map.put(field, value)
      |> Evidence.new()
end
