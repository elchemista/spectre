defmodule Mix.Tasks.Spectre.Routes do
  @moduledoc """
  Displays an Agent's resolved routing destinations, including mounted Skills.

      mix spectre.routes MyApp.SupportAgent
      mix spectre.routes MyApp.SupportAgent --json

  This reports declared destinations. Arbitrary Elixir guards in a Server's
  callbacks still require behavior tests; the task does not claim static
  coverage of every possible callback clause.
  """
  use Mix.Task

  @shortdoc "Show Agent intents, scoped flows and Server destinations"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: [json: :boolean])

    if invalid != [] or length(args) != 1,
      do: Mix.raise("expected: mix spectre.routes MyApp.Agent [--json]")

    Mix.Task.run("compile")
    agent = args |> hd() |> String.split(".") |> Module.concat()
    definition = Spectre.Definition.fetch!(agent)
    server = Keyword.get(definition.config, :server)

    routes =
      Enum.map(Spectre.Definition.rules(agent), fn attrs ->
        rule = Spectre.Rule.new(attrs)

        %{
          intent: Atom.to_string(rule.label),
          flow_path: Enum.map(rule.flow_path, &Atom.to_string/1),
          scope: inspect(rule.scope),
          server: if(server, do: inspect(server)),
          dispatch:
            rule
            |> Spectre.Route.from_rule(:declared, nil)
            |> Spectre.Server.Router.dispatch_key()
            |> inspect(),
          handler: rule.handler |> elem(0) |> Atom.to_string(),
          protected: Keyword.get(rule.opts, :protected, false)
        }
      end)

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Spectre.JSON.encode!(routes, pretty: true))
    else
      Mix.shell().info(
        "#{inspect(agent)} → #{if(server, do: inspect(server), else: "legacy runtime")}"
      )

      Enum.each(routes, &print_route/1)
    end

    :ok
  end

  defp print_route(route) do
    flow = if route.flow_path == [], do: "(global)", else: Enum.join(route.flow_path, "/")
    destination = if route.handler == "server", do: "handle_flow/3", else: route.handler

    Mix.shell().info(
      "#{route.scope} #{flow} #{route.intent} → #{destination} #{route.dispatch} protected=#{route.protected}"
    )
  end
end
