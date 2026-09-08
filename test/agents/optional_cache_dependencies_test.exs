defmodule Spectre.AgentsTest.OptionalCacheDependenciesTest do
  use ExUnit.Case, async: true

  test "native search and embedding dependencies are confined to the test environment" do
    dependencies = Mix.Project.config()[:deps]
    {:ok, applications} = :application.get_key(:spectre, :applications)

    for name <- [:vettore, :ex_fastembed] do
      dependency = Enum.find(dependencies, &(elem(&1, 0) == name))
      options = elem(dependency, tuple_size(dependency) - 1)
      assert options[:only] == :test
      assert options[:runtime] == false
      refute name in applications
    end
  end

  test "Spectre and its Exact cache run without either optional dependency on the code path" do
    # A separate VM proves absence without purging dependencies used by other
    # tests. Only Spectre and its runtime dependency are added to Elixir's path.
    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Application.app_dir(:spectre, "ebin"),
          "-pa",
          Application.app_dir(:uuid_v7, "ebin"),
          Path.expand("../../scripts/check_optional_runtime.exs", __DIR__)
        ],
        env: [{"ERL_LIBS", nil}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "optional backends absent; Spectre available"
  end
end
