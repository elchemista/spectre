defmodule Mix.Tasks.Spectre.Gen.Installable do
  @moduledoc """
  Generates a minimal Stack-installable Spectre package and conformance test.

      mix spectre.gen.installable MyApp.SupportPackage

  Files are never overwritten unless `--force` is passed. `--dry-run`
  validates the complete generation plan without changing the filesystem.

  ## Options

    * `--dry-run` - print the files that would be generated;
    * `--force` - replace existing regular files.
  """

  use Mix.Task

  alias Mix.Tasks.Spectre.Gen.Support

  @shortdoc "Generate a Stack-installable Spectre package and test"
  @usage "expected: mix spectre.gen.installable MyApp.SupportPackage [--dry-run] [--force]"
  @templates [
    {"spectre.gen.installable/installable.ex.eex", "lib/<%= @module_path %>.ex"},
    {"spectre.gen.installable/installable_test.exs.eex", "test/<%= @module_path %>_test.exs"}
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv), do: Support.generate!(argv, @usage, @templates)
end
