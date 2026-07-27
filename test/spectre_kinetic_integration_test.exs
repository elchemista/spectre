defmodule SpectreKineticIntegrationTest.KineticActions do
  @moduledoc false

  use SpectreKinetic

  @al ~s(CREATE PROJECT WITH: TITLE="Roadmap")
  @doc "Creates a project."
  @spec create_project(title :: String.t()) :: map()
  def create_project(title), do: %{created_project: title}
end

defmodule SpectreKineticIntegrationTest.KineticAgent do
  @moduledoc false

  use Spectre.Agent

  use Spectre.Kinetic,
    actions: SpectreKineticIntegrationTest.KineticActions,
    modes: [create_project: :write],
    top_k: 1,
    tool_threshold: 0.0,
    mapping_threshold: 0.0
end

defmodule SpectreKineticIntegrationTest.GenericProvider do
  @moduledoc false

  @behaviour Spectre.Action.Provider

  @open_issue_al ~s(OPEN ISSUE WITH: TITLE="Parser bug")

  @impl true
  def actions(_opts) do
    [
      %{
        name: :open_issue,
        description: "Opens an issue in a remote tracker.",
        mode: :write,
        schema: %{
          type: "object",
          properties: %{
            title: %{type: "string", aliases: ["SUBJECT"]}
          },
          required: ["title"]
        },
        metadata: %{examples: [@open_issue_al]}
      }
    ]
  end

  @impl true
  def execute(%Spectre.Action{name: :open_issue, args: args}, _ctx, opts) do
    %{
      opened_issue: Map.fetch!(args, "title"),
      provider_id: Keyword.fetch!(opts, :provider_id),
      namespace: Keyword.fetch!(opts, :namespace)
    }
  end
end

defmodule SpectreKineticIntegrationTest.GenericAgent do
  @moduledoc false

  use Spectre.Agent

  action_provider(
    {:remote, :issues},
    SpectreKineticIntegrationTest.GenericProvider,
    namespace: :integration
  )

  use Spectre.Kinetic,
    top_k: 1,
    tool_threshold: 0.0,
    mapping_threshold: 0.0
end

defmodule SpectreKineticIntegrationTest do
  use ExUnit.Case, async: false

  alias Spectre.Action.Provider
  alias Spectre.Action.Provider.Mount
  alias Spectre.Action.Spec
  alias Spectre.ActionConfig
  alias Spectre.ActionDispatcher
  alias Spectre.ActionPlanner
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.State

  alias SpectreKineticIntegrationTest.GenericAgent
  alias SpectreKineticIntegrationTest.KineticActions
  alias SpectreKineticIntegrationTest.KineticAgent

  @create_project_al ~s(CREATE PROJECT WITH: TITLE="Roadmap")
  @open_issue_al ~s(OPEN ISSUE WITH: TITLE="Parser bug")

  test "Kinetic mounts one planner and its local provider with a stable schema" do
    assert {Spectre.Kinetic.Planner, planner_opts} = ActionConfig.planner(KineticAgent)
    assert planner_opts[:top_k] == 1
    assert planner_opts[:tool_threshold] == 0.0
    assert planner_opts[:mapping_threshold] == 0.0

    assert [
             %Mount{
               id: :kinetic,
               module: Spectre.Kinetic.Actions,
               opts: provider_opts
             } = mount
           ] = ActionConfig.providers(KineticAgent)

    assert provider_opts[:module] == KineticActions
    assert provider_opts[:modes] == [create_project: :write]

    assert {:ok,
            [
              %Spec{
                name: :create_project,
                via: :kinetic,
                mode: :write,
                schema_hash: schema_hash
              } = spec
            ]} = Provider.actions(mount)

    assert is_binary(schema_hash)
    assert byte_size(schema_hash) == 64
    assert spec.metadata.kinetic
    assert @create_project_al in spec.metadata.examples
  end

  test "Kinetic plans and dispatches its annotated action provider" do
    ctx = context(KineticAgent)

    assert {:ok,
            %Effect{
              name: :create_project,
              mode: :write,
              status: :pending,
              owner: KineticAgent,
              scope: :agent
            } = effect} = ActionPlanner.plan(@create_project_al, ctx, planner_opts(ctx))

    assert Effect.via(effect) == :kinetic
    assert Effect.planned_by(effect) == Spectre.Kinetic.Planner
    assert is_binary(Effect.schema_hash(effect))
    assert effect.args == %{"title" => "Roadmap"}

    assert {:ok, %{created_project: "Roadmap"}} =
             ActionDispatcher.dispatch(effect, ctx)
  end

  test "Kinetic plans and dispatches an unrelated generic Spectre provider" do
    ctx = context(GenericAgent)

    assert [
             %Mount{
               id: {:remote, :issues},
               module: SpectreKineticIntegrationTest.GenericProvider
             }
           ] = ActionConfig.providers(GenericAgent)

    assert {:ok,
            %Effect{
              name: :open_issue,
              mode: :write,
              status: :pending,
              owner: GenericAgent
            } = effect} = ActionPlanner.plan(@open_issue_al, ctx, planner_opts(ctx))

    assert Effect.via(effect) == {:remote, :issues}
    assert effect.args == %{"title" => "Parser bug"}
    assert is_binary(Effect.schema_hash(effect))

    assert {:ok,
            %{
              opened_issue: "Parser bug",
              provider_id: {:remote, :issues},
              namespace: :integration
            }} = ActionDispatcher.dispatch(effect, ctx)
  end

  defp context(agent) do
    %Context{
      agent: agent,
      input: Input.new(""),
      state: %State{}
    }
  end

  defp planner_opts(ctx) do
    ActionConfig.planner_opts(ctx,
      effect_owner: ctx.agent,
      effect_scope: :agent
    )
  end
end
