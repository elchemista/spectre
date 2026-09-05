defmodule Spectre.Core.DutyEvidenceCauseTest do
  use ExUnit.Case, async: true

  alias Spectre.Domain.Event.Metadata
  alias Spectre.Duty.Derive.{EvidenceMarker, Facts}
  alias Spectre.Duty.EvidenceCause
  alias Spectre.Evidence
  alias Spectre.GovernedAct.State
  alias Spectre.Portable

  setup do
    attrs = %{
      class: "app.receipt_missing",
      accountable_ref: "owner",
      subject_refs: ["order"],
      related_evidence_refs: ["evidence:related"],
      missing: [%{"receipt" => "not received"}]
    }

    {:ok, cause} = EvidenceCause.new(attrs)
    evidence = evidence(cause)

    rules = %{
      "duty_rules" => %{
        "app.receipt_missing" => %{
          "cause_source_refs" => ["monitor"],
          "disposition_authority_refs" => ["reviewer"],
          "containment" => %{"retry" => :forbidden},
          "closing_conditions" => ["independent review"]
        }
      }
    }

    state = State.new("domain", rules)

    facts =
      Facts.from_state(%{
        state
        | evidence: %{evidence.ref => evidence},
          event_metadata: %{
            evidence.ref => %Metadata{revision: 1, batch_id: "batch", recorded_at: 110}
          }
      })

    %{attrs: attrs, cause: cause, evidence: evidence, rules: rules, facts: facts}
  end

  test "application facts round-trip without carrying authority policy", c do
    canonical = EvidenceCause.canonical(c.cause)
    assert {:ok, exact} = EvidenceCause.from_canonical(canonical)
    assert exact == c.cause
    assert Portable.validate(canonical) == :ok
    refute Map.has_key?(canonical, "disposition_authority_refs")
    refute Map.has_key?(canonical, "containment")
    assert {:ok, exact} = EvidenceCause.extract(c.evidence, c.rules)
    assert exact == c.cause
  end

  for forbidden <- [
        :disposition_authority_refs,
        :containment,
        :closing_conditions,
        :grant,
        :mandate
      ] do
    test "Evidence payload cannot smuggle #{forbidden} policy", c do
      assert {:error, _} =
               EvidenceCause.new(Map.put(c.attrs, unquote(forbidden), "self-authorized"))

      assert {:ok, _} = EvidenceCause.new(c.attrs)
    end
  end

  test "builtin Duty classes cannot be forged using an application marker", c do
    for class <- [:ambiguous_outcome, "scope_promise_overdue", "disputed_evidence"] do
      assert {:error, {:duty_evidence_cause_requires_application_class, ^class}} =
               EvidenceCause.new(%{c.attrs | class: class})
    end
  end

  test "a cause must explain at least one missing fact", c do
    for missing <- [nil, [], "receipt", %{}] do
      assert {:error, {:invalid_duty_evidence_cause_missing, _}} =
               EvidenceCause.new(%{c.attrs | missing: missing})
    end
  end

  test "an accountable principal cannot be omitted", c do
    assert {:error, _} = EvidenceCause.new(Map.delete(c.attrs, :accountable_ref))
    assert {:error, _} = EvidenceCause.new(%{c.attrs | accountable_ref: ""})
  end

  test "an optional causal Mandate remains a reference, not embedded authority", c do
    assert {:ok, cause} = EvidenceCause.new(Map.put(c.attrs, :mandate_ref, "mandate:causal"))
    assert cause.mandate_ref == "mandate:causal"
    assert {:error, _} = EvidenceCause.new(Map.put(c.attrs, :mandate_ref, %{holder_ref: "self"}))
  end

  test "unknown and noninteger schema tags cannot reinterpret a marker", c do
    for version <- [0, 2, 1.0, "1"] do
      assert {:error, {:unsupported_duty_evidence_cause_schema_version, ^version}} =
               EvidenceCause.new(Map.put(c.attrs, :schema_version, version))
    end
  end

  test "unrelated propositions are not application Duty markers", c do
    unrelated = evidence(c.cause, proposition: "ordinary.observation")
    assert :not_cause = EvidenceCause.extract(unrelated, c.rules)
  end

  test "a contrary stance cannot demand a Duty", c do
    contrary = evidence(c.cause, stance: :contradicts)

    assert {:error, {:duty_evidence_cause_must_support, ref}} =
             EvidenceCause.extract(contrary, c.rules)

    assert ref == contrary.ref
  end

  test "provisional speculation cannot open a normative obligation", c do
    provisional = evidence(c.cause, provisional: true, valid_until: 200)

    assert {:error, {:provisional_duty_evidence_cause, ref}} =
             EvidenceCause.extract(provisional, c.rules)

    assert ref == provisional.ref
  end

  test "a payload reference alone is not a decoded cause marker", c do
    payload_ref = Portable.content_ref!(:payload, EvidenceCause.canonical(c.cause))
    indirect = evidence(c.cause, payload: nil, payload_ref: payload_ref)

    assert {:error, {:invalid_duty_evidence_cause_payload, ref}} =
             EvidenceCause.extract(indirect, c.rules)

    assert ref == indirect.ref
  end

  test "the issuer cannot substitute for a configured source", c do
    untrusted = evidence(c.cause, issuer_ref: "monitor", source_ref: "unconfigured")

    assert {:error, {:duty_evidence_source_not_configured, "app.receipt_missing", "unconfigured"}} =
             EvidenceCause.extract(untrusted, c.rules)
  end

  test "a source allowed for another class does not authorize this cause", c do
    rules = %{"duty_rules" => %{"app.other" => %{"cause_source_refs" => ["monitor"]}}}

    assert {:error, {:duty_evidence_source_not_configured, "app.receipt_missing", "monitor"}} =
             EvidenceCause.extract(c.evidence, rules)
  end

  test "an absent source policy does not grant a default right to create debt", c do
    assert {:error, {:duty_evidence_source_not_configured, _, _}} =
             EvidenceCause.extract(c.evidence, %{})
  end

  test "noncanonical payload spelling cannot be interpreted as a second marker shape", c do
    noncanonical = evidence(c.cause, payload: Map.from_struct(c.cause))
    assert {:error, _} = EvidenceCause.extract(noncanonical, c.rules)
  end

  test "the cause key binds its class and exact supporting observation", c do
    assert EvidenceCause.cause_key(c.evidence, c.cause) ==
             {:evidence_gap, c.cause.class, c.evidence.ref}

    later = evidence(c.cause, observed_at: 101)
    assert EvidenceCause.cause_key(later, c.cause) != EvidenceCause.cause_key(c.evidence, c.cause)
  end

  test "derivation waits for durable acquisition, not the observation's claimed time", c do
    assert [] = EvidenceMarker.causes(c.facts, c.rules, 109)
    assert [cause] = EvidenceMarker.causes(c.facts, c.rules, 110)
    assert cause.required_at == 110
  end

  test "a missing ledger position is not a known fact", c do
    facts = %{c.facts | event_metadata: %{}}
    assert [] = EvidenceMarker.causes(facts, c.rules, 200)
  end

  test "Constitution supplies the disposition route and containment, not the payload", c do
    assert [cause] = EvidenceMarker.causes(c.facts, c.rules, 110)
    assert cause.disposition_authority == ["reviewer"]
    assert cause.containment == %{"retry" => :forbidden}
    assert cause.closing_conditions == ["independent review"]
    assert cause.accountable_ref == "owner"
    assert cause.known_evidence_refs == Enum.sort([c.evidence.ref, "evidence:related"])
    assert cause.conflict_refs == ["owner"]
  end

  test "expiration of marker Evidence does not erase already incurred debt", c do
    expiring = evidence(c.cause, valid_until: 120)
    metadata = Map.fetch!(c.facts.event_metadata, c.evidence.ref)

    facts = %{
      c.facts
      | evidence: %{expiring.ref => expiring},
        event_metadata: %{expiring.ref => metadata}
    }

    assert [before] = EvidenceMarker.causes(facts, c.rules, 110)
    assert [after_expiry] = EvidenceMarker.causes(facts, c.rules, 120)
    assert before == after_expiry
  end

  defp evidence(cause, overrides \\ []) do
    {:ok, evidence} =
      Evidence.new(
        Map.merge(
          %{
            proposition: EvidenceCause.proposition(),
            issuer_ref: "issuer",
            source_ref: "monitor",
            provenance: :observed,
            observed_at: 100,
            payload: EvidenceCause.canonical(cause)
          },
          Map.new(overrides)
        )
      )

    evidence
  end
end
