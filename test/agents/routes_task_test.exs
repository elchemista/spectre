defmodule Spectre.Agents.RoutesTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Spectre.Routes, as: RoutesTask

  defmodule OfflineAdapter do
    use Spectre.Router.Adapter

    @impl true
    def evaluate(_request, _opts), do: raise("routing must not execute during inspection")
  end

  defmodule OrdersRouter do
    use Spectre.Router

    flow :orders do
      pipe_through(:normalize)
      router(via: [:regex, :binary], accept: 0.85, margin: 0.05)
      route(:lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u])
      route(:help, match: [binary: "PRIVATE_MATCHER_INPUT"])
    end
  end

  defmodule Faq do
    use Spectre.Skill, namespace: "routes-cli", name: "faq"

    flow :questions do
      router(via: [:string_bag])
      route(:hours, match: [string_bag: ["opening hours"]])
    end
  end

  defmodule Support do
    use Spectre.Agent, namespace: "routes-cli", name: "support"

    router(OrdersRouter)
    skill(Faq, as: :faq)
    adapter(:router, :binary, OfflineAdapter, credential: "PRIVATE_CREDENTIAL")
    prompt(:safety, "PRIVATE_PROMPT_CONTENT")
    inject(:safety, position: :start)
    classifier(:intent, class: "model.classify", via: :inference)
    semantic_cache(:routing, learn: :review)

    flow :intent do
      router(via: [:semantic_cache, :llm_classifier], cache: :routing, classifier: :intent)
      route(:refund, cache: true, classify: true, inject: :safety)
    end

    flow :unrouted do
      pipe_through(:normalize)
    end
  end

  defmodule PlainAgent do
    use Spectre.Agent, namespace: "routes-cli", name: "plain"
  end

  # Faults in declaration callbacks are not failures to resolve a module name.
  defmodule BrokenSources do
    defdelegate __spectre_plan__(), to: PlainAgent
    def __spectre_sources__, do: raise(ArgumentError, "source metadata is invalid")
  end

  defmodule BrokenPorts do
    defdelegate __spectre_plan__(), to: PlainAgent
    defdelegate __spectre_sources__(), to: PlainAgent
    def ports, do: raise(ArgumentError, "port declaration is invalid")
  end

  defmodule BrokenPlan do
    def __spectre_plan__, do: raise(ArgumentError, "compiled plan is invalid")
  end

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "compiled flows show method order, thresholds, pipelines and source location" do
    output = routes(Support)

    assert output =~
             ~s|orders (#{inspect(Support)}) via=["regex", "binary"] accept=0.85 margin=0.05 pipelines=["normalize"]|

    assert output =~ ~s(lookup -> handle_turn {:orders, :lookup, captures}; methods=["regex"])
    assert output =~ ~r/routes_task_test.exs:\d+ \(.*OrdersRouter\)/
    assert output =~ "common injections: [%{"
    assert output =~ "prompt: :safety"
    assert output =~ "    injections: [%{"
  end

  test "mounted skills show qualified paths but retain local handler atoms" do
    output = routes(Support)
    assert output =~ "faq/questions (#{inspect(Faq)})"

    assert output =~
             ~s(hours -> handle_turn {:questions, :hours, captures}; methods=["string_bag"])

    refute output =~ "{:faq/questions,"
  end

  test "cache and classifier inspection describes the boundary without calling a provider" do
    output = routes(Support)
    assert output =~ ~s(via=["semantic_cache", "llm_classifier"])

    assert output =~
             "classifier: consumes an observed result; no provider call during routing"

    assert output =~ ~s(methods=["llm_classifier", "local_classifier", "semantic_cache"])
    assert output =~ "required ports:"
    assert output =~ "router/binary"

    for private <- ["PRIVATE_MATCHER_INPUT", "PRIVATE_CREDENTIAL", "PRIVATE_PROMPT_CONTENT"] do
      refute output =~ private
    end
  end

  test "flows without routing and agents without flows need no default matcher" do
    assert routes(Support) =~
             ~s|unrouted (#{inspect(Support)}) via=[] accept=nil margin=nil pipelines=["normalize"]|

    assert routes(PlainAgent) == "required ports: \n"
  end

  test "an extracted Router can be inspected with or without the Elixir prefix" do
    output = routes(OrdersRouter)
    assert output == routes(Atom.to_string(OrdersRouter))
    refute output =~ "classifier:"
    assert output =~ "required ports: pipelines/normalize, router/binary\n"
  end

  test "unknown names fail without interning a new atom" do
    name = "Elixir.Spectre.UnknownRoutes#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

    assert_raise Mix.Error, "unknown compiled authoring module", fn -> routes(name) end

    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "existing atoms that are not authoring modules get a different diagnostic" do
    # The second atom intentionally exists but has no loadable BEAM file.
    for module <- [String, Spectre.NotLoadedRoutesTaskModule] do
      assert_raise Mix.Error, "module has no compiled Spectre declarations", fn ->
        routes(module)
      end
    end
  end

  test "invalid arguments print usage instead of attempting a module lookup" do
    for args <- [[], ["Support", "extra"]] do
      assert_raise Mix.Error, "usage: mix spectre.routes MyApp.Agent", fn ->
        RoutesTask.run(args)
      end
    end
  end

  test "errors inside declaration callbacks retain their real cause" do
    for {module, message} <- [
          {BrokenPlan, "compiled plan is invalid"},
          {BrokenSources, "source metadata is invalid"},
          {BrokenPorts, "port declaration is invalid"}
        ] do
      assert_raise ArgumentError, message, fn -> routes(module) end
    end
  end

  defp routes(module) when is_atom(module), do: routes(inspect(module))
  defp routes(name), do: capture_io(fn -> RoutesTask.run([name]) end)
end
