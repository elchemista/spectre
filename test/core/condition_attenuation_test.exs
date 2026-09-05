defmodule Spectre.Core.ConditionAttenuationTest do
  use ExUnit.Case, async: true

  alias Spectre.{Condition, Evidence}

  # Each row is a different attenuation rule or structural boundary. Positive
  # controls accompany rejected mutations; these are not repeated random seeds.
  for {name, parent_attrs, child_attrs, weakened_field} <- [
        {"integer proposition changed to float", [proposition: 1], [proposition: 1.0],
         :proposition},
        {"nested proposition changes type", [proposition: %{"id" => 1}],
         [proposition: %{"id" => 1.0}], :proposition},
        {"integer binding changed to float", [bindings: %{"id" => 1}], [bindings: %{"id" => 1.0}],
         :bindings},
        {"tuple binding changes type", [bindings: %{"id" => {:account, 1}}],
         [bindings: %{"id" => {:account, 1.0}}], :bindings},
        {"coverage changes opaque numeric type", [coverage: %{"account" => 1}],
         [coverage: %{"account" => 1.0}], :coverage},
        {"required binding removed", [bindings: %{"account" => "A"}], [bindings: %{}], :bindings},
        {"nested binding removed", [bindings: %{"order" => %{"paid" => true, "id" => "A"}}],
         [bindings: %{"order" => %{"id" => "A"}}], :bindings},
        {"required list member removed", [bindings: %{"regions" => ["EU", "US"]}],
         [bindings: %{"regions" => ["EU"]}], :bindings},
        {"list identifier changes numeric type", [bindings: %{"ids" => [1]}],
         [bindings: %{"ids" => [1.0]}], :bindings},
        {"concrete coverage becomes open", [coverage: %{"regions" => ["EU"]}], [coverage: :all],
         :coverage},
        {"minimum witness count decreases", [cardinality: %{min: 2}], [cardinality: %{min: 1}],
         :cardinality},
        {"maximum witness count increases", [cardinality: %{min: 1, max: 2}],
         [cardinality: %{min: 1, max: 3}], :cardinality},
        {"finite maximum disappears", [cardinality: %{min: 1, max: 2}],
         [cardinality: %{min: 1, max: nil}], :cardinality},
        {"generated provenance added", [accepted_provenance: [:observed]],
         [accepted_provenance: [:observed, :generated]], :accepted_provenance},
        {"finite freshness disappears", [freshness_ms: 10], [freshness_ms: nil], :freshness_ms},
        {"freshness window grows", [freshness_ms: 10], [freshness_ms: 11], :freshness_ms},
        {"provisional facts newly accepted", [allow_provisional: false],
         [allow_provisional: true], :allow_provisional},
        {"issuer policy changed", [parameters: %{"issuer_refs" => ["A"]}],
         [parameters: %{"issuer_refs" => ["B"]}], :parameters},
        {"opaque parameters change numeric type", [parameters: %{"revision" => 1}],
         [parameters: %{"revision" => 1.0}], :parameters}
      ] do
    test "attenuation rejects #{name}" do
      parent = condition(unquote(Macro.escape(parent_attrs)))
      child = condition(unquote(Macro.escape(child_attrs)))
      field = unquote(weakened_field)
      assert parent.ref != child.ref
      assert {:error, {:condition_weakened, ^field}} = Condition.attenuation(parent, child)
      refute Condition.attenuates?(child, parent)
      assert :ok = Condition.attenuation(parent, parent)
    end
  end

  for {name, parent_attrs, child_attrs} <- [
        {"adding a binding", [bindings: %{}], [bindings: %{"account" => "A"}]},
        {"adding a nested binding", [bindings: %{"order" => %{"id" => "A"}}],
         [bindings: %{"order" => %{"id" => "A", "paid" => true}}]},
        {"requiring more set members", [bindings: %{"regions" => ["EU"]}],
         [bindings: %{"regions" => ["EU", "US"]}]},
        {"open coverage made concrete", [coverage: :all], [coverage: %{"region" => "EU"}]},
        {"any coverage made concrete", [coverage: :any], [coverage: %{"region" => "EU"}]},
        {"raising the minimum", [cardinality: %{min: 1}], [cardinality: %{min: 2}]},
        {"lowering the maximum", [cardinality: %{min: 1, max: 3}],
         [cardinality: %{min: 1, max: 2}]},
        {"introducing a finite maximum", [cardinality: %{min: 1}], [cardinality: 1]},
        {"removing generated provenance", [accepted_provenance: [:observed, :generated]],
         [accepted_provenance: [:observed]]},
        {"introducing finite freshness", [freshness_ms: nil], [freshness_ms: 10]},
        {"shortening freshness", [freshness_ms: 10], [freshness_ms: 9]},
        {"rejecting provisional facts", [allow_provisional: true], [allow_provisional: false]}
      ] do
    test "attenuation permits #{name}" do
      parent = condition(unquote(Macro.escape(parent_attrs)))
      child = condition(unquote(Macro.escape(child_attrs)))
      assert parent.ref != child.ref
      assert :ok = Condition.attenuation(parent, child)
      assert Condition.attenuates?(child, parent)
      assert {:error, {:condition_weakened, _}} = Condition.attenuation(child, parent)
    end
  end

  test "malformed parent is reported on the parent boundary" do
    assert {:error, {:invalid_attenuation_condition, :parent, _}} =
             Condition.attenuation(%{}, condition())
  end

  test "malformed child is reported on the child boundary" do
    assert {:error, {:invalid_attenuation_condition, :child, _}} =
             Condition.attenuation(condition(), %{})
  end

  test "attenuation is transitive across independent restrictions" do
    first = condition(accepted_provenance: [:observed, :generated])
    second = condition(accepted_provenance: [:observed], freshness_ms: 100)
    third = condition(accepted_provenance: [:observed], freshness_ms: 10, cardinality: 2)
    assert :ok = Condition.attenuation(first, second)
    assert :ok = Condition.attenuation(second, third)
    assert :ok = Condition.attenuation(first, third)
    refute Condition.attenuates?(first, third)
  end

  test "opposition requires the exact proposition, not a numerically coerced one" do
    {:ok, support} =
      Evidence.new(
        proposition: %{"revision" => 1},
        issuer_ref: "A",
        source_ref: "S",
        provenance: :observed,
        observed_at: 100,
        payload: "proof"
      )

    attrs = support |> Map.from_struct() |> Map.put(:ref, nil) |> Map.put(:stance, :contradicts)
    {:ok, exact} = Evidence.new(attrs)
    {:ok, different} = Evidence.new(Map.put(attrs, :proposition, %{"revision" => 1.0}))
    assert Evidence.opposes?(support, exact)
    assert Evidence.opposes?(exact, support)
    refute Evidence.opposes?(support, different)
    refute Evidence.opposes?(different, support)
  end

  test "accepted assumptions must be a list before a Condition can enter a Mandate" do
    for malformed <- [nil, true, 42, "network.available", %{"network.available" => true}] do
      assert {:error, {:invalid_condition_parameter, "accepted_assumptions", _}} =
               Condition.new(
                 proposition: "paid",
                 parameters: %{"accepted_assumptions" => malformed}
               )
    end

    assert {:ok, _} =
             Condition.new(proposition: "paid", parameters: %{"accepted_assumptions" => []})

    assert {:ok, _} =
             Condition.new(
               proposition: "paid",
               parameters: %{
                 "accepted_assumptions" => ["network.available", %{"mode" => "sandbox"}]
               }
             )
  end

  test "unknown application parameters stay opaque rather than becoming recognition policy" do
    parameters = %{"application.policy" => %{"callback" => "host:checks", "revision" => 1}}
    assert {:ok, condition} = Condition.new(proposition: "paid", parameters: parameters)
    assert condition.parameters == parameters
    assert {:ok, ^condition} = Condition.from_canonical(Condition.canonical(condition))
  end

  defp condition(attrs \\ []) do
    {:ok, condition} = Condition.new(Keyword.merge([proposition: "paid"], attrs))
    condition
  end
end
