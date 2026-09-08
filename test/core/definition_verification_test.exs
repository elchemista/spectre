defmodule Spectre.CoreTest.DefinitionVerificationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Agent.RequestBuilder
  alias Spectre.Consequence.Contract
  alias Spectre.{Definition, Surface}

  defmodule LookupSkill do
    use Spectre.Skill, namespace: "verify", name: "lookup"
    use Spectre.Test.Authoring
    request(:lookup, class: "lookup")
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "verify", name: "support"
    use Spectre.Test.Authoring
    skill(LookupSkill, as: :orders)
    request(:missing, class: "not-declared")
  end

  setup do
    {:ok, contract} = Contract.new(shape: %{"target" => "target_ref", "query" => "string"})

    {:ok, surface} =
      Surface.new(
        revision: 1,
        declarations: %{"lookup" => %{read: true}},
        consequence_contracts: %{"lookup" => contract}
      )

    %{surface: surface, contract: contract}
  end

  test "reports exact immutable refs and leaves occurrence facts explicitly deferred", c do
    definition = definition(%{"lookup" => %{class: "lookup"}})
    assert {:ok, report} = Surface.verify_definition(c.surface, definition)
    assert report.definition_ref == definition.ref
    assert report.surface_ref == c.surface.ref
    assert report.templates["lookup"].checked == [:class]
    assert report.templates["lookup"].errors == []
    assert :consequence in report.templates["lookup"].deferred
    assert :target_refs in report.templates["lookup"].deferred
    assert {:ok, restored} = definition |> Definition.canonical() |> Definition.from_canonical()
    assert {:ok, ^report} = Surface.verify_definition(c.surface, restored)
  end

  test "installed Skill declarations are checked under their actual Agent namespace", c do
    assert {:ok, report} = Surface.verify_definition(c.surface, LookupSkill.definition())
    assert Map.keys(report.templates) == ["lookup"]

    assert {:error, {:definition_surface_mismatch, report}} =
             Surface.verify_definition(c.surface, Assistant.definition())

    assert report.templates["orders/lookup"].checked == [:class]
    assert report.templates["orders/lookup"].errors == []
    assert report.templates["missing"].errors == [{:unknown_class, "not-declared"}]
  end

  test "missing class is allowed in a partial template, not guessed from the name", c do
    definition = definition(%{"lookup" => %{consequence: %{}}, "empty" => %{}})
    assert {:ok, report} = Surface.verify_definition(c.surface, definition)
    assert report.templates["lookup"].checked == []
    assert :class in report.templates["lookup"].deferred
    assert report.templates["empty"].checked == []
  end

  test "collects errors in different templates without stopping at the first mismatch", c do
    definition =
      definition(%{
        "unknown" => %{class: "not-declared"},
        "wrong-consequence" => %{class: "lookup", consequence: %{}},
        "correct" => %{class: "lookup"}
      })

    assert {:error, {:definition_surface_mismatch, report}} =
             Surface.verify_definition(c.surface, definition)

    assert report.templates["unknown"].errors == [{:unknown_class, "not-declared"}]
    assert report.templates["wrong-consequence"].errors != []
    assert report.templates["correct"].errors == []
  end

  test "fixed consequences must already satisfy the complete closed schema", c do
    for value <- [
          %{"target" => "a"},
          %{"target" => "a", "query" => 1},
          %{"target" => "a", "query" => "ok", "hidden" => "power"}
        ] do
      definition = definition(%{"lookup" => %{class: "lookup", consequence: value}})

      assert {:error, {:definition_surface_mismatch, report}} =
               Surface.verify_definition(c.surface, definition)

      assert report.templates["lookup"].errors != []
    end
  end

  test "only supplied static bindings are checked, runtime omission still fails closed", c do
    consequence = %{"target" => "a", "query" => "ok"}
    definition = definition(%{"lookup" => %{class: "lookup", consequence: consequence}})
    assert {:ok, report} = Surface.verify_definition(c.surface, definition)
    assert :consequence in report.templates["lookup"].checked
    assert :target_refs in report.templates["lookup"].deferred

    assert {:error, {:consequence_binding_mismatch, :target, ["a"], []}} =
             Contract.validate(c.contract, consequence, %{})

    assert :ok = Contract.validate(c.contract, consequence, %{target_refs: ["a"]})

    wrong =
      definition(%{"lookup" => %{class: "lookup", consequence: consequence, target_refs: ["b"]}})

    assert {:error, {:definition_surface_mismatch, report}} =
             Surface.verify_definition(c.surface, wrong)

    assert report.templates["lookup"].errors == [
             {:consequence_binding_mismatch, :target, ["a"], ["b"]}
           ]
  end

  test "endpoint set normalization agrees with runtime validation", c do
    consequence = %{"target" => "a", "query" => "ok"}

    definition =
      definition(%{
        "lookup" => %{
          class: "lookup",
          consequence: consequence,
          target_refs: ["a", "a"],
          subject_refs: [],
          disclosure: nil,
          meter_requests: %{}
        }
      })

    assert {:ok, report} = Surface.verify_definition(c.surface, definition)
    assert report.templates["lookup"].deferred == []
    assert :ok = Contract.validate(c.contract, consequence, %{target_refs: ["a", "a"]})
  end

  test "disclosure destinations and exact Meter amounts are not inferred over supplied values" do
    {:ok, contract} =
      Contract.new(shape: %{"recipient" => "destination_ref", "cost" => "meter_requests"})

    {:ok, surface} =
      Surface.new(
        revision: 1,
        declarations: %{"send" => %{disclose: true, spend: true}},
        consequence_contracts: %{"send" => contract}
      )

    consequence = %{"recipient" => "recipient", "cost" => %{"credits" => 2}}

    correct =
      definition(%{
        "send" => %{
          class: "send",
          consequence: consequence,
          disclosure: %{destination_refs: ["recipient"]},
          target_refs: ["recipient"],
          meter_requests: %{"credits" => 2}
        }
      })

    assert {:ok, report} = Surface.verify_definition(surface, correct)
    assert report.templates["send"].deferred == [:subject_refs]

    for fixed <- [
          %{disclosure: nil},
          %{meter_requests: %{"credits" => 2.0}},
          %{meter_requests: %{"credits" => 1}},
          %{target_refs: []}
        ] do
      definition =
        definition(%{"send" => Map.merge(%{class: "send", consequence: consequence}, fixed)})

      assert {:error, {:definition_surface_mismatch, _}} =
               Surface.verify_definition(surface, definition)
    end

    assert {:error, _} = Contract.validate(contract, consequence, %{})
  end

  test "intrinsic governance is deferred instead of validated against a fake projection" do
    {:ok, surface} =
      Surface.new(revision: 1, declarations: %{"definition.revise" => %{govern: true}})

    definition =
      definition(%{
        "revise" => %{class: "definition.revise", consequence: %{}}
      })

    assert {:ok, report} = Surface.verify_definition(surface, definition)
    assert report.templates["revise"].checked == [:class]
    assert :consequence in report.templates["revise"].deferred
  end

  property "fully supplied static bindings agree with the runtime contract, including wrong scalar types" do
    {:ok, contract} =
      Contract.new(
        shape: %{
          "target" => "target_ref",
          "subjects" => "subject_refs",
          "cost" => "meter_requests"
        }
      )

    {:ok, surface} =
      Surface.new(
        revision: 1,
        declarations: %{"lookup" => %{read: true, spend: true}},
        consequence_contracts: %{"lookup" => contract}
      )

    check all(
            subjects <- list_of(member_of(["a", "b", "c"]), max_length: 5),
            cost <- integer(1..100),
            mutation <- member_of([:none, :target, :subject, :meter_float, :cost_float, :extra])
          ) do
      consequence = %{
        "target" => "target",
        "subjects" => subjects,
        "cost" => %{"credits" => cost}
      }

      boundary = %{
        subject_refs: Enum.uniq(subjects),
        target_refs: ["target"],
        destination_refs: [],
        meter_requests: %{"credits" => cost}
      }

      {consequence, boundary} = mutate(consequence, boundary, mutation)
      attrs = boundary |> Map.delete(:destination_refs) |> Map.put(:disclosure, nil)

      attrs =
        Map.merge(attrs, %{
          class: "lookup",
          consequence: consequence
        })

      result = Surface.verify_definition(surface, definition(%{"lookup" => attrs}))

      case Contract.validate(contract, consequence, boundary) do
        :ok ->
          assert {:ok, report} = result
          assert report.templates["lookup"].errors == []
          assert report.templates["lookup"].deferred == []

        {:error, reason} ->
          assert {:error, {:definition_surface_mismatch, report}} = result
          assert report.templates["lookup"].errors == [reason]
      end
    end
  end

  test "corrupted refs and data-only bodies outside the Agent schema are not accepted", c do
    definition = definition(%{})
    assert {:error, _} = Surface.verify_definition(%{c.surface | ref: "forged"}, definition)
    assert {:error, _} = Surface.verify_definition(c.surface, %{definition | ref: "forged"})

    {:ok, plain} =
      Definition.new(namespace: "verify", name: "plain", revision: 1, declared_at: 0, body: %{})

    assert {:error, :not_an_agent_declaration} = Surface.verify_definition(c.surface, plain)
    assert {:error, _} = Surface.verify_definition(nil, definition)
  end

  defp definition(templates) do
    templates =
      Map.new(templates, fn {name, attrs} ->
        {:ok, value} = RequestBuilder.template(attrs)
        {name, value}
      end)

    {:ok, definition} =
      Definition.new(
        namespace: "verify",
        name: "assistant",
        revision: 1,
        declared_at: 0,
        body: put_in(LookupSkill.definition().body, ["authoring", "plan", :requests], templates)
      )

    definition
  end

  defp mutate(consequence, boundary, :none), do: {consequence, boundary}
  defp mutate(consequence, boundary, :target), do: {consequence, %{boundary | target_refs: []}}

  defp mutate(consequence, boundary, :subject),
    do: {consequence, %{boundary | subject_refs: ["outsider"]}}

  defp mutate(consequence, boundary, :meter_float),
    do:
      {consequence,
       %{boundary | meter_requests: %{"credits" => boundary.meter_requests["credits"] / 1}}}

  defp mutate(consequence, boundary, :cost_float),
    do:
      {Map.put(consequence, "cost", %{"credits" => consequence["cost"]["credits"] / 1}), boundary}

  defp mutate(consequence, boundary, :extra), do: {Map.put(consequence, "hidden", true), boundary}
end
