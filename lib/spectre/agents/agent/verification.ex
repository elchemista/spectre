defmodule Spectre.Agent.Verification do
  @moduledoc false

  # This is an authoring diagnostic, not another admission path. Checks only
  # use immutable declarations; no Scope, Mandate, clock or provider is read.
  alias Spectre.Agent.Declaration
  alias Spectre.Consequence.Contract
  alias Spectre.{Definition, Row, Surface}

  @static_fields [
    :class,
    :row,
    :consequence,
    :subject_refs,
    :target_refs,
    :disclosure,
    :meter_requests
  ]
  @unchecked %{checked: [], deferred: @static_fields, errors: []}

  @doc "Checks immutable template data only; absent occurrence facts remain deferred."
  @spec verify(Surface.t(), Definition.t()) ::
          {:ok, Surface.definition_report()} | {:error, term()}
  def verify(surface, definition) do
    with {:ok, surface} <- Surface.new(surface),
         {:ok, definition} <- Definition.new(definition),
         {:ok, declaration} <- Declaration.read(definition) do
      reports =
        Map.new(declaration.templates, fn {name, data} -> {name, check(surface, data)} end)

      report = %{surface_ref: surface.ref, definition_ref: definition.ref, templates: reports}

      if Enum.all?(reports, fn {_name, item} -> item.errors == [] end),
        do: {:ok, report},
        else: {:error, {:definition_surface_mismatch, report}}
    end
  end

  # Definition bodies are intentionally portable data. Declaration.read/1
  # validates that grammar once; no atom/string guessing belongs in this walk.
  @spec check(Surface.t(), map()) :: Surface.template_check()
  defp check(surface, %{"class" => class} = data) do
    case Surface.classify(surface, class) do
      {:ok, row} ->
        @unchecked
        |> record([:class], :ok)
        |> check_row(data, row)
        |> check_consequence(data, Map.get(surface.consequence_contracts, class))

      {:error, reason} ->
        record(@unchecked, [:class], {:error, {reason, class}})
    end
  end

  defp check(_surface, _data), do: @unchecked

  defp check_row(report, data, row) do
    case Map.fetch(data, "row") do
      :error -> report
      {:ok, declared} -> record(report, [:row], match_row(declared, row))
    end
  end

  defp match_row(declared, row) do
    if declared === Row.canonical(row),
      do: :ok,
      else: {:error, :candidate_row_mismatch}
  end

  # Intrinsic classes need actual governed state to validate their consequence.
  # No dummy Candidate, fake authority or incomplete State is manufactured here.
  defp check_consequence(report, _data, nil), do: report

  defp check_consequence(report, data, contract) do
    case Map.fetch(data, "consequence") do
      :error ->
        report

      {:ok, consequence} ->
        boundary = boundary(data)
        fields = Enum.map(Map.keys(boundary), &template_field/1)

        record(
          report,
          [:consequence | fields],
          Contract.validate_static(contract, consequence, boundary)
        )
    end
  end

  defp boundary(data) do
    boundary =
      for field <- [:subject_refs, :target_refs, :meter_requests],
          {:ok, value} <- [Map.fetch(data, Atom.to_string(field))],
          into: %{},
          do: {field, value}

    case Map.fetch(data, "disclosure") do
      :error -> boundary
      {:ok, nil} -> Map.put(boundary, :destination_refs, [])
      {:ok, value} -> Map.put(boundary, :destination_refs, value["destination_refs"])
    end
  end

  defp template_field(:destination_refs), do: :disclosure
  defp template_field(field), do: field

  defp record(report, fields, result) do
    errors =
      case result do
        :ok -> report.errors
        {:error, reason} -> report.errors ++ [reason]
      end

    %{
      checked: Enum.sort(report.checked ++ fields),
      deferred: report.deferred -- fields,
      errors: errors
    }
  end
end
