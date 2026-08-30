defmodule Spectre.Execution.HandoffTest do
  use ExUnit.Case, async: true

  alias Spectre.Execution.Handoff
  alias Spectre.Execution.Materialization

  @definition_ref "sha256:" <> String.duplicate("a", 64)

  test "typed handoffs survive JSON-shaped persistence with stable identity" do
    assert {:ok, handoff} =
             Handoff.flow_to_work(
               @definition_ref,
               :triage,
               :resolve,
               %{"ticket" => 42},
               parent_loop_id: "parent",
               causation_id: "cause",
               provenance: %{"source" => "test"},
               metadata: %{"tenant" => "one"}
             )

    assert handoff.source == %{kind: :flow, ref: "triage"}
    assert handoff.target == %{kind: :work, ref: "resolve"}
    assert handoff.id =~ "execution-handoff:"
    assert handoff.correlation_id == "correlation:" <> handoff.id

    json_data = handoff |> Handoff.to_data() |> Spectre.JSON.encode!() |> Spectre.JSON.decode!()

    assert {:ok, restored} = Handoff.from_data(json_data)
    assert restored == handoff
    assert {:ok, ^handoff} = Handoff.new(handoff)

    assert {:ok, timer_handoff} =
             Handoff.flow_to_work(@definition_ref, :timer, :queue, %{})

    assert timer_handoff.source.ref == "timer"
    assert timer_handoff.target.ref == "queue"

    assert {:ok, ^timer_handoff} =
             timer_handoff
             |> Handoff.to_data()
             |> Spectre.JSON.encode!()
             |> Spectre.JSON.decode!()
             |> Handoff.from_data()

    assert {:ok, event_handoff} =
             Handoff.work_to_flow(@definition_ref, :resolve, :completed, %{"ticket" => 42})

    assert {:ok, event} = Handoff.event(event_handoff)
    assert event.handoff_digest == event_handoff.digest
    assert event.target == %{kind: :flow, ref: "completed"}
  end

  test "target validation binds kind, Definition, Work and exact input" do
    assert {:ok, handoff} =
             Handoff.flow_to_work(@definition_ref, :triage, :resolve, %{"ticket" => 42})

    materialization =
      struct(Materialization,
        definition_ref: @definition_ref,
        program: %{id: "resolve"},
        input: %{"ticket" => 42}
      )

    assert :ok = Handoff.validate_target(handoff, materialization)

    assert {:error, :execution_handoff_definition_mismatch} =
             Handoff.validate_target(
               handoff,
               %{materialization | definition_ref: "sha256:" <> String.duplicate("b", 64)}
             )

    assert {:error, :execution_handoff_work_mismatch} =
             Handoff.validate_target(handoff, %{materialization | program: %{id: "other"}})

    assert {:error, :execution_handoff_input_mismatch} =
             Handoff.validate_target(handoff, %{materialization | input: %{"ticket" => 43}})

    assert {:ok, flow_target} =
             Handoff.work_to_flow(@definition_ref, :resolve, :completed, %{"ticket" => 42})

    assert {:error, {:execution_handoff_target_kind_mismatch, :flow, :work}} =
             Handoff.validate_target(flow_target, materialization)

    assert {:error, {:execution_handoff_target_kind_mismatch, :work, :flow}} =
             Handoff.event(handoff)

    assert {:error, {:invalid_execution_handoff_target, :atom, :map}} =
             Handoff.validate_target(:invalid, materialization)

    assert {:error, {:invalid_execution_handoff, :atom}} = Handoff.event(:invalid)
  end

  test "authored handoff fields and options fail closed" do
    base = %{
      definition_ref: @definition_ref,
      source: %{kind: :flow, ref: :triage},
      target: %{kind: :work, ref: :resolve},
      input: %{"ticket" => 42}
    }

    assert {:error, :invalid_execution_handoff_options} =
             Handoff.flow_to_work(@definition_ref, :triage, :resolve, %{}, [:not_keyword])

    assert {:error, :invalid_execution_handoff_options} =
             Handoff.flow_to_work(@definition_ref, :triage, :resolve, %{}, :not_options)

    assert {:error, {:ambiguous_execution_handoff_field, :source}} =
             Handoff.new(Map.put(base, "source", %{"kind" => "flow", "ref" => "other"}))

    assert {:error, {:unknown_execution_handoff_fields, [:unknown]}} =
             Handoff.new(Map.put(base, :unknown, true))

    assert {:error, {:unsupported_execution_handoff_schema, 2}} =
             Handoff.new(Map.put(base, :schema_version, 2))

    assert {:error, :execution_handoff_self_reference} =
             Handoff.new(%{base | source: %{kind: :work, ref: :resolve}})

    assert {:error, {:ambiguous_execution_handoff_field, :kind}} =
             Handoff.new(%{
               base
               | source: %{"kind" => "flow", "ref" => "triage", kind: :flow}
             })

    assert {:error, {:unknown_execution_handoff_endpoint_fields, :source, [:extra]}} =
             Handoff.new(%{base | source: %{kind: :flow, ref: :triage, extra: true}})

    assert {:error, {:invalid_execution_handoff_endpoint, :source, :atom}} =
             Handoff.new(%{base | source: :triage})

    assert {:error, {:invalid_execution_handoff_kind, :source, :unknown}} =
             Handoff.new(%{base | source: %{kind: :unknown, ref: :triage}})

    assert {:error, {:invalid_execution_handoff_ref, :source, ""}} =
             Handoff.new(%{base | source: %{kind: :flow, ref: ""}})

    assert {:error, {:execution_handoff_code_reference_forbidden, :source}} =
             Handoff.new(%{base | source: %{kind: :flow, ref: System}})

    assert {:error, {:invalid_execution_handoff_input, {:module_execution_literal, []}}} =
             Handoff.new(%{base | input: System})

    assert {:error, {:invalid_execution_handoff_id, :parent_loop_id, 1}} =
             Handoff.new(Map.put(base, :parent_loop_id, 1))

    assert {:error, {:invalid_execution_handoff_field, :provenance, :list}} =
             Handoff.new(Map.put(base, :provenance, []))

    assert {:error, {:invalid_execution_handoff_id, ""}} =
             Handoff.new(Map.put(base, :id, ""))

    assert {:error, {:execution_handoff_digest_mismatch, "tampered", _actual}} =
             base
             |> Map.put(:digest, "tampered")
             |> Handoff.new()

    assert {:error, {:invalid_execution_handoff, :tuple}} = Handoff.new({:bad, :handoff})
  end
end
