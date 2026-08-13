defmodule Mix.Tasks.Spectre.Gen.Agent do
  @moduledoc """
  Generates a minimal Spectre Agent and its contract test.

      mix spectre.gen.agent MyApp.SupportAgent

  Files are never overwritten unless `--force` is passed. `--dry-run` performs
  validation and prints the complete plan without changing the filesystem.

  ## Options

    * `--dry-run` - print the files that would be generated;
    * `--force` - replace existing regular files.
  """

  use Mix.Task

  alias Mix.Tasks.Spectre.Gen.Support

  @shortdoc "Generate a Spectre Agent and test"
  @usage "expected: mix spectre.gen.agent MyApp.SupportAgent [--dry-run] [--force]"
  @templates [
    {"spectre.gen.agent/agent.ex.eex", "lib/<%= @module_path %>.ex"},
    {"spectre.gen.agent/agent_test.exs.eex", "test/<%= @module_path %>_test.exs"}
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv), do: Support.generate!(argv, @usage, @templates)
end
