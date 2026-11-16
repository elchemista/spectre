defmodule Spectre.Server.CollectionTest do
  use ExUnit.Case, async: true

  defmodule Model do
    def complete(_, _), do: {:ok, "DELETE"}
  end

  defmodule Dataset do
    def lookup(_, _), do: {:error, :miss}

    def put(text, result, opts) do
      send(opts[:test_pid], {:collected, text, result})
      :ok
    end
  end

  defmodule App do
    use Spectre.Server
  end

  defmodule Definition do
    use Spectre.Agent, server: App
    classifier(:llm, Model)
    router(strategies: [:llm_classifier], semantic_cache: Dataset)

    flow :support do
      on(:delete, protected: true, collect_intent: true)
    end
  end

  test "protected eligibility reads declarative route metadata and allows only explicit host opt-in" do
    assert {:ok, _, %{protected: true}} =
             Spectre.Server.Router.route(Definition, "delete my account", test_pid: self())

    refute_receive {:collected, _, _}

    assert {:ok, _, _} =
             Spectre.Server.Router.route(Definition, "delete my account",
               test_pid: self(),
               semantic_learn_protected?: true
             )

    assert_receive {:collected, "delete my account", _}, 2_000
  end
end
