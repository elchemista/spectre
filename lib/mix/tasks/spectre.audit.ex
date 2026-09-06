defmodule Mix.Tasks.Spectre.Audit do
  @shortdoc "Independently verifies a canonical Spectre Domain export"

  @moduledoc """
  Verifies a self-contained export without starting or consulting its Domain:

      mix spectre.audit path/to/domain.spectre

  By default the semantic state is checked at the trusted capture time stored
  in the export. A later trusted time can be supplied to expose Duties that
  became due after capture. These causes are reported separately from recorded
  open Duties; missing materializations already required at capture still fail
  the audit. This does not query the live Domain or predict later world events:

      mix spectre.audit path/to/domain.spectre --at 1735689600000

  `--max-bytes` bounds both the file read and canonical decoder. The default is
  256 MiB.
  """

  use Mix.Task

  alias Spectre.Audit.Export

  @default_max_bytes 256 * 1_024 * 1_024
  @switches [at: :integer, max_bytes: :integer]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")

    with {opts, [path], []} <- OptionParser.parse(argv, strict: @switches),
         {:ok, max_bytes} <- max_bytes(opts),
         {:ok, encoded} <- read_bounded(path, max_bytes),
         {:ok, report} <-
           Export.verify(encoded, Keyword.get(opts, :at), max_bytes: max_bytes) do
      print_report(report)
    else
      {_opts, positional, invalid} ->
        Mix.raise(
          "usage: mix spectre.audit EXPORT [--at MILLISECONDS] [--max-bytes BYTES]; " <>
            "received #{inspect(positional ++ invalid)}"
        )

      {:error, reason} ->
        Mix.raise("Spectre audit failed: #{inspect(reason)}")
    end
  end

  defp max_bytes(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_max_bytes, value}}
    end
  end

  defp read_bounded(path, max_bytes) when is_binary(path) and path != "" do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         true <- stat.size <= max_bytes,
         {:ok, encoded} <- File.read(path) do
      {:ok, encoded}
    else
      false -> {:error, {:audit_export_not_regular_or_too_large, path, max_bytes}}
      {:error, reason} -> {:error, {:audit_export_unreadable, path, reason}}
    end
  end

  defp print_report(report) do
    Mix.shell().info([:green, "Spectre audit passed", :reset])
    Mix.shell().info("domain: #{report.domain_ref}")
    Mix.shell().info("revision: #{report.ledger_revision}")
    Mix.shell().info("head: #{report.head_digest}")
    Mix.shell().info("captured at: #{report.captured_at}")
    Mix.shell().info("audited at: #{report.audited_at}")
    Mix.shell().info("acts: #{report.counts.acts}")
    Mix.shell().info("attempts: #{report.counts.attempts}")
    Mix.shell().info("open duties: #{length(report.open_duties)}")
    Mix.shell().info("pending duty causes: #{length(report.pending_duty_causes)}")
    Mix.shell().info("expired dispatches: #{length(report.expired_dispatches)}")
  end
end
