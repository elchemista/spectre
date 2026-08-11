defmodule SpectreReflectiveExecutionContractTest.Operations do
  @moduledoc false

  def echo(input, _context), do: {:ok, input}
  def predicate(_input, _context), do: {:ok, true}
end

defmodule SpectreReflectiveExecutionContractTest.BindingAgent do
  @moduledoc false

  use Spectre.Agent, id: :reflective_execution_binding_agent

  alias SpectreReflectiveExecutionContractTest.Operations

  operation(:echo, {Operations, :echo}, input: :any, output: :any, side_effect: :none)
  operation(:infer, :inference, kind: :cognitive, input: :any, output: :any, side_effect: :none)

  operation(:predicate, {Operations, :predicate},
    input: :any,
    output: :boolean,
    side_effect: :none
  )

  operation(:wrong_predicate, {Operations, :echo},
    input: :any,
    output: :map,
    side_effect: :none
  )

  operation(:impure_predicate, {Operations, :predicate},
    input: :any,
    output: :boolean,
    side_effect: :idempotent
  )

  operation(:impure_migration, {Operations, :echo},
    input: :map,
    output: :map,
    side_effect: :idempotent
  )
end

defmodule SpectreReflectiveExecutionContractTest.NoProgram do
  @moduledoc false
end

defmodule SpectreReflectiveExecutionContractTest.RaisingProgram do
  @moduledoc false
  def __spectre_execution_program__, do: raise("program unavailable")
end

defmodule SpectreReflectiveExecutionContractTest.ThrowingProgram do
  @moduledoc false
  def __spectre_execution_program__, do: throw(:program_unavailable)
end

defmodule SpectreReflectiveExecutionContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Execution.Controller
  alias Spectre.Execution.Program
  alias Spectre.Operation.Result
  alias Spectre.Operation.Update
  alias Spectre.Prompt.Plan
  alias SpectreReflectiveExecutionContractTest.BindingAgent
  alias SpectreReflectiveExecutionContractTest.NoProgram
  alias SpectreReflectiveExecutionContractTest.RaisingProgram
  alias SpectreReflectiveExecutionContractTest.ThrowingProgram

  test "a closed execution graph survives JSON and exposes only registered dependencies" do
    attrs = full_program_attrs()
    assert {:ok, program} = Program.new(Map.to_list(attrs))
    assert {:ok, ^program} = Program.new(program)

    assert program.id == "reflective_work"
    assert program.operation_refs == ["echo", "infer", "predicate"]
    assert program.prompt_refs == ["support_prompt"]
    assert Program.profile_refs(program) == ["deep"]
    assert Program.uses_inference?(program)
    assert :ok = Program.validate_profile_pinning(program)
    assert :ok = Program.validate_bindings(program, BindingAgent)
    assert :ok = Program.validate_state(program, %{"request" => "refund"})
    assert {:error, _} = Program.validate_state(program, [])

    assert {:ok, repeat} = Program.fetch_node(program, :repeat)
    assert repeat.max_iterations == 2
    assert {:error, {:unknown_execution_node, "missing"}} = Program.fetch_node(program, :missing)

    definition = Program.operation_definition(program)
    assert definition.id == "reflective_work"
    assert definition.metadata.execution_program_digest == program.digest
    assert definition.branches[Program.migration_branch()] == ["echo"]

    data = Program.to_data(program)
    transported = data |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = Program.from_data(transported)
    assert restored == program

    assert {:error, {:execution_program_digest_mismatch, "forged", _actual}} =
             data |> Map.put(:digest, "forged") |> Program.from_data()

    no_profile =
      attrs
      |> update_in([:nodes], fn nodes ->
        Enum.map(nodes, fn
          %{kind: :infer} = node -> Map.delete(node, :profile_ref)
          node -> node
        end)
      end)
      |> Program.new!()

    assert {:error, {:execution_inference_profile_required, "infer"}} =
             Program.validate_profile_pinning(no_profile)

    refute Program.uses_inference?(Program.new!(terminal_program_attrs()))
    assert Program.profile_refs(Program.new!(terminal_program_attrs())) == []
  end

  test "compiled program loading contains missing modules, callbacks, raises and throws" do
    assert {:error, {:execution_program_module_not_loaded, _}} =
             Program.from_compiled(SpectreReflectiveExecutionContractTest.NotLoaded)

    assert {:error, {:execution_program_export_missing, NoProgram}} =
             Program.from_compiled(NoProgram)

    assert {:error, {:execution_program_load_exception, RaisingProgram, RuntimeError}} =
             Program.from_compiled(RaisingProgram)

    assert {:error,
            {:execution_program_load_failure, ThrowingProgram, :throw, :program_unavailable}} =
             Program.from_compiled(ThrowingProgram)

    assert {:error, {:invalid_execution_program_module, "module"}} =
             Program.from_compiled("module")

    assert_raise ArgumentError, ~r/invalid execution program/, fn ->
      Program.new!(%{id: :missing_nodes})
    end
  end

  test "execution graph validation rejects malformed, unreachable and unbounded programs" do
    base = terminal_program_attrs()

    invalid_programs = [
      {[:not_keyword], {:invalid_execution_program, :list}},
      {{:program}, {:invalid_execution_program, :tuple}},
      {Map.put(base, :unknown, true), {:unknown_execution_program_fields, [:unknown]}},
      {Map.put(base, "id", "duplicate"), {:ambiguous_execution_program_field, :program, :id}},
      {Map.put(base, :schema_version, 2), {:unsupported_execution_program_schema, 2}},
      {Map.put(base, :id, nil), {:invalid_execution_name, :execution_program_id, nil}},
      {Map.put(base, :id, __MODULE__),
       {:execution_code_reference_forbidden, :execution_program_id}},
      {Map.put(base, :version, 0), {:invalid_execution_program_version, 0}},
      {Map.put(base, :input, "record"), {:invalid_execution_validator, :input, "record"}},
      {Map.put(base, :state, 1), {:invalid_execution_validator, :state, 1}},
      {Map.put(base, :update, :record), {:invalid_execution_validator, :update, :record}},
      {Map.put(base, :nodes, []), {:invalid_execution_nodes, :list}},
      {Map.put(base, :nodes, %{}), {:invalid_execution_nodes, :list}},
      {Map.put(base, :nodes, :nodes), {:invalid_execution_nodes, :atom}},
      {Map.put(base, :entry, :missing), {:unknown_execution_entry, "missing"}},
      {Map.put(base, :budget, nil), :execution_program_requires_budget},
      {Map.put(base, :budget, %{steps: 0, attempts: 1}), :execution_program_requires_step_limit},
      {Map.put(base, :budget, %{steps: 1, attempts: 0}),
       :execution_program_requires_attempt_limit},
      {Map.put(base, :budget, %{"steps" => 1, steps: 1, attempts: 1}),
       {:ambiguous_execution_program_field, :budget, :steps}},
      {Map.put(base, :security, %{allow: true}), :execution_program_security_is_host_owned},
      {Map.put(base, :security, []), {:invalid_execution_program_field, :security, :list}},
      {Map.put(base, :metadata, []), {:invalid_execution_program_field, :metadata, :list}},
      {Map.put(base, :mutable_paths, :all), {:invalid_execution_mutable_paths, :atom}},
      {Map.put(base, :mutable_paths, [[]]),
       {:invalid_execution_mutable_path, 0, :execution_path_cannot_be_empty}},
      {Map.put(base, :migrations, :none), {:invalid_execution_migrations, :atom}},
      {Map.put(base, :migrations, [:bad]),
       {:invalid_execution_migration, 0, {:invalid_execution_migration_shape, :atom}}}
    ]

    Enum.each(invalid_programs, fn {attrs, reason} ->
      assert {:error, ^reason} = Program.new(attrs)
    end)

    duplicate_nodes =
      Map.put(base, :nodes, [
        %{id: :done, kind: :complete},
        %{"id" => "done", "kind" => "complete"}
      ])

    assert {:error, {:duplicate_execution_node, "done"}} = Program.new(duplicate_nodes)

    invalid_nodes = [
      {:not_a_node, {:invalid_execution_node_shape, :atom}},
      {%{id: :done, kind: :unknown}, {:invalid_execution_enum, :execution_node_kind, :unknown}},
      {%{id: __MODULE__, kind: :complete},
       {:execution_code_reference_forbidden, :execution_node_id}},
      {%{id: :done, kind: :complete, extra: true}, {:unknown_execution_node_fields, [:extra]}},
      {%{id: :step, kind: :step, operation: :echo, operation_ref: :echo, next: :done},
       {:duplicate_execution_name, :operation_ref, :operation}},
      {%{id: :step, kind: :step, next: :done}, {:invalid_execution_name, :operation_ref, nil}},
      {%{id: :repeat, kind: :repeat, body: :done, next: :done, max_iterations: 0},
       {:invalid_execution_positive_integer, :max_iterations, 0}}
    ]

    Enum.each(invalid_nodes, fn {node, reason} ->
      assert {:error, {:invalid_execution_node, 0, ^reason}} =
               Program.new(Map.put(base, :nodes, [node]))
    end)

    unknown_target =
      Map.merge(base, %{
        entry: :step,
        nodes: [%{id: :step, kind: :step, operation: :echo, next: :missing}]
      })

    assert {:error, {:unknown_execution_node_target, "step", "missing"}} =
             Program.new(unknown_target)

    unreachable =
      Map.put(base, :nodes, [
        %{id: :done, kind: :complete},
        %{id: :orphan, kind: :fail, reason: :unused}
      ])

    assert {:error, {:unreachable_execution_node, "orphan"}} = Program.new(unreachable)

    cycle =
      Map.merge(base, %{
        entry: :first,
        nodes: [
          %{id: :first, kind: :step, operation: :echo, next: :second},
          %{id: :second, kind: :step, operation: :echo, next: :first}
        ]
      })

    assert {:error, {:unbounded_execution_cycle, _ids}} = Program.new(cycle)

    repeat_cycle =
      Map.merge(base, %{
        entry: :first,
        nodes: [
          %{id: :first, kind: :repeat, body: :second, next: :done, max_iterations: 1},
          %{id: :second, kind: :repeat, body: :first, next: :done, max_iterations: 1},
          %{id: :done, kind: :complete}
        ]
      })

    assert {:error, {:execution_repeat_control_cycle, _ids}} = Program.new(repeat_cycle)

    repeat_over_budget =
      Map.merge(base, %{
        entry: :repeat,
        budget: %{steps: 1, attempts: 1},
        nodes: [
          %{id: :repeat, kind: :repeat, body: :done, next: :done, max_iterations: 2},
          %{id: :done, kind: :complete}
        ]
      })

    assert {:error, {:execution_repeat_exceeds_budget, "repeat", 2, 1}} =
             Program.new(repeat_over_budget)
  end

  test "inference constraints, migrations and prompt plans stay sealed and transport-stable" do
    base = full_program_attrs()

    assert {:error,
            {:invalid_execution_node, 1, {:invalid_execution_inference_constraints, :list}}} =
             base
             |> update_in([:nodes], &replace_infer(&1, %{constraints: []}))
             |> Program.new()

    assert {:error,
            {:invalid_execution_node, 1,
             {:invalid_execution_inference_constraint, :risk, "catastrophic"}}} =
             base
             |> update_in(
               [:nodes],
               &replace_infer(&1, %{constraints: %{risk: "catastrophic"}})
             )
             |> Program.new()

    assert {:error, {:invalid_execution_node, 1, {:invalid_execution_inference_level, 42}}} =
             base
             |> update_in(
               [:nodes],
               &replace_infer(&1, %{constraints: %{minimum_level: 42}})
             )
             |> Program.new()

    assert {:error,
            {:invalid_execution_node, 1, {:conflicting_execution_inference_profile, :fast, :deep}}} =
             base
             |> update_in(
               [:nodes],
               &replace_infer(&1, %{
                 profile_ref: :deep,
                 constraints: %{preferred_level: :fast}
               })
             )
             |> Program.new()

    assert {:error, {:duplicate_execution_migration, 1}} =
             base
             |> Map.put(:migrations, [
               %{from: 1, operation: :echo},
               %{from: 1, operation: :echo}
             ])
             |> Program.new()

    assert {:error,
            {:invalid_execution_migration, 0, {:execution_migration_target_mismatch, 3, 2}}} =
             base
             |> Map.put(:migrations, [%{from: 1, to: 3, operation: :echo}])
             |> Program.new()

    assert {:error,
            {:invalid_execution_migration, 0, {:unknown_execution_migration_fields, [:extra]}}} =
             base
             |> Map.put(:migrations, [%{from: 1, operation: :echo, extra: true}])
             |> Program.new()

    program = Program.new!(base)
    {:ok, plan} = Plan.compose("support evidence", [], [])

    assert {:ok, %{"support_prompt" => ^plan}} =
             Program.normalize_plans(program, %{support_prompt: plan})

    assert {:error, :execution_prompt_plan_set_mismatch} =
             Program.normalize_plans(program, %{})

    assert {:error, :duplicate_execution_prompt_plan_ref} =
             Program.normalize_plans(program, %{"support_prompt" => plan, support_prompt: plan})

    assert {:error, :invalid_execution_prompt_plan} =
             Program.normalize_plans(program, %{support_prompt: %{rendered: "not a plan"}})

    assert {:error, {:invalid_execution_prompt_plans, :list}} =
             Program.normalize_plans(program, [])

    assert {:error, {:execution_code_reference_forbidden, :execution_prompt_ref}} =
             Program.normalize_plans(program, %{__MODULE__ => plan})
  end

  test "operation binding verification rejects code-kind, purity and schema mismatches" do
    assert {:error, {:invalid_execution_program_agent, "agent"}} =
             Program.validate_bindings(Program.new!(terminal_program_attrs()), "agent")

    infer_wrong =
      Program.new!(
        single_node_program(:infer,
          operation: :echo,
          prompt: :prompt,
          profile_ref: :deep,
          next: :done
        )
      )

    assert {:error, {:execution_infer_requires_cognitive_operation, "node", :echo, :function}} =
             Program.validate_bindings(infer_wrong, BindingAgent)

    decide_impure =
      Program.new!(decision_program_attrs(:impure_predicate))

    assert {:error, {:execution_predicate_must_be_pure, "node", :impure_predicate, :idempotent}} =
             Program.validate_bindings(decide_impure, BindingAgent)

    decide_wrong = Program.new!(decision_program_attrs(:wrong_predicate))

    assert {:error, {:execution_predicate_must_return_boolean, "node", :wrong_predicate}} =
             Program.validate_bindings(decide_wrong, BindingAgent)

    missing =
      Program.new!(single_node_program(:step, operation: :missing, next: :done))

    assert {:error, {:execution_operation_unavailable, "node", _reason}} =
             Program.validate_bindings(missing, BindingAgent)

    impure_migration =
      terminal_program_attrs()
      |> Map.put(:version, 2)
      |> Map.put(:migrations, [%{from: 1, operation: :impure_migration}])
      |> Program.new!()

    assert {:error, {:execution_migration_must_be_pure, "impure_migration", :idempotent}} =
             Program.validate_bindings(impure_migration, BindingAgent)

    missing_migration =
      terminal_program_attrs()
      |> Map.put(:version, 2)
      |> Map.put(:migrations, [%{from: 1, operation: :missing}])
      |> Program.new!()

    assert {:error, {:execution_migration_unavailable, 1, _reason}} =
             Program.validate_bindings(missing_migration, BindingAgent)
  end

  test "the data-driven controller executes every node kind and keeps requests pinned" do
    program = Program.new!(full_program_attrs())
    context = execution_context(program)

    definition = Controller.__spectre_loop_definition__()
    assert definition.kind == :work
    assert Controller.program_key() == :spectre_execution_program
    assert Controller.plans_key() == :spectre_execution_plans
    assert Controller.materialization_key() == :spectre_execution_materialization_digest
    assert Controller.migration_key() == :spectre_execution_migration
    assert Controller.checkpoint_compatible?(program.digest, program.digest)
    refute Controller.checkpoint_compatible?(program.digest, "changed")

    assert {:ok, state0} = Controller.init(%{"request" => "refund"}, context)
    assert state0.pc == "step"
    assert :continue = Controller.complete(state0, context)

    assert {:run, step_request} = Controller.next(state0, context)
    assert step_request.operation == "echo"
    assert step_request.input == %{"request" => "refund"}

    forged_program_request =
      put_in(step_request.metadata.execution_program_digest, String.duplicate("0", 64))

    assert {:error, :execution_request_program_mismatch} =
             Controller.apply_result(state0, forged_program_request, result(:ignored), context)

    forged_state_request = put_in(step_request.metadata.execution_origin_pc, "infer")

    assert {:error, :execution_request_state_mismatch} =
             Controller.apply_result(state0, forged_state_request, result(:ignored), context)

    assert {:ok, state1} =
             Controller.apply_result(state0, step_request, result(%{"echoed" => true}), context)

    assert state1.pc == "infer"
    assert length(state1.history) == 1

    assert {:run, infer_request} = Controller.next(state1, context)
    assert infer_request.operation == "infer"
    assert infer_request.input.plan.rendered == "support evidence"
    assert infer_request.input.constraints.preferred_level == :deep

    assert {:ok, state2} =
             Controller.apply_result(state1, infer_request, result("refund accepted"), context)

    assert state2.data["answer"] == "refund accepted"
    assert state2.pc == "decide"

    assert {:run, decision_request} = Controller.next(state2, context)
    assert decision_request.operation == "predicate"

    assert {:error, {:execution_predicate_returned_non_boolean, "decide", :map}} =
             Controller.apply_result(state2, decision_request, result(%{}), context)

    invalid_counts_request =
      put_in(decision_request.metadata.execution_repeat_counts, [:not, :a, :map])

    assert {:error, {:invalid_execution_request_repeat_counts, :list}} =
             Controller.apply_result(state2, invalid_counts_request, result(true), context)

    assert {:ok, repeating} =
             Controller.apply_result(
               state2,
               decision_request,
               result(true, %{trace: "predicate"}),
               context
             )

    assert repeating.pc == "repeat"
    assert {:run, repeated_step} = Controller.next(repeating, context)
    assert repeated_step.metadata.execution_repeat_counts == %{"repeat" => 1}

    assert {:ok, failed} =
             Controller.apply_result(state2, decision_request, result(false), context)

    assert failed.pc == "failed"
    assert {:error, %{"code" => "rejected"}} = Controller.next(failed, context)
    assert {:error, %{"code" => "rejected"}} = Controller.complete(failed, context)

    terminal = Program.new!(terminal_program_attrs())
    terminal_context = execution_context(terminal)
    assert {:ok, terminal_state} = Controller.init(%{"done" => true}, terminal_context)
    assert {:complete, %{"done" => true}} = Controller.next(terminal_state, terminal_context)
    assert {:complete, %{"done" => true}} = Controller.complete(terminal_state, terminal_context)
  end

  test "controller rejects drifted state, missing plans and nonportable updates" do
    program = Program.new!(full_program_attrs())
    context = execution_context(program)
    assert {:ok, state} = Controller.init(%{"request" => "refund"}, context)

    assert {:error, {:execution_program_missing_from_context, :atom}} =
             Controller.init(%{}, %{execution_program: nil})

    assert {:error, :execution_prompt_plan_set_mismatch} =
             Controller.init(%{}, %{execution_program: program, execution_plans: %{}})

    assert {:error, {:unsupported_execution_state_schema, 2}} =
             Controller.next(%{state | schema_version: 2}, context)

    assert {:error, :execution_state_program_mismatch} =
             Controller.next(%{state | program_digest: String.duplicate("0", 64)}, context)

    assert {:error, :invalid_execution_state_pc} = Controller.next(%{state | pc: nil}, context)

    assert {:error, :invalid_execution_repeat_counts} =
             Controller.next(%{state | repeat_counts: []}, context)

    assert {:error, :invalid_execution_history} =
             Controller.next(%{state | history: %{}}, context)

    assert {:error, {:invalid_execution_state, :tuple}} = Controller.next({:state}, context)

    assert {:error, {:execution_count_for_non_repeat, "step"}} =
             Controller.next(%{state | repeat_counts: %{"step" => 1}}, context)

    assert {:error, {:execution_count_for_unknown_repeat, "missing"}} =
             Controller.next(%{state | repeat_counts: %{"missing" => 1}}, context)

    assert {:error, :execution_history_limit_exceeded} =
             Controller.next(%{state | history: List.duplicate(%{}, 129)}, context)

    update =
      Update.new(%{changes: [%{path: ["profile"], value: "strict"}]},
        id: "update-1",
        correlation_id: "correlation-1",
        provenance: %{source: :operator},
        requested_at: 1
      )

    assert {:ok, updated, %{"request" => "refund"}} =
             Controller.apply_update(state, %{"request" => "refund"}, update, context)

    assert updated.data["profile"] == "strict"

    invalid_updates = [
      {42, {:invalid_execution_update, :other}},
      {%{unknown: []}, :execution_update_contains_unknown_fields},
      {%{"changes" => [], changes: []}, :duplicate_execution_update_changes_field},
      {%{changes: %{}}, {:invalid_execution_update_changes, :map}},
      {%{changes: [:bad]},
       {:invalid_execution_update_change, 0, {:invalid_execution_update_change, :atom}}},
      {%{changes: [%{path: ["profile"]}]},
       {:invalid_execution_update_change, 0, :execution_update_change_requires_value}},
      {%{changes: [%{path: ["private"], value: true}]},
       {:execution_update_path_not_mutable, ["private"]}},
      {%{changes: [%{path: ["profile"], value: 1}, %{path: ["profile"], value: 2}]},
       :duplicate_execution_update_path}
    ]

    Enum.each(invalid_updates, fn {payload, reason} ->
      assert {:error, ^reason} =
               Controller.apply_update(
                 state,
                 %{"request" => "refund"},
                 %{update | payload: payload},
                 context
               )
    end)
  end

  defp full_program_attrs do
    %{
      id: :reflective_work,
      version: 2,
      entry: :step,
      input: :map,
      state: :map,
      update: :map,
      initial: :input,
      budget: %{steps: 12, attempts: 12, pages: 2},
      mutable_paths: [[:profile], ["answer"]],
      migrations: [%{from: 1, operation: :echo}],
      metadata: %{purpose: :learning},
      nodes: [
        %{id: :step, kind: :step, operation: :echo, input: :state, next: :infer},
        %{
          id: :infer,
          kind: :infer,
          operation: :infer,
          prompt: :support_prompt,
          profile_ref: :deep,
          constraints: %{
            risk: :medium,
            privacy: :private_cloud_only,
            maximum_cost_tier: :medium,
            maximum_output_tokens: 256
          },
          save_as: ["answer"],
          next: :decide
        },
        %{
          id: :decide,
          kind: :decide,
          predicate: :predicate,
          input: :state,
          on_true: :repeat,
          on_false: :failed
        },
        %{id: :repeat, kind: :repeat, body: :step, next: :done, max_iterations: 2},
        %{id: :failed, kind: :fail, reason: %{code: :rejected}},
        %{id: :done, kind: :complete, output: :state}
      ]
    }
  end

  defp execution_context(program) do
    {:ok, plan} = Plan.compose("support evidence", [], [])

    %{
      execution_program: program,
      execution_plans: Map.new(program.prompt_refs, &{&1, plan}),
      execution_materialization_digest: String.duplicate("a", 64),
      input: %{"request" => "refund"},
      last_result: result("previous"),
      loop_id: "controller-loop",
      loop_revision: 0
    }
  end

  defp result(value, receipt \\ nil) do
    %Result{
      id: "result",
      attempt_id: "attempt",
      loop_id: "controller-loop",
      operation: "echo",
      epoch: "epoch",
      fencing_token: "fence",
      context_revision: 0,
      control_generation: 0,
      trigger_generation: 0,
      status: :ok,
      value: value,
      error: nil,
      receipt: receipt,
      usage: %{},
      finished_at: 10,
      artifacts: [],
      metadata: %{}
    }
  end

  defp terminal_program_attrs do
    %{
      id: :terminal_work,
      version: 1,
      entry: :done,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 2, attempts: 2},
      nodes: [%{id: :done, kind: :complete, output: :state}]
    }
  end

  defp single_node_program(kind, attrs) do
    node = attrs |> Map.new() |> Map.merge(%{id: :node, kind: kind})

    terminal_program_attrs()
    |> Map.put(:entry, :node)
    |> Map.put(:nodes, [node, %{id: :done, kind: :complete}])
  end

  defp decision_program_attrs(predicate) do
    terminal_program_attrs()
    |> Map.put(:entry, :node)
    |> Map.put(:nodes, [
      %{
        id: :node,
        kind: :decide,
        predicate: predicate,
        on_true: :done,
        on_false: :failed
      },
      %{id: :failed, kind: :fail, reason: :failed},
      %{id: :done, kind: :complete}
    ])
  end

  defp replace_infer(nodes, changes) do
    Enum.map(nodes, fn
      %{kind: :infer} = node -> Map.merge(node, changes)
      node -> node
    end)
  end
end
