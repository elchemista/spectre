defmodule SpectreDataDrivenExecutionTest.Operations do
  @moduledoc false

  def echo(input, _context), do: {:ok, input}

  def continue?(input, _context) when is_map(input) do
    {:ok, Map.get(input, :continue, Map.get(input, "continue", false))}
  end

  def allow_prompt(_input, _context), do: {:ok, true}
  def deny_prompt(_input, _context), do: {:ok, false}
  def invalid_prompt(_input, _context), do: {:ok, %{not: :boolean}}

  def migrate(%{state: state}, _context), do: {:ok, Map.put(state, "schema", 2)}
  def external(_input, _context), do: raise("rehearsal dispatched a real Effect")
end

defmodule SpectreDataDrivenExecutionTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :data_driven_execution_host

  alias SpectreDataDrivenExecutionTest.Operations

  operation(:echo, {Operations, :echo}, input: :map, output: :map, side_effect: :none)

  operation(:retry_echo, {Operations, :echo},
    input: :map,
    output: :map,
    side_effect: :none,
    retry: %{max_attempts: 2, base_delay_ms: 0, max_delay_ms: 0}
  )

  operation(:continue, {Operations, :continue?},
    input: :map,
    output: :boolean,
    domain: [true, false],
    side_effect: :none
  )

  operation(:infer, :inference,
    kind: :cognitive,
    input: :any,
    output: :any,
    side_effect: :none
  )

  operation(:migrate, {Operations, :migrate}, input: :map, output: :map, side_effect: :none)

  operation(:external, {Operations, :external},
    input: :map,
    output: :map,
    side_effect: :non_idempotent
  )

  operation(:prompt_allow, {Operations, :allow_prompt},
    input: :map,
    output: :boolean,
    side_effect: :none
  )

  operation(:prompt_deny, {Operations, :deny_prompt},
    input: :map,
    output: :boolean,
    side_effect: :none
  )

  operation(:prompt_invalid, {Operations, :invalid_prompt},
    input: :map,
    output: :boolean,
    side_effect: :none
  )

  operation(:prompt_impure, {Operations, :allow_prompt},
    input: :map,
    output: :boolean,
    side_effect: :idempotent
  )
end

defmodule SpectreDataDrivenExecutionTest.CompiledWork do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :compiled_equivalent,
    version: 1,
    entry: :echo,
    input: :map,
    state: :map,
    initial: :input,
    budget: %{steps: 4, attempts: 4}

  step(:echo, operation: :echo, input: :state, save_as: ["echo"], next: :done)
  finish(:done, output: :state)
end

defmodule SpectreDataDrivenExecutionTest.CompiledFullWork do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :compiled_full_work,
    version: 2,
    entry: :repeat,
    input: :map,
    state: :map,
    initial: :input,
    budget: %{steps: 8, attempts: 8}

  repeat(:repeat, body: :infer, next: :done, max_iterations: 1)
  infer(:infer, operation: :infer, prompt: :prompt, save_as: ["answer"], next: :decide)

  decide(:decide,
    predicate: :continue,
    input: :state,
    on_true: :repeat,
    on_false: :failed
  )

  fail(:failed, :predicate_rejected)
  finish(:done)
  migration(1, operation: :migrate)
end

defmodule SpectreDataDrivenExecutionTest.CompiledSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :compiled_execution_skill,
    version: 1,
    prompt_budget: 64,
    applicability: %{
      scopes: [:execution],
      positive: ["compiled"],
      negative: ["do not run"]
    }

  flow :execution do
    on :run, check: {:text, "compiled"} do
      work(SpectreDataDrivenExecutionTest.CompiledWork, input: :input)
    end
  end
end

defmodule SpectreDataDrivenExecutionTest.ActivatedAgent do
  @moduledoc false

  use Spectre.Agent, id: :activated_data_driven_execution_host

  alias SpectreDataDrivenExecutionTest.Operations

  operation(:echo, {Operations, :echo}, input: :map, output: :map, side_effect: :none)

  operation(:continue, {Operations, :continue?},
    input: :map,
    output: :boolean,
    side_effect: :none
  )

  operation(:infer, :inference, kind: :cognitive, input: :any, output: :any, side_effect: :none)
  operation(:migrate, {Operations, :migrate}, input: :map, output: :map, side_effect: :none)

  skill(SpectreDataDrivenExecutionTest.CompiledSkill, as: :execution)
end

defmodule SpectreDataDrivenExecutionTest.MigrationWork do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :instance_migration_work,
    version: 2,
    entry: :done,
    input: :map,
    state: :map,
    initial: :input,
    budget: %{steps: 2, attempts: 2, pages: 1}

  finish(:done, output: :state)
  migration(1, operation: :migrate)
end

defmodule SpectreDataDrivenExecutionTest.MigrationSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :instance_migration_skill,
    version: 1,
    prompt_budget: 32,
    applicability: %{scopes: [:execution], positive: ["migrate"], negative: ["skip"]}

  flow :execution do
    on :migrate, check: {:text, "migrate"} do
      work(SpectreDataDrivenExecutionTest.MigrationWork, input: :input)
    end
  end
end

defmodule SpectreDataDrivenExecutionTest.MigrationAgent do
  @moduledoc false

  use Spectre.Agent, id: :instance_migration_agent

  alias SpectreDataDrivenExecutionTest.Operations

  operation(:migrate, {Operations, :migrate}, input: :map, output: :map, side_effect: :none)
  skill(SpectreDataDrivenExecutionTest.MigrationSkill, as: :migration)
end

defmodule SpectreDataDrivenExecutionTest.ImpureMigrationAgent do
  @moduledoc false

  use Spectre.Agent, id: :impure_migration_agent

  alias SpectreDataDrivenExecutionTest.Operations

  operation(:migrate, {Operations, :migrate},
    input: :map,
    output: :map,
    side_effect: :idempotent
  )

  skill(SpectreDataDrivenExecutionTest.MigrationSkill, as: :migration)
end

defmodule SpectreDataDrivenExecutionTest.DriftedMigrationAgent do
  @moduledoc false

  use Spectre.Agent, id: :drifted_migration_agent

  alias SpectreDataDrivenExecutionTest.Operations

  operation(:migrate, {Operations, :migrate}, input: :map, output: :any, side_effect: :none)
  skill(SpectreDataDrivenExecutionTest.MigrationSkill, as: :migration)
end

defmodule SpectreDataDrivenExecutionTest.SealedInferenceWork do
  @moduledoc false

  use Spectre.Execution.Work,
    id: :sealed_inference_work,
    version: 1,
    entry: :infer,
    input: :map,
    state: :map,
    initial: :input,
    budget: %{steps: 2, attempts: 2, pages: 1}

  infer(:infer,
    operation: :infer,
    prompt: :context,
    profile_ref: :deep,
    constraints: %{maximum_cost_tier: :medium},
    save_as: ["answer"],
    next: :done
  )

  finish(:done, output: :state)
end

defmodule SpectreDataDrivenExecutionTest.SealedInferenceSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :sealed_inference_skill,
    version: 1,
    prompt_root: "test/fixtures/canonical_prompts",
    prompt_budget: 64,
    applicability: %{
      scopes: [:execution],
      positive: ["sealed inference"],
      negative: ["skip inference"]
    }

  inject(:context,
    into: :context,
    visibility: :agent,
    priority: :low,
    budget_class: :small,
    token_cap: 64
  )

  flow :execution do
    on :infer, check: {:text, "sealed inference"} do
      work(SpectreDataDrivenExecutionTest.SealedInferenceWork, input: :input)
    end
  end
end

defmodule SpectreDataDrivenExecutionTest.SealedInferenceAgent do
  @moduledoc false

  use Spectre.Agent, id: :sealed_inference_agent

  operation(:infer, :inference, kind: :cognitive, input: :any, output: :any, side_effect: :none)
  skill(SpectreDataDrivenExecutionTest.SealedInferenceSkill, as: :inference)
end

defmodule SpectreDataDrivenExecutionTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory, as: DefinitionMemory
  alias Spectre.Execution.Admission
  alias Spectre.Execution.Closure
  alias Spectre.Execution.Controller
  alias Spectre.Execution.Expression
  alias Spectre.Execution.Handoff
  alias Spectre.Execution.Materialization
  alias Spectre.Execution.Materializer
  alias Spectre.Execution.Migration
  alias Spectre.Execution.Migration.Receipt, as: MigrationReceipt
  alias Spectre.Execution.PortableDigest
  alias Spectre.Execution.Program
  alias Spectre.Execution.Rehearsal
  alias Spectre.Execution.Rehearsal.Report
  alias Spectre.Execution.Runtime, as: ExecutionRuntime
  alias Spectre.Foundation.Conformance
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Instance
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Execution
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime, as: OperationRuntime
  alias Spectre.Operation.View
  alias Spectre.Projection
  alias Spectre.Projection.Execution, as: ExecutionProjection
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Materializer, as: PromptMaterializer
  alias Spectre.Prompt.Plan
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime, as: SkillRuntime
  alias Spectre.Skill.Runtime.Response
  alias Spectre.Subject
  alias SpectreDataDrivenExecutionTest.ActivatedAgent
  alias SpectreDataDrivenExecutionTest.Agent
  alias SpectreDataDrivenExecutionTest.CompiledFullWork
  alias SpectreDataDrivenExecutionTest.CompiledSkill
  alias SpectreDataDrivenExecutionTest.CompiledWork
  alias SpectreDataDrivenExecutionTest.DriftedMigrationAgent
  alias SpectreDataDrivenExecutionTest.ImpureMigrationAgent
  alias SpectreDataDrivenExecutionTest.MigrationAgent
  alias SpectreDataDrivenExecutionTest.MigrationSkill
  alias SpectreDataDrivenExecutionTest.Operations
  alias SpectreDataDrivenExecutionTest.SealedInferenceAgent
  alias SpectreDataDrivenExecutionTest.SealedInferenceSkill

  test "compiled and runtime Work declarations produce the exact same IR" do
    assert {:ok, compiled} = Program.from_compiled(CompiledWork)

    assert {:ok, runtime} =
             Program.new(%{
               "id" => "compiled_equivalent",
               "version" => 1,
               "entry" => "echo",
               "input" => "map",
               "state" => "map",
               "initial" => "input",
               "budget" => %{"steps" => 4, "attempts" => 4},
               "nodes" => [
                 %{
                   "id" => "echo",
                   "kind" => "step",
                   "operation_ref" => "echo",
                   "input" => "state",
                   "save_as" => ["echo"],
                   "next" => "done"
                 },
                 %{"id" => "done", "kind" => "complete", "output" => "state"}
               ]
             })

    assert Program.to_data(compiled) == Program.to_data(runtime)
    assert compiled.digest == runtime.digest
  end

  test "the compiled Work DSL lowers every closed node and migration form" do
    assert {:ok, compiled} = Program.from_compiled(CompiledFullWork)

    runtime =
      Program.new!(%{
        id: :compiled_full_work,
        version: 2,
        entry: :repeat,
        input: :map,
        state: :map,
        initial: :input,
        budget: %{steps: 8, attempts: 8},
        migrations: [%{from: 1, operation: :migrate}],
        nodes: [
          %{id: :repeat, kind: :repeat, body: :infer, next: :done, max_iterations: 1},
          %{
            id: :infer,
            kind: :infer,
            operation: :infer,
            prompt: :prompt,
            save_as: ["answer"],
            next: :decide
          },
          %{
            id: :decide,
            kind: :decide,
            predicate: :continue,
            input: :state,
            on_true: :repeat,
            on_false: :failed
          },
          %{id: :failed, kind: :fail, reason: :predicate_rejected},
          %{id: :done, kind: :complete}
        ]
      })

    assert compiled == runtime
  end

  test "inert Program identifiers do not depend on loaded Erlang module names" do
    assert {:ok, program} =
             Program.new(%{
               id: :timer,
               version: 1,
               entry: :queue,
               input: :map,
               state: :map,
               initial: :input,
               budget: %{steps: 2, attempts: 2},
               nodes: [
                 %{id: :queue, kind: :step, operation: :echo, next: :done},
                 %{id: :done, kind: :complete}
               ]
             })

    assert program.id == "timer"
    assert program.entry == "queue"
    assert Map.has_key?(program.nodes, "queue")
  end

  test "Program identity survives JSON with inference constraints and authored atoms" do
    program =
      Program.new!(%{
        id: :json_transport,
        entry: :infer,
        input: :map,
        state: :map,
        initial: {:fixed, %{status: :ready}},
        budget: %{steps: 2, attempts: 2},
        metadata: %{mode: :safe},
        nodes: [
          %{
            id: :infer,
            kind: :infer,
            operation: :infer,
            prompt: :prompt,
            constraints: %{
              minimum_level: :deep,
              preferred_level: :deep,
              risk: :medium,
              privacy: :local_only,
              maximum_cost_tier: :medium
            },
            next: :failed,
            metadata: %{source: :fixture}
          },
          %{id: :failed, kind: :fail, reason: :boom}
        ]
      })

    assert {:ok, restored} =
             program
             |> Program.to_data()
             |> Spectre.JSON.encode!()
             |> Spectre.JSON.decode!()
             |> Program.from_data()

    assert restored == program
    assert restored.digest == program.digest
  end

  test "deep runtime Work data is rejected without crashing Skill ingestion" do
    expression =
      Enum.reduce(1..200, {:fixed, "leaf"}, fn _depth, nested ->
        %{kind: :list, items: [nested]}
      end)

    program = %{
      id: :deep_work,
      entry: :done,
      initial: expression,
      budget: %{steps: 1, attempts: 1},
      nodes: [%{id: :done, kind: :complete, output: :state}]
    }

    assert {:error, {:invalid_runtime_work, 0, {:execution_expression_depth_exceeded, 48}}} =
             SkillDefinition.new(%{
               id: :deep_skill,
               publisher_ref: "host:depth-test",
               works: [program]
             })
  end

  test "a compiled Skill data Work lowers to the same route/program IR as runtime data" do
    assert {:ok, compiled} = SkillDefinition.from_compiled(CompiledSkill)
    assert [compiled_program] = SkillDefinition.works(compiled)

    assert compiled_program.digest ==
             Program.from_compiled(CompiledWork) |> elem(1) |> Map.fetch!(:digest)

    runtime =
      SkillDefinition.new!(%{
        id: :compiled_execution_skill,
        declared_version: 1,
        publisher_ref: "host:compiled-equivalence",
        applicability: %{
          scopes: [:execution],
          positive: ["compiled"],
          negative: ["do not run"]
        },
        prompt_budget: 64,
        works: [Program.to_data(compiled_program)],
        flows: [
          %{
            id: :execution,
            routes: [
              %{
                label: :run,
                match: {:text, "compiled"},
                handler: {:work, compiled_program.id, input: :input}
              }
            ]
          }
        ]
      })

    assert SkillDefinition.equivalent?(compiled, runtime)

    mounted = mounted_runtime(compiled)

    assert {:ok, materialization, _mounted} =
             Materializer.materialize(mounted, "compiled", %{scope: :execution},
               expected_revision: 1
             )

    assert materialization.program.digest == compiled_program.digest
  end

  test "a canonical Skill revalidates its exact Work and operation requirements on load" do
    definition = runtime_skill(loop_program())
    canonical = SkillDefinition.canonical(definition)

    assert {:ok, encoded} = Canonical.encode(canonical)
    assert {:ok, decoded} = Canonical.decode(encoded)
    assert {:ok, restored} = SkillDefinition.from_canonical(decoded)
    assert [program] = SkillDefinition.works(restored)
    assert program.digest == loop_program().digest

    assert MapSet.new(SkillDefinition.operation_refs(restored)) ==
             MapSet.new(["continue", "echo"])

    execution = component(decoded, :execution)

    tampered =
      rewrite_component(decoded, :execution, fn payload ->
        update_in(payload, [:programs, Access.at(0), :digest], &(&1 <> "tampered"))
      end)

    assert {:error,
            {:invalid_canonical_skill_work, 0,
             {:execution_program_digest_mismatch, _declared, _actual}}} =
             SkillDefinition.from_canonical(tampered)

    smuggled_handler =
      rewrite_component(decoded, :routing, fn payload ->
        update_in(payload, [:rules, Access.at(0), :handler], &Map.put(&1, :controller_ref, Agent))
      end)

    assert {:error, {:invalid_skill_handler, 0, :unknown_runtime_skill_handler_fields}} =
             SkillDefinition.from_canonical(smuggled_handler)

    assert execution.schema_ref == "spectre.definition.execution/1"
    assert execution.criticality == :must_understand
  end

  test "host authority caps data Work cost and duration at mount" do
    program = loop_program()
    skill = runtime_skill(program)

    authority =
      Envelope.new!(
        operations: [:echo, :continue],
        open_capabilities: [SkillRuntime.capability(:mount)],
        limits: %{max_tokens: 1_024, max_cost: 5, max_duration_ms: 4_000}
      )

    runtime =
      SkillRuntime.new!(Agent, authority,
        max_prompt_tokens: 1_024,
        kernel_prompt_tokens: 256,
        per_skill_prompt_cap: 512
      )

    assert {:error, {:execution_budget_not_authorized, "bounded_loop", :cost, 10, 5}} =
             SkillRuntime.mount(runtime, :execution, skill, expected_revision: 0)

    duration_only =
      program
      |> Program.to_data()
      |> Map.delete(:digest)
      |> put_in([:budget, :cost], 5)
      |> Program.new!()
      |> runtime_skill()

    assert {:error,
            {:execution_budget_not_authorized, "bounded_loop", :duration_ms, 5_000, 4_000}} =
             SkillRuntime.mount(runtime, :execution, duration_only, expected_revision: 0)
  end

  test "runtime inference requires an exact host-authorized profile and purpose" do
    unpinned =
      inference_program()
      |> Program.to_data()
      |> Map.delete(:digest)
      |> Map.update!(:nodes, fn nodes ->
        Enum.map(nodes, fn
          %{kind: :infer} = node -> Map.delete(node, :profile_ref)
          node -> node
        end)
      end)
      |> Program.new!()

    assert {:error, {:execution_inference_profile_required, "infer"}} =
             unpinned
             |> runtime_skill_attrs(prompt?: true, route: "infer")
             |> SkillDefinition.new()

    skill = runtime_skill(inference_program(), prompt?: true, route: "infer")

    without_purpose =
      Envelope.new!(
        operations: [:infer],
        open_capabilities: [SkillRuntime.capability(:mount)],
        prompt_budget_classes: [:small],
        model_profiles: [:deep],
        limits: %{max_tokens: 1_024}
      )

    runtime =
      SkillRuntime.new!(Agent, without_purpose,
        max_prompt_tokens: 1_024,
        kernel_prompt_tokens: 256,
        per_skill_prompt_cap: 512
      )

    assert {:error,
            {:execution_model_purpose_not_authorized, "inference_work", :data_driven_work}} =
             SkillRuntime.mount(runtime, :inference, skill, expected_revision: 0)

    without_profile = %{
      without_purpose
      | model_purposes: [:data_driven_work],
        model_profiles: []
    }

    runtime =
      SkillRuntime.new!(Agent, without_profile,
        max_prompt_tokens: 1_024,
        kernel_prompt_tokens: 256,
        per_skill_prompt_cap: 512
      )

    assert {:error, {:execution_model_profile_not_authorized, "inference_work", "deep"}} =
             SkillRuntime.mount(runtime, :inference, skill, expected_revision: 0)
  end

  test "repeat and pure predicate execute on the existing fenced runtime" do
    program = loop_program()
    env = operation_env()

    assert {:ok, loop, control, _events} =
             OperationRuntime.start_program(program, %{ignored: true}, [], env)

    assert loop.controller == Controller
    assert loop.controller_id == program.id

    {loop, control} = commit_value(loop, control, %{"round" => 1}, env)
    assert loop.state.repeat_counts == %{"repeat" => 1}

    {loop, control} = commit_value(loop, control, %{"round" => 2}, env)
    assert loop.state.repeat_counts == %{"repeat" => 2}

    {loop, control} = commit_value(loop, control, true, env)
    assert loop.status == :terminal
    assert loop.outcome.category == :completed
    assert loop.outcome.result["last"] == %{"round" => 2}
    assert length(loop.state.history) == 3
    assert control.state == :terminal
  end

  test "checkpoint recovery preserves the exact materialization, program and history" do
    program = loop_program()
    runtime = mounted_runtime(runtime_skill(program))

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "run", %{scope: :execution}, expected_revision: 1)

    env = operation_env()

    assert {:ok, loop, control, _events} =
             ExecutionRuntime.start(materialization, [metadata: %{request: "recovery"}], env)

    {checkpointed, checkpointed_control} =
      commit_value(loop, control, %{"round" => 1}, env)

    assert :ok = OperationRuntime.validate_checkpoint(checkpointed, checkpointed_control, env)

    recovered_env = %{
      env
      | epoch: "epoch:data-execution:recovered",
        snapshot_id: "snapshot:data-execution:recovered",
        now: env.now + 100
    }

    assert {:ok, recovered, recovered_control, events} =
             OperationRuntime.recover(checkpointed, checkpointed_control, recovered_env)

    assert is_list(events)
    assert recovered.state.program_digest == program.digest
    assert length(recovered.state.history) == 1
    assert recovered.metadata.request == "recovery"
    assert recovered.metadata.execution_materialization_digest == materialization.digest
    assert recovered.metadata.execution_projection_digest == materialization.projection.digest
    assert recovered.metadata.execution_definition_ref == materialization.definition_ref

    {recovered, recovered_control} =
      commit_value(recovered, recovered_control, %{"round" => 2}, recovered_env)

    {terminal, terminal_control} =
      commit_value(recovered, recovered_control, true, recovered_env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :completed
    assert length(terminal.state.history) == 3
    assert terminal_control.state == :terminal
    assert :ok = OperationRuntime.validate_checkpoint(terminal, terminal_control, recovered_env)
  end

  test "pause amend and resume preserves the pinned program and accepts only declared state paths" do
    program = loop_program()
    env = operation_env()

    assert {:ok, loop, control, _events} =
             OperationRuntime.start_program(program, %{ignored: true}, [], env)

    {loop, control} = commit_value(loop, control, %{"round" => 1}, env)
    original_metadata = loop.metadata
    original_history = loop.state.history
    original_pc = loop.state.pc
    original_counts = loop.state.repeat_counts

    pause =
      Command.new(loop.id, :pause,
        id: "execution-pause",
        correlation_id: "execution-pause"
      )

    assert {:ok, paused, paused_control, :keep_runner, [%{type: :paused}]} =
             OperationRuntime.request_control(loop, control, pause, env)

    amend =
      Command.new(loop.id, :update_and_resume,
        id: "execution-amend",
        correlation_id: "execution-amend",
        payload: %{changes: [%{path: ["continue"], value: false}]}
      )

    assert {:ok, resumed, resumed_control, :keep_runner, events} =
             OperationRuntime.request_control(paused, paused_control, amend, env)

    assert Enum.map(events, & &1.type) == [:update_applied, :resumed]
    assert resumed.status == :queued
    assert resumed_control.state == :active
    assert resumed.state.data["continue"] == false
    assert resumed.effective_input == %{ignored: true}
    assert resumed.base_input == %{ignored: true}
    assert resumed.metadata == original_metadata
    assert resumed.state.program_digest == program.digest
    assert resumed.state.history == original_history
    assert resumed.state.pc == original_pc
    assert resumed.state.repeat_counts == original_counts
    assert resumed.context_revision == 1

    invalid =
      Command.new(loop.id, :update_and_resume,
        id: "execution-invalid-amend",
        correlation_id: "execution-invalid-amend",
        payload: %{changes: [], input: %{ignored: false}}
      )

    assert {:ok, rejected, rejected_control, :keep_runner, [%{type: :control_rejected}]} =
             OperationRuntime.request_control(resumed, resumed_control, invalid, env)

    assert rejected.status == :paused
    assert rejected.state == resumed.state
    assert rejected.effective_input == resumed.effective_input
    assert rejected_control.last_command.rejection == :execution_update_contains_unknown_fields

    duplicate =
      Command.new(loop.id, :update_and_resume,
        id: "execution-duplicate-amend",
        correlation_id: "execution-duplicate-amend",
        payload: %{
          changes: [
            %{path: ["continue"], value: true},
            %{"path" => ["continue"], "value" => false}
          ]
        }
      )

    assert {:ok, still_paused, duplicate_control, :keep_runner, [%{type: :control_rejected}]} =
             OperationRuntime.request_control(rejected, rejected_control, duplicate, env)

    assert still_paused.status == :paused
    assert still_paused.state == resumed.state
    assert duplicate_control.last_command.rejection == :duplicate_execution_update_path
  end

  test "materialization pins prompt receipt, projection, model constraints and continuation" do
    program = inference_program()
    assert Program.profile_refs(program) == ["deep"]
    skill = runtime_skill(program, prompt?: true, route: "infer")
    runtime = mounted_runtime(skill)

    assert {:ok, %Materialization{} = materialization, runtime} =
             Materializer.materialize(
               runtime,
               %{text: "infer", meta: %{locale: "it"}},
               %{audience: "operator", scope: :execution},
               expected_revision: 1
             )

    assert :ok = Materialization.verify(materialization)
    assert materialization.program.digest == program.digest
    assert materialization.projection.input_evidence_digest
    assert materialization.projection.generator_id == "spectre.projection.execution"
    assert [%{digest: receipt_digest}] = materialization.projection.content.prompt_receipts
    assert [receipt] = materialization.prompt_receipts
    assert receipt.digest == receipt_digest
    assert receipt.definition_ref == materialization.definition_ref
    refute Map.has_key?(materialization.projection.content, :input)
    refute inspect(materialization.projection.content) =~ "operator"
    refute inspect(materialization.projection.content) =~ "Summarize"

    assert {:ok, pinned} =
             SkillRuntime.continuation(runtime, materialization.continuation_id)

    assert SkillDefinition.ref(pinned) == materialization.projection.definition_ref

    assert {:ok, loop, control, _events} =
             ExecutionRuntime.start(materialization, [], operation_env())

    assert {:run, _active, _attempt, _spec, request, false, _events} =
             OperationRuntime.prepare(loop, control, operation_env())

    assert %InferenceRequest{} = request.input
    assert %Plan{} = request.input.plan
    assert request.input.constraints.preferred_level == :deep
    assert request.input.metadata.required_profile_ref == "deep"
    assert request.input.metadata.explicit_model_override? == false
  end

  test "an Instance starts materialized data Work and exposes normal lifecycle/query APIs" do
    {:ok, skill} = SkillDefinition.from_compiled(CompiledSkill)
    [program] = SkillDefinition.works(skill)
    runtime = mounted_runtime(skill, ActivatedAgent)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "compiled", %{scope: :execution},
               expected_revision: 1
             )

    instance = start_activated_instance(ActivatedAgent)

    assert {:ok, ref, %View{status: :queued}} =
             Spectre.start_execution(instance, materialization, id: "data-work")

    assert {:ok, %View{} = view} = eventually_loop(instance, ref.id)
    assert view.status == :terminal
    assert view.terminal_category == :completed
    assert view.attempts == 1
    assert view.definition == program.id

    assert {:error, :loop_terminal} = Spectre.pause_loop(instance, ref)
  end

  test "an Instance rejects Work outside its active Definition and admits the exact sealed mount" do
    {:ok, skill} = SkillDefinition.from_compiled(CompiledSkill)
    runtime = mounted_runtime(skill, ActivatedAgent)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "compiled", %{scope: :execution},
               expected_revision: 1
             )

    subject = Subject.new("unsealed-execution-#{System.unique_integer([:positive, :monotonic])}")
    instance = start_supervised!({Instance, agent: ActivatedAgent, subject: subject, idle: false})

    assert {:error, :execution_requires_active_definition} =
             Spectre.start_execution(instance, materialization)

    {active, store} = start_activated_instance_with_store(ActivatedAgent)
    activation = Spectre.activation(active)

    assert :ok = Admission.verify(materialization, store, activation)

    assert {:error, :execution_definition_store_not_configured} =
             Admission.verify(materialization, nil, activation)

    assert {:error, :execution_activation_manifest_mismatch} =
             Admission.verify(
               materialization,
               store,
               %{activation | manifest_digest: String.duplicate("0", 64)}
             )

    assert {:error, :execution_activation_closure_mismatch} =
             Admission.verify(
               materialization,
               store,
               %{activation | closure_digest: String.duplicate("0", 64)}
             )

    assert {:ok, _ref, %View{status: :queued}} = Spectre.start_execution(active, materialization)

    shadow_runtime = mounted_runtime(skill, ActivatedAgent, :shadow)

    assert {:ok, shadow_materialization, _runtime} =
             Materializer.materialize(shadow_runtime, "compiled", %{scope: :execution},
               expected_revision: 1
             )

    assert {:error, {:execution_skill_mount_not_active, "shadow"}} =
             Admission.verify(shadow_materialization, store, activation)

    [program] = SkillDefinition.works(skill)
    foreign_skill = runtime_skill(program, route: "compiled")
    foreign_runtime = mounted_runtime(foreign_skill, ActivatedAgent)

    assert {:ok, foreign_materialization, _runtime} =
             Materializer.materialize(foreign_runtime, "compiled", %{scope: :execution},
               expected_revision: 1
             )

    assert {:error, :execution_materialization_not_in_active_definition} =
             Admission.verify(foreign_materialization, store, activation)
  end

  test "registered migration executes through the fenced Instance runtime and emits a receipt" do
    {:ok, skill} = SkillDefinition.from_compiled(MigrationSkill)
    runtime = mounted_runtime(skill, MigrationAgent, :migration)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "migrate", %{scope: :execution},
               expected_revision: 1
             )

    instance = start_activated_instance(MigrationAgent)

    assert {:error, {:execution_migration_not_declared, 0, 2}} =
             Spectre.start_execution(instance, materialization,
               migration: [source_version: 0, state: %{"value" => 1}]
             )

    assert {:ok, ref, %View{status: :queued}} =
             Spectre.start_execution(instance, materialization,
               id: "migrated-instance-work",
               migration: [source_version: 1, state: %{"value" => 1}]
             )

    assert {:ok, %View{} = view} = eventually_loop(instance, ref.id)
    assert view.status == :terminal
    assert view.terminal_category == :completed
    assert view.attempts == 1
    assert [%{"schema" => 2, "value" => 1}] = view.partial_results
    assert digest?(view.metadata.execution_migration_receipt_digest)

    instance_state = :sys.get_state(instance)
    assert {:ok, work_section} = Sections.fetch(instance_state.canonical.sections, :work)
    loop = Map.fetch!(work_section.value, ref.id)
    assert {:ok, receipt} = MigrationReceipt.from_data(loop.state.migration.receipt)
    assert receipt.definition_ref == materialization.definition_ref
    assert receipt.materialization_digest == materialization.digest
  end

  test "migration admission rejects malformed, incomplete and unbound host options" do
    {:ok, skill} = SkillDefinition.from_compiled(MigrationSkill)
    runtime = mounted_runtime(skill, MigrationAgent, :migration)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "migrate", %{scope: :execution},
               expected_revision: 1
             )

    env = %{operation_env() | agent: MigrationAgent}

    assert {:error, :incomplete_execution_migration_options} =
             ExecutionRuntime.start(materialization, [migration: %{source_version: 1}], env)

    assert {:error, {:unknown_execution_migration_options, [:unreviewed]}} =
             ExecutionRuntime.start(
               materialization,
               [migration: %{source_version: 1, state: %{}, unreviewed: true}],
               env
             )

    assert {:error, {:unknown_execution_migration_options, ["source_version", "state"]}} =
             ExecutionRuntime.start(
               materialization,
               [migration: %{"source_version" => 1, "state" => %{}}],
               env
             )

    assert {:error, :execution_migration_agent_missing} =
             ExecutionRuntime.start(
               materialization,
               [migration: %{source_version: 1, state: %{}}],
               Map.delete(env, :agent)
             )

    assert {:error, {:invalid_execution_migration_options, :binary}} =
             ExecutionRuntime.start(materialization, [migration: "untrusted"], env)
  end

  test "migration controller recovery rejects drifted preparation and checkpoint state" do
    program = migration_program()
    source_state = %{"value" => 1}

    assert {:error, :execution_migration_owner_binding_required} =
             Migration.prepare(program, 1, source_state, Agent)

    assert {:ok, prepared} =
             Migration.prepare(program, 1, source_state, Agent, migration_owner(program))

    migration = %{
      definition_ref: prepared.definition_ref,
      materialization_digest: prepared.materialization_digest,
      source_version: prepared.source_version,
      source_state: prepared.source_state,
      prepared_digest: prepared.digest
    }

    context = %{
      agent: Agent,
      execution_definition_ref: prepared.definition_ref,
      execution_materialization_digest: prepared.materialization_digest,
      execution_program: program,
      execution_plans: %{},
      execution_migration: migration,
      input: %{},
      loop_id: "migration-recovery",
      loop_revision: 0
    }

    assert {:ok, state} = Controller.init(%{}, context)
    assert :continue = Controller.complete(state, context)
    assert {:run, request} = Controller.next(state, context)

    assert {:error, :pending_execution_migration_has_target_state} =
             Controller.next(%{state | data: %{}}, context)

    for field <- [:prepared_digest, :source_state_digest] do
      tampered = put_in(state, [:migration, field], "invalid")

      assert {:error, :invalid_execution_migration_state_digest} =
               Controller.next(tampered, context)
    end

    assert {:error, :invalid_execution_migration_state_version} =
             state
             |> put_in([:migration, :source_version], nil)
             |> Controller.next(context)

    assert {:error, :pending_execution_migration_has_receipt} =
             state
             |> put_in([:migration, :receipt], %{})
             |> Controller.next(context)

    assert {:error, {:invalid_execution_migration_state, :map}} =
             state
             |> Map.put(:migration, %{status: :unknown})
             |> Controller.next(context)

    assert {:error, {:unknown_execution_migration_state_fields, [:unreviewed]}} =
             state
             |> put_in([:migration, :unreviewed], true)
             |> Controller.next(context)

    assert {:error, :execution_migration_state_binding_mismatch} =
             state
             |> put_in([:migration, :source_state_digest], String.duplicate("0", 64))
             |> Controller.next(context)

    assert {:error, :incomplete_execution_migration_context} =
             Controller.next(
               state,
               put_in(context, [:execution_migration], Map.delete(migration, :source_state))
             )

    assert {:error, {:unknown_execution_migration_context_fields, [:unreviewed]}} =
             Controller.next(
               state,
               put_in(context, [:execution_migration, :unreviewed], true)
             )

    assert {:error, :incomplete_execution_migration_context} =
             Controller.next(
               state,
               put_in(context, [:execution_migration, :source_version], nil)
             )

    assert {:error, :execution_migration_preparation_drift} =
             Controller.next(
               state,
               put_in(
                 context,
                 [:execution_migration, :prepared_digest],
                 String.duplicate("0", 64)
               )
             )

    assert {:error, :execution_migration_owner_binding_mismatch} =
             Controller.next(
               state,
               %{
                 context
                 | execution_definition_ref:
                     to_string(Definition.manifest!(CompiledSkill).definition_ref)
               }
             )

    assert {:error, :execution_migration_owner_binding_mismatch} =
             Controller.next(
               state,
               %{context | execution_materialization_digest: String.duplicate("0", 64)}
             )

    assert {:error, {:invalid_execution_migration_context, :list}} =
             Controller.next(state, %{context | execution_migration: []})

    assert {:ok, other_prepared} =
             Migration.prepare(
               program,
               1,
               %{"value" => 2},
               Agent,
               migration_owner(program)
             )

    drifted_context = %{
      context
      | execution_migration: %{
          definition_ref: other_prepared.definition_ref,
          materialization_digest: other_prepared.materialization_digest,
          source_version: other_prepared.source_version,
          source_state: other_prepared.source_state,
          prepared_digest: other_prepared.digest
        }
    }

    assert {:error, :execution_migration_state_binding_mismatch} =
             Controller.next(state, drifted_context)

    result = migration_result(request, %{"schema" => 2, "value" => 1})
    assert :ok = Result.validate(result)

    assert {:error, :execution_migration_result_mismatch} =
             Controller.apply_result(
               state,
               %{request | id: request.id <> ":tampered"},
               result,
               context
             )

    assert {:ok, migrated, %{receipt: receipt_data}} =
             Controller.apply_result(state, request, result, context)

    assert migrated.migration.status == :complete

    assert {:complete, %{"schema" => 2, "value" => 1}} =
             Controller.next(migrated, context)

    assert {:error, :execution_migration_receipt_state_mismatch} =
             migrated
             |> Map.put(:data, %{"schema" => 2, "value" => 999})
             |> Controller.next(context)

    assert {:ok, receipt} = MigrationReceipt.from_data(receipt_data)

    forged_receipt =
      receipt
      |> Map.from_struct()
      |> Map.delete(:digest)
      |> Map.put(:program_digest, String.duplicate("0", 64))
      |> MigrationReceipt.new()
      |> then(fn {:ok, forged} -> MigrationReceipt.to_data(forged) end)

    assert {:error, :execution_migration_receipt_state_mismatch} =
             migrated
             |> put_in([:migration, :receipt], forged_receipt)
             |> Controller.next(context)

    forged_owner_receipt =
      receipt
      |> Map.from_struct()
      |> Map.delete(:digest)
      |> Map.put(:definition_ref, Definition.manifest!(CompiledSkill).definition_ref)
      |> MigrationReceipt.new()
      |> then(fn {:ok, forged} -> MigrationReceipt.to_data(forged) end)

    assert {:error, :execution_migration_receipt_state_mismatch} =
             migrated
             |> put_in([:migration, :receipt], forged_owner_receipt)
             |> Controller.next(context)

    assert {:error, {:invalid_execution_migration_receipt, :other}} =
             migrated
             |> put_in([:migration, :receipt], nil)
             |> Controller.next(context)
  end

  test "compiled Skill closure seals the Work contracts and projection generator" do
    manifest = Definition.manifest!(CompiledSkill)
    closure = manifest.execution_closure

    assert "spectre.operation:echo" in closure.contract_refs

    assert %{id: "spectre.projection.execution", version: 1} in closure.projection_generators

    assert closure.model_profile_refs == []

    agent_closure = Definition.manifest!(ActivatedAgent).execution_closure
    executor_ref = "beam:" <> Atom.to_string(Operations)

    assert Enum.any?(agent_closure.build_fingerprints, &(&1.ref == executor_ref))
  end

  test "active admission requires every sealed inference dependency and authority grant" do
    {:ok, skill} = SkillDefinition.from_compiled(SealedInferenceSkill)
    runtime = mounted_runtime(skill, SealedInferenceAgent, :inference)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "sealed inference", %{scope: :execution},
               expected_revision: 1
             )

    canonical = Definition.canonical!(SealedInferenceAgent)

    manifest =
      Definition.manifest!(SealedInferenceAgent,
        authority_requests: execution_authority(),
        authority_ceiling: execution_authority()
      )

    closure = manifest.execution_closure
    [prompt_receipt] = materialization.prompt_receipts
    prompt_plan = Map.fetch!(materialization.plans, "context")

    assert "spectre.operation:infer" in closure.contract_refs
    assert prompt_receipt.fragment_digest in closure.prompt_fragment_digests
    assert prompt_receipt.rendered_digest == Value.digest!(Plan.legacy(prompt_plan))
    assert Plan.legacy(prompt_plan) =~ ~s(<spectre-context trust="data">)
    assert closure.model_profile_refs == ["deep"]

    assert %{id: "spectre.projection.execution", version: 1} in closure.projection_generators

    {store, activation} = published_activation(canonical, manifest)
    assert :ok = Admission.verify(materialization, store, activation)

    {store, activation} =
      republished_activation(canonical, manifest, contract_refs: [])

    assert {:error, {:execution_closure_missing_contracts, ["spectre.operation:infer"]}} =
             Admission.verify(materialization, store, activation)

    {store, activation} =
      republished_activation(canonical, manifest, prompt_fragment_digests: [])

    assert {:error, {:execution_closure_missing_prompts, [missing_prompt]}} =
             Admission.verify(materialization, store, activation)

    assert missing_prompt == prompt_receipt.fragment_digest

    {store, activation} =
      republished_activation(canonical, manifest, model_profile_refs: [])

    assert {:error, {:execution_closure_missing_profiles, ["deep"]}} =
             Admission.verify(materialization, store, activation)

    generators =
      Enum.reject(closure.projection_generators, &(&1.id == "spectre.projection.execution"))

    {store, activation} =
      republished_activation(canonical, manifest, projection_generators: generators)

    assert {:error, {:execution_closure_missing_projection, {"spectre.projection.execution", 1}}} =
             Admission.verify(materialization, store, activation)

    restricted = Manifest.new!(canonical, Envelope.empty(), closure)
    {store, activation} = published_activation(canonical, restricted)

    assert {:error, {:execution_operation_not_authorized, "infer"}} =
             Admission.verify(materialization, store, activation)

    no_purpose = %{execution_authority() | model_purposes: []}
    restricted = Manifest.new!(canonical, no_purpose, closure)
    {store, activation} = published_activation(canonical, restricted)

    assert {:error,
            {:execution_model_purpose_not_authorized, "sealed_inference_work", :data_driven_work}} =
             Admission.verify(materialization, store, activation)

    no_profile = %{execution_authority() | model_profiles: []}
    restricted = Manifest.new!(canonical, no_profile, closure)
    {store, activation} = published_activation(canonical, restricted)

    assert {:error, {:execution_model_profile_not_authorized, "sealed_inference_work", "deep"}} =
             Admission.verify(materialization, store, activation)

    limited =
      execution_authority()
      |> Map.from_struct()
      |> update_in([:limits], &Map.put(&1, :max_pages, 0))
      |> Envelope.new!()

    restricted = Manifest.new!(canonical, limited, closure)
    {store, activation} = published_activation(canonical, restricted)

    assert {:error, {:execution_budget_not_authorized, "sealed_inference_work", :pages, 1, 0}} =
             Admission.verify(materialization, store, activation)
  end

  test "page usage is enforced by the shared operational runtime before the next step" do
    program =
      Program.new!(%{
        id: :page_bounded_work,
        entry: :first,
        input: :map,
        state: :map,
        initial: :input,
        budget: %{steps: 3, attempts: 3, pages: 1},
        nodes: [
          %{id: :first, kind: :step, operation: :echo, input: :state, next: :second},
          %{id: :second, kind: :step, operation: :echo, input: :state, next: :done},
          %{id: :done, kind: :complete, output: :state}
        ]
      })

    env = operation_env()

    assert {:ok, loop, control, _events} =
             OperationRuntime.start_program(program, %{"page" => 1}, [], env)

    assert {:run, active, attempt, _spec, _request, false, _events} =
             OperationRuntime.prepare(loop, control, env)

    result =
      Result.new(attempt, :ok, %{"page" => 1},
        usage: %{pages: 1},
        finished_at: env.now + 1
      )

    assert {:ok, evaluating, control, _events} =
             OperationRuntime.apply_result(active, control, result, env)

    assert {:ok, terminal, terminal_control, events} =
             OperationRuntime.evaluate(evaluating, control, env)

    assert terminal.status == :terminal
    assert terminal.outcome.category == :budget_exhausted
    assert terminal.outcome.reason == {:budget_exhausted, :pages}
    assert terminal_control.state == :terminal
    assert Enum.any?(events, &(&1.type == :budget_exhausted))
  end

  test "authored data cannot inject modules, MFA, unbounded cycles or impure predicates" do
    base = Program.to_data(loop_program())

    injected_nodes =
      Enum.map(base.nodes, fn
        %{id: "echo"} = node -> Map.put(node, :operation_ref, Agent)
        node -> node
      end)

    assert {:error,
            {:invalid_execution_node, _index,
             {:execution_code_reference_forbidden, :operation_ref}}} =
             Program.new(%{base | nodes: injected_nodes})

    assert {:error, {:unbounded_execution_cycle, _ids}} =
             Program.new(%{
               id: :cycle,
               entry: :one,
               budget: %{steps: 2, attempts: 2},
               nodes: [
                 %{id: :one, kind: :step, operation: :echo, next: :two},
                 %{id: :two, kind: :step, operation: :echo, next: :one}
               ]
             })

    assert {:error, {:execution_repeat_control_cycle, ["repeat"]}} =
             Program.new(%{
               id: :control_cycle,
               entry: :repeat,
               budget: %{steps: 2, attempts: 2},
               nodes: [
                 %{
                   id: :repeat,
                   kind: :repeat,
                   body: :repeat,
                   next: :done,
                   max_iterations: 1
                 },
                 %{id: :done, kind: :complete, output: :state}
               ]
             })

    assert {:error, :execution_program_security_is_host_owned} =
             base |> Map.put(:security, %{allow_immediate_pause: true}) |> Program.new()

    assert {:error, :execution_program_requires_step_limit} =
             base |> put_in([:budget, :steps], 1.5) |> Program.new()

    assert {:error, {:ambiguous_execution_program_field, :program, :security}} =
             base
             |> Map.put("security", %{"allow_code" => true})
             |> Program.new()

    assert {:error,
            {:invalid_execution_node, _index,
             {:ambiguous_execution_program_field, :node, :operation_ref}}} =
             base
             |> Map.update!(:nodes, fn nodes ->
               Enum.map(nodes, fn
                 %{id: "echo"} = node -> Map.put(node, "operation_ref", "other")
                 node -> node
               end)
             end)
             |> Program.new()

    assert {:error, {:ambiguous_execution_program_field, :budget, :steps}} =
             base
             |> update_in([:budget], &Map.put(&1, "steps", 99))
             |> Program.new()

    assert {:error, {:ambiguous_execution_program_field, :budget, :pages}} =
             base
             |> Map.delete(:digest)
             |> update_in([:budget], &(&1 |> Map.put(:pages, 1) |> Map.put("pages", 2)))
             |> Program.new()

    assert {:error,
            {:invalid_execution_node, _index,
             {:duplicate_execution_name, :operation_ref, :operation}}} =
             base
             |> Map.update!(:nodes, fn nodes ->
               Enum.map(nodes, fn
                 %{id: "echo"} = node -> Map.put(node, :operation, :echo)
                 node -> node
               end)
             end)
             |> Program.new()

    atom_operation =
      base
      |> Map.delete(:digest)
      |> Map.update!(:nodes, fn nodes ->
        Enum.map(nodes, fn
          %{id: "echo"} = node -> Map.put(node, :operation_ref, :os)
          node -> node
        end)
      end)
      |> Program.new!()

    string_operation =
      base
      |> Map.delete(:digest)
      |> Map.update!(:nodes, fn nodes ->
        Enum.map(nodes, fn
          %{id: "echo"} = node -> Map.put(node, :operation_ref, "os")
          node -> node
        end)
      end)
      |> Program.new!()

    assert atom_operation == string_operation
    assert Program.operation_refs(atom_operation) == ["continue", "os"]

    conflicting_profile =
      inference_program()
      |> Program.to_data()
      |> Map.update!(:nodes, fn nodes ->
        Enum.map(nodes, fn
          %{kind: :infer} = node -> Map.put(node, :profile_ref, :fast)
          node -> node
        end)
      end)

    assert {:error,
            {:invalid_execution_node, _index,
             {:conflicting_execution_inference_profile, :deep, :fast}}} =
             Program.new(conflicting_profile)

    assert {:error, :duplicate_execution_object_key} =
             Expression.normalize(%{
               kind: :object,
               fields: %{:answer => {:fixed, 1}, "answer" => {:fixed, 2}}
             })

    operations =
      Agent.__spectre_config__()
      |> Keyword.fetch!(:operations)
      |> Enum.map(fn
        %{id: :continue} = spec -> %{spec | side_effect: :idempotent}
        spec -> spec
      end)

    impure_agent =
      Module.concat(__MODULE__, "Impure#{System.unique_integer([:positive])}")

    Module.create(
      impure_agent,
      quote do
        def __spectre_config__, do: [operations: unquote(Macro.escape(operations))]
      end,
      Macro.Env.location(__ENV__)
    )

    assert {:error, {:execution_predicate_must_be_pure, "decide", :continue, :idempotent}} =
             Program.validate_bindings(loop_program(), impure_agent)
  end

  test "materialization detects modified plans, receipts and program identity" do
    runtime = mounted_runtime(runtime_skill(inference_program(), prompt?: true, route: "infer"))

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(
               runtime,
               "infer",
               %{audience: "operator", scope: :execution},
               expected_revision: 1
             )

    plan = Map.fetch!(materialization.plans, "prompt")
    changed_plan = %{plan | rendered: plan.rendered <> " injected"}

    assert {:error, :execution_materialization_prompt_plan_digest_mismatch} =
             Materialization.verify(%{
               materialization
               | plans: Map.put(materialization.plans, "prompt", changed_plan)
             })

    assert {:error, :invalid_prompt_receipt_token_estimate} =
             materialization.prompt_receipts
             |> hd()
             |> Map.update!(:bytes, &(&1 + 1))
             |> Spectre.Prompt.Receipt.to_data()
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, :prompt_receipt_digest_mismatch} =
             materialization.prompt_receipts
             |> hd()
             |> Map.put(:digest, String.duplicate("0", 64))
             |> Spectre.Prompt.Receipt.to_data()
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, {:materialization, :digest_mismatch}} =
             Materialization.verify(%{materialization | digest: String.duplicate("0", 64)})

    for changed <- [
          %{materialization | mount_id: :different_mount},
          %{materialization | route_label: :different_route},
          %{materialization | continuation_id: "different-continuation"},
          %{materialization | input: %{"different" => true}}
        ] do
      changed = %{
        changed
        | digest:
            changed
            |> Materialization.to_data()
            |> Map.delete(:digest)
            |> Value.digest!()
      }

      assert {:error, :execution_materialization_projection_mismatch} =
               Materialization.verify(changed)
    end

    assert {:error, :projection_digest_mismatch} =
             Materialization.verify(%{
               materialization
               | projection: %{materialization.projection | content: %{}}
             })

    assert {:error, {:nonportable_projection, _reason}} =
             Materialization.verify(%{
               materialization
               | projection: %{
                   materialization.projection
                   | content: %{unsafe: self()}
                 }
             })

    assert {:error, {:unknown_prompt_receipt_fields, :prompt_receipt}} =
             materialization.prompt_receipts
             |> hd()
             |> Spectre.Prompt.Receipt.to_data()
             |> Map.put(:unexpected, true)
             |> Spectre.Prompt.Receipt.from_data()

    receipt = hd(materialization.prompt_receipts)
    receipt_data = Spectre.Prompt.Receipt.to_data(receipt)

    assert {:ok, ^receipt} = Spectre.Prompt.Receipt.from_data(receipt)

    assert {:ok, json_receipt} =
             receipt_data
             |> Spectre.JSON.encode!()
             |> Spectre.JSON.decode!()
             |> Spectre.Prompt.Receipt.from_data()

    assert json_receipt.digest == receipt.digest

    assert {:error, {:unsupported_prompt_receipt_schema, 2}} =
             receipt_data
             |> Map.put(:schema_version, 2)
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, :prompt_receipt_generator_mismatch} =
             receipt_data
             |> Map.put(:generator_id, "unknown")
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, {:invalid_prompt_receipt_definition_ref, "invalid"}} =
             receipt_data
             |> Map.put(:definition_ref, "invalid")
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, :invalid_prompt_receipt_evidence_digest} =
             receipt_data
             |> Map.put(:rendered_digest, "invalid")
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, {:invalid_prompt_receipt_bytes, -1}} =
             receipt_data
             |> Map.put(:bytes, -1)
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, :invalid_prompt_receipt_placement} =
             receipt_data
             |> update_in([:placement], &Map.put(&1, :target, :unknown))
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, {:invalid_prompt_receipt_fields, :placement}} =
             receipt_data
             |> Map.put(:placement, [])
             |> Spectre.Prompt.Receipt.from_data()

    assert {:error, {:invalid_prompt_receipt, :tuple}} =
             Spectre.Prompt.Receipt.from_data({:invalid, :receipt})
  end

  test "materialization reconstructs transported evidence and rejects malformed sealed fields" do
    program = inference_program()
    skill = runtime_skill(program, prompt?: true, route: "infer")
    runtime = mounted_runtime(skill)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(
               runtime,
               "infer",
               %{audience: "operator", scope: :execution},
               expected_revision: 1
             )

    non_work = %Response{
      kind: :reply,
      mount_id: materialization.mount_id,
      definition_ref: SkillDefinition.ref(skill),
      route_label: materialization.route_label,
      work_ref: program.id,
      work_input: materialization.input,
      program_digest: program.digest,
      continuation_id: materialization.continuation_id
    }

    assert {:error, {:execution_materialization_requires_work_response, :reply}} =
             Materialization.new(
               skill,
               non_work,
               program,
               materialization.input,
               materialization.plans,
               materialization.prompt_receipts,
               materialization.projection
             )

    assert {:error, {:unsupported_execution_materialization_schema, 2}} =
             Materialization.verify(%{materialization | schema_version: 2})

    transported_receipts =
      Enum.map(materialization.prompt_receipts, &Spectre.Prompt.Receipt.to_data/1)

    assert :ok =
             Materialization.verify(%{materialization | prompt_receipts: transported_receipts})

    assert {:error,
            {:invalid_execution_materialization_receipt, 0, {:invalid_prompt_receipt, :atom}}} =
             Materialization.verify(%{materialization | prompt_receipts: [:invalid]})

    assert {:error, {:invalid_execution_materialization_receipts, :map}} =
             Materialization.verify(%{materialization | prompt_receipts: %{}})

    [prompt_ref] = program.prompt_refs
    plan = Map.fetch!(materialization.plans, prompt_ref)

    assert {:error, :duplicate_execution_materialization_prompt_plan_ref} =
             Materialization.verify(%{
               materialization
               | plans: %{prompt_ref => plan, String.to_atom(prompt_ref) => plan}
             })

    assert {:error, {:invalid_execution_materialization_plans, :list}} =
             Materialization.verify(%{materialization | plans: []})

    assert {:error, :invalid_execution_materialization_prompt_plan} =
             Materialization.verify(%{materialization | plans: %{prompt_ref => %{}}})

    malformed_plan = %{plan | rendered: :not_text}

    assert {:error, :invalid_execution_materialization_prompt_plan} =
             Materialization.verify(%{
               materialization
               | plans: %{prompt_ref => malformed_plan}
             })

    continuation_projection =
      materialization.projection
      |> Map.update!(:content, &Map.put(&1, :continuation_id, nil))
      |> redigest_projection()

    assert {:error, {:invalid_execution_continuation_id, nil}} =
             Materialization.verify(%{
               materialization
               | continuation_id: nil,
                 projection: continuation_projection
             })

    assert {:error, :execution_materialization_projection_mismatch} =
             Materialization.verify(%{materialization | mount_id: self()})

    assert {:error,
            {:invalid_operation_value, {:execution_materialization_input, _}, :map, :other}} =
             Materialization.verify(%{materialization | input: self()})

    invalid_content = redigest_projection(materialization.projection, [])

    assert {:error, :invalid_execution_materialization_projection} =
             Materialization.verify(%{materialization | projection: invalid_content})

    invalid_receipts =
      materialization.projection
      |> Map.update!(:content, &Map.put(&1, :prompt_receipts, :invalid))
      |> redigest_projection()

    assert {:error, :invalid_execution_materialization_projection_receipts} =
             Materialization.verify(%{materialization | projection: invalid_receipts})
  end

  test "execution projection, materializer and runtime boundaries fail closed" do
    program = inference_program()
    skill = runtime_skill(program, prompt?: true, route: "infer")
    runtime = mounted_runtime(skill)

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(
               runtime,
               "infer",
               %{audience: "operator", scope: :execution},
               expected_revision: 1
             )

    plan_digests =
      Map.new(materialization.plans, fn {ref, plan} -> {ref, plan.metadata.hash} end)

    projection_opts = [
      program: materialization.program,
      input: materialization.input,
      prompt_receipts: materialization.prompt_receipts,
      plan_digests: plan_digests,
      mount_id: materialization.mount_id,
      route: %{label: materialization.route_label},
      continuation_id: materialization.continuation_id
    ]

    assert {:ok, projection} =
             Projection.generate(skill.canonical, ExecutionProjection, projection_opts)

    assert projection.content.program.digest == program.digest

    response = %Response{
      kind: :work,
      mount_id: materialization.mount_id,
      definition_ref: SkillDefinition.ref(skill),
      route_label: materialization.route_label,
      work_ref: program.id,
      work_input: materialization.input,
      program_digest: program.digest,
      continuation_id: materialization.continuation_id
    }

    assert {:error, :execution_materialization_projection_evidence_missing} =
             Materialization.new(
               skill,
               response,
               program,
               materialization.input,
               materialization.plans,
               materialization.prompt_receipts,
               projection
             )

    assert {:ok, mismatched_evidence} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :evidence, %{different: true})
             )

    assert {:error, :execution_materialization_projection_evidence_mismatch} =
             Materialization.new(
               skill,
               response,
               program,
               materialization.input,
               materialization.plans,
               materialization.prompt_receipts,
               mismatched_evidence
             )

    missing_evidence = %{materialization | projection: projection}

    missing_evidence = %{
      missing_evidence
      | digest:
          missing_evidence
          |> Materialization.to_data()
          |> Map.delete(:digest)
          |> Value.digest!()
    }

    assert {:error, :execution_materialization_projection_evidence_missing} =
             Materialization.verify(missing_evidence)

    assert {:error, {:invalid_execution_projection_options, :list}} =
             ExecutionProjection.project(skill.canonical, [:not_keyword])

    assert {:error, {:invalid_execution_projection_program, :atom}} =
             Projection.generate(skill.canonical, ExecutionProjection, [])

    mismatched =
      materialization.program
      |> Program.to_data()
      |> Map.delete(:digest)
      |> Map.put(:metadata, %{changed: true})
      |> Program.new!()

    assert {:error, {:execution_projection_program_mismatch, _declared, _supplied}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :program, mismatched)
             )

    assert {:error, {:invalid_execution_projection_receipts, :atom}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :prompt_receipts, :invalid)
             )

    assert {:error, {:invalid_execution_projection_receipt, 0, {:invalid_prompt_receipt, :other}}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :prompt_receipts, [42])
             )

    assert {:error, {:execution_projection_prompt_set_mismatch, ["prompt"], []}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :prompt_receipts, [])
             )

    assert {:error, {:invalid_execution_projection_plan_digests, :list}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :plan_digests, [])
             )

    assert {:error, :execution_projection_plan_set_mismatch} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :plan_digests, %{})
             )

    digest = Map.fetch!(plan_digests, "prompt")

    assert {:error, :duplicate_execution_projection_plan_ref} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :plan_digests, %{
                 "prompt" => digest,
                 prompt: digest
               })
             )

    assert {:error, :invalid_execution_projection_plan_digest} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :plan_digests, %{"prompt" => "invalid"})
             )

    assert {:error, {:invalid_execution_projection_field, :route, :list}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :route, [])
             )

    assert {:error, {:nonportable_execution_projection_field, :route, _reason}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :route, %{unsafe: self()})
             )

    assert {:error, {:nonportable_execution_projection_field, :mount_id, _reason}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :mount_id, self())
             )

    assert {:error, {:invalid_execution_projection_continuation, nil}} =
             Projection.generate(
               skill.canonical,
               ExecutionProjection,
               Keyword.put(projection_opts, :continuation_id, nil)
             )

    assert {:error, {:invalid_execution_materialization, :atom}} =
             Materialization.verify(:invalid)

    assert {:error, {:invalid_execution_materialization, :atom}} =
             Materializer.handoff(:invalid)

    malformed_plan = %Plan{rendered: self(), metadata: %{hash: "not-a-plan-hash"}}

    assert {:error, :invalid_execution_prompt_plan} =
             Program.normalize_plans(program, %{"prompt" => malformed_plan})

    assert {:error, :invalid_execution_materialization_prompt_plan} =
             Materialization.verify(%{
               materialization
               | plans: %{"prompt" => malformed_plan}
             })

    assert {:error, {:invalid_execution_materialization_options, :list, :list}} =
             Materializer.materialize(runtime, "infer", [], [])

    assert {:error, :invalid_execution_materialization_options} =
             Materializer.materialize(runtime, "infer", %{}, [:not_keyword])

    assert {:error, {:invalid_execution_materializer, :atom, :map, :list}} =
             Materializer.materialize(:invalid, %{}, %{}, [])

    assert {:error, {:invalid_execution_runtime_start, :atom, :list, :map}} =
             ExecutionRuntime.start(:invalid)

    assert {:error, :invalid_execution_runtime_options} =
             ExecutionRuntime.start(materialization, [:not_keyword], operation_env())

    assert {:error, :invalid_execution_runtime_options} =
             ExecutionRuntime.start(materialization, [], [])

    assert {:error, {:invalid_execution_runtime_metadata, :list}} =
             ExecutionRuntime.start(materialization, [metadata: []], operation_env())

    assert {:error, {:invalid_execution_runtime_handoff, :map}} =
             ExecutionRuntime.start(materialization, [handoff: %{}], operation_env())
  end

  test "state migration resolves a pure registered operation and commits a receipt" do
    program = migration_program()
    source = %{"schema" => 1, "value" => 42}

    assert {:ok, migration} =
             Migration.prepare(program, 1, source, Agent, migration_owner(program))

    assert migration.request.operation == "migrate"
    assert migration.request.input.state == source
    assert migration.target_version == 2
    assert :ok = Migration.verify(migration)

    assert {:ok, same} =
             Migration.prepare(program, 1, source, Agent, migration_owner(program))

    assert same.digest == migration.digest
    assert same.request.id == migration.request.id

    execution =
      Execution.new(%{"schema" => 2, "value" => 42},
        receipt: %{executor: :registered_migration}
      )

    assert {:ok, migrated, %MigrationReceipt{} = receipt} =
             Migration.commit(migration, execution, Agent)

    assert migrated == %{"schema" => 2, "value" => 42}
    assert receipt.program_digest == program.digest
    assert receipt.definition_ref == migration.definition_ref
    assert receipt.materialization_digest == migration.materialization_digest
    assert receipt.source_state_digest == migration.source_state_digest
    assert {:ok, ^receipt} = receipt |> MigrationReceipt.to_data() |> MigrationReceipt.from_data()

    assert {:ok, json_receipt} =
             receipt
             |> MigrationReceipt.to_data()
             |> Spectre.JSON.encode!()
             |> Spectre.JSON.decode!()
             |> MigrationReceipt.from_data()

    assert json_receipt == receipt

    structured_execution =
      Execution.new(%{"schema" => 2, "value" => 42},
        receipt:
          Subject.new("migration-operation-receipt",
            metadata: %{tags: [:registered, :migration]}
          )
      )

    assert {:ok, _migrated, %MigrationReceipt{} = structured_receipt} =
             Migration.commit(migration, structured_execution, Agent)

    assert is_binary(structured_receipt.operation_receipt_digest)

    assert {:ok, ^structured_receipt} =
             structured_receipt
             |> MigrationReceipt.to_data()
             |> Spectre.JSON.encode!()
             |> Spectre.JSON.decode!()
             |> MigrationReceipt.from_data()

    assert {:ok, _migrated, %MigrationReceipt{operation_receipt_digest: nil}} =
             Migration.commit(
               migration,
               Execution.new(%{"schema" => 2, "value" => 42}),
               Agent
             )

    assert {:error, {:invalid_operation_value, _, :map, :list}} =
             Migration.commit(migration, Execution.new([]), Agent)

    tampered_request = %{
      migration.request
      | metadata: Map.put(migration.request.metadata, :unbound, true)
    }

    assert {:error, :execution_migration_request_metadata_mismatch} =
             Migration.verify(%{migration | request: tampered_request})
  end

  test "state migration is owner-bound, pure, contract-pinned and fail-closed" do
    program = migration_program()
    source = %{"schema" => 1, "value" => 42}
    owner = migration_owner(program)

    assert {:error, :invalid_execution_migration_options} =
             Migration.prepare(program, 1, source, Agent, [:not_keyword])

    assert {:error, {:invalid_execution_migration_agent, nil}} =
             Migration.prepare(program, 1, source, nil, owner)

    assert {:error, :invalid_execution_migration_options} =
             Migration.prepare(program, 1, source, Agent, %{})

    assert {:error, {:nonportable_execution_migration_state, _reason}} =
             Migration.prepare(program, 1, %{process: self()}, Agent, owner)

    assert {:error, {:unknown_execution_migration_options, [:unreviewed]}} =
             Migration.prepare(program, 1, source, Agent, owner ++ [unreviewed: true])

    assert {:error, :invalid_execution_migration_materialization_digest} =
             Migration.prepare(
               program,
               1,
               source,
               Agent,
               Keyword.put(owner, :materialization_digest, "invalid")
             )

    assert {:error, :execution_migration_owner_binding_required} =
             Migration.prepare(
               program,
               1,
               source,
               Agent,
               Keyword.delete(owner, :definition_ref)
             )

    assert {:error, :invalid_execution_migration_definition_ref} =
             Migration.prepare(
               program,
               1,
               source,
               Agent,
               Keyword.put(owner, :definition_ref, "invalid")
             )

    assert {:error, {:execution_migration_must_be_pure, "migrate", :idempotent}} =
             Migration.prepare(program, 1, source, ImpureMigrationAgent, owner)

    assert {:ok, migration} = Migration.prepare(program, 1, source, Agent, owner)
    assert Migration.to_data(migration).digest == migration.digest

    assert {:error, :execution_migration_operation_contract_drift} =
             Migration.commit(
               migration,
               Execution.new(%{"schema" => 2, "value" => 42}),
               DriftedMigrationAgent
             )

    assert {:error, {:invalid_execution_migration_commit, Agent}} =
             Migration.commit(migration, :not_an_execution, Agent)

    assert {:error, {:invalid_execution_migration_commit, nil}} =
             Migration.commit(migration, Execution.new(%{}), nil)

    assert {:error, :invalid_execution_migration_request} =
             Migration.verify(%{migration | request: :invalid})

    assert {:error, :execution_migration_integrity_mismatch} =
             Migration.verify(%{migration | schema_version: 2})

    assert {:error, :execution_migration_integrity_mismatch} =
             Migration.verify(%{migration | definition_ref: nil})

    assert {:error, :execution_migration_integrity_mismatch} =
             Migration.verify(%{migration | materialization_digest: nil})

    assert {:error, :execution_migration_request_operation_mismatch} =
             Migration.verify(%{migration | operation_ref: :migrate})
  end

  test "migration receipts reject incomplete, ambiguous and nonsensical durable data" do
    digest = String.duplicate("a", 64)

    attrs = %{
      migration_digest: digest,
      program_digest: digest,
      definition_ref: Definition.manifest!(MigrationSkill).definition_ref,
      materialization_digest: digest,
      operation_ref: :migrate,
      operation_contract_digest: digest,
      source_version: 1,
      target_version: "2",
      source_state_digest: digest,
      target_state_digest: digest,
      operation_receipt_digest: nil
    }

    assert {:ok, %MigrationReceipt{} = receipt} = MigrationReceipt.new(attrs)
    assert receipt.operation_ref == "migrate"
    assert {:ok, ^receipt} = MigrationReceipt.from_data(receipt)

    assert {:error, {:invalid_execution_migration_receipt, :tuple}} =
             MigrationReceipt.new({:invalid, :receipt})

    assert {:error, {:unknown_execution_migration_receipt_fields, [:unknown]}} =
             attrs |> Map.put(:unknown, true) |> MigrationReceipt.new()

    assert {:error, :invalid_execution_migration_receipt_operation} =
             attrs |> Map.put(:operation_ref, nil) |> MigrationReceipt.new()

    assert {:error, :invalid_execution_migration_receipt_definition_ref} =
             attrs |> Map.put(:definition_ref, "not-a-definition-ref") |> MigrationReceipt.new()

    assert {:error, :invalid_execution_migration_receipt_version} =
             attrs |> Map.put(:source_version, 0) |> MigrationReceipt.new()

    data = MigrationReceipt.to_data(receipt)

    assert {:error, :execution_migration_receipt_digest_mismatch} =
             data |> Map.put(:digest, digest) |> MigrationReceipt.from_data()

    assert {:error, :unknown_execution_migration_receipt_fields} =
             data |> Map.put(:unknown, true) |> MigrationReceipt.from_data()

    assert {:error, :missing_execution_migration_receipt_fields} =
             data |> Map.delete(:digest) |> MigrationReceipt.from_data()

    assert {:error, :duplicate_execution_migration_receipt_fields} =
             data |> Map.put("schema_version", 1) |> MigrationReceipt.from_data()

    assert {:error, {:unsupported_execution_migration_receipt_schema, 2}} =
             data |> Map.put(:schema_version, 2) |> MigrationReceipt.from_data()

    assert {:error, :invalid_execution_migration_receipt_digest} =
             data |> Map.put(:migration_digest, "invalid") |> MigrationReceipt.from_data()

    assert {:error, :invalid_execution_migration_operation_receipt_digest} =
             data
             |> Map.put(:operation_receipt_digest, "invalid")
             |> MigrationReceipt.from_data()

    assert {:error, {:invalid_execution_migration_receipt, :list}} =
             MigrationReceipt.from_data([])
  end

  test "Flow/Work and Work/Work exchanges use closed typed handoffs" do
    runtime = mounted_runtime(runtime_skill(loop_program()))

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(runtime, "run", %{scope: :execution}, expected_revision: 1)

    assert {:ok, flow_handoff} = Materializer.handoff(materialization)
    assert flow_handoff.source == %{kind: :flow, ref: "run"}
    assert flow_handoff.target == %{kind: :work, ref: loop_program().id}
    assert :ok = Handoff.validate_target(flow_handoff, materialization)

    assert {:ok, work_handoff} =
             Handoff.work_to_work(
               materialization.definition_ref,
               :parent_work,
               loop_program().id,
               materialization.input,
               parent_loop_id: "parent-loop"
             )

    assert :ok = Handoff.validate_target(work_handoff, materialization)

    assert {:ok, loop, _control, _events} =
             ExecutionRuntime.start(materialization, [handoff: work_handoff], operation_env())

    assert loop.metadata.execution_handoff_digest == work_handoff.digest

    assert {:ok, flow_event_handoff} =
             Handoff.work_to_flow(
               materialization.definition_ref,
               loop_program().id,
               :follow_up,
               %{result: :ready}
             )

    assert {:ok, event} = Handoff.event(flow_event_handoff)
    assert event.type == :execution_handoff
    assert event.target == %{kind: :flow, ref: "follow_up"}
    assert event.handoff_digest == flow_event_handoff.digest

    assert {:error, {:execution_handoff_code_reference_forbidden, :target}} =
             Handoff.work_to_work(
               materialization.definition_ref,
               :parent_work,
               Agent,
               materialization.input
             )
  end

  test "prompt materialization replaces only placeholders from the original template" do
    program = inference_program()
    runtime = mounted_runtime(runtime_skill(program, prompt?: true, route: "infer"))

    assert {:ok, materialization, _runtime} =
             Materializer.materialize(
               runtime,
               "infer",
               %{audience: "{{input.text}}", scope: :execution},
               expected_revision: 1
             )

    plan = Map.fetch!(materialization.plans, "prompt")
    assert plan.rendered == "Summarize infer for {{input.text}}"

    [receipt] = materialization.prompt_receipts
    assert receipt.rendered_digest == Value.digest!(plan.rendered)
  end

  test "prompt predicates are registry-bound, pure, boolean and actually control placement" do
    assert {:ok, %{"predicate_ref" => "prompt_allow"}} =
             Spectre.Prompt.Predicate.ref_data(:prompt_allow)

    assert {:ok, %{"predicate_ref" => "prompt_allow"}} =
             Spectre.Prompt.Predicate.ref_data("prompt_allow")

    assert {:error, {:invalid_prompt_predicate_ref, nil}} =
             Spectre.Prompt.Predicate.ref_data(nil)

    assert {:error, :prompt_predicate_registry_required} =
             Spectre.Prompt.Predicate.evaluate(
               %{predicate_ref: "prompt_allow"},
               Spectre.Input.new("accepted"),
               %{},
               []
             )

    assert {:error, {:invalid_prompt_predicate_ref, %{}}} =
             Spectre.Prompt.Predicate.validate_ref(Agent, %{})

    {:ok, content, placeholders} = Fragment.close_template("Input <%= @input.text %>")

    fragment =
      Fragment.canonical!(%{
        id: :conditional_prompt,
        content: content,
        scope: :execution,
        target: :context,
        position: :end,
        source: %{kind: :runtime},
        trust: :data,
        placeholders: placeholders,
        token_cap: 32,
        condition_ref: %{"predicate_ref" => "prompt_allow"}
      })

    assert {:ok, "Input accepted", evidence} =
             PromptMaterializer.render(fragment, "accepted", %{}, agent: Agent)

    assert evidence["predicate_ref"] == "prompt_allow"
    assert evidence["matched"]

    denied =
      fragment
      |> Map.from_struct()
      |> Map.put(:condition_ref, %{"predicate_ref" => "prompt_deny"})
      |> Map.put(:digest, nil)
      |> Fragment.canonical!()

    assert {:ok, "", %{"matched" => false, "predicate_ref" => "prompt_deny"}} =
             PromptMaterializer.render(denied, "must not appear", %{}, agent: Agent)

    missing =
      fragment
      |> Map.from_struct()
      |> Map.put(:condition_ref, %{"predicate_ref" => "not_registered"})
      |> Map.put(:digest, nil)
      |> Fragment.canonical!()

    assert {:error, {:operation_not_registered, "not_registered"}} =
             PromptMaterializer.render(missing, "blocked", %{}, agent: Agent)

    invalid =
      fragment
      |> Map.from_struct()
      |> Map.put(:condition_ref, %{"predicate_ref" => "prompt_invalid"})
      |> Map.put(:digest, nil)
      |> Fragment.canonical!()

    assert {:error, {:prompt_predicate_returned_non_boolean, _condition_ref}} =
             PromptMaterializer.render(invalid, "blocked", %{}, agent: Agent)

    assert {:error, {:prompt_condition_not_pure_boolean, _condition_ref}} =
             Spectre.Prompt.Predicate.validate_ref(Agent, %{
               "predicate_ref" => "prompt_impure"
             })
  end

  test "rendered prompt bytes cannot expand beyond the fragment token cap" do
    {:ok, content, placeholders} = Fragment.close_template("<%= @input.text %>")

    fragment =
      Fragment.canonical!(%{
        id: :bounded_render,
        content: content,
        scope: :execution,
        target: :context,
        position: :end,
        source: %{kind: :runtime},
        trust: :data,
        placeholders: placeholders,
        token_cap: 4
      })

    assert {:ok, "short", %{"input.text" => "short"}} =
             PromptMaterializer.render(fragment, "short", %{})

    assert {:error, {:rendered_prompt_fragment_over_budget, :bounded_render, 25, 4}} =
             PromptMaterializer.render(fragment, String.duplicate("x", 100), %{})
  end

  test "the closed inspect renderer handles portable values without opening code execution" do
    assert {:ok, content, placeholders} =
             Fragment.close_template("State: <%= inspect(@state.data) %>")

    fragment =
      Fragment.canonical!(%{
        id: :portable_state,
        content: content,
        scope: :execution,
        target: :context,
        position: :end,
        source: %{kind: :compiled_asset},
        trust: :data,
        placeholders: placeholders
      })

    assert {:ok, "State: %{count: 2}", %{"state.data" => %{count: 2}}} =
             PromptMaterializer.render(fragment, "ignored", %{state: %{data: %{count: 2}}})

    assert {:error, {:non_scalar_runtime_prompt_value, "state.data", :other}} =
             PromptMaterializer.render(fragment, "ignored", %{state: %{data: self()}})
  end

  test "execution materialization refuses a selected non-Work route" do
    skill =
      SkillDefinition.new!(%{
        id: :reply_only_execution_skill,
        declared_version: 1,
        publisher_ref: "host:data-execution-test",
        applicability: %{
          scopes: [:execution],
          positive: ["reply"],
          negative: ["do not reply"]
        },
        prompt_budget: 64,
        prompt_fragments: [
          %{id: :reply_prompt, content: "Reply {{input.text}}", token_cap: 16}
        ],
        flows: [
          %{
            id: :execution,
            routes: [
              %{
                label: :reply,
                match: {:exact, "reply"},
                handler: {:reply, :reply_prompt}
              }
            ]
          }
        ]
      })

    runtime = mounted_runtime(skill)

    assert {:error, {:runtime_skill_response_is_not_work, :reply}} =
             Materializer.materialize(
               runtime,
               "reply",
               %{scope: :execution},
               expected_revision: 1
             )
  end

  test "prompt materialization protects input evidence and rejects non-static fragments" do
    fragment =
      Fragment.canonical!(%{
        id: :protected_input,
        content: "Resolve {{input.text}} for {{audience}}",
        scope: :execution,
        target: :context,
        position: :end,
        source: %{kind: :runtime},
        trust: :data,
        placeholders: %{
          "audience" => %{
            path: ["audience"],
            renderer_ref: "spectre.renderer.text/1"
          },
          "input.text" => %{
            path: ["input", "text"],
            renderer_ref: "spectre.renderer.text/1"
          }
        }
      })

    assert {:ok, "Resolve honest for operator",
            %{"audience" => :operator, "input.text" => "honest"}} =
             PromptMaterializer.render(fragment, "honest", %{
               "input" => %{"text" => "string-spoof"},
               input: %{text: "atom-spoof"},
               audience: :operator
             })

    dynamic =
      Fragment.canonical!(%{
        id: :dynamic_context,
        content: nil,
        scope: :execution,
        target: :context,
        position: :end,
        source: %{kind: :runtime},
        trust: :data
      })

    assert {:error, {:dynamic_prompt_fragment_not_materializable, :dynamic_context}} =
             PromptMaterializer.render(dynamic, "honest", %{})

    assert {:error, :prompt_materialization_fragment_digest_mismatch} =
             PromptMaterializer.render(
               %{fragment | content: "Changed {{input.text}} for {{audience}}"},
               "honest",
               %{}
             )

    assert {:error,
            {:invalid_prompt_materialization_fragment,
             {:prompt_placeholder_schema_mismatch, [], ["audience", "input.text"]}}} =
             PromptMaterializer.render(%{fragment | placeholders: %{}}, "honest", %{})

    assert {:error, {:invalid_prompt_materialization_context, :list}} =
             PromptMaterializer.render(fragment, "honest", [])

    assert {:error, {:invalid_skill_input, :other}} =
             PromptMaterializer.render(fragment, fn -> :not_data end, %{audience: :operator})
  end

  test "rehearsal consumes exact recordings and never dispatches real Effects" do
    program = effect_program()
    initial = %{"value" => 1}
    assert {:ok, input_digest} = Rehearsal.input_digest(initial)
    assert input_digest == Value.digest!(initial)
    assert {:ok, ^input_digest} = PortableDigest.digest(initial)

    recordings = [
      %{
        operation_ref: "external",
        input_digest: input_digest,
        status: :ok,
        value: %{"value" => 2},
        receipt: %{source: :fixture}
      }
    ]

    assert {:ok, %Report{} = first} =
             Rehearsal.run(program, initial, recordings, agent: Agent)

    assert {:ok, %Report{} = replayed} =
             Rehearsal.run(program, initial, recordings, agent: Agent)

    assert first.digest == replayed.digest
    assert first.status == :completed
    assert first.effect_dispatches == 0
    assert first.consumed_recordings == 1
    assert [trace] = first.trace
    assert trace.side_effect == :non_idempotent
    assert trace.dispatched? == false
    assert trace.receipt_digest

    assert {:error, {:execution_rehearsal_recording_mismatch, 0, "external"}} =
             Rehearsal.run(
               program,
               initial,
               [Map.put(hd(recordings), :input_digest, String.duplicate("0", 64))],
               agent: Agent
             )
  end

  test "rehearsal follows real retry transitions and rejects ambiguous recording shapes" do
    program = retry_program()
    initial = %{"value" => 1}
    assert {:ok, input_digest} = Rehearsal.input_digest(initial)

    recordings = [
      %{
        operation_ref: "retry_echo",
        input_digest: input_digest,
        status: :error,
        error: :error
      },
      %{
        operation_ref: "retry_echo",
        input_digest: input_digest,
        status: :ok,
        value: %{"value" => 2}
      }
    ]

    assert {:ok, %Report{} = report} =
             Rehearsal.run(program, initial, recordings, agent: Agent)

    assert report.status == :completed
    assert report.consumed_recordings == 2
    assert Enum.map(report.trace, & &1.status) == [:error, :ok]
    assert Enum.all?(report.trace, &(&1.dispatched? == false))

    no_retries =
      retry_program()
      |> Program.to_data()
      |> Map.delete(:digest)
      |> put_in([:budget, :retries], 0)
      |> Program.new!()

    assert {:ok, %Report{status: :completed, consumed_recordings: 1}} =
             Rehearsal.run(
               no_retries,
               initial,
               [
                 %{
                   operation_ref: "retry_echo",
                   input_digest: input_digest,
                   value: %{"value" => 2}
                 }
               ],
               agent: Agent
             )

    assert {:error,
            {:invalid_execution_rehearsal_recording, 0,
             {:ambiguous_execution_rehearsal_recording_field, :operation_ref, :operation}}} =
             Rehearsal.run(
               program,
               initial,
               [
                 %{
                   operation_ref: "retry_echo",
                   operation: "echo",
                   input_digest: input_digest,
                   value: initial
                 }
               ],
               agent: Agent
             )

    assert {:error,
            {:invalid_execution_rehearsal_recording, 0,
             :ok_execution_rehearsal_recording_has_error}} =
             Rehearsal.run(
               program,
               initial,
               [
                 %{
                   operation_ref: "retry_echo",
                   input_digest: input_digest,
                   value: initial,
                   error: :smuggled
                 }
               ],
               agent: Agent
             )
  end

  test "rehearsal ingestion rejects malformed options and recording envelopes" do
    program = effect_program()
    initial = %{"value" => 1}
    assert {:ok, input_digest} = Rehearsal.input_digest(initial)

    recording = %{
      operation_ref: "external",
      input_digest: input_digest,
      value: %{"value" => 2}
    }

    assert {:error, :invalid_execution_rehearsal_options} =
             Rehearsal.run(program, initial, [recording], [:not_keyword])

    assert {:error, {:invalid_execution_rehearsal_input, :atom, :list}} =
             Rehearsal.run(program, initial, :invalid, [])

    assert {:error, {:invalid_execution_rehearsal_agent, nil}} =
             Rehearsal.run(program, initial, [recording])

    assert {:error, {:invalid_execution_rehearsal_option, :plans, []}} =
             Rehearsal.run(program, initial, [recording], agent: Agent, plans: [])

    assert {:error, {:invalid_execution_rehearsal_digest, :materialization_digest, "invalid"}} =
             Rehearsal.run(program, initial, [recording],
               agent: Agent,
               materialization_digest: "invalid"
             )

    assert {:error, {:invalid_execution_rehearsal_definition_ref, "invalid"}} =
             Rehearsal.run(program, initial, [recording],
               agent: Agent,
               definition_ref: "invalid"
             )

    malformed = [
      {{:invalid, :recording}, {:invalid_execution_rehearsal_recording_shape, :tuple}},
      {recording |> Map.put(:status, :ok) |> Map.put("status", "ok"),
       :duplicate_execution_rehearsal_recording_field},
      {Map.put(recording, :unknown, true),
       {:unknown_execution_rehearsal_recording_fields, [:unknown]}},
      {Map.delete(recording, :operation_ref),
       {:missing_execution_rehearsal_recording_field, :operation_ref}},
      {%{recording | operation_ref: nil}, {:invalid_execution_rehearsal_operation, nil}},
      {Map.delete(recording, :input_digest),
       {:missing_execution_rehearsal_recording_field, :input_digest}},
      {%{recording | input_digest: "invalid"},
       {:invalid_execution_rehearsal_input_digest, "invalid"}},
      {Map.put(recording, :status, :future), {:invalid_execution_rehearsal_status, :future}},
      {recording |> Map.delete(:value) |> Map.put(:status, :ok),
       :execution_rehearsal_recording_requires_value},
      {Map.put(recording, :status, :error), :failed_execution_rehearsal_recording_has_value},
      {recording |> Map.delete(:value) |> Map.put(:status, :error),
       :execution_rehearsal_recording_requires_error},
      {Map.put(recording, :usage, []),
       {:invalid_execution_rehearsal_recording_map, :usage, :list}},
      {Map.put(recording, :metadata, []),
       {:invalid_execution_rehearsal_recording_map, :metadata, :list}}
    ]

    Enum.each(malformed, fn {value, reason} ->
      assert {:error, {:invalid_execution_rehearsal_recording, 0, ^reason}} =
               Rehearsal.run(program, initial, [value], agent: Agent)
    end)

    assert {:error,
            {:invalid_execution_rehearsal_recording, 0, {:nonportable_run_value, _path, :pid}}} =
             Rehearsal.run(
               program,
               initial,
               [Map.put(recording, :receipt, self())],
               agent: Agent
             )

    assert {:error, {:execution_rehearsal_recording_missing, 0, "external"}} =
             Rehearsal.run(program, initial, [], agent: Agent)

    assert {:error, {:unused_execution_rehearsal_recordings, 1}} =
             Rehearsal.run(program, initial, [recording, recording], agent: Agent)

    alias_recording = %{
      operation: :external,
      request_input_digest: input_digest,
      value: %{"value" => 2},
      receipt:
        Subject.new("rehearsal-operation-receipt",
          metadata: %{tags: [:recorded, :rehearsal]}
        )
    }

    assert {:ok, %Report{} = report} =
             Rehearsal.run(program, initial, [alias_recording], agent: Agent)

    assert report.input_evidence_digest == Value.digest!(initial)
    assert hd(report.trace).receipt_digest
  end

  test "the 0.2.8 fixture pins data Work and no-Effect rehearsal identities" do
    fixture =
      "test/fixtures/compatibility/0.2.8/data-driven-execution-v1.json"
      |> File.read!()
      |> Spectre.JSON.decode!()

    assert fixture["schema_version"] == 1
    assert fixture["release"] == "0.2.8"
    assert {:ok, program} = Program.from_data(fixture["program"])

    expected = fixture["expected"]
    rehearsal = fixture["rehearsal"]

    assert program.digest == expected["program_digest"]
    assert Program.operation_refs(program) == expected["operation_refs"]

    assert {:ok, input_digest} = Rehearsal.input_digest(rehearsal["input"])
    assert input_digest == expected["input_evidence_digest"]

    assert {:ok, %Report{} = report} =
             Rehearsal.run(program, rehearsal["input"], rehearsal["recordings"], agent: Agent)

    assert report.digest == expected["report_digest"]
    assert report.final_state_digest == expected["final_state_digest"]
    assert Atom.to_string(report.status) == expected["status"]
    assert report.effect_dispatches == expected["effect_dispatches"]
    assert report.consumed_recordings == expected["consumed_recordings"]

    matrix = Conformance.matrix()
    assert matrix.release == "0.3.4"
    assert matrix.data_execution.program_schema == 1
    assert matrix.data_execution.handoff_schema == 1
    assert matrix.data_execution.prompt_receipt_schema == 1
    assert matrix.data_execution.execution_projection == 1
    assert matrix.data_execution.migration_receipt_schema == 1
    assert matrix.data_execution.rehearsal_report_schema == 1

    Enum.each(matrix.golden_path, fn {module, function, arity} ->
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, function, arity)
    end)
  end

  defp loop_program do
    Program.new!(%{
      id: :bounded_loop,
      version: 1,
      entry: :repeat,
      input: :any,
      state: :map,
      update: :map,
      initial: {:fixed, %{"continue" => true}},
      mutable_paths: [["continue"]],
      budget: %{steps: 8, attempts: 8, retries: 2, duration_ms: 5_000, cost: 10},
      nodes: [
        %{id: :repeat, kind: :repeat, body: :echo, next: :decide, max_iterations: 2},
        %{
          id: :echo,
          kind: :step,
          operation: :echo,
          input: :state,
          save_as: ["last"],
          next: :repeat
        },
        %{
          id: :decide,
          kind: :decide,
          predicate: :continue,
          input: :state,
          on_true: :done,
          on_false: :failed
        },
        %{id: :done, kind: :complete, output: :state},
        %{id: :failed, kind: :fail, reason: :predicate_rejected}
      ]
    })
  end

  defp inference_program do
    Program.new!(%{
      id: :inference_work,
      version: 1,
      entry: :infer,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 2, attempts: 2, duration_ms: 5_000, cost: 2},
      nodes: [
        %{
          id: :infer,
          kind: :infer,
          operation: :infer,
          prompt: :prompt,
          profile_ref: :deep,
          constraints: %{preferred_level: :deep, maximum_cost_tier: :medium},
          save_as: ["answer"],
          next: :done
        },
        %{id: :done, kind: :complete, output: :state}
      ]
    })
  end

  defp redigest_projection(projection, content \\ :preserve) do
    content = if content == :preserve, do: projection.content, else: content

    digest =
      Value.digest!(%{
        definition_ref: to_string(projection.definition_ref),
        generator_id: projection.generator_id,
        generator_version: projection.generator_version,
        input_evidence_digest: projection.input_evidence_digest,
        content: content
      })

    %{projection | content: content, digest: digest}
  end

  defp migration_program do
    Program.new!(%{
      id: :migrated_work,
      version: 2,
      entry: :done,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 1, attempts: 1},
      migrations: [%{from: 1, operation: :migrate}],
      nodes: [%{id: :done, kind: :complete, output: :state}]
    })
  end

  defp effect_program do
    Program.new!(%{
      id: :effect_rehearsal,
      version: 1,
      entry: :external,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 2, attempts: 2},
      nodes: [
        %{
          id: :external,
          kind: :step,
          operation: :external,
          input: :state,
          save_as: ["result"],
          next: :done
        },
        %{id: :done, kind: :complete, output: :state}
      ]
    })
  end

  defp retry_program do
    Program.new!(%{
      id: :retry_rehearsal,
      version: 1,
      entry: :retry,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 3, attempts: 3, retries: 1},
      nodes: [
        %{
          id: :retry,
          kind: :step,
          operation: :retry_echo,
          input: :state,
          save_as: ["result"],
          next: :done
        },
        %{id: :done, kind: :complete, output: :state}
      ]
    })
  end

  defp runtime_skill(program, opts \\ []) do
    program
    |> runtime_skill_attrs(opts)
    |> SkillDefinition.new!()
  end

  defp runtime_skill_attrs(program, opts) do
    route = Keyword.get(opts, :route, "run")

    fragments =
      if Keyword.get(opts, :prompt?, false) do
        [
          %{
            id: :prompt,
            content: "Summarize {{input.text}} for {{audience}}",
            token_cap: 64,
            budget_class: :small
          }
        ]
      else
        []
      end

    %{
      id: "execution-skill-#{program.id}",
      declared_version: 1,
      publisher_ref: "host:data-execution-test",
      applicability: %{
        scopes: [:execution],
        positive: [route],
        negative: ["do not run"]
      },
      prompt_fragments: fragments,
      prompt_budget: if(fragments == [], do: 64, else: 128),
      works: [Program.to_data(program)],
      flows: [
        %{
          id: :execution,
          routes: [
            %{
              label: :run,
              match: %{kind: :exact, value: route},
              handler: %{kind: :work, work_ref: program.id, input: :input}
            }
          ]
        }
      ]
    }
  end

  defp mounted_runtime(skill, agent \\ Agent, mount_id \\ :execution) do
    authority = execution_authority()

    runtime =
      SkillRuntime.new!(agent, authority,
        max_prompt_tokens: 1_024,
        kernel_prompt_tokens: 256,
        per_skill_prompt_cap: 512
      )

    {:ok, runtime} = SkillRuntime.mount(runtime, mount_id, skill, expected_revision: 0)
    runtime
  end

  defp operation_env do
    %{
      agent: Agent,
      subject_id: "subject:data-execution",
      epoch: "epoch:data-execution",
      snapshot_id: "snapshot:data-execution",
      canonical_revision: 0,
      committed: %{},
      now: 1_000
    }
  end

  defp migration_owner(program) do
    [
      definition_ref: Definition.manifest!(MigrationSkill).definition_ref,
      materialization_digest:
        Value.digest!(%{kind: :test_materialization, program_digest: program.digest})
    ]
  end

  defp commit_value(loop, control, value, env) do
    assert {:run, active, attempt, _spec, _request, false, _events} =
             OperationRuntime.prepare(loop, control, env)

    result = Result.new(attempt, :ok, value, finished_at: env.now + active.attempts)

    assert {:ok, evaluating, control, _events} =
             OperationRuntime.apply_result(active, control, result, env)

    assert {:ok, next, control, _events} = OperationRuntime.evaluate(evaluating, control, env)
    {next, control}
  end

  defp migration_result(request, value) do
    %Result{
      id: "migration-result",
      attempt_id: "migration-attempt",
      loop_id: "migration-recovery",
      operation: request.operation,
      epoch: "migration-epoch",
      fencing_token: "migration-fence",
      context_revision: 0,
      control_generation: 0,
      trigger_generation: 0,
      status: :ok,
      value: value,
      error: nil,
      receipt: nil,
      usage: %{},
      finished_at: 1,
      artifacts: [],
      metadata: %{}
    }
  end

  defp start_activated_instance(agent) do
    {instance, _store} = start_activated_instance_with_store(agent)
    instance
  end

  defp start_activated_instance_with_store(agent) do
    authority = execution_authority()
    canonical = Definition.canonical!(agent)

    manifest =
      Definition.manifest!(agent,
        authority_requests: authority,
        authority_ceiling: authority
      )

    store = memory_definition_store()
    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)

    assert {:ok, candidate_ref} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject = Subject.new("activated-execution-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(
        {Instance, agent: agent, subject: subject, definition_store: store, idle: false}
      )

    assert {:ok, %{generation: 1}} =
             Spectre.activate(instance, candidate_ref, expected_generation: 0)

    {instance, store}
  end

  defp republished_activation(canonical, manifest, closure_updates) do
    closure =
      manifest.execution_closure
      |> Map.from_struct()
      |> Map.merge(Map.new(closure_updates))
      |> Closure.new!()

    published_activation(
      canonical,
      Manifest.new!(canonical, manifest.authority, closure)
    )
  end

  defp published_activation(canonical, manifest) do
    store = memory_definition_store()
    assert {:ok, _receipt} = Store.publish(store, canonical, manifest)

    assert {:ok, resolution} =
             Resolver.resolve(store, Canonical.ref(canonical), observe_builds: true)

    assert {:ok, candidate} = Candidate.from_resolution(resolution, created_at: 1)

    assert {:ok, activation} =
             Activation.new(candidate, resolution,
               generation: 1,
               owner_fencing_token: 1,
               activated_at: 1
             )

    {store, activation}
  end

  defp memory_definition_store do
    id = {:execution_admission, System.unique_integer([:positive, :monotonic])}

    server =
      start_supervised!(%{
        id: id,
        start: {DefinitionMemory, :start_link, [[id: id]]}
      })

    {DefinitionMemory, server: server}
  end

  defp execution_authority do
    Envelope.new!(
      operations: [:echo, :retry_echo, :continue, :infer, :migrate, :external],
      open_capabilities: [
        SkillRuntime.capability(:mount),
        SkillRuntime.capability(:replace),
        SkillRuntime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard, :large],
      model_purposes: [:data_driven_work],
      model_profiles: [:fast, :balanced, :deep],
      limits: %{max_tokens: 1_024}
    )
  end

  defp eventually_loop(instance, loop_id, attempts \\ 100)
  defp eventually_loop(_instance, _loop_id, 0), do: {:error, :timeout}

  defp eventually_loop(instance, loop_id, attempts) do
    case Spectre.loop(instance, loop_id) do
      {:ok, %View{status: :terminal} = view} ->
        {:ok, view}

      {:ok, _view} ->
        Process.sleep(10)
        eventually_loop(instance, loop_id, attempts - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp component(canonical, type) do
    {:ok, component} = Canonical.fetch_component(canonical, type)
    component
  end

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _bytes}, Base.decode16(value, case: :lower))

  defp digest?(_value), do: false

  defp rewrite_component(canonical, type, fun) do
    components =
      Enum.map(canonical.components, fn
        %{component_type: ^type} = component -> %{component | payload: fun.(component.payload)}
        component -> component
      end)

    %{canonical | components: components}
  end
end
