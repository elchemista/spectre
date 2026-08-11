defmodule Spectre.Experience do
  @moduledoc """
  Opt-in boundary for recording and querying redacted operational evidence.

  Recording is disabled unless trusted host code passes `enabled?: true`.
  Experience remains observational: it never mutates an Instance, grants
  authority, completes a continuation, or replaces the Journal.
  """

  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Redactor
  alias Spectre.Experience.Store
  alias Spectre.Governance.Data

  @record_fields [:facts, :provenance, :redactions]

  @doc "Redacts, validates and publishes one evidence item when explicitly enabled."
  @spec record(Store.config(), map() | keyword(), keyword()) ::
          {:ok, Spectre.Experience.Evidence.Ref.t()} | {:error, term()}
  def record(store, attrs, opts \\ [])

  def record(store, attrs, opts) when is_list(attrs) and is_list(opts) do
    cond do
      not valid_options?(opts) ->
        {:error, :invalid_experience_record_options}

      not (Keyword.keyword?(attrs) and unique_keyword?(attrs)) ->
        {:error, {:invalid_experience_record, :list}}

      true ->
        record(store, Map.new(attrs), opts)
    end
  end

  def record(store, attrs, opts) when is_map(attrs) and not is_struct(attrs) and is_list(opts) do
    with true <- valid_options?(opts),
         true <- Keyword.get(opts, :enabled?, false) == true,
         [] <- Data.alias_collisions(attrs, @record_fields),
         facts when is_map(facts) and not is_struct(facts) <- value(attrs, :facts, %{}),
         provenance when is_map(provenance) and not is_struct(provenance) <-
           value(attrs, :provenance, %{}),
         {:ok, facts, fact_paths} <-
           Redactor.redact(facts, keys: Keyword.get(opts, :redact_keys, [])),
         {:ok, provenance, provenance_paths} <-
           Redactor.redact(provenance, keys: Keyword.get(opts, :redact_keys, [])),
         redactions =
           Enum.map(fact_paths, fn path -> ["facts" | path] end) ++
             Enum.map(provenance_paths, fn path -> ["provenance" | path] end),
         {:ok, evidence} <-
           attrs
           |> put(:facts, facts)
           |> put(:provenance, provenance)
           |> put(:redactions, redactions)
           |> Evidence.new() do
      Store.publish(store, evidence)
    else
      false ->
        if valid_options?(opts),
          do: {:error, :experience_recording_not_enabled},
          else: {:error, :invalid_experience_record_options}

      [_first | _rest] = collisions ->
        {:error, {:ambiguous_experience_record_fields, collisions}}

      {:error, _reason} = error ->
        error

      value ->
        {:error, {:invalid_experience_record_data, shape(value)}}
    end
  end

  def record(_store, attrs, opts),
    do: {:error, {:invalid_experience_record, shape(attrs), shape(opts)}}

  @doc "Fetches verified evidence by Ref."
  defdelegate fetch(store, ref), to: Store

  @doc "Lists verified evidence for one Definition."
  defdelegate list(store, definition_ref, opts \\ []), to: Store, as: :list_evidence

  @doc "Returns the exact evidence snapshot used by Reflection and Forge."
  defdelegate snapshot(store, definition_ref, opts \\ []), to: Store

  @doc "Purges expired non-retained evidence after explicit confirmation."
  defdelegate purge_expired(store, now, opts \\ []), to: Store

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp put(attrs, key, value) do
    attrs
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp valid_options?(opts), do: Keyword.keyword?(opts) and unique_keyword?(opts)

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
