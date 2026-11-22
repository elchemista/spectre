defmodule Spectre.StackFlowPortsTest do
  use ExUnit.Case, async: true

  alias Spectre.Flow.Port
  alias Spectre.Server.Router

  defmodule Read do
    use Spectre.Flow.Port

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
