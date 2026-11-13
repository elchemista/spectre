Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.RecordCoordinateBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.{
    Act,
    Attempt,
    Candidate,
    Condition,
    Decision,
    Duty,
    Evidence,
    HostProfile,
    Mandate,
    Outcome,
    Principal,
    Surface
  }

  alias Spectre.GAM.Domain.{Event, Sequencer}
  alias Spectre.GAM.GovernedAct.State
  alias Spectre.GAM.Scope.Opening
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    f = Fixture.start_domain(namespace: "record-coordinates")
    on_exit(fn -> Fixture.stop_domain(f) end)
    evidence = Fixture.paid_evidence(f)
    {:ok, _} = Fixture.observe_payment(f, evidence)

    {:ok, candidate} =
      Candidate.new(Fixture.refund_candidate(f, 100, evidence_refs: [evidence.ref]))

    {:ok, %{act: act, decision: decision, grant: grant}} =
      Sequencer.submit(f.server, Fixture.context(f), candidate)

    {:ok, _, attempt, _} = Sequencer.consume_grant(f.server, grant)
    outcome = Fixture.outcome(f, act, attempt, :ambiguous)
    {:ok, _} = Sequencer.record_outcome(f.server, outcome)
    state = Sequencer.projection(f.server)
    [duty] = Map.values(state.duties)

    records = %{
      Act => act,
      Attempt => attempt,
      Candidate => candidate,
      Decision => decision,
      Duty => duty,
      Evidence => evidence,
      HostProfile => State.host_profile(state),
      Mandate => f.mandate,
      Outcome => outcome,
      Principal => hd(Map.values(state.catalog.principals)),
      Surface => State.surface(state),
      Condition => f.condition,
      Opening => state.catalog.scopes[f.refs.scope]
    }

    %{records: records}
  end

  # Mutate freshly decoded records, clearing a content reference so rejection
  # proves the field contract, not just detection of a stale digest.
  for {module, fields} <- [
        {Act,
         [
           class: "",
           consequence: nil,
           purpose_params: [],
           mandate_revision: 0,
           surface_revision: -1,
           observation_window_ms: 1.0,
           committed_at: 1.0,
           host_generation: -1,
           proposer_ref: "",
           executor_ref: nil,
           authorizer_ref: nil,
           accountable_ref: "",
           scope_ref: "",
           purpose_ref: "",
           mandate_ref: "",
           host_profile_ref: "",
           executor_contract_ref: "",
           reservations: %{x: 1},
           subject_refs: [nil],
           recognition_refs: [""],
           evidence_refs: [1]
         ]},
        {Candidate,
         [
           class: "",
           consequence: nil,
           purpose_params: [],
           observation_window_ms: -1,
           identity_key: "",
           proposer_ref: "",
           executor_ref: "",
           accountable_ref: "",
           scope_ref: "",
           purpose_ref: "",
           executor_contract_ref: "",
           requested_mandate_ref: 1,
           presentation_ref: "unbound",
           meter_requests: %{"x" => 1.0}
         ]},
        {Decision,
         [
           outcome: :allowed,
           reasons: %{},
           surface_revision: -1,
           authority_revision: -1,
           decided_at: 1.0,
           host_generation: 1.0,
           mandate_ref: nil,
           mandate_revision: 0,
           executor_ref: nil,
           authorizer_ref: nil,
           accountable_ref: nil,
           candidate_class: "",
           candidate_digest: "",
           domain_ref: "",
           ingress_ref: ""
         ]},
        {Evidence,
         [
           proposition: nil,
           stance: :maybe,
           provenance: :trusted,
           observed_at: 1.0,
           freshness_ms: -1,
           bindings: [],
           assumptions: %{},
           labels: [nil],
           valid_until: 0,
           issuer_ref: "",
           source_ref: "",
           provisional: :yes,
           parent_refs: ["parent:observed-cannot-derive"]
         ]},
        {HostProfile,
         [revision: 0, mode: :trusted, assumptions: %{}, declared_at: 1.0, attestation_ref: ""]},
        {Principal, [kind: :superuser, display_name: 1, attributes: []]},
        {Outcome,
         [
           status: :confirmed,
           observed_at: 1.0,
           details_ref: "",
           act_ref: "",
           attempt_ref: "",
           contradicts_outcome_ref: "unallowed-ambiguous-correction"
         ]},
        {Attempt,
         [
           generation: -1,
           started_at: 1.0,
           act_ref: "",
           executor_ref: "",
           material_digest: "",
           grant_nonce_digest: ""
         ]},
        {Duty,
         [
           status: :expired,
           disposition_act_ref: "without-disposition",
           missing: %{},
           closing_conditions: %{},
           opened_at: 1.0,
           accountable: ""
         ]},
        {Opening,
         [
           kind: :workspace,
           parent_ref: "session-cannot-have-parent",
           opened_at: 1.0,
           host_generation: -1,
           source_act_ref: "session-cannot-have-source",
           domain_ref: ""
         ]},
        {Surface,
         [
           revision: -1,
           declarations: [],
           consequence_contracts: [],
           consequence_validators: [],
           presentation_required_classes: ["absent"],
           fallbacks: []
         ]},
        {Mandate,
         [
           revision: 0,
           grantor_ref: "",
           holder_ref: "",
           accountable_ref: "",
           not_before: 1.0,
           expires_at: 0,
           purpose_params: [],
           delegation: %{"allowed" => true, "max_depth" => -1},
           revocation: %{"mode" => :forget},
           meters: %{"meter" => -1}
         ]},
        {Condition,
         [
           proposition: nil,
           accepted_provenance: [:trusted],
           freshness_ms: -1,
           bindings: [],
           parameters: [],
           allow_provisional: :yes,
           cardinality: %{"min" => -1, "max" => 1}
         ]}
      ] do
    test "#{inspect(module)} refuses malformed coordinates independently of content-ref mismatch",
         c do
      module = unquote(module)
      original = Map.fetch!(c.records, module)
      assert {:ok, ^original} = module.new(original)

      for {field, invalid} <- unquote(Macro.escape(fields)) do
        attrs = construction_attrs(original) |> Map.replace!(field, invalid)
        result = module.new(attrs)
        assert match?({:error, _}, result), inspect({module, field, invalid, result})
        refute match?({:error, {:content_ref_mismatch, _, _}}, result), inspect({module, field})
      end
    end
  end

  test "all governed record types reject an unknown schema, including float version one", c do
    for {module, record} <- c.records, version <- [0, 2, 1.0, "1"] do
      assert {:error, reason} =
               module.new(Map.put(construction_attrs(record), :schema_version, version))

      assert inspect(reason) =~ "schema_version", inspect({module, version, reason})
    end
  end

  test "transported records cannot smuggle a field absent from the declared schema", c do
    for {module, record} <- c.records do
      canonical = module.canonical(record)
      assert {:ok, ^record} = module.from_canonical(canonical)
      assert {:error, _} = module.from_canonical(Map.put(canonical, "bypass", true))
      assert {:error, _} = module.from_canonical(Map.delete(canonical, "schema_version"))
      assert {:error, _} = module.from_canonical(record)
    end
  end

  test "event envelopes accept the declared record kind, not a similarly shaped map", c do
    for {kind, module} <- [
          act: Act,
          decision: Decision,
          evidence: Evidence,
          attempt: Attempt,
          outcome: Outcome,
          duty: Duty,
          scope: Opening
        ] do
      record = c.records[module]
      assert {:ok, envelope} = Event.record(kind, record)
      assert {:ok, decoded} = Event.decode(envelope)
      assert decoded.identity == record.ref

      assert {:error, {:invalid_domain_record, ^kind}} =
               Event.record(kind, Map.from_struct(record))

      assert {:error, _} = Event.record(kind, %{record | schema_version: 0})
    end

    assert {:error, _} = Event.record(:unknown, c.records[Act])
  end

  test "malformed governance event arguments cannot manufacture an envelope", c do
    act = c.records[Act]

    for {function, args, reason} <- [
          {:meter, [:mint, act], :invalid_meter_event},
          {:meter_recontained, [act, nil, %{}, %{}], :invalid_meter_recontainment_event},
          {:meter_devolved, [act, "", %{}], :invalid_meter_devolution_event},
          {:surface_revised, [act, nil, c.records[Surface]], :invalid_surface_revision_event},
          {:host_profile_revised, [act, "", c.records[HostProfile]],
           :invalid_host_profile_revision_event},
          {:definition_revised, [act, nil], :invalid_definition_revision_event},
          {:principal_registered, [act, %{}], :invalid_principal_registration_event},
          {:dispatch_cancelled, [act, c.records[Mandate], :forget],
           :invalid_dispatch_cancellation_event},
          {:mandate_revoked, [act, ""], :invalid_mandate_revocation_event},
          {:mandate_restricted, [act, "", c.records[Mandate]],
           :invalid_mandate_restriction_event},
          {:duty_disposed, [act, nil], :invalid_duty_disposition_event},
          {:scope_opened, [Map.from_struct(c.records[Opening])], :invalid_scope_event}
        ] do
      assert {:error, ^reason} = apply(Event, function, args)
    end
  end

  test "devolution records an exact nonempty quantity and never rounds invalid amounts", c do
    act = c.records[Act]
    assert {:ok, event} = Event.meter_devolved(act, "mandate:child", act.reservations)
    assert {:ok, decoded} = Event.decode(event)
    assert decoded.data["child_mandate_ref"] == "mandate:child"
    assert decoded.data["amounts"] === act.reservations
    assert {:error, :empty_meter_devolution} = Event.meter_devolved(act, "mandate:child", %{})

    for amounts <- [%{"meter" => -1}, %{"meter" => 1.0}, %{nil => 1}] do
      assert {:error, :invalid_meter_devolution} =
               Event.meter_devolved(act, "mandate:child", amounts)
    end

    {:ok, unmetered} = Act.new(%{act | ref: nil, reservations: %{}})
    assert {:error, :empty_meter_reservations} = Event.meter(:release, unmetered)
  end

  test "expiry cancellation binds to the Mandate revision and its exact expiry", c do
    act = c.records[Act]
    mandate = c.records[Mandate]
    assert {:ok, event} = Event.dispatch_cancelled(act, mandate, :mandate_expired)
    assert event["data"]["cancelled_at"] === mandate.expires_at
    assert event["data"]["cause_ref"] == mandate.ref

    {:ok, other} = Mandate.new(%{mandate | ref: nil, revision: mandate.revision + 1})

    assert {:error, :dispatch_expiration_mandate_mismatch} =
             Event.dispatch_cancelled(act, other, :mandate_expired)

    assert {:error, _} =
             Event.dispatch_cancelled(act, %{mandate | expires_at: nil}, :mandate_expired)
  end

  test "recontainment must partition the original reservation, never mint or lose a unit", c do
    act = c.records[Act]
    original = c.records[Outcome]

    {:ok, correction} =
      Outcome.new(%{
        original
        | ref: nil,
          status: :succeeded,
          contradicts_outcome_ref: original.ref,
          evidence_refs: [c.records[Evidence].ref]
      })

    recontained = Map.new(act.reservations, fn {ref, amount} -> {ref, div(amount, 2)} end)
    deficits = Map.new(act.reservations, fn {ref, amount} -> {ref, amount - recontained[ref]} end)

    assert {:ok, event} = Event.meter_recontained(act, correction, recontained, deficits)
    assert event["data"]["recontained"] === recontained
    assert event["data"]["deficits"] === deficits

    assert {:error, :invalid_meter_recontainment_partition} =
             Event.meter_recontained(act, correction, %{}, %{})

    for amounts <- [nil, [], %{"meter" => -1}, %{"meter" => 0.5}] do
      assert {:error, :invalid_meter_recontainment_amounts} =
               Event.meter_recontained(act, correction, amounts, deficits)
    end

    {:ok, other} = Outcome.new(%{correction | ref: nil, act_ref: "act:other"})

    assert {:error, :meter_recontainment_cause_mismatch} =
             Event.meter_recontained(act, other, recontained, deficits)
  end

  defp construction_attrs(%Attempt{} = record), do: Map.from_struct(record)
  defp construction_attrs(%Opening{} = record), do: Map.from_struct(record)
  defp construction_attrs(record), do: record |> Map.from_struct() |> Map.delete(:ref)
end
