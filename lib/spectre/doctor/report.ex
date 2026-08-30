defmodule Spectre.Doctor.Report do
  @moduledoc "Contract-v1 privacy-safe result returned by `Spectre.Doctor`."

  @enforce_keys [:contract_version, :spectre_version, :status, :checks, :summary]
  defstruct [:contract_version, :spectre_version, :status, :checks, :summary]

  @type t :: %__MODULE__{}

  @doc "Returns the stable JSON-safe contract-v1 map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = report) do
    %{
      contract_version: report.contract_version,
      spectre_version: report.spectre_version,
      status: Atom.to_string(report.status),
      summary: report.summary,
      checks: Enum.map(report.checks, &check_map/1)
    }
  end

  @doc "Formats a report as terminal text or JSON."
  @spec format(t(), :text | :json) :: String.t()
  def format(report, format \\ :text)

  def format(%__MODULE__{} = report, :json),
    do: report |> to_map() |> Spectre.JSON.encode!(pretty: true)

  def format(%__MODULE__{} = report, :text) do
    data = to_map(report)
    lines = Enum.map_join(data.checks, "\n", &check_line/1)
    summary = data.summary

    """
    Spectre doctor #{data.spectre_version}: #{data.status}
    #{lines}

    Summary: #{summary.passed} passed, #{summary.warnings} warnings, #{summary.errors} errors, #{summary.skipped} skipped
    """
    |> String.trim()
  end

  @doc "Returns whether the report should produce a successful command exit."
  @spec acceptable?(t(), keyword()) :: boolean()
  def acceptable?(%__MODULE__{} = report, opts \\ []) do
    report.summary.errors == 0 and (opts[:strict] != true or report.summary.warnings == 0)
  end

  defp check_map(check) do
    %{
      id: check.id,
      status: Atom.to_string(check.status),
      code: Atom.to_string(check.code),
      summary: check.summary,
      details: safe(check.details)
    }
  end

  defp safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp safe(value) when is_atom(value), do: Atom.to_string(value)
  defp safe(value) when is_list(value), do: Enum.map(value, &safe/1)

  defp safe(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {safe_key(key), safe(item)} end)

  defp safe(_value), do: "<redacted>"
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(_key), do: "redacted_key"

  defp check_line(check) do
    status = check.status |> String.upcase() |> String.pad_trailing(7)

    suffix =
      if map_size(check.details) == 0, do: "", else: " #{Spectre.JSON.encode!(check.details)}"

    "#{status} #{check.id} [#{check.code}] #{check.summary}#{suffix}"
  end
end
