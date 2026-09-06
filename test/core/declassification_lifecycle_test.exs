defmodule Spectre.Core.DeclassificationLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Declassification, Evidence, Governance, Label, Ledger, Row}
  alias Spectre.Domain.{Event, Projection, Sequencer}
  alias Spectre.GovernedAct.Transition.Information
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "declassification-lifecycle"
    domain_ref = "v0.4:#{namespace}:domain"
    row = %Row{write: true, govern: true}

    opts = [
      namespace: namespace,
      governance_allowed: true,
      governance_classes: ["data.declassify"],
      governance_ceiling: row,
      governance_declarations: %{"data.declassify" => row},
      name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}}
    ]

    planning = Fixture.start_domain(opts)
    {:ok, label} = Label.new(owner_ref: planning.refs.grantor, value: "private")

    input = %{
      proposition: "report",
      issuer_ref: planning.refs.grantor,
      provenance: :observed,
      labels: [label],
      payload: "confidential",
      bindings: %{}
    }

    context = Fixture.context(planning, authenticated_principal_ref: planning.refs.grantor)
    {:ok, [parent]} = Sequencer.observe(planning.server, context, input)

    {:ok, output} =
      Evidence.new(
        proposition: "public-summary",
        provenance: :derived,
        issuer_ref: planning.refs.grantor,
        source_ref: planning.refs.grantor,
        parent_refs: [parent.ref],
        observed_at: Runtime.now(),
        payload: "redacted"
      )

    {:ok, targets} = Declassification.required_target_refs(output, [label])
    Fixture.stop_domain(planning)
    fixture = Fixture.start_domain(opts ++ [governance_targets: targets])
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(domain_ref)

    {:ok, scope} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    assert {:ok, [^parent]} = Spectre.observe(scope, input)
    %{fixture: fixture, scope: scope, parent: parent, output: output, label: label}
  end

  test "owner-authorized declassification appends its proof before the new Evidence", c do
    before = Sequencer.projection(c.fixture.server)
    assert {:ok, result} = declassify(c)
    assert result.primary.decision.outcome == :admitted, inspect(result)
    assert result.primary.attempt == nil
    after_commit = Sequencer.projection(c.fixture.server)
    assert after_commit.evidence[c.parent.ref] == c.parent
    assert after_commit.evidence[c.output.ref] == c.output
    assert {:ok, [record]} = Spectre.declassifications(c.scope)
    assert record.source_act_ref == result.primary.act.ref
    assert record.removed_owner_refs == [c.label.owner_ref]
    assert record.removed_label_refs == [c.label.ref]
    suffix = Fixture.snapshot(c.fixture).entries |> Enum.drop(before.revision)

    assert Enum.map(suffix, & &1.payload["type"]) ==
             [
               "decision_recorded",
               "act_committed",
               "declassification_recorded",
               "evidence_recorded"
             ]

    assert length(Enum.uniq_by(suffix, & &1.batch_id)) == 1
    assert_replay(c)
    assert {:ok, replayed} = declassify(c)
    assert replayed.primary.act == result.primary.act
    assert Sequencer.projection(c.fixture.server) == after_commit
  end

  test "a second identity cannot relabel an already materialized output", c do
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = declassify(c)
    before = Sequencer.projection(c.fixture.server)
    assert {:ok, result} = declassify(c, "second")
    assert result.primary.decision.outcome == :refused
    assert result.primary.act == nil
    assert Sequencer.projection(c.fixture.server).declassifications == before.declassifications
    assert_replay(c)
  end

  test "the helper binds the authenticated producer and cannot remove a retained label", c do
    {:ok, foreign} =
      c.output
      |> Map.from_struct()
      |> Map.merge(%{ref: nil, issuer_ref: "other", source_ref: "other"})
      |> Evidence.new()

    assert {:ok, candidate} =
             Governance.declassify_evidence(c.scope, foreign, [c.label], attrs(c, "helper"))

    assert candidate.consequence["evidence_declassification"]["evidence"] ==
             Evidence.canonical(c.output)

    assert {:error, _} =
             Spectre.declassify_evidence(c.scope, c.parent, [c.label], attrs(c, "observed"))

    assert {:error, :declassification_labels_required} =
             Spectre.declassify_evidence(c.scope, c.output, [], attrs(c, "empty"))
  end

  for {field, value} <- [
        class: "refund.issue",
        row: %Row{},
        reservations: %{"meter" => 1},
        executor_ref: "executor:outside",
        target_refs: [],
        proposer_ref: "other"
      ] do
    test "replay transition rejects a declassification Act with altered #{field}", c do
      {prefix, act, event, _evidence_event} = committed_events(c)
      changed = Map.replace!(act, unquote(field), unquote(Macro.escape(value)))

      assert {:error, _} =
               Information.apply(%{prefix | acts: %{act.ref => changed}}, event, event.revision)

      assert {:ok, _} =
               Information.apply(%{prefix | acts: %{act.ref => act}}, event, event.revision)
    end
  end

  test "declassification requires available parents, a unique proof and a unique output", c do
    {prefix, act, event, evidence_event} = committed_events(c)
    state = %{prefix | acts: %{act.ref => act}}
    assert {:ok, proof_state} = Information.apply(state, event, event.revision)
    assert {:ok, final} = Information.apply(proof_state, evidence_event, evidence_event.revision)
    assert final.evidence[c.output.ref] == c.output
    assert {:error, _} = Information.apply(%{state | evidence: %{}}, event, event.revision)

    assert {:error, {:declassified_evidence_already_recorded, _}} =
             Information.apply(%{state | evidence: final.evidence}, event, event.revision)

    assert {:error, {:evidence_already_declassified, _}} =
             Information.apply(
               %{
                 state
                 | declassifications_by_evidence: proof_state.declassifications_by_evidence
               },
               event,
               event.revision
             )

    assert {:error, {:act_already_has_declassification, _, _}} =
             Information.apply(
               %{
                 state
                 | declassifications: %{
                     "other-index" => hd(Map.values(proof_state.declassifications))
                   }
               },
               event,
               event.revision
             )

    dangling = %{proof_state | declassifications: %{}}

    assert {:error, {:declassification_not_found, _}} =
             Information.apply(dangling, evidence_event, evidence_event.revision)
  end

  test "label removal without the governed proof fails even for a valid derived record", c do
    {prefix, _act, _event, evidence_event} = committed_events(c)

    assert {:error, {:evidence_labels_not_conservative, _}} =
             Information.apply(prefix, evidence_event, evidence_event.revision)

    assert {:error, {:evidence_parent_not_found, _, _}} =
             Information.apply(%{prefix | evidence: %{}}, evidence_event, evidence_event.revision)

    future_parent = %{c.parent | observed_at: c.output.observed_at + 1}

    assert {:error, {:evidence_parent_from_future, _, _}} =
             Information.apply(
               %{prefix | evidence: %{c.parent.ref => future_parent}},
               evidence_event,
               evidence_event.revision
             )
  end

  defp committed_events(c) do
    prefix = Sequencer.projection(c.fixture.server)
    {:ok, result} = declassify(c)
    assert result.primary.decision.outcome == :admitted, inspect(result)

    [proof, evidence] =
      Fixture.snapshot(c.fixture).entries
      |> Enum.take(-2)
      |> Enum.map(fn entry ->
        {:ok, event} = Event.decode_entry(entry)
        event
      end)

    {prefix, result.primary.act, proof, evidence}
  end

  defp declassify(c, identity \\ "declassify"),
    do: Spectre.declassify_evidence(c.scope, c.output, [c.label], attrs(c, identity))

  defp attrs(c, identity),
    do: [
      identity_key: identity,
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    ]

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, rebuilt} = Projection.replay(snapshot, c.fixture.constitution)
    assert rebuilt == Sequencer.projection(c.fixture.server)
    assert {:ok, _} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())
  end
end
