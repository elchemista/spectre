Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.SurfaceBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Consequence.Validator
  alias Spectre.GAM.GovernedAct.State
  alias Spectre.GAM.{Portable, Row, Surface}

  test "an undeclared class never falls back to an empty row, contract or validator", c do
    surface = State.surface(c.before)
    candidate = %{c.candidate | class: "orders.unknown"}

    assert {:error, {:consequence_contract_not_declared, "orders.unknown"}} =
             Surface.validate_consequence(surface, candidate)

    assert {:error, {:consequence_validator_not_declared, "orders.unknown"}} =
             Surface.validate_facts(surface, candidate, c.before, c.before.recorded_at)

    assert {:error, {:consequence_validator_not_declared, "orders.unknown"}} =
             Surface.validate_transition(surface, candidate, c.decision, c.act, c.before)

    for invalid <- [nil, :refund, %{}, []] do
      assert {:error, :unknown_class} = Surface.classify(surface, invalid)
      assert {:error, :unknown_class} = Surface.fallback(surface, invalid)
      refute Surface.presentation_required?(surface, invalid)
    end

    assert {:error, :invalid_consequence_candidate} = Surface.validate_consequence(surface, %{})

    assert {:error, :invalid_consequence_validator_input} =
             Surface.validate_facts(surface, %{}, c.before, 0)

    assert {:error, :invalid_consequence_transition_input} =
             Surface.validate_transition(surface, c.candidate, nil, c.act, c.before)
  end

  test "a class cannot acquire a zero row or malformed dimension", c do
    surface = State.surface(c.before)

    assert {:error, {:empty_governed_surface_row, "empty"}} =
             Surface.new(%{surface | ref: nil, declarations: %{"empty" => %{}}})

    assert {:error, {:invalid_row_dimension, :read, :yes}} =
             Surface.new(%{surface | ref: nil, declarations: %{"invalid" => %{read: :yes}}})

    assert {:error, {:invalid_intrinsic_surface_row, "mandate.revoke", [:read], [:govern]}} =
             Surface.new(%{
               surface
               | ref: nil,
                 declarations: %{"mandate.revoke" => %{read: true}}
             })
  end

  test "contracts, validators and refusal policies must name declared classes", c do
    surface = State.surface(c.before)
    contract = surface.consequence_contracts[c.candidate.class]
    validator = Validator.default_for_class(c.candidate.class)

    for {field, value, error} <- [
          {:consequence_contracts, %{"missing" => contract},
           {:consequence_contract_for_unknown_class, "missing"}},
          {:consequence_validators, %{"missing" => validator},
           {:consequence_validator_for_unknown_class, "missing"}},
          {:fallbacks, %{"missing" => :silence}, {:fallback_for_unknown_surface_class, "missing"}}
        ] do
      assert {:error, ^error} =
               Surface.new(surface |> Map.put(:ref, nil) |> Map.replace!(field, value))
    end

    for {field, value} <- [
          {:consequence_contracts, %{c.candidate.class => %{shape: nil}}},
          {:consequence_validators, %{c.candidate.class => "runtime:my-module"}},
          {:fallbacks, %{c.candidate.class => :execute_anyway}},
          {:presentation_required_classes, [nil]}
        ] do
      assert {:error, _} =
               Surface.new(surface |> Map.put(:ref, nil) |> Map.replace!(field, value))
    end
  end

  test "presentation delivery cannot recursively require approval of itself" do
    assert {:error, :presentation_show_cannot_require_approval} =
             Surface.new(
               revision: 1,
               declarations: %{
                 "presentation.show" => %{attempt: true, disclose: true, present: true}
               },
               presentation_required_classes: ["presentation.show"]
             )
  end

  test "Surface content identity agrees with its exact canonical bytes", c do
    surface = State.surface(c.before)
    assert Surface.content_ref(surface) === surface.ref
    assert Surface.digest(surface) === Portable.digest!(Surface.canonical(surface))
    assert {:ok, ^surface} = Surface.from_canonical(Surface.canonical(surface))
  end

  test "Row dimensions are booleans, not implicit grants or truthy values" do
    dimensions = [
      :attempt,
      :observe,
      :read,
      :write,
      :disclose,
      :spend,
      :delegate,
      :govern,
      :present
    ]

    assert Row.known_dimensions() === dimensions

    for dimension <- dimensions do
      assert {:ok, row} = Row.new(%{dimension => true})
      assert :ok = Row.validate(row)
      assert Row.dimensions(row) === [dimension]
      assert Row.digest(row) === Portable.digest!(Row.canonical(row))
      assert {:ok, ^row} = Row.from_canonical(Row.canonical(row))

      for invalid <- [1, "true", nil] do
        assert {:error, {:invalid_row_dimension, ^dimension, ^invalid}} =
                 Row.validate(%{dimension => invalid})

        refute Row.subset?(%{dimension => invalid}, row)
        refute Row.subset?(row, %{dimension => invalid})
      end
    end
  end
end
