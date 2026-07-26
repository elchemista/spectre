defmodule SpectreActionBoundaryContractTest.Actions do
  @moduledoc false

  def one(args), do: {:ok, {:one, args}}

  def two(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:two, args, ctx.opts})
    {:ok, {:two, args}}
  end

  def three(_args, _ctx, _extra), do: :unsupported

  def __spectre_actions__ do
    [
      %{name: :one, schema: %{arity: 1}},
      %{name: :two, schema: %{arity: 2}},
      %{name: :three, schema: %{arity: 3}}
    ]
  end
end

defmodule SpectreActionBoundaryContractTest.ActionAgent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreActionBoundaryContractTest.Actions)
end

defmodule SpectreActionBoundaryContractTest.NoActionsAgent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreActionBoundaryContractTest.Planner do
  @moduledoc false

  @behaviour Spectre.Action.Planner

  @impl true
  def plan(instruction, _ctx, _opts) do
    case instruction do
      "PLANNER ERROR" -> {:error, :planner_error}
      "NON MAP" -> {:ok, :not_an_action}
      other -> {:ok, action(other)}
    end
  end

  @impl true
  def plan_response(text, _ctx, _opts) do
    cond do
      String.contains?(text, "PLANNER ERROR") ->
        {:error, :planner_error}

      String.contains?(text, "INVALID RESPONSE") ->
        :invalid_response

      String.contains?(text, "MALFORMED ACTION") ->
        {:ok, %{reply_text: "visible", actions: [:not_an_action]}}

      String.contains?(text, "VALID CHAIN") ->
        {:ok,
         %{
           reply_text: "visible",
           actions: [action("EXACT ONE"), action("EXACT TWO")]
         }}

      true ->
        {:ok, %{reply_text: String.trim(text), actions: []}}
    end
  end

  @impl true
  def clean_reply(text, _ctx, _opts), do: String.trim(text)

  defp action(instruction) do
    {name, selected_tool} =
      case instruction do
        "EXACT ONE" ->
          {:one, "Elixir.SpectreActionBoundaryContractTest.Actions.one/1"}

        "EXACT TWO" ->
          {:two, "Elixir.SpectreActionBoundaryContractTest.Actions.two/2"}

        _other ->
          {:unmatched, "unmatched/1"}
      end

    Spectre.Action.new(%{
      name: name,
      via: :local,
      args: %{},
      planned_by: __MODULE__,
      metadata: %{al: instruction, selected_tool: selected_tool}
    })
  end
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
        %{action: {:remote, :remote_one}, policy: :confirm_remote},
        %{action: {:invalid, :shape}, policy: :never_matches}
      ]
    }
  end
end

defmodule SpectreActionBoundaryContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Action.Spec
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
  @planner SpectreActionBoundaryContractTest.Planner

  test "the optional planner boundary rejects malformed plans without staging work" do
    assert {:ok, %{reply_text: "plain reply", effects: []}} =
             ActionPlanner.plan_response("  plain reply  ")

    assert {:error, :action_planner_not_configured} =
             ActionPlanner.plan("EXACT ONE")

    assert {:ok, %Effect{status: :pending, scope: :agent}} =
             ActionPlanner.plan("EXACT ONE", action_planner: @planner)

    assert {:ok,
            %Effect{
              owner: @agent,
              scope: :agent,
              name: :one,
              payload: %{selected_tool: "Elixir.SpectreActionBoundaryContractTest.Actions.one/1"}
            }} =
             ActionPlanner.plan("EXACT ONE",
               action_planner: @planner,
               effect_owner: @agent,
               effect_scope: :agent
             )

    assert {:error, {:incomplete_effect_origin, {@agent, nil}}} =
             ActionPlanner.plan("EXACT ONE",
               action_planner: @planner,
               effect_owner: @agent
             )

    assert {:error, :planner_error} =
             ActionPlanner.plan("PLANNER ERROR", action_planner: @planner)

    assert {:error, {:invalid_action, :not_an_action}} =
             ActionPlanner.plan("NON MAP", action_planner: @planner)

    assert {:error, :planner_error} =
             ActionPlanner.plan_response("PLANNER ERROR",
               action_planner: @planner
             )

    assert {:error, {:invalid_action_planner_response, :invalid_response}} =
             ActionPlanner.plan_response("INVALID RESPONSE",
               action_planner: @planner
             )

    assert {:error, {:invalid_planned_action, 0, {:invalid_action, :not_an_action}}} =
             ActionPlanner.plan_response("visible MALFORMED ACTION",
               action_planner: @planner
             )

    assert {:ok, %{reply_text: "visible", effects: [first, second]}} =
             ActionPlanner.plan_response(
               "visible VALID CHAIN",
               action_planner: @planner,
               effect_owner: @agent,
               effect_scope: :agent
             )

    assert first.owner == @agent
    assert second.owner == @agent
    assert first.payload.al == "EXACT ONE"
    assert second.payload.al == "EXACT TWO"
  end

  test "dispatcher resolves registered providers and preserves idempotency" do
    one = effect(:one, %{value: 1})
    assert {:ok, {:one, %{value: 1}}} = ActionDispatcher.dispatch(one, %{agent: @agent})

    two = effect(:two, %{value: 2})

    assert {:ok, {:two, %{value: 2}}} =
             ActionDispatcher.dispatch(two, %Context{agent: @agent, input: Input.new("")},
               test_pid: self()
             )

    assert_receive {:two, %{value: 2}, opts}
    assert opts[:effect_id] == two.id
    assert opts[:idempotency_key] == Effect.idempotency_key(two)

    three_spec = Spec.new(%{name: :three, via: :local, schema: %{arity: 3}})

    three = effect(:three, %{}, schema_hash: three_spec.schema_hash)

    assert {:error, {:unsupported_action_arity, @actions, :three, 3}} =
             ActionDispatcher.dispatch(three, %{agent: @agent})

    assert {:error, {:unknown_action_provider, :missing}} =
             ActionDispatcher.dispatch(effect(:one, %{}, via: :missing), %{agent: @agent})

    assert {:error, {:unknown_action_provider, :local}} =
             ActionDispatcher.dispatch(effect(:one, %{}), %{
               agent: SpectreActionBoundaryContractTest.NoActionsAgent
             })

    assert {:error, {:undefined_action, @actions, :missing}} =
             ActionDispatcher.dispatch(effect(:missing, %{}), %{agent: @agent})
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

  test "action protection uses canonical provider/name refs and normalized legacy metadata" do
    agent = SpectreActionBoundaryContractTest.ProtectionAgent

    assert :confirm_one ==
             ActionProtection.protected_by(
               agent,
               Effect.stage_action(%{name: :one}, agent, :agent)
             )

    assert is_nil(
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
           )

    remote =
      {:remote, :remote_one}
      |> Spectre.Action.new()
      |> Spectre.Action.to_effect_attrs()
      |> Effect.stage_action(agent, :agent)

    assert ActionProtection.protected_by(agent, remote) == :confirm_remote

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

  defp effect(name, args, opts \\ []) do
    name
    |> Spectre.Action.new(
      via: Keyword.get(opts, :via, :local),
      args: args,
      schema_hash: Keyword.get(opts, :schema_hash)
    )
    |> Spectre.Action.to_effect_attrs()
    |> Effect.stage_action(@agent, :agent)
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
