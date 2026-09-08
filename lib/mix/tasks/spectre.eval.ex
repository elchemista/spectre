defmodule Mix.Tasks.Spectre.Eval do
  @moduledoc """
  Evaluates a compiled flow against JSONL routing expectations without starting an application.

      mix spectre.eval MyApp.Hello test/my_app/hello_routes.jsonl --flow greetings

  `--flow` is required; no flow is selected implicitly. `--max-cases` (10,000)
  and `--max-failures` (20) bound evaluation and retained diagnostics. Any
  mismatch or malformed dataset fails the command for use in CI.

  This CLI uses the flow's built-in methods. For custom methods, pipelines,
  semantic caches or recorded classifier results, use `Spectre.Eval` with the
  host's explicitly prepared routing plan/function. No wiring, credentials,
  model downloads or application startup are inferred by this task.
  """
  use Mix.Task
  @shortdoc "Check routing regressions from JSONL without running an agent"
  alias Spectre.Eval

  @impl Mix.Task
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args,
        strict: [flow: :string, max_cases: :integer, max_failures: :integer]
      )

    case {positional, opts[:flow]} do
      {[name, path], flow} when is_binary(flow) ->
        Mix.Task.run("compile")
        module = existing_module(name)
        run_eval(module, flow, path, Keyword.delete(opts, :flow))

      _other ->
        Mix.raise("usage: mix spectre.eval MyApp.Agent cases.jsonl --flow greetings")
    end
  end

  defp existing_module(name) do
    normalized = "Elixir." <> String.trim_leading(name, "Elixir.")

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> Mix.raise("unknown compiled authoring module")
    end
  end

  defp run_eval(module, flow, path, opts) do
    with {:ok, prepared} <- Eval.prepare(module, flow),
         {:ok, report} <- Eval.run_file(prepared, path, opts) do
      Mix.shell().info(
        "Routing: #{report.passed}/#{report.total} passed; #{report.failed} failed"
      )

      for failure <- report.failures do
        Mix.shell().error(
          "line #{failure.case}: expected #{inspect(failure.expected)}, got #{inspect(failure.actual)}"
        )
      end

      if report.failed > 0, do: Mix.raise("routing regression: #{report.failed} mismatch(es)")
    else
      {:error, reason} -> Mix.raise("cannot evaluate routing: #{inspect(reason)}")
    end
  end
end
