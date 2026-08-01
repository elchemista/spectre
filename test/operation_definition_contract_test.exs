defmodule SpectreOperationDefinitionContractTest.Callbacks do
  @moduledoc false

  def execute(value, _context), do: {:ok, value}
end

defmodule SpectreOperationDefinitionContractTest.LegacyController do
  @moduledoc false

  def definition do
    [
      id: :legacy_controller,
      version: "v1",
      kind: :directive,
      operations: [
        [
          id: :legacy_operation,
          executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute}
        ]
      ]
    ]
  end
end

defmodule SpectreOperationDefinitionContractTest.InvalidController do
  @moduledoc false
  def definition, do: :invalid
end

defmodule SpectreOperationDefinitionContractTest.RaisingController do
  @moduledoc false
  def definition, do: raise("definition failed")
end

defmodule SpectreOperationDefinitionContractTest.ThrowingController do
  @moduledoc false
  def definition, do: throw(:definition_failed)
end

defmodule SpectreOperationDefinitionContractTest.EmptyController do
  @moduledoc false
end

defmodule SpectreOperationDefinitionContractTest.CompatibleController do
  @moduledoc false
  def checkpoint_compatible?(:old, :new), do: true
end

defmodule SpectreOperationDefinitionContractTest.RaisingCompatibility do
  @moduledoc false
  def checkpoint_compatible?(_old, _new), do: raise("compatibility failed")
end

defmodule SpectreOperationDefinitionContractTest.ThrowingCompatibility do
  @moduledoc false
  def checkpoint_compatible?(_old, _new), do: throw(:compatibility_failed)
end

defmodule SpectreOperationDefinitionContractTest.ListRegistryAgent do
  @moduledoc false

  def __spectre_config__ do
    [
      operations: [
        [
          id: :shared,
          executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute}
        ]
      ]
    ]
  end
end

defmodule SpectreOperationDefinitionContractTest.MapRegistryAgent do
  @moduledoc false

  alias Spectre.Operation.Spec

  def __spectre_config__ do
    [
      operations: %{
        struct_entry: %Spec{
          id: :ignored,
          kind: :function,
          executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute},
          policy: :registered,
          remember: false
        },
        map_entry: %{
          executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute}
        },
        keyword_entry: [
          executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute}
        ]
      }
    ]
  end
end

defmodule SpectreOperationDefinitionContractTest.DuplicateRegistryAgent do
  @moduledoc false

  def __spectre_config__ do
    callback = {SpectreOperationDefinitionContractTest.Callbacks, :execute}
    [operations: [[id: :duplicate, executor: callback], [id: :duplicate, executor: callback]]]
  end
end

defmodule SpectreOperationDefinitionContractTest.InvalidRegistryAgent do
  @moduledoc false
  def __spectre_config__, do: [operations: :invalid]
end

defmodule SpectreOperationDefinitionContractTest.RaisingRegistryAgent do
  @moduledoc false
  def __spectre_config__, do: raise("registry failed")
end

defmodule SpectreOperationDefinitionContractTest.Work do
  @moduledoc false

  use Spectre.Work, id: :definition_work, version: 1, imports: [:configured_shared]

  operation(:keyword_operation,
    executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute},
    input: :map
  )

  operation(
    :explicit_operation,
    {SpectreOperationDefinitionContractTest.Callbacks, :execute},
    output: :map
  )

  uses_operation(:shared)

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, _context), do: complete(:done)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: complete(:done)
end

defmodule SpectreOperationDefinitionContractTest.Vigil do
  @moduledoc false

  use Spectre.Vigil, id: :definition_vigil, version: 1, imports: [:configured_shared]

  operation(:keyword_observation,
    executor: {SpectreOperationDefinitionContractTest.Callbacks, :execute}
  )

  operation(:explicit_observation, {SpectreOperationDefinitionContractTest.Callbacks, :execute},
    output: :map
  )

  uses_operation(:shared)

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(_state, context), do: wait_for(5, context)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}
end

defmodule SpectreOperationDefinitionContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Spec

  @callbacks SpectreOperationDefinitionContractTest.Callbacks

  test "operation specs reject every malformed contract dimension" do
    valid = %Spec{
      id: :valid,
      kind: :function,
      executor: {@callbacks, :execute},
      policy: :registered,
      remember: false
    }

    assert :ok = Spec.validate(valid)

    cases = [
      {%{id: nil}, {:invalid_operation_id, nil}},
      {%{id: ""}, {:invalid_operation_id, ""}},
      {%{id: 123}, {:invalid_operation_id, 123}},
      {%{kind: :unknown}, {:invalid_operation_kind, :unknown}},
      {%{executor: %{}}, {:invalid_operation_executor, :valid, %{}}},
      {%{input: self()}, {:invalid_operation_input_validator, :valid}},
      {%{output: self()}, {:invalid_operation_output_validator, :valid}},
      {%{reconcile: 123}, {:invalid_operation_reconcile, :valid}},
      {%{fallback: 123}, {:invalid_operation_fallback, :valid}},
      {%{policy: 123}, {:invalid_operation_policy, :valid}},
      {%{timeout: 0}, {:invalid_operation_timeout, :valid, 0}},
      {%{side_effect: :unknown}, {:invalid_operation_side_effect, :valid, :unknown}},
      {%{side_effect: :reconcilable}, {:operation_reconcile_required, :valid}},
      {%{domain: :invalid}, {:invalid_operation_domain, :valid}},
      {%{kind: :cognitive, domain: [], executor: {@callbacks, :execute}},
       {:empty_cognitive_domain, :valid}},
      {%{kind: :cognitive, executor: {@callbacks, :execute}},
       {:unbounded_cognitive_operation, :valid}},
      {%{domain: [:one, :one]}, {:duplicate_operation_domain_value, :valid}},
      {%{kind: :planner, catalog: [], executor: {@callbacks, :execute}},
       {:empty_operation_catalog, :valid}},
      {%{catalog: [:one, nil]}, {:invalid_operation_catalog, :valid}},
      {%{metadata: []}, {:invalid_operation_metadata, :valid}},
      {%{remember: :sometimes}, {:invalid_operation_memory_policy, :valid}},
      {%{risk: "high"}, {:invalid_operation_risk, :valid}},
      {%{description: :invalid}, {:invalid_operation_description, :valid}}
    ]

    Enum.each(cases, fn {changes, expected} ->
      assert {:error, ^expected} = valid |> struct!(changes) |> Spec.validate()
    end)

    assert {:error, {:nonportable_operation_contract, :valid, _reason}} =
             valid |> Map.put(:metadata, %{pid: self()}) |> Spec.validate()

    assert_raise ArgumentError, ~r/invalid operation spec/, fn ->
      Spec.validate!(%{valid | timeout: 0})
    end

    assert %Spec{side_effect: :non_idempotent} =
             Spec.new(id: :action, kind: :action, executor: %{name: :deliver})

    assert %Spec{side_effect: :non_idempotent} =
             Spec.new(id: :effect, kind: :effect, executor: nil)

    assert %Spec{} =
             Spec.new(
               id: "planner",
               kind: :planner,
               executor: @callbacks,
               catalog: ["one"]
             )
  end

  test "loop definitions normalize supported shapes and reject malformed topology" do
    operation = %Spec{
      id: :local,
      kind: :function,
      executor: {@callbacks, :execute},
      policy: :registered,
      remember: false
    }

    valid = %Definition{
      id: :valid,
      version: 1,
      kind: :work,
      operations: %{local: operation},
      imports: [:shared],
      branches: %{main: [:local, :shared]},
      blockers: [:approval],
      waits: [:external],
      triggers: [:external],
      update_fields: [:all],
      security: %{
        allowed_origins: [:console],
        allowed_destinations: [:console],
        allowed_visibility: [:origin],
        allow_immediate_pause: true
      },
      artifact_policy: %{
        allowed_kinds: [:report],
        max_count: 1,
        publish_results: true,
        publish_artifacts: false,
        publish_progress: true,
        publish_blocker: false
      },
      on_budget_exhausted: :terminate
    }

    assert :ok = Definition.validate(valid)
    assert {:ok, ^operation} = Definition.operation(valid, :local)
    assert {:error, {:operation_not_registered, :missing}} = Definition.operation(valid, :missing)

    cases = [
      {%{id: nil}, {:invalid_loop_definition_id, nil}},
      {%{id: ""}, {:invalid_loop_definition_id, ""}},
      {%{id: 123}, {:invalid_loop_definition_id, 123}},
      {%{version: nil}, {:invalid_loop_definition_version, nil}},
      {%{version: ""}, {:invalid_loop_definition_version, ""}},
      {%{version: 0}, {:invalid_loop_definition_version, 0}},
      {%{kind: :unknown}, {:invalid_loop_definition_kind, :unknown}},
      {%{input: self()}, :invalid_loop_definition_input},
      {%{state: self()}, :invalid_loop_definition_state},
      {%{update: self()}, :invalid_loop_definition_update},
      {%{operations: []}, :invalid_loop_definition_operations},
      {%{imports: [:local]}, :invalid_loop_definition_imports},
      {%{imports: [:shared, :shared]}, :invalid_loop_definition_imports},
      {%{branches: []}, :invalid_loop_definition_branches},
      {%{branches: %{main: []}}, :invalid_loop_definition_branches},
      {%{branches: %{main: [:missing]}}, :invalid_loop_definition_branches},
      {%{blockers: [:approval, :approval]}, :invalid_loop_definition_blockers},
      {%{waits: ["external"]}, :invalid_loop_definition_waits},
      {%{triggers: [:external, :external]}, :invalid_loop_definition_triggers},
      {%{can_start: [:vigil]}, :invalid_loop_definition_start_capabilities},
      {%{can_start: [:work, :work]}, :invalid_loop_definition_start_capabilities},
      {%{can_start: [:work]}, :loop_start_capability_requires_directive},
      {%{update_fields: [:all, :all]}, :invalid_loop_definition_update_fields},
      {%{on_budget_exhausted: :ignore}, :invalid_loop_budget_exhaustion_behavior},
      {%{security: []}, :invalid_loop_definition_security},
      {%{security: %{allowed_visibility: []}}, :invalid_loop_definition_security},
      {%{security: %{trigger_correlation: :sometimes}}, :invalid_loop_definition_security},
      {%{security: %{trigger_correlation: nil}}, :invalid_loop_definition_security},
      {%{security: %{require_trigger_correlation: :yes}}, :invalid_loop_definition_security},
      {%{
         security: %{
           trigger_correlation: :required,
           require_trigger_correlation: false
         }
       }, :invalid_loop_definition_security},
      {%{artifact_policy: []}, :invalid_loop_artifact_policy},
      {%{artifact_policy: %{max_count: 257}}, :invalid_loop_artifact_policy},
      {%{artifact_policy: %{publish_progress: :yes}}, :invalid_loop_artifact_policy},
      {%{artifact_policy: %{publish_blocker: :yes}}, :invalid_loop_artifact_policy},
      {%{metadata: []}, :invalid_loop_definition_metadata}
    ]

    Enum.each(cases, fn {changes, expected} ->
      assert {:error, ^expected} = valid |> struct!(changes) |> Definition.validate()
    end)

    mismatched = %{valid | operations: %{other: operation}, branches: %{}}

    assert {:error, {:invalid_loop_operation_entry, :other, ^operation}} =
             Definition.validate(mismatched)

    assert {:error, {:nonportable_loop_definition, _reason}} =
             valid |> Map.put(:metadata, %{pid: self()}) |> Definition.validate()

    assert_raise ArgumentError, ~r/invalid loop definition/, fn ->
      Definition.validate!(%{valid | kind: :invalid})
    end

    assert %Definition{branches: %{main: [:local]}} =
             Definition.new(
               id: "normalized",
               version: "v1",
               kind: :directive,
               can_start: [:work],
               security: %{require_trigger_correlation: true},
               operations: %{local: Map.from_struct(operation)},
               branches: [main: :local]
             )

    assert :ok =
             Definition.validate(%{
               valid
               | security: %{require_trigger_correlation: true}
             })

    assert :ok =
             Definition.validate(%{
               valid
               | security: %{
                   trigger_correlation: :required,
                   require_trigger_correlation: true
                 }
             })

    assert %Definition{branches: %{}} =
             Definition.new(
               id: :nil_branches,
               kind: :work,
               operations: [Map.from_struct(operation)],
               branches: nil
             )

    assert_raise ArgumentError, ~r/duplicate operation id/, fn ->
      Definition.new(
        id: :duplicates,
        kind: :work,
        operations: [Map.from_struct(operation), Map.from_struct(operation)]
      )
    end

    assert_raise ArgumentError, ~r/duplicate operation id/, fn ->
      Definition.new(
        id: :map_duplicates,
        kind: :work,
        operations: %{
          first: Map.from_struct(operation),
          second: Map.from_struct(operation)
        }
      )
    end
  end

  test "definition discovery and checkpoint compatibility contain callback failures" do
    assert {:ok, %Definition{id: :legacy_controller}} =
             Definition.load(SpectreOperationDefinitionContractTest.LegacyController)

    assert {:error, {:operational_controller_not_loaded, _module}} =
             Definition.load(SpectreOperationDefinitionContractTest.MissingController)

    assert {:error, {:operational_controller_definition_missing, _module}} =
             Definition.load(SpectreOperationDefinitionContractTest.EmptyController)

    assert {:error, {:invalid_operational_controller_definition, _module, :invalid}} =
             Definition.load(SpectreOperationDefinitionContractTest.InvalidController)

    assert {:error, {:operational_controller_definition_exception, _module, RuntimeError}} =
             Definition.load(SpectreOperationDefinitionContractTest.RaisingController)

    assert {:error,
            {:operational_controller_definition_failure, _module, :throw, :definition_failed}} =
             Definition.load(SpectreOperationDefinitionContractTest.ThrowingController)

    assert Definition.compatible?(@callbacks, 1, 1)
    refute Definition.compatible?(@callbacks, 1, 2)

    assert Definition.compatible?(
             SpectreOperationDefinitionContractTest.CompatibleController,
             :old,
             :new
           )

    refute Definition.compatible?(
             SpectreOperationDefinitionContractTest.RaisingCompatibility,
             :old,
             :new
           )

    refute Definition.compatible?(
             SpectreOperationDefinitionContractTest.ThrowingCompatibility,
             :old,
             :new
           )
  end

  test "registry accepts list and map catalogs and fails closed" do
    definition = Definition.new(id: :imports, kind: :work, imports: [:shared])

    assert {:ok, %{shared: %Spec{id: :shared}}} =
             Registry.all(SpectreOperationDefinitionContractTest.ListRegistryAgent, definition)

    assert {:ok, %Spec{id: :shared}} =
             Registry.resolve(
               SpectreOperationDefinitionContractTest.ListRegistryAgent,
               definition,
               :shared
             )

    assert {:error, {:operation_not_registered, :missing}} =
             Registry.resolve(
               SpectreOperationDefinitionContractTest.ListRegistryAgent,
               definition,
               :missing
             )

    assert {:ok, operations} =
             Registry.all(
               SpectreOperationDefinitionContractTest.MapRegistryAgent,
               Definition.new(
                 id: :map,
                 kind: :work,
                 imports: [:struct_entry, :map_entry, :keyword_entry]
               )
             )

    assert Map.keys(operations) |> Enum.sort() == [:keyword_entry, :map_entry, :struct_entry]

    assert {:error, {:imported_operation_not_registered, :absent}} =
             Registry.all(
               SpectreOperationDefinitionContractTest.ListRegistryAgent,
               Definition.new(id: :missing_import, kind: :work, imports: [:absent])
             )

    assert {:error, {:duplicate_registered_operation, :duplicate}} =
             Registry.all(
               SpectreOperationDefinitionContractTest.DuplicateRegistryAgent,
               Definition.new(id: :duplicate, kind: :work)
             )

    assert {:error, {:invalid_agent_operation_registry, :invalid}} =
             Registry.all(
               SpectreOperationDefinitionContractTest.InvalidRegistryAgent,
               Definition.new(id: :invalid, kind: :work)
             )

    assert {:error, {:operation_registry_exception, _module, RuntimeError}} =
             Registry.all(
               SpectreOperationDefinitionContractTest.RaisingRegistryAgent,
               Definition.new(id: :raising, kind: :work)
             )

    assert {:error, {:operation_agent_not_loaded, _module}} =
             Registry.all(
               SpectreOperationDefinitionContractTest.MissingRegistryAgent,
               Definition.new(id: :missing, kind: :work)
             )
  end

  test "Work and Vigil expose every declaration and helper form" do
    work = SpectreOperationDefinitionContractTest.Work.__spectre_loop_definition__()
    vigil = SpectreOperationDefinitionContractTest.Vigil.__spectre_loop_definition__()

    assert Map.keys(work.operations) |> Enum.sort() == [:explicit_operation, :keyword_operation]
    assert work.imports == [:shared, :configured_shared]

    assert Map.keys(vigil.operations) |> Enum.sort() == [
             :explicit_observation,
             :keyword_observation
           ]

    assert vigil.imports == [:shared, :configured_shared]

    assert {:run, %{operation: :one}} = Spectre.Work.run(:one, %{})
    assert {:wait, %{kind: :external}} = Spectre.Work.wait(:external)
    assert {:blocked, :approval} = Spectre.Work.blocked(:approval)
    assert {:complete, :done} = Spectre.Work.complete(:done)
    assert {:error, :failed} = Spectre.Work.fail(:failed)

    assert {:run, %{operation: :observe}} = Spectre.Vigil.observe(:observe, %{})
    assert {:wait, %{kind: :external}} = Spectre.Vigil.wait(:external)
    assert {:wait, %{kind: :timer, due_at: 15}} = Spectre.Vigil.wait_for(5, %{now: 10})
    assert {:complete, :done} = Spectre.Vigil.complete(:done)
    assert {:error, :failed} = Spectre.Vigil.fail(:failed)

    assert :continue = SpectreOperationDefinitionContractTest.Vigil.complete(%{}, %{})

    assert {:error, :vigil_updates_not_supported} =
             SpectreOperationDefinitionContractTest.Vigil.apply_update(%{}, %{}, %{}, %{})

    assert {:ok, %{kept: true}} =
             SpectreOperationDefinitionContractTest.Vigil.handle_trigger(
               %{kept: true},
               :ignored,
               %{}
             )
  end
end
