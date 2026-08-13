defmodule Mix.Tasks.Spectre.Doctor do
  @moduledoc "Runs read-only Spectre diagnostics in text or JSON form."

  use Mix.Task

  alias Spectre.Doctor
  alias Spectre.Doctor.Report

  @shortdoc "Check Spectre runtime contracts"
  @switches [agent: :string, format: :string, strict: :boolean]

  @impl Mix.Task
  @doc false
  @spec run([String.t()]) :: :ok | no_return()
  def run(argv) do
    Mix.Task.run("app.config")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if args != [] or invalid != [], do: fail("invalid_arguments", "invalid arguments")

    format = format!(opts[:format] || "text")
    agent = agent!(opts[:agent])
    doctor_opts = if agent, do: [agent: agent], else: []

    report =
      case Doctor.run(doctor_opts) do
        {:ok, report} -> report
        _error -> fail("invalid_options", "invalid doctor options")
      end

    Mix.shell().info(Report.format(report, format))
    enforce!(report, opts[:strict] == true)
    :ok
  end

  defp format!("text"), do: :text
  defp format!("json"), do: :json
  defp format!(_format), do: fail("invalid_format", "expected --format text or json")

  defp agent!(nil), do: nil

  defp agent!(name) do
    parts =
      name
      |> String.trim()
      |> String.trim_leading("Elixir.")
      |> String.split(".", trim: true)

    if parts != [] and Enum.all?(parts, &Regex.match?(~r/^[A-Z][A-Za-z0-9_]*$/, &1)) do
      module = Module.safe_concat(parts)

      if Code.ensure_loaded?(module),
        do: module,
        else: fail("invalid_agent", "agent is unavailable")
    else
      fail("invalid_agent", "agent is unavailable")
    end
  rescue
    _exception -> fail("invalid_agent", "agent is unavailable")
  end

  defp enforce!(report, strict?) do
    unless Report.acceptable?(report, strict: strict?) do
      code = if report.summary.errors == 0 and strict?, do: "strict_failed", else: "failed"
      fail(code, "checks did not pass")
    end
  end

  defp fail(code, message), do: Mix.raise("[spectre_doctor_#{code}] #{message}")
end
