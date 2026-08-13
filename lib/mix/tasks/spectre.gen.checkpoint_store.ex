defmodule Mix.Tasks.Spectre.Gen.CheckpointStore do
  @moduledoc """
  Generates an in-memory Instance CheckpointStore adapter and conformance test.

      mix spectre.gen.checkpoint_store MyApp.SpectreCheckpointStore

  The generated adapter is intentionally process-local and intended for tests
  and development. Replace it with durable storage for production. Files are
  never overwritten unless `--force` is passed. `--dry-run` changes no files.

  ## Options

    * `--dry-run` - print the files that would be generated;
    * `--force` - replace existing regular files.
  """

  use Mix.Task

  alias Mix.Tasks.Spectre.Gen.Support

  @shortdoc "Generate an Instance CheckpointStore and test"
  @usage "expected: mix spectre.gen.checkpoint_store MyApp.SpectreCheckpointStore [--dry-run] [--force]"
  @templates [
    {"spectre.gen.checkpoint_store/checkpoint_store.ex.eex", "lib/<%= @module_path %>.ex"},
    {"spectre.gen.checkpoint_store/checkpoint_store_test.exs.eex",
     "test/<%= @module_path %>_test.exs"}
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv), do: Support.generate!(argv, @usage, @templates)
end
