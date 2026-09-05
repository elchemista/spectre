defmodule Spectre.Candidate.Template do
  @moduledoc """
  Partial, portable Candidate declaration shared by authoring tools.

  A template fixes only fields that the application knows in advance. Missing
  fields are supplied at materialization; complete cross-field validation still
  belongs to `Spectre.Candidate.new/1`. There are no placeholder identities or
  implicit defaults masquerading as actual proposal data.

  Occurrence identity, proposer and Scope cannot be installed in a reusable
  template. Binding rejects collisions instead of silently overriding fixed
  fields. A template requests authority; it neither provides nor selects it.
  """

  alias Spectre.{Candidate, Consent, Disclosure, Portable, Row}

  @fields Candidate.request_fields() -- [:identity_key]
  @type t :: %{optional(String.t()) => term()}

  @doc "Normalizes a partial declaration to plain data without constructing an Act."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :candidate_template),
         {:ok, entries} <- normalize_entries(attrs),
         value = Map.new(entries),
         :ok <- Portable.validate(value) do
      {:ok, value}
    end
  end

  @doc "Adds occurrence fields without permitting overrides of the declaration."
  @spec bind(t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def bind(template, attrs) do
    with {:ok, template} <- new(template),
         {:ok, fixed} <- Portable.normalize_attrs(template, @fields, :candidate_template),
         {:ok, attrs} <-
           Portable.normalize_attrs(attrs, Candidate.request_fields(), :candidate_request),
         [] <- Enum.filter(Map.keys(fixed), &Map.has_key?(attrs, &1)) do
      {:ok, Map.merge(fixed, attrs)}
    else
      [_ | _] = collisions -> {:error, {:candidate_template_override, Enum.sort(collisions)}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entries(attrs) do
    Enum.reduce_while(attrs, {:ok, []}, fn {field, value}, {:ok, entries} ->
      case normalize_value(field, value) do
        {:ok, value} -> {:cont, {:ok, [{Atom.to_string(field), value} | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_value(:row, value) do
    with {:ok, row} <- Row.new(value), do: {:ok, Row.canonical(row)}
  end

  defp normalize_value(:disclosure, nil), do: {:ok, nil}

  defp normalize_value(:disclosure, value) do
    with {:ok, disclosure} <- Disclosure.new(value), do: {:ok, Disclosure.canonical(disclosure)}
  end

  defp normalize_value(:consent, nil), do: {:ok, nil}
  defp normalize_value(:consent, value), do: Consent.new(value)
  defp normalize_value(_field, value), do: {:ok, value}
end
