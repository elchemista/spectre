defmodule Mix.Tasks.Spectre.Gen.Agent do
  @moduledoc """
  Generates a minimal Spectre Agent and its contract test.

      mix spectre.gen.agent MyApp.SupportAgent
      mix spectre.gen.agent MyApp.SupportAgent --server

  Files are never overwritten unless `--force` is passed. `--dry-run` performs
  validation and prints the complete plan without changing the filesystem.

  ## Options

    * `--dry-run` - print the files that would be generated;
    * `--force` - replace existing regular files.
    * `--server` - generate a declarative Agent, a separate OTP Server and a runtime test.
  """

  use Mix.Task

  alias Mix.Tasks.Spectre.Gen.Support

  @shortdoc "Generate a Spectre Agent and test"
  @usage "expected: mix spectre.gen.agent MyApp.SupportAgent [--server] [--dry-run] [--force]"
  @templates [
    {"spectre.gen.agent/agent.ex.eex", "lib/<%= @module_path %>.ex"},
    {"spectre.gen.agent/agent_test.exs.eex", "test/<%= @module_path %>_test.exs"}
  ]
  @server_templates [
    {"spectre.gen.agent/server_agent.ex.eex", "lib/<%= @module_path %>.ex"},
    {"spectre.gen.agent/server.ex.eex", "lib/<%= @server_path %>.ex"},
    {"spectre.gen.agent/server_agent_test.exs.eex", "test/<%= @module_path %>_test.exs"}
  ]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [server: :boolean, dry_run: :boolean, force: :boolean])

    if invalid != [], do: Mix.raise("invalid options\n\n#{@usage}")

    if Keyword.get(opts, :server, false) do
      module =
        case args do
          [name] -> name
          _ -> Mix.raise(@usage)
        end

      server =
        if String.ends_with?(module, "Agent"),
          do: String.replace_suffix(module, "Agent", "Server"),
          else: module <> "Server"

      server_path = server |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)
      argv = Enum.reject(argv, &(&1 in ["--server", "--no-server"]))
      Support.generate!(argv, @usage, @server_templates, server: server, server_path: server_path)
    else
      Support.generate!(Enum.reject(argv, &(&1 == "--no-server")), @usage, @templates)
    end
  end
end
