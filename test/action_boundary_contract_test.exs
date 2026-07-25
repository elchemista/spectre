defmodule SpectreActionBoundaryContractTest.Actions do
  @moduledoc false

  def one(args), do: {:ok, {:one, args}}

  def two(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:two, args, ctx.opts})
    {:ok, {:two, args}}
  end

  def three(_args, _ctx, _extra), do: :unsupported

  def __spectre_tools__ do
    [
      %{al: "EXACT ONE", function: :one, arity: 1},
      %{al: "EXACT TWO", function: :two, arity: 2},
      %{al: "EXACT THREE", function: :three, arity: 3}
    ]
  end
end

defmodule SpectreActionBoundaryContractTest.ActionAgent do
  @moduledoc false

  def __spectre_config__,
    do: [actions: {SpectreActionBoundaryContractTest.Actions, []}]
end

defmodule SpectreActionBoundaryContractTest.NoActionsAgent do
  @moduledoc false
  def __spectre_config__, do: []
end

defmodule SpectreActionBoundaryContractTest.RaisingTools do
  @moduledoc false
  def __spectre_tools__, do: raise("private registry detail")
end

defmodule SpectreActionBoundaryContractTest.ThrowingTools do
  @moduledoc false
  def __spectre_tools__, do: throw(:private_registry_detail)
end

defmodule SpectreActionBoundaryContractTest.Hooks do
  @moduledoc false
  def existing(_result), do: :ok
end

defmodule SpectreActionBoundaryContractTest.HookAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :action_boundary_hooks,
      owner: SpectreActionBoundaryContractTest.Hooks,
      after_actions: [
        %{action: "one", on: :delivered, run: :existing},
        %{action: "coverage-action-that-is-not-an-atom", on: :delivered, run: :existing},
        %{action: 404, on: :delivered, run: :existing}
      ]
    }
  end
end

defmodule SpectreActionBoundaryContractTest.ProtectionAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :action_boundary_protection,
      owner: __MODULE__,
      protections: [
        %{action: :one, policy: :confirm_one},
        %{action: {:al, "delete account"}, policy: :confirm_al},
        %{
          action: "Elixir.SpectreActionBoundaryContractTest.Actions.two/2",
          policy: :confirm_tool
        },
        %{action: {:invalid, :shape}, policy: :never_matches}
      ]
    }
  end
end

defmodule SpectreActionBoundaryContractTest do
  use ExUnit.Case, async: false

  alias Spectre.ActionDispatcher
  alias Spectre.ActionHooks
  alias Spectre.ActionPlanner
  alias Spectre.ActionProtection
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Result

  @actions SpectreActionBoundaryContractTest.Actions
  @agent SpectreActionBoundaryContractTest.ActionAgent

  test "the optional planner boundary rejects malformed plans without staging work" do
    on_exit(fn ->
      Application.delete_env(:spectre, :coverage_action_boundary_pid)
      Application.delete_env(:spectre, :spectre_kinetic_runtime)
      Application.delete_env(:spectre_kinetic, :compiled_registry)
      Application.delete_env(:spectre_kinetic, :registry_json)
    end)

    assert {:ok, %{reply_text: "plain reply", effects: []}} =
             ActionPlanner.plan_response("  plain reply  ")

    Application.put_env(:spectre, :coverage_action_boundary_pid, self())

    assert {:ok, %Effect{status: :pending, scope: :agent}} =
             ActionPlanner.plan("EXACT ONE", runtime: %{source: :explicit})

    assert_receive {:kinetic_plan, %{source: :explicit}, "EXACT ONE", []}

    assert {:ok,
            %Effect{
              owner: @agent,
              scope: :agent,
              payload: %{selected_tool: "Elixir.SpectreActionBoundaryContractTest.Actions.one/1"}
            }} =
             ActionPlanner.plan("EXACT ONE",
               runtime: %{source: :origin},
               actions_module: @actions,
               effect_owner: @agent,
               effect_scope: :agent
             )

    assert {:error, {:incomplete_effect_origin, {@agent, nil}}} =
             ActionPlanner.plan("EXACT ONE",
               runtime: %{source: :origin},
               effect_owner: @agent
             )

    for {al, expected} <- [
          {"HALTED", :action_plan_halted},
          {"REJECTED", :action_plan_not_executable},
          {"MISSING TOOL", :action_plan_missing_tool},
          {"INVALID ARGS", :invalid_action_args},
          {"NON MAP", :invalid_planned_action}
        ] do
      assert {:error, reason} = ActionPlanner.plan(al, runtime: %{source: :validation})
      assert elem(reason, 0) == expected
    end

    assert {:error, {:invalid_action_chain, :not_a_chain}} =
             ActionPlanner.plan_response("visible <al>INVALID CHAIN</al>",
               runtime: %{source: :chain}
             )

    assert {:error, {:invalid_planned_action, 1, :not_an_action}} =
             ActionPlanner.plan_response("visible <al>MALFORMED CHAIN</al>",
               runtime: %{source: :chain}
             )

    assert {:ok, %{reply_text: "visible", effects: [first, second]}} =
             ActionPlanner.plan_response(
               "visible <al>VALID CHAIN</al>",
               runtime: %{source: :chain},
               effect_owner: @agent,
               effect_scope: :agent
             )

    assert first.owner == @agent
    assert second.owner == @agent
    assert first.payload.al == "EXACT ONE"
    assert second.payload.al == "EXACT TWO"

    assert {:ok, %Effect{payload: %{selected_tool: "unmatched/1"}}} =
             ActionPlanner.plan("NO EXACT MATCH",
               runtime: %{source: :exact},
               actions_module: @actions
             )

    assert {:ok, %Effect{payload: %{selected_tool: "unmatched/1"}}} =
             ActionPlanner.plan("EXACT ONE",
               runtime: %{source: :exact},
               actions_module: SpectreActionBoundaryContractTest.RaisingTools
             )

    assert {:ok, %Effect{payload: %{selected_tool: "unmatched/1"}}} =
             ActionPlanner.plan("EXACT ONE",
               runtime: %{source: :exact},
               actions_module: SpectreActionBoundaryContractTest.ThrowingTools
             )

    Application.put_env(:spectre, :spectre_kinetic_runtime, %{source: :application})
    assert {:ok, %Effect{}} = ActionPlanner.plan("EXACT ONE")
    assert_receive {:kinetic_plan, %{source: :application}, "EXACT ONE", []}

    Application.delete_env(:spectre, :spectre_kinetic_runtime)

    registry =
      Path.join(System.tmp_dir!(), "spectre-compiled-registry-#{System.unique_integer()}")

    File.write!(registry, "{}")
    on_exit(fn -> File.rm(registry) end)
    Application.put_env(:spectre_kinetic, :compiled_registry, registry)

    assert {:ok, %Effect{}} = ActionPlanner.plan("EXACT ONE")

    assert_receive {:kinetic_load_runtime, compiled_registry_opts}
    assert compiled_registry_opts[:compiled_registry] == registry
    assert compiled_registry_opts[:classifiers] == []

    Application.delete_env(:spectre_kinetic, :compiled_registry)
    Application.put_env(:spectre_kinetic, :registry_json, registry)

    assert {:ok, %Effect{}} =
             ActionPlanner.plan("EXACT ONE",
               classifiers: [:classifier],
               top_k: 3,
               ignored: :option
             )

    assert_receive {:kinetic_load_runtime, registry_json_opts}
    assert registry_json_opts[:registry_json] == registry
    assert registry_json_opts[:classifiers] == [:classifier]
    assert registry_json_opts[:top_k] == 3

    Application.delete_env(:spectre_kinetic, :registry_json)

    assert {:ok, %Effect{}} =
             ActionPlanner.plan("EXACT ONE", actions_module: @actions)

    assert_receive {:kinetic_extract, @actions}
    assert_receive {:kinetic_load_runtime, runtime_opts}
    assert is_binary(runtime_opts[:registry_json])
    assert File.exists?(runtime_opts[:registry_json])

    assert {:error, :extract_failed} =
             ActionPlanner.plan("EXACT ONE",
               actions_module: SpectreActionBoundaryContractTest.NoActionsAgent
             )

    assert {:error, {:registry_encode_failed, _reason}} =
             ActionPlanner.plan("EXACT ONE",
               actions_module: SpectreActionBoundaryContractTest.Hooks
             )
  end

  test "dispatcher authorizes exact tools, preserves idempotency, and rejects malformed capability IDs" do
    one = effect("Elixir.SpectreActionBoundaryContractTest.Actions.one/1", %{value: 1})
    assert {:ok, {:one, %{value: 1}}} = ActionDispatcher.dispatch(one, %{agent: @agent})

    two = effect("Elixir.SpectreActionBoundaryContractTest.Actions.two/2", %{value: 2})

    assert {:ok, {:two, %{value: 2}}} =
             ActionDispatcher.dispatch(two, %Context{agent: @agent, input: Input.new("")},
               test_pid: self()
             )

    assert_receive {:two, %{value: 2}, opts}
    assert opts[:effect_id] == two.id
    assert opts[:idempotency_key] == Effect.idempotency_key(two)

    three = effect("Elixir.SpectreActionBoundaryContractTest.Actions.three/3", %{})

    assert {:error, {:unsupported_action_arity, @actions, :three, 3}} =
             ActionDispatcher.dispatch(three, %{agent: @agent})

    for {tool, expected} <- [
          {"not-elixir", :invalid_tool},
          {"Elixir.SpectreActionBoundaryContractTest.Actions.one", :invalid_tool},
          {"Elixir.SpectreActionBoundaryContractTest.DoesNotExist.one/1", :unknown_tool_module}
        ] do
      assert {:error, ^expected} =
               ActionDispatcher.dispatch(effect(tool, %{}), %{agent: @agent})
    end

    unknown_function = "coverage_function_#{System.unique_integer([:positive])}"

    assert {:error, :unknown_tool_function} =
             ActionDispatcher.dispatch(
               effect(
                 "Elixir.SpectreActionBoundaryContractTest.Actions.#{unknown_function}/1",
                 %{}
               ),
               %{agent: @agent}
             )

    assert {:error, :missing_actions_module} =
             ActionDispatcher.dispatch(Effect.stage(%{name: :one}), %{
               agent: SpectreActionBoundaryContractTest.NoActionsAgent
             })

    assert {:error, :unknown_action_name} =
             ActionDispatcher.dispatch(%Effect{kind: :action, name: 404}, %{agent: @agent})

    assert {:error, {:undefined_action, @actions, :missing}} =
             ActionDispatcher.dispatch(Effect.stage(%{name: :missing}), %{agent: @agent})
  end

  test "hooks match atom, unknown string, and non-atom action identities and report missing callbacks" do
    completed =
      completed_effect(:one, [
        %{
          action: :one,
          on: :delivered,
          run: {SpectreActionBoundaryContractTest.Hooks, :missing}
        }
      ])

    assert {:error,
            [
              {:undefined_after_action_hook, SpectreActionBoundaryContractTest.Hooks, :missing}
            ]} =
             ActionHooks.run(
               SpectreActionBoundaryContractTest.HookAgent,
               :delivered,
               %Result{effects: [completed], input: Input.new("one")},
               %{}
             )

    unknown = completed_effect("coverage-action-that-is-not-an-atom", [])
    numeric = %{completed_effect(:one, []) | name: 404}

    assert :ok =
             ActionHooks.run(
               SpectreActionBoundaryContractTest.HookAgent,
               :delivered,
               %Result{effects: [unknown, numeric], input: Input.new("other")},
               %{}
             )
  end

  test "action protection distinguishes action names, normalized AL, exact tools, and invalid shapes" do
    agent = SpectreActionBoundaryContractTest.ProtectionAgent

    assert :confirm_one ==
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(%{name: :one}, agent, :agent)
             )

    assert :confirm_one ==
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(
                 %{
                   name: :different,
                   selected_tool: "Elixir.SpectreActionBoundaryContractTest.Actions.one/1"
                 },
                 agent,
                 :agent
               )
             )

    assert :confirm_al ==
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(%{al: "  DELETE   ACCOUNT "}, agent, :agent)
             )

    assert :confirm_tool ==
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(
                 %{selected_tool: "Elixir.SpectreActionBoundaryContractTest.Actions.two/2"},
                 agent,
                 :agent
               )
             )

    assert is_nil(
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(%{name: :unprotected}, agent, :agent)
             )
           )
  end

  defp effect(tool, args) do
    Effect.stage(%{
      name: :one,
      args: args,
      payload: %{selected_tool: tool}
    })
  end

  defp completed_effect(name, hooks) do
    Effect.stage_action(
      %{name: name, hooks: hooks},
      SpectreActionBoundaryContractTest.Hooks,
      :agent
    )
    |> Effect.complete(:done)
  end
end
