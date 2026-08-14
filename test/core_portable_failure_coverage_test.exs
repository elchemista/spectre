defmodule SpectreCorePortableFailureCoverageTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :core_portable_failure_coverage_agent
end

defmodule SpectreCorePortableFailureCoverageTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Effect
  alias Spectre.Event.Envelope
  alias Spectre.Input
  alias Spectre.Instance
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Runtime
  alias Spectre.State
  alias Spectre.State.Codec, as: StateCodec
  alias Spectre.Subject
  alias SpectreCorePortableFailureCoverageTest.Agent

  test "Event envelopes fail closed across every public shape and scalar boundary" do
    attrs = event_attrs()
    pending = Envelope.new!(attrs)

    assert_raise ArgumentError, ~r/invalid Event Envelope/, fn ->
      Envelope.new!(Map.put(attrs, :status, :future))
    end

    assert {:error, {:unknown_event_envelope_fields, [:unknown]}} =
             attrs |> Map.put(:unknown, true) |> Envelope.new()

    assert {:error, {:unsupported_event_envelope_schema, 99}} =
             attrs |> Map.put(:schema_version, 99) |> Envelope.new()

    assert {:error, {:invalid_event_class, :future}} =
             attrs |> Map.put(:event_class, :future) |> Envelope.new()

    assert {:error, {:invalid_event_status, :future}} =
             attrs |> Map.put(:status, :future) |> Envelope.new()

    assert {:error, {:invalid_event_definition_ref, :invalid}} =
             attrs |> Map.put(:origin_definition_ref, :invalid) |> Envelope.new()

    invalid_ref = %DefinitionRef{
      algorithm: :sha256,
      digest: "",
      canonicalization_version: 1,
      contract_version: 1
    }

    assert {:error, {:invalid_event_definition_ref, ^invalid_ref}} =
             attrs |> Map.put(:origin_definition_ref, invalid_ref) |> Envelope.new()

    assert {:error, {:invalid_event_continuation, :invalid}} =
             attrs |> Map.put(:continuation_ref, :invalid) |> Envelope.new()

    assert {:error, {:nonportable_event_field, :payload, _reason}} =
             attrs |> Map.put(:payload, self()) |> Envelope.new()

    assert {:error, {:invalid_event_field, :provenance, :list}} =
             attrs |> Map.put(:provenance, []) |> Envelope.new()

    assert {:error, {:invalid_event_field, :id, ""}} =
             attrs |> Map.put(:id, "") |> Envelope.new()

    assert {:error, {:invalid_event_field, :emitted_at, -1}} =
             attrs |> Map.put(:emitted_at, -1) |> Envelope.new()

    assert {:error, {:invalid_event_field, :owner_fencing_token, 0}} =
             Envelope.admit(pending,
               status: :quarantined,
               admitted_activation_generation: 0,
               authority_epoch: 0,
               owner_fencing_token: 0,
               admission_revision: 1,
               admitted_at: 0,
               quarantine_reason: :invalid_fence
             )

    for {value, shape} <- [
          {{:bad}, :tuple},
          {"bad", :binary},
          {1, :integer},
          {self(), :other}
        ] do
      assert {:error, {:invalid_event_envelope, ^shape}} = Envelope.new(value)
    end
  end

  test "Event envelope readers reject corrupted scalar and reference encodings" do
    data = event_attrs() |> Envelope.new!() |> Envelope.to_data()

    assert {:error, {:invalid_event_class, "future"}} =
             data |> Map.put("event_class", "future") |> Envelope.from_data()

    assert {:error, {:invalid_event_status, "future"}} =
             data |> Map.put("status", "future") |> Envelope.from_data()

    assert {:error, {:invalid_event_definition_ref_data, 42}} =
             data |> Map.put("origin_definition_ref", 42) |> Envelope.from_data()

    assert {:error, :invalid_event_run_continuation} =
             data
             |> Map.put("continuation_ref", %{
               "type" => "run",
               "run_id" => "",
               "revision" => 0,
               "kind" => "reply",
               "boundary_id" => "boundary",
               "subject_id" => nil
             })
             |> Envelope.from_data()

    assert {:error, {:invalid_event_continuation_data, :integer}} =
             data |> Map.put("continuation_ref", 7) |> Envelope.from_data()

    assert {:error, {:invalid_event_field, :admitted_activation_generation, nil}} =
             data |> Map.put("status", "quarantined") |> Envelope.from_data()
  end

  test "canonical Definition lowering rejects malformed compiled sources and components" do
    definition = %Definition{id: :coverage_definition, owner: __MODULE__}

    assert {:ok, _canonical} = Canonical.lower(definition)

    for {source, shape} <- [
          {[], :list},
          {%{}, :map},
          {{:bad}, :tuple},
          {nil, :atom},
          {self(), :other}
        ] do
      assert {:error, {:invalid_compiled_definition_source, ^shape}} = Canonical.lower(source)
    end

    assert {:error, {:recursive_compiled_definition, Agent}} =
             Canonical.lower(Agent, ancestors: [Agent])

    assert {:error, {:invalid_definition_description, :bad}} =
             definition |> Map.put(:config, description: :bad) |> Canonical.lower()

    assert {:error, {:invalid_compiled_skill_applicability, _reason}} =
             definition
             |> Map.merge(%{kind: :skill, config: [applicability: :bad]})
             |> Canonical.lower()

    assert {:error, {:invalid_compiled_skill_prompt_budget, _reason}} =
             definition
             |> Map.merge(%{kind: :skill, config: [prompt_budget: -1]})
             |> Canonical.lower()

    assert {:error, {:invalid_compiled_skill_mount, 0, :atom}} =
             definition |> Map.put(:skills, [:bad]) |> Canonical.lower()

    assert {:error, {:change_surface_requires_agent, :skill}} =
             definition
             |> Map.merge(%{kind: :skill, change_surface: %{}})
             |> Canonical.lower()

    assert {:error,
            {:nonportable_compiled_definition_value, [:handler, 0, :rules, :routing], :pid}} =
             definition
             |> Map.put(:rules, [%{label: :bad, handler: self()}])
             |> Canonical.lower()
  end

  test "Runtime rejects failed, fenced, malformed, and unnormalizable resumes" do
    run = Run.new(Agent, %Input{text: "hello"}, %State{})

    assert {:error, :run_failed, _run} =
             run |> Map.merge(%{status: :failed, last_error: nil}) |> Runtime.advance()

    assert {:error, {:run_requires_resume, _, _, :effect}, _run} =
             run |> Map.merge(%{status: :awaiting, cursor: :effect}) |> Runtime.advance()

    assert {:error, {:run_failed, _, _, :boom}, _run} =
             run |> Map.merge(%{status: :failed, last_error: :boom}) |> Runtime.resume(:ignored)

    assert {:error, {:invalid_run_resume, _, _, :turn, :tuple2}, _run} =
             Runtime.resume(run, {:tuple2, :value})

    assert {:error, {:invalid_run_resume, _, _, :turn, :tuple3}, _run} =
             Runtime.resume(run, {:tuple3, :value, :more})

    assert {:error, {:invalid_run_resume, _, _, :turn, :unknown}, _run} =
             Runtime.resume(run, 42)

    boundary_run =
      Map.merge(run, %{
        status: :boundary,
        cursor: :policy,
        waiting: %Boundary{id: "boundary:coverage", kind: :policy, ref: nil}
      })

    assert {:error, {:run_input_failed, Protocol.UndefinedError}, _run} =
             Runtime.resume(boundary_run, {:input, self()})

    assert {:error, {:invalid_input_pipeline, :invalid}, _run} =
             Runtime.start(Agent, "hello", input_pipeline: :invalid)
  end

  test "State transport rejects malformed lifecycle members before persistence" do
    assert {:error, {:invalid_effect, :atom}} =
             StateCodec.encode(%State{pending_effects: [:invalid]})

    assert {:error, {:invalid_awaitable, :atom}} =
             StateCodec.encode(%State{awaitables: [:invalid]})

    assert {:error, :improper_state_list} =
             StateCodec.encode(%State{data: %{invalid: [1 | 2]}})

    effect = Effect.stage_action(%{name: :publish}, __MODULE__, :agent)
    awaitable = Awaitable.open_policy(:confirm, effect)

    assert {:error, {:invalid_lifecycle_run_id, :effect, ""}} =
             StateCodec.encode(%State{pending_effects: [%{effect | run_id: ""}]})

    assert {:error, {:invalid_lifecycle_run_id, :awaitable, ""}} =
             StateCodec.encode(%State{awaitables: [%{awaitable | run_id: ""}]})
  end

  test "Instance default lifecycle APIs remain fenced" do
    subject = Subject.new("portable-failure-instance-#{System.unique_integer([:positive])}")

    instance =
      start_supervised!({Instance, agent: Agent, subject: subject, idle: false})

    candidate_ref = "candidate:sha256:" <> String.duplicate("a", 64)

    assert {:error, :expected_activation_generation_required} =
             Instance.activate(instance, candidate_ref)

    assert {:error, :expected_activation_generation_required} =
             Instance.rollback(instance, candidate_ref)

    assert {:ok, lifecycle} = Instance.drain_definition(instance)
    assert lifecycle.admission == :draining

    assert {:ok, revoked} = Instance.revoke_definition(instance)
    assert revoked.authority == :revoked

    assert {:error, {:invalid_definition_lifecycle_transition, :future, :invalid}} =
             Instance.transition_definition_lifecycle(instance, :active, :future, :invalid)
  end

  test "State compatibility helpers preserve ownership and fail closed on stale effects" do
    first = Effect.stage_action(%{name: :first}, __MODULE__, :agent)
    second = Effect.stage_action(%{name: :second}, __MODULE__, :agent)
    awaitable = Awaitable.open_policy(:confirm, first)

    state = %State{
      pending_effects: [first, second],
      planned_effects: [first, second],
      awaitables: [awaitable, %{awaitable | id: "other", subject_id: second.id}]
    }

    claimed = State.claim_run_lifecycle(state, "run:coverage")
    assert Enum.map(claimed.pending_effects, & &1.run_id) == ["run:coverage", nil]
    assert Enum.map(claimed.planned_effects, & &1.run_id) == ["run:coverage", nil]
    assert Enum.map(claimed.awaitables, & &1.run_id) == ["run:coverage", nil]

    cancelled = State.cancel_pending(claimed, "run:coverage")
    refute Enum.any?(cancelled.pending_effects, &(&1.run_id == "run:coverage"))

    completed = %{first | status: :completed}
    stale = %State{pending_effects: [completed], planned_effects: [completed]}
    assert {^stale, nil} = State.complete_pending_effect(stale, :duplicate)

    assert %State{awaitables: [^awaitable]} =
             State.new(%{pending_effects: [], awaitables: [awaitable]})

    assert %State{} = State.new(%Input{text: "foreign struct"})
  end

  defp event_attrs do
    %{
      event_class: :input,
      id: "event:coverage",
      correlation_id: "correlation:coverage",
      payload_schema_ref: "spectre.test/input/1",
      payload: %{},
      emitted_at: 0
    }
  end
end
