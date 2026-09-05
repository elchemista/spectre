defmodule Spectre.Core.RetainedRevocationTest do
  use ExUnit.Case, async: true

  alias Spectre.{Candidate, Condition, Disclosure, Mandate, Row}
  alias Spectre.GovernedAct.{Class, Execution}
  alias Spectre.Kernel.Authority.{Effective, Facts, RetainedRevocation}
  alias Spectre.Mandate.Revocation

  setup do
    {:ok, condition} = Condition.new(proposition: "work.completed")
    {:ok, ceiling} = Row.new(spend: true)

    {:ok, mandate} =
      Mandate.new(%{
        revision: 1,
        grantor_ref: "controller",
        holder_ref: "worker",
        accountable_ref: "owner",
        executor_refs: ["executor"],
        executor_contract_refs: ["contract"],
        scope_refs: ["scope:worker"],
        subject_refs: ["account"],
        target_refs: ["order"],
        classes: ["app.refund"],
        ceiling: ceiling,
        purpose_ref: "purpose:refund",
        purpose_params: %{},
        conditions: [condition],
        not_before: 90,
        expires_at: 110,
        meters: %{"meter" => 100},
        delegation: %{"allowed" => false, "max_depth" => 0},
        revocation: %{"mode" => :retained_controller, "controller_refs" => ["controller"]},
        source_ref: "genesis"
      })

    {:ok, row} = Row.new(govern: true)

    {:ok, candidate} =
      Candidate.new(%{
        identity_key: "revoke:once",
        class: "mandate.revoke",
        row: row,
        proposer_ref: "controller",
        scope_ref: "scope:operator",
        subject_refs: [],
        target_refs: [mandate.ref],
        requested_mandate_ref: mandate.ref,
        accountable_ref: "owner",
        purpose_ref: Class.retained_revocation_purpose_ref(),
        purpose_params: %{},
        executor_ref: Execution.kernel_executor_ref(),
        executor_contract_ref: Execution.kernel_contract_ref(),
        consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate.ref}},
        observation_window_ms: 0
      })

    facts = %Facts{
      mandates: %{mandate.ref => mandate},
      mandate_successors: %{},
      revocations: %{},
      blocked_mandate_refs: MapSet.new(),
      blocked_effect_digests: MapSet.new()
    }

    %{
      mandate: mandate,
      candidate: candidate,
      facts: facts,
      context: %{authenticated_principal_ref: "controller", scope_ref: "scope:operator"}
    }
  end

  test "a controller receives only exact revocation authority, never the holder's powers", c do
    assert RetainedRevocation.request?(c.candidate, c.mandate)
    assert {:ok, effective} = authorize(c)
    assert {:ok, snapshot} = Effective.snapshot(effective, c.candidate)
    assert snapshot.classes == ["mandate.revoke"]
    assert snapshot.target_refs == [c.mandate.ref]
    assert snapshot.holder_ref == "controller"
    assert snapshot.conditions == []
    assert snapshot.meters == %{}
    assert snapshot.ceiling == c.candidate.row
    assert c.facts.mandates[c.mandate.ref] == c.mandate
  end

  # Every mutation preserves Candidate structural validity and changes exactly
  # one of the closed revocation constraints. All have a positive control.
  for {field, value, reason} <- [
        {:consequence, %{"mandate_revoke" => %{"mandate_ref" => "other"}},
         :revocation_consequence_mismatch},
        {:executor_ref, "application-executor", :retained_revocation_executor_mismatch},
        {:executor_contract_ref, "application-contract", :retained_revocation_contract_mismatch},
        {:scope_ref, "scope:foreign", :candidate_scope_mismatch},
        {:subject_refs, ["victim"], :retained_revocation_subjects_not_empty},
        {:target_refs, ["other"], :retained_revocation_targets_mismatch},
        {:purpose_ref, "purpose:refund", :retained_revocation_purpose_mismatch},
        {:purpose_params, %{"extra" => true}, :retained_revocation_purpose_parameters_not_empty},
        {:evidence_refs, ["proof"], :retained_revocation_evidence_not_empty},
        {:meter_requests, %{"meter" => 1}, :retained_revocation_meter_request_present},
        {:observation_window_ms, 1, :retained_revocation_observation_window_present},
        {:accountable_ref, "someone-else", :accountable_claim_mismatch}
      ] do
    test "retained revocation cannot change #{field}", c do
      assert {:ok, _} = authorize(c)
      candidate = replace(c.candidate, unquote(field), unquote(Macro.escape(value)))
      assert {:error, unquote(reason)} = authorize(%{c | candidate: candidate})
    end
  end

  test "retained revocation cannot attach disclosure", c do
    {:ok, disclosure} = Disclosure.new(destination_refs: [c.mandate.ref], labels: [])
    {:ok, row} = Row.new(govern: true, disclose: true)

    {:ok, candidate} =
      c.candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.merge(%{row: row, disclosure: disclosure})
      |> Candidate.new()

    assert {:error, :retained_revocation_disclosure_present} =
             authorize(%{c | candidate: candidate})
  end

  test "retained revocation cannot borrow a Presentation even with valid consent material", c do
    {:ok, digest} = Spectre.Consent.data_digest("revocation")

    {:ok, consent} =
      Spectre.Consent.new(%{
        schema_version: 1,
        recipient_refs: ["controller"],
        data_digest: digest,
        cost: 0,
        purpose_ref: c.candidate.purpose_ref,
        purpose_params: %{},
        risk: "none",
        reversibility: "irreversible",
        alternatives: []
      })

    candidate =
      c.candidate |> replace(:consent, consent) |> replace(:presentation_ref, "presentation")

    assert {:error, :retained_revocation_presentation_present} =
             authorize(%{c | candidate: candidate})
  end

  test "even one additional Row power is rejected", c do
    {:ok, row} = Row.new(govern: true, read: true)
    candidate = replace(c.candidate, :row, row)
    assert {:error, :retained_revocation_row_mismatch} = authorize(%{c | candidate: candidate})
  end

  test "a holder cannot impersonate the authenticated controller", c do
    candidate = replace(c.candidate, :proposer_ref, "worker")
    assert {:error, :proposer_claim_mismatch} = authorize(%{c | candidate: candidate})
  end

  test "a genuinely authenticated holder still lacks retained control", c do
    candidate = replace(c.candidate, :proposer_ref, "worker")
    context = %{c.context | authenticated_principal_ref: "worker"}

    assert {:error, :principal_not_revocation_controller} =
             authorize(%{c | candidate: candidate, context: context})
  end

  test "control cannot be used before the Mandate becomes valid", c do
    assert {:error, :mandate_not_yet_valid} = authorize(c, 89)
    assert {:ok, _} = authorize(c, 90)
  end

  test "control does not outlive its Mandate's exclusive expiry", c do
    assert {:ok, _} = authorize(c, 109)
    assert {:error, :mandate_expired} = authorize(c, 110)
  end

  test "already effective direct revocation prevents another authorization", c do
    revocation = %Revocation{
      identity: "revocation",
      effective_at: 100,
      mode: :retained_controller
    }

    facts = %{c.facts | revocations: %{c.mandate.ref => revocation}}
    assert {:error, :mandate_revoked} = authorize(%{c | facts: facts})
  end

  test "a future revocation is not treated as already effective", c do
    revocation = %Revocation{
      identity: "revocation",
      effective_at: 101,
      mode: :retained_controller
    }

    facts = %{c.facts | revocations: %{c.mandate.ref => revocation}}
    assert {:ok, _} = authorize(%{c | facts: facts}, 100)
    assert {:error, :mandate_revoked} = authorize(%{c | facts: facts}, 101)
  end

  test "another class cannot select the retained-control path", c do
    candidate = replace(c.candidate, :class, "definition.revise")
    refute RetainedRevocation.request?(candidate, c.mandate)
  end

  test "requesting a different Mandate cannot select this controller", c do
    candidate = replace(c.candidate, :requested_mandate_ref, "other")
    refute RetainedRevocation.request?(candidate, c.mandate)
  end

  test "ephemeral authority is not reusable by a second occurrence", c do
    assert {:ok, effective} = authorize(c)
    other = replace(c.candidate, :identity_key, "another-occurrence")

    assert {:error, :effective_authority_candidate_mismatch} =
             Effective.snapshot(effective, other)
  end

  defp authorize(c, time \\ 100),
    do: RetainedRevocation.authorize(c.candidate, c.context, c.mandate, c.facts, time)

  defp replace(candidate, field, value) do
    {:ok, updated} =
      candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(field, value)
      |> Candidate.new()

    updated
  end
end
