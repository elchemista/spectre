defmodule Spectre.StackFlowPortsTest do
  use ExUnit.Case, async: true

  alias Spectre.Flow.Port
  alias Spectre.Server.Router

  defmodule Read do
    use Spectre.Flow.Port

    @server_helpers Keyword.get(__ENV__.functions, Spectre.Server, [])
    def server_helpers, do: @server_helpers

    @impl true
    def routes, do: [on(:read, regex: ~r/^show (?<id>D[0-9]+)$/i)]

    @impl true
    def handle_flow(:read, _input, ctx), do: ctx
  end

  defmodule ListDocuments do
    use Spectre.Flow.Port

    @impl true
    def routes, do: [on(:list, regex: ~r/^list documents$/i)]

    @impl true
    def handle_flow(:list, _input, ctx), do: ctx

    @impl true
    def handle_result(_tag, _result, ctx), do: respond(ctx, "Catalog fallback")
  end

  defmodule Documents do
    use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

    @impl true
    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.flow(:browse, Read)
    end
  end

  defmodule Catalog do
    use Spectre.Stack.Installable, id: :catalog, version: "1.0.0"

    @impl true
    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.flow(:search, Read)
      |> Spectre.Integration.flow(:inventory, ListDocuments)
    end
  end

  defmodule Empty do
    use Spectre.Stack.Installable, id: :empty, version: "1.0.0"
  end

  defmodule Stack do
    use Spectre.Stack

    install(Documents, as: :library)
    install(Catalog)
    install(Empty)
  end

  defmodule Root do
    use Spectre.Server
  end

  defmodule EmptyRoutes do
    def routes, do: []
    def handle_flow(_key, _input, ctx), do: ctx
  end

  defmodule MalformedRoutes do
    def routes, do: [:read]
    def handle_flow(_key, _input, ctx), do: ctx
  end

  defmodule PrivateAgent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])
  end

  defmodule PublicAgent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])

    expose(:library)
    expose(flows: [{:catalog, :inventory}])
  end

  test "a Flow imports callback commands and leaves host calls explicit" do
    helpers = Read.server_helpers()

    for helper <- [call_tool: 4, respond: 2, signal_activity: 4, cancel_activity: 3] do
      assert helper in helpers
    end

    for host_call <- [start_link: 1, input: 3, reset: 2, status: 1, deliver: 4] do
      refute host_call in helpers
    end
  end

  test "a Flow can own the fallback for all continuation tags" do
    assert %{commands: [%{kind: :respond, args: ["Catalog fallback"]}]} =
             ListDocuments.handle_result(:unmatched, :any, %Spectre.Server.Context{})
  end

  test "Flow registration rejects incomplete modules and malformed route declarations" do
    alias Spectre.Integration

    assert_raise ArgumentError, ~r/invalid Stack flow module/, fn ->
      Integration.flow(Integration.new(), :browse, Root)
    end

    assert_raise ArgumentError, ~r/invalid routes .*\[\]/, fn ->
      Integration.flow(Integration.new(), :browse, EmptyRoutes)
    end

    assert_raise ArgumentError, ~r/invalid Stack flow route: :read/, fn ->
      Integration.flow(Integration.new(), :browse, MalformedRoutes)
    end

    for {label, options} <- [{"read", []}, {:read, [:not_keyword_options]}] do
      assert_raise ArgumentError, ~r/invalid Stack flow route/, fn -> Port.on(label, options) end
    end
  end

  test "an imported Flow binding must contain well-formed portable routes" do
    assert_raise ArgumentError, ~r/invalid Stack flow binding/, fn ->
      Port.validate!(%{module: Read, routes: []})
    end

    for route <- [:read, {:read, []}, {:read, [regex: [{:not_source_text, []}]]}] do
      assert_raise ArgumentError, ~r/invalid Stack flow route/, fn ->
        Port.validate!(%{module: Read, routes: [route]})
      end
    end

    assert_raise ArgumentError, ~r/invalid Stack flow route/, fn ->
      Port.rule_options!(:read)
    end
  end

  test "installation alone does not change the visible routes" do
    assert PrivateAgent.__spectre_rules__() == []
    assert {:unmatched, _} = Router.route(PrivateAgent, "show D12")
  end

  test "agents expose an installation's single flow or a selected scope" do
    assert {:ok, {:browse, :read}, %{route: read}} = Router.route(PublicAgent, "SHOW D12")
    assert Port.owner(read) == {:library, :browse, Read}

    assert {:ok, {:inventory, :list}, %{route: list}} =
             Router.route(PublicAgent, "list documents")

    assert Port.owner(list) == {:catalog, :inventory, ListDocuments}
    refute Enum.any?(PublicAgent.__spectre_rules__(), &(&1.flow == :search))
  end

  test "unknown, missing and ambiguous exposures have compile diagnostics" do
    assert_raise ArgumentError, ~r/unknown flow installation :missing/, fn ->
      compile_agent(NoInstallation, quote(do: expose(:missing)))
    end

    assert_raise ArgumentError, ~r/installation :empty has no flows/, fn ->
      compile_agent(NoFlows, quote(do: expose(:empty)))
    end

    assert_raise ArgumentError, ~r/multiple flows in :catalog/, fn ->
      compile_agent(Ambiguous, quote(do: expose(:catalog)))
    end

    assert_raise ArgumentError, ~r/unknown installed flow \{:catalog, :missing\}/, fn ->
      compile_agent(NoScope, quote(do: expose(flows: [{:catalog, :missing}])))
    end
  end

  test "overlapping selections and duplicate labels cannot take ownership of a route" do
    assert_raise ArgumentError, ~r/duplicate exposed flow \{:library, :browse\}/, fn ->
      compile_agent(
        DuplicateScope,
        quote do
          expose(:library)
          expose(flows: [{:library, :browse}])
        end
      )
    end

    assert_raise ArgumentError, ~r/duplicate_rule_label, :read/, fn ->
      compile_agent(
        DuplicateLabel,
        quote do
          expose(:library)
          expose(flows: [{:catalog, :search}])
        end
      )
    end
  end

  defp compile_agent(module, body) do
    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Spectre.Agent, stack: unquote(Stack), server: unquote(Root)
          unquote(body)
        end
      end
    )
  end
end
