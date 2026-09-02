defmodule Mix.Tasks.Spectre.Doctor do
  @shortdoc "Checks Spectre's declared governance boundary"

  @moduledoc """
  Runs the Spectre boundary and Zone M dependency checks.

  Application-specific modules and records can be supplied through:

      config :spectre, :doctor,
        mind_modules: [MyApp.AgentMind],
        executor_modules: [MyApp.PaymentExecutor],
        ingress: MyApp.Ingress,
        store: {Spectre.Ledger.Store.Postgres, repo: MyApp.Repo},
        genesis: genesis,
        host_profile: host_profile,
        surface: surface

  The static result is evidence about ordinary compiled dependencies, not proof
  of process or machine isolation.
  """

  use Mix.Task

  alias Spectre.Doctor

  @impl Mix.Task
  def run(argv) do
    if argv != [], do: Mix.raise("spectre.doctor does not accept command-line arguments")

    Mix.Task.run("compile")
    opts = Application.get_env(:spectre, :doctor, [])
    report = Doctor.check(opts)

    Enum.each(report.warnings, fn finding ->
      Mix.shell().info([:yellow, "warning: ", :reset, format_finding(finding)])
    end)

    Enum.each(report.errors, fn finding ->
      Mix.shell().error(["error: ", format_finding(finding)])
    end)

    if report.ok? do
      Mix.shell().info([:green, "Spectre doctor passed", :reset])
    else
      Mix.raise("Spectre doctor found #{length(report.errors)} error(s)")
    end
  end

  defp format_finding(%{check: check, reason: reason}),
    do: "#{check}: #{inspect(reason)}"
end
