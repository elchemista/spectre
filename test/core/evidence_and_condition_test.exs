defmodule Spectre.Core.EvidenceAndConditionTest do
  use ExUnit.Case, async: true

  alias Spectre.{Condition, Evidence}
  alias Spectre.Kernel.Recognition

  test "canonical key spelling cannot change condition identity or attenuation" do
    assert {:ok, atoms} =
             Condition.new(
               proposition: %{paid: true},
               bindings: %{order: %{id: "1"}},
               parameters: %{issuer_refs: ["issuer"]}
             )

    assert {:ok, strings} =
             Condition.new(
               proposition: %{"paid" => true},
               bindings: %{"order" => %{"id" => "1"}},
               parameters: %{"issuer_refs" => ["issuer"]}
             )

    assert atoms == strings
    assert Condition.digest(atoms) == Condition.digest(strings)
    assert {:ok, ^atoms} = atoms |> Condition.canonical() |> Condition.from_canonical()
    assert :ok = Condition.attenuation(atoms, strings)
    assert :ok = Condition.attenuation(strings, atoms)

    assert {:ok, narrower} =
             Condition.new(
               proposition: %{paid: true},
               bindings: %{order: %{id: "1", customer: "alice"}},
               parameters: %{issuer_refs: ["issuer"]}
             )

    assert :ok = Condition.attenuation(strings, narrower)
    assert {:error, {:condition_weakened, :bindings}} = Condition.attenuation(narrower, atoms)
  end

  test "colliding atom/string keys are rejected even when nested and equal" do
    for value <- [%{:id => "1", "id" => "1"}, %{:id => "1", "id" => "2"}] do
      assert {:error, {:condition_key_collision, "id"}} =
               Condition.new(proposition: "paid", bindings: %{order: value})
    end
  end

  test "attenuation cannot weaken provenance, freshness, cardinality or provisional policy" do
    attrs = %{
      proposition: "paid",
      accepted_provenance: [:observed],
      freshness_ms: 10,
      cardinality: 2,
      allow_provisional: false
    }

    assert {:ok, parent} = Condition.new(attrs)

    for {field, value} <- [
          accepted_provenance: [:observed, :generated],
          freshness_ms: 11,
          cardinality: 1,
          allow_provisional: true
        ] do
      assert {:ok, child} = Condition.new(Map.put(attrs, field, value))
      assert {:error, {:condition_weakened, ^field}} = Condition.attenuation(parent, child)
    end
  end

  test "recognition distinguishes missing, contrary and conflicting facts independently of order" do
    {:ok, condition} = Condition.new(proposition: "paid", cardinality: 1)
    support = evidence()
    contrary = evidence(stance: :contradicts)
    assert {:satisfied, [ref]} = Recognition.check_with_basis([condition], [support], 100)
    assert ref == support.ref
    assert {:undecidable, _} = Recognition.check([condition], [], 100)
    assert {:unsatisfied, _} = Recognition.check([condition], [contrary], 100)

    assert {{:undecidable, _}, basis} =
             Recognition.check_with_basis([condition], [support, contrary], 100)

    assert basis == Enum.sort([support.ref, contrary.ref])

    assert Recognition.check_with_basis([condition], [support, contrary], 100) ==
             Recognition.check_with_basis([condition], [contrary, support], 100)
  end

  test "time boundaries and freshness cannot silently extend factual validity" do
    value = evidence(valid_from: 110, valid_until: 120)
    assert Evidence.temporal_status(value, 99) == :from_future
    assert Evidence.temporal_status(value, 109) == :not_yet_valid
    assert Evidence.temporal_status(value, 110) == :current
    assert Evidence.temporal_status(value, 119) == :current
    assert Evidence.temporal_status(value, 120) == :expired
    assert Evidence.current_at?(value, 110, 10)
    refute Evidence.current_at?(value, 111, 10)
  end

  test "strict normalization preserves order but rejects duplicate refs and changed content" do
    first = evidence()
    second = evidence(payload: %{"receipt" => "2"})

    assert {:ok, [^second, ^first]} =
             Evidence.normalize_unique([second, Evidence.canonical(first)])

    assert {:error, {:duplicate_evidence, ref}} = Evidence.normalize_unique([first, first])
    assert ref == first.ref
    assert {:error, _} = Evidence.new(%{first | proposition: "forged"})
    assert {:error, :invalid_evidence_list} = Evidence.normalize_unique(%{})
    assert {:ok, []} = Evidence.normalize_unique([])
  end

  defp evidence(overrides \\ []) do
    {:ok, evidence} =
      Evidence.new(
        Keyword.merge(
          [
            proposition: "paid",
            issuer_ref: "issuer",
            source_ref: "source",
            provenance: :observed,
            observed_at: 100,
            payload: %{"receipt" => "1"},
            provisional: false
          ],
          overrides
        )
      )

    evidence
  end
end
