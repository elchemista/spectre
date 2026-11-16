defmodule Spectre.ServerRegexCacheTest do
  use ExUnit.Case, async: true

  test "explicit regex remains hard evidence when a cache proposes another route" do
    agent = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(agent)} do
      use Spectre.Agent, server: MyApp.Server
      router strategies: [:regex, :intent_dataset]
      flow :memory do
        on :map, regex: ~r/^mappa memoria$/
        on :recall
      end
    end
    """)

    test_pid = self()

    cache = fn _text, opts ->
      send(test_pid, {:cache_called, opts[:semantic_search?]})
      {:ok, %{label: :recall, accepted?: true, confidence: 1.0, margin: 1.0}}
    end

    assert {:ok, {:memory, :map}, %{route: %{strategy: :regex}, candidates: candidates}} =
             Spectre.Server.Router.route(agent, "mappa memoria", semantic_lookup: cache)

    assert Enum.any?(candidates, &(&1.provider == :regex and &1.strength == :hard))
    refute_receive {:cache_called, true}
  end
end
