defmodule Spectre.Core.EvidenceAndConditionTest do
  use ExUnit.Case, async: true

  alias Spectre.{Condition, Disclosure, Evidence, Label}
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

  test "an improper evidence batch is rejected without raising after a valid first record" do
    assert {:error, :invalid_evidence_list} = Evidence.normalize_unique([evidence() | :broken])
  end

  test "malformed label tails cannot bypass information-flow validation by crashing it" do
    assert {:ok, label} = Label.new(owner_ref: "owner", value: "private")
    malformed = [label | :broken]

    assert {:error, :invalid_labels} = Label.normalize_many(malformed)
    assert {:error, _} = Evidence.new(%{evidence() | ref: nil, labels: malformed})

    assert {:error, _} =
             Disclosure.new(destination_refs: ["destination"], labels: malformed)

    assert {:ok, [^label]} = Label.normalize_many([label, Label.canonical(label)])
  end

  test "schema versions are integer tags, not numerically equivalent floats" do
    for {module, attrs} <- [
          {Label, %{owner_ref: "owner", value: "private"}},
          {Condition, %{proposition: "paid"}},
          {Spectre.Row, %{attempt: true}},
          {Evidence, evidence() |> Map.from_struct() |> Map.delete(:ref)}
        ] do
      assert {:ok, _record} = module.new(attrs)

      for version <- [1.0, "1", nil, true, 0, 2] do
        assert {:error, _reason} = module.new(Map.put(attrs, :schema_version, version))
      end
    end
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
