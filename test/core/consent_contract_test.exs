defmodule Spectre.Core.ConsentContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Candidate, Consent, Presentation, Row}

  setup do
    data = %{"order" => "A"}
    {:ok, digest} = Consent.data_digest(data)

    attrs = %{
      schema_version: 1,
      recipient_refs: ["recipient"],
      data_digest: digest,
      cost: 1,
      purpose_ref: "purpose",
      purpose_params: %{"revision" => 1},
      risk: %{"level" => 1},
      reversibility: {:window, 1},
      alternatives: [%{"delay" => 1}]
    }

    {:ok, consent} = Consent.new(attrs)
    {:ok, row} = Row.new(read: true)

    {:ok, candidate} =
      Candidate.new(%{
        identity_key: "read",
        class: "app.read",
        row: row,
        consequence: %{"read" => "document"},
        proposer_ref: "agent",
        executor_ref: "reader",
        executor_contract_ref: "contract",
        accountable_ref: "owner",
        scope_ref: "scope",
        purpose_ref: attrs.purpose_ref,
        purpose_params: attrs.purpose_params,
        consent: consent,
        observation_window_ms: 0
      })

    presentation_attrs =
      attrs
      |> Map.drop([:data_digest])
      |> Map.merge(%{
        candidate_binding_ref: Candidate.presentation_binding_ref(candidate),
        scope_ref: "scope",
        approval_source_refs: ["ingress"],
        data: data,
        renderer_ref: "renderer",
        rendered_payload: %{"text" => "displayed material", "revision" => 1},
        prepared_at: 100
      })

    {:ok, presentation} = Presentation.new(presentation_attrs)
    assert :ok = Presentation.validate_candidate(candidate, presentation)

    %{
      attrs: attrs,
      consent: consent,
      candidate: candidate,
      presentation_attrs: presentation_attrs,
      presentation: presentation
    }
  end

  for {field, changed} <- [
        cost: 1.0,
        risk: %{"level" => 1.0},
        reversibility: {:window, 1.0},
        alternatives: [%{"delay" => 1.0}],
        purpose_params: %{"revision" => 1.0}
      ] do
    test "consent cannot equate a different canonical #{field}", c do
      assert {:ok, changed} =
               Presentation.new(
                 Map.put(c.presentation_attrs, unquote(field), unquote(Macro.escape(changed)))
               )

      assert changed.material_digest != c.presentation.material_digest

      assert {:error, :presentation_consent_material_mismatch} =
               Presentation.validate_candidate(c.candidate, changed)
    end
  end

  test "Candidate consent requires exactly matching opaque purpose parameters", c do
    assert :ok = Consent.validate_purpose(c.consent, "purpose", %{"revision" => 1})

    assert {:error, :consent_purpose_mismatch} =
             Consent.validate_purpose(c.consent, "purpose", %{"revision" => 1.0})

    attrs =
      c.candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:purpose_params, %{"revision" => 1.0})

    assert {:error, :consent_purpose_mismatch} = Candidate.new(attrs)
  end

  test "a show Candidate cannot substitute numerically equal purpose parameters", c do
    attrs = show_attrs(c.presentation)

    assert {:ok, exact} = Candidate.new(attrs)
    assert :ok = Presentation.validate_show(exact, c.presentation)
    assert {:ok, changed} = Candidate.new(%{attrs | purpose_params: %{"revision" => 1.0}})

    assert {:error, :presentation_show_purpose_mismatch} =
             Presentation.validate_show(changed, c.presentation)
  end

  for {field, value} <- [
        {"presentation_ref", "other-presentation"},
        {"scope_ref", "other-scope"},
        {"recipient_refs", ["other-recipient"]},
        {"material_digest", String.duplicate("a", 64)},
        {"renderer_ref", "other-renderer"},
        {"rendered_payload", %{"text" => "displayed material", "revision" => 1.0}},
        {"rendered_payload_ref", "payload:other"},
        {"disclosure", %{"destination_refs" => ["other-recipient"]}}
      ] do
    test "show consequence pins its exact #{field}", c do
      attrs = show_attrs(c.presentation)
      assert {:ok, original} = Candidate.new(attrs)
      assert :ok = Presentation.validate_show(original, c.presentation)

      changed =
        put_in(
          attrs,
          [:consequence, "presentation_show", unquote(field)],
          unquote(Macro.escape(value))
        )

      assert {:ok, candidate} = Candidate.new(changed)

      assert {:error, :presentation_show_consequence_mismatch} =
               Presentation.validate_show(candidate, c.presentation)
    end
  end

  test "show validation rejects extra consequence siblings rather than ignoring them", c do
    attrs = show_attrs(c.presentation)
    attrs = %{attrs | consequence: Map.put(attrs.consequence, "transfer", "hidden-effect")}
    assert {:ok, candidate} = Candidate.new(attrs)

    assert {:error, :presentation_show_consequence_mismatch} =
             Presentation.validate_show(candidate, c.presentation)
  end

  test "show validation requires its intrinsic class", c do
    attrs = %{show_attrs(c.presentation) | class: "app.display"}
    assert {:ok, candidate} = Candidate.new(attrs)

    assert {:error, :presentation_show_class_mismatch} =
             Presentation.validate_show(candidate, c.presentation)
  end

  test "show validation requires explicit presentation power", c do
    {:ok, row} = Row.new(attempt: true, disclose: true)
    attrs = %{show_attrs(c.presentation) | row: row}
    assert {:ok, candidate} = Candidate.new(attrs)

    assert {:error, :presentation_show_row_mismatch} =
             Presentation.validate_show(candidate, c.presentation)
  end

  test "show metadata cannot disagree with its consequence's Scope", c do
    attrs = %{show_attrs(c.presentation) | scope_ref: "other-scope"}
    assert {:ok, candidate} = Candidate.new(attrs)

    assert {:error, :presentation_show_scope_mismatch} =
             Presentation.validate_show(candidate, c.presentation)
  end

  test "a changed data digest cannot reuse an existing consent", c do
    assert {:ok, changed} = Presentation.new(%{c.presentation_attrs | data: %{"order" => "B"}})

    assert {:error, :presentation_consent_material_mismatch} =
             Presentation.validate_candidate(c.candidate, changed)
  end

  test "the same material presented in another Scope cannot approve this Candidate", c do
    assert {:ok, changed} = Presentation.new(%{c.presentation_attrs | scope_ref: "another-scope"})

    assert {:error, :presentation_scope_mismatch} =
             Presentation.validate_candidate(c.candidate, changed)
  end

  test "renderer changes alter Presentation identity but not the declared consent", c do
    assert {:ok, changed} =
             Presentation.new(%{
               c.presentation_attrs
               | renderer_ref: "other-renderer",
                 rendered_payload: "other rendition"
             })

    assert changed.ref != c.presentation.ref
    assert changed.material_digest == c.presentation.material_digest
    assert :ok = Presentation.validate_candidate(c.candidate, changed)
  end

  test "every consent material field is explicit, including empty alternatives", c do
    for field <- Map.keys(c.attrs) do
      assert {:error, {:missing_consent_fields, [^field]}} =
               Consent.new(Map.delete(c.attrs, field))
    end
  end

  test "unknown policy fields cannot hide inside the closed consent record", c do
    assert {:error, _} = Consent.new(Map.put(c.attrs, :auto_approve, true))
    assert {:ok, exact} = Consent.new(c.consent)
    assert exact == c.consent
  end

  test "conflicting atom and string spellings cannot pick a different displayed cost", c do
    assert {:error, _} = Consent.new(Map.put(c.attrs, "cost", 0))
  end

  test "no recipient means there is nobody who can approve", c do
    assert {:error, :missing_consent_recipients} = Consent.new(%{c.attrs | recipient_refs: []})
  end

  test "false and zero are explicit material rather than missing declarations", c do
    assert {:ok, material} =
             Consent.new(%{
               c.attrs
               | cost: 0,
                 risk: false,
                 reversibility: false,
                 alternatives: []
             })

    assert material["cost"] == 0
    assert material["risk"] == false
    assert material["reversibility"] == false
  end

  test "opaque material may not contain a VM-local executable", c do
    for field <- [:cost, :risk, :reversibility] do
      assert {:error, _} = Consent.new(Map.put(c.attrs, field, fn -> :approve end))
    end
  end

  test "data digests are canonical and sensitive to numeric types" do
    assert {:ok, integer} = Consent.data_digest(%{"value" => 1})
    assert {:ok, float} = Consent.data_digest(%{"value" => 1.0})
    assert integer != float
    assert {:ok, ^integer} = Consent.data_digest(Map.new([{"value", 1}]))
  end

  defp show_attrs(presentation) do
    %{
      identity_key: "show",
      class: Presentation.show_class(),
      row: Presentation.show_row(),
      consequence: Presentation.show_consequence(presentation),
      proposer_ref: "agent",
      executor_ref: "renderer",
      executor_contract_ref: "renderer:contract",
      accountable_ref: "owner",
      scope_ref: "scope",
      target_refs: ["recipient"],
      purpose_ref: "purpose",
      purpose_params: %{"revision" => 1},
      disclosure: presentation.disclosure,
      observation_window_ms: 0
    }
  end
end
