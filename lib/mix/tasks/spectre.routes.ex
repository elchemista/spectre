defmodule Mix.Tasks.Spectre.Routes do
  @moduledoc """
  Prints compiled flow/handler routes without starting a Domain or adapter.

      mix spectre.routes MyApp.SupportAgent

  Shows ordered methods, thresholds, pipelines, participating cache/classifier
  routes and their component owner. It never dumps prompt text, inputs, vectors,
  runtime options or credentials. LLM classification consumes an observed
  result; it does not call a model from the Router.
  """
  use Mix.Task
  @shortdoc "Inspect compiled agent routes and their origin"

  @impl Mix.Task
  def run([name]) do
    Mix.Task.run("compile")
    module = name |> String.trim_leading("Elixir.") |> then(&("Elixir." <> &1))

    try do
      module = String.to_existing_atom(module)

      if not Code.ensure_loaded?(module) or not function_exported?(module, :__spectre_plan__, 0),
        do: Mix.raise("module has no compiled Spectre declarations")

      print(module, module.__spectre_plan__(), "")

      Mix.shell().info(
        "required ports: " <> (module.ports() |> Map.keys() |> Enum.sort() |> Enum.join(", "))
      )
    rescue
      ArgumentError -> Mix.raise("unknown compiled authoring module")
    end
  end

  def run(_args), do: Mix.raise("usage: mix spectre.routes MyApp.Agent")

  defp print(module, plan, prefix) do
    sources = module.__spectre_sources__()

    for {name, flow} <- Enum.sort(plan.flows) do
      config = flow.routing || %{"via" => [], "accept" => nil, "margin" => nil}

      Mix.shell().info(
        "#{prefix}#{name} (#{inspect(module)}) via=#{inspect(config["via"])} " <>
          "accept=#{inspect(config["accept"])} margin=#{inspect(config["margin"])} pipelines=#{inspect(flow.pipelines)}"
      )

      source(Map.get(sources, {:flows, name}))
      Mix.shell().info("  common injections: #{inspect(plan.injections ++ flow.injections)}")

      if "llm_classifier" in config["via"],
        do:
          Mix.shell().info(
            "  classifier: consumes an observed result; no provider call during routing"
          )

      for {name, route} <- Enum.sort(flow.routes) do
        methods = route.rule["match"] |> Map.keys() |> Enum.sort()

        Mix.shell().info(
          "  #{name} -> handle_turn {#{inspect(flow.local)}, #{inspect(route.local)}, captures}; methods=#{inspect(methods)}"
        )

        source(Map.get(sources, {:route, to_string(flow.local), name}))

        if route.injections != [],
          do: Mix.shell().info("    injections: #{inspect(route.injections)}")
      end
    end

    for {name, child} <- Enum.sort(plan.components),
        do: print(child.module, child.plan, prefix <> name <> "/")
  end

  defp source(nil), do: :ok

  defp source(source),
    do: Mix.shell().info("  #{source.file}:#{source.line} (#{inspect(source.module)})")
end
