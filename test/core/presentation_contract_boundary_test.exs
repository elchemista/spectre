defmodule Spectre.Core.PresentationContractBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.{Act, Candidate, Portable, Presentation}

  setup do
    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: "candidate:binding",
        scope_ref: "scope:checkout",
        recipient_refs: ["principal:customer"],
        approval_source_refs: ["ingress:chat"],
        data: %{"amount_cents" => 100},
        cost: 100,
        purpose_ref: "purpose:refund",
        purpose_params: %{"currency" => "EUR"},
        risk: "money transfer",
        reversibility: false,
        alternatives: ["cancel"],
        renderer_ref: "renderer:checkout",
        rendered_payload: "Refund EUR 1.00?",
        prepared_at: 10
      })

    %{presentation: presentation}
  end

  test "material, digest and canonical restoration describe the same immutable consent", c do
    material = Presentation.material(c.presentation)
    refute Map.has_key?(material, "renderer_ref")
    assert material["data"] == %{"amount_cents" => 100}

    assert Presentation.digest(c.presentation) ==
             Portable.digest!(Presentation.canonical(c.presentation))

    assert c.presentation.material_digest == Portable.digest!(material)
    assert Presentation.content_ref(c.presentation) == c.presentation.ref

    assert {:ok, restored} =
             c.presentation |> Presentation.canonical() |> Presentation.from_canonical()

    assert restored === c.presentation
  end

  test "malformed material is rejected before it can be displayed", c do
    for {field, value, expected} <- [
          {:schema_version, 2, :unsupported_presentation_schema_version},
          {:purpose_params, [], :invalid_presentation_purpose_params},
          {:alternatives, %{}, :invalid_presentation_alternatives},
          {:prepared_at, 10.0, :invalid_presentation_prepared_at}
        ] do
      assert {:error, reason} = rebuild(c.presentation, %{field => value})
      assert elem(reason, 0) == expected
    end

    assert {:error, :invalid_presentation_candidate} =
             Presentation.validate_candidate(%{}, c.presentation)

    assert {:error, {:invalid_presentation_consent_material, _reason}} =
             Presentation.validate_candidate(struct(Candidate), c.presentation)

    assert {:error, :invalid_presentation_show} =
             Presentation.validate_show(%{}, c.presentation)
  end

  test "show validation binds the exact payload, recipients and purpose", c do
    base =
      struct(Act,
        class: Presentation.show_class(),
        row: Presentation.show_row(),
        consequence: Presentation.show_consequence(c.presentation),
        presentation_ref: nil,
        scope_ref: c.presentation.scope_ref,
        target_refs: c.presentation.recipient_refs,
        disclosure: c.presentation.disclosure,
        purpose_ref: c.presentation.purpose_ref,
        purpose_params: c.presentation.purpose_params
      )

    assert :ok = Presentation.validate_show(base, c.presentation)

    for {field, value, reason} <- [
          {:class, "other", :presentation_show_class_mismatch},
          {:row, %{}, :presentation_show_row_mismatch},
          {:consequence, %{}, :presentation_show_consequence_mismatch},
          {:presentation_ref, c.presentation.ref, :presentation_show_cannot_require_approval},
          {:scope_ref, "scope:other", :presentation_show_scope_mismatch},
          {:target_refs, [], :presentation_show_recipients_mismatch},
          {:disclosure, nil, :presentation_show_disclosure_mismatch},
          {:purpose_ref, "purpose:other", :presentation_show_purpose_mismatch}
        ] do
      assert {:error, ^reason} =
               Presentation.validate_show(Map.put(base, field, value), c.presentation)
    end
  end

  test "approval delegates reject malformed records instead of guessing", c do
    assert {:error, _reason} =
             Presentation.validate_approval_contradiction_with_basis(
               nil,
               c.presentation,
               nil,
               [],
               [],
               10
             )
  end

  defp rebuild(presentation, changes) do
    presentation
    |> Map.from_struct()
    |> Map.merge(changes)
    |> Map.put(:ref, nil)
    |> Map.put(:material_digest, nil)
    |> Presentation.new()
  end
end
