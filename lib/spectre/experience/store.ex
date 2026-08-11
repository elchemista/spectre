defmodule Spectre.Experience.Store do
  @moduledoc """
  Opt-in persistence boundary for redacted Experience evidence.

  Unlike the Definition Store, this Store is not canonical Agent state and is
  never consulted for authorization or continuation ownership. Core verifies
  every content-addressed entry before exposing it to Reflection.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Evidence.Ref

  @artifact_schema 1
  @max_list 10_000

  @type durability :: :volatile | :durable
  @type config :: module() | {module(), keyword()}
  @type snapshot :: %{
          required(:definition_ref) => DefinitionRef.t(),
          required(:as_of) => non_neg_integer(),
          required(:evidence) => [Evidence.t()],
          required(:evidence_refs) => [String.t()],
          required(:digest) => String.t()
        }

  @callback identity(keyword()) :: term()
  @callback durability(keyword()) :: durability()
  @callback get(String.t(), keyword()) :: :not_found | {:ok, binary()} | {:error, term()}
  @callback put(String.t(), binary(), keyword()) ::
              :ok | {:ok, :created | :existing} | {:error, term()}
  @callback list(keyword()) :: {:ok, [{String.t(), binary()}]} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | :not_found | {:error, term()}

  @doc "Normalizes an Experience Store configuration."
  @spec normalize(config()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, {:invalid_experience_store, {module, :non_keyword_options}}}
  end

  def normalize(value), do: {:error, {:invalid_experience_store, value}}

  @doc "Returns the Store identity after validating its adapter callbacks."
  @spec identity(config()) :: {:ok, term()} | {:error, term()}
  def identity(store) do
    with {:ok, {module, opts}} <- normalize(store),
         :ok <- ensure_adapter(module),
         {:ok, identity} <- invoke(module, :identity, fn -> module.identity(opts) end),
         :ok <- Value.validate(identity) do
      {:ok, identity}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the Store's declared durability."
  @spec durability(config()) :: {:ok, durability()} | {:error, term()}
  def durability(store) do
    with {:ok, {module, opts}} <- normalize(store),
         :ok <- ensure_adapter(module),
         {:ok, durability} <- invoke(module, :durability, fn -> module.durability(opts) end),
         true <- durability in [:volatile, :durable] do
      {:ok, durability}
    else
      false -> {:error, :invalid_experience_store_durability}
      {:error, _reason} = error -> error
    end
  end

  @doc "Publishes immutable, content-addressed evidence and reads it back."
  @spec publish(config(), Evidence.t()) :: {:ok, Ref.t()} | {:error, term()}
  def publish(store, %Evidence{} = evidence) do
    with :ok <- Evidence.verify(evidence),
         ref = Evidence.ref(evidence),
         key = Ref.to_string(ref),
         encoded = encode_artifact(ref, evidence),
         {:ok, normalized} <- normalize(store),
         :ok <- adapter_put(normalized, key, encoded),
         {:ok, ^encoded} <- adapter_get(normalized, key) do
      {:ok, ref}
    else
      :not_found -> {:error, :experience_store_readback_missing}
      {:ok, _different} -> {:error, :experience_store_readback_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetches and revalidates evidence by content Ref."
  @spec fetch(config(), Ref.t() | String.t()) ::
          :not_found | {:ok, Evidence.t()} | {:error, term()}
  def fetch(store, ref) do
    with {:ok, normalized} <- normalize(store),
         {:ok, ref} <- normalize_ref(ref),
         {:ok, encoded} <- adapter_get(normalized, Ref.to_string(ref)),
         {:ok, evidence} <- decode_artifact(encoded, ref) do
      {:ok, evidence}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc "Lists verified evidence for one Definition under an explicit time snapshot."
  @spec list_evidence(config(), DefinitionRef.t() | String.t(), keyword()) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def list_evidence(store, definition_ref, opts \\ [])

  def list_evidence(store, definition_ref, opts) when is_list(opts) do
    with :ok <- options(opts),
         {:ok, definition_ref} <- normalize_definition_ref(definition_ref),
         {:ok, as_of} <- timestamp(Keyword.get(opts, :as_of, System.system_time(:millisecond))),
         {:ok, limit} <- limit(Keyword.get(opts, :limit, 1_000)),
         {:ok, normalized} <- normalize(store),
         {:ok, entries} <- adapter_list(normalized),
         true <- length(entries) <= @max_list,
         {:ok, evidence} <- decode_entries(entries) do
      include_expired? = Keyword.get(opts, :include_expired?, false) == true

      selected =
        evidence
        |> Enum.filter(fn item ->
          item.definition_ref == definition_ref and item.observed_at <= as_of and
            (include_expired? or not Evidence.expired?(item, as_of))
        end)
        |> Enum.sort_by(&{&1.observed_at, Ref.to_string(Evidence.ref(&1))})
        |> Enum.take(limit)

      {:ok, selected}
    else
      false -> {:error, {:experience_store_entry_limit_exceeded, @max_list}}
      {:error, _reason} = error -> error
    end
  end

  def list_evidence(_store, _definition_ref, opts),
    do: {:error, {:invalid_experience_store_options, opts}}

  @doc "Builds the exact redacted evidence snapshot bound by Reflection and Forge."
  @spec snapshot(config(), DefinitionRef.t() | String.t(), keyword()) ::
          {:ok, snapshot()} | {:error, term()}
  def snapshot(store, definition_ref, opts \\ []) when is_list(opts) do
    with :ok <- options(opts),
         {:ok, definition_ref} <- normalize_definition_ref(definition_ref),
         {:ok, as_of} <- timestamp(Keyword.get(opts, :as_of, System.system_time(:millisecond))),
         snapshot_opts =
           opts
           |> Keyword.put(:as_of, as_of)
           |> Keyword.put(:include_expired?, false),
         {:ok, evidence} <- list_evidence(store, definition_ref, snapshot_opts),
         snapshot = build_snapshot(definition_ref, as_of, evidence),
         :ok <- verify_snapshot(snapshot) do
      {:ok, snapshot}
    end
  end

  @doc "Builds an explicitly empty snapshot when Experience is not configured."
  @spec empty_snapshot(DefinitionRef.t() | String.t(), non_neg_integer()) ::
          {:ok, snapshot()} | {:error, term()}
  def empty_snapshot(definition_ref, as_of) do
    with {:ok, definition_ref} <- normalize_definition_ref(definition_ref),
         {:ok, as_of} <- timestamp(as_of) do
      {:ok, build_snapshot(definition_ref, as_of, [])}
    end
  end

  @doc "Revalidates a snapshot and every embedded evidence item."
  @spec verify_snapshot(snapshot()) :: :ok | {:error, term()}
  def verify_snapshot(%{
        definition_ref: %DefinitionRef{} = definition_ref,
        as_of: as_of,
        evidence: evidence,
        evidence_refs: refs,
        digest: digest
      })
      when is_list(evidence) and is_list(refs) do
    with true <- DefinitionRef.valid?(definition_ref),
         {:ok, ^as_of} <- timestamp(as_of),
         :ok <- verify_snapshot_evidence(evidence, definition_ref, as_of),
         :ok <- unique_snapshot_evidence(evidence),
         expected = build_snapshot(definition_ref, as_of, evidence),
         true <- refs == expected.evidence_refs,
         true <- digest == expected.digest do
      :ok
    else
      false -> {:error, :experience_snapshot_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def verify_snapshot(_value), do: {:error, :invalid_experience_snapshot}

  @doc "Returns portable JSON-shaped snapshot data."
  @spec snapshot_to_data(snapshot()) :: {:ok, map()} | {:error, term()}
  def snapshot_to_data(snapshot) do
    with :ok <- verify_snapshot(snapshot) do
      {:ok,
       %{
         "definition_ref" => DefinitionRef.to_string(snapshot.definition_ref),
         "definition_canonicalization_version" =>
           snapshot.definition_ref.canonicalization_version,
         "definition_contract_version" => snapshot.definition_ref.contract_version,
         "as_of" => snapshot.as_of,
         "evidence" => Enum.map(snapshot.evidence, &Evidence.to_data/1),
         "evidence_refs" => snapshot.evidence_refs,
         "digest" => snapshot.digest
       }}
    end
  end

  @doc "Restores and fully verifies a snapshot from portable data."
  @spec snapshot_from_data(map()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot_from_data(
        %{
          "definition_ref" => definition_ref,
          "definition_canonicalization_version" => canonicalization_version,
          "definition_contract_version" => contract_version,
          "as_of" => as_of,
          "evidence" => evidence,
          "evidence_refs" => refs,
          "digest" => digest
        } = data
      )
      when map_size(data) == 7 and is_list(evidence) and is_list(refs) do
    with {:ok, definition_ref} <-
           DefinitionRef.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         {:ok, as_of} <- timestamp(as_of),
         {:ok, evidence} <- restore_snapshot_evidence(evidence),
         snapshot = build_snapshot(definition_ref, as_of, evidence),
         true <- snapshot.evidence_refs == refs,
         true <- snapshot.digest == digest,
         :ok <- verify_snapshot(snapshot) do
      {:ok, snapshot}
    else
      false -> {:error, :experience_snapshot_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def snapshot_from_data(_value), do: {:error, :invalid_experience_snapshot_data}

  @doc "Encodes a snapshot with the production canonical codec."
  @spec encode_snapshot(snapshot()) :: {:ok, binary()} | {:error, term()}
  def encode_snapshot(snapshot) do
    with {:ok, data} <- snapshot_to_data(snapshot), do: Value.encode(data)
  end

  @doc "Decodes and verifies canonical snapshot bytes."
  @spec decode_snapshot(binary()) :: {:ok, snapshot()} | {:error, term()}
  def decode_snapshot(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: snapshot_from_data(data)
  end

  def decode_snapshot(_value), do: {:error, :invalid_experience_snapshot_binary}

  @doc "Deletes only expired, non-retained Experience evidence after explicit confirmation."
  @spec purge_expired(config(), non_neg_integer(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def purge_expired(store, now, opts \\ [])

  def purge_expired(store, now, opts) when is_list(opts) do
    with :ok <- options(opts),
         true <- Keyword.get(opts, :confirm?, false) == true,
         {:ok, now} <- timestamp(now),
         {:ok, normalized} <- normalize(store),
         {:ok, entries} <- adapter_list(normalized),
         :ok <- entry_limit(entries),
         {:ok, evidence} <- decode_entries(entries) do
      refs =
        evidence
        |> Enum.filter(&(&1.retention != :retained and Evidence.expired?(&1, now)))
        |> Enum.map(&(Evidence.ref(&1) |> Ref.to_string()))

      delete_refs(normalized, refs)
    else
      false -> {:error, :experience_purge_confirmation_required}
      {:error, _reason} = error -> error
    end
  end

  def purge_expired(_store, now, opts),
    do: {:error, {:invalid_experience_purge, now, opts}}

  @doc "Returns the Experience Store artifact schema version."
  @spec artifact_schema_version() :: pos_integer()
  def artifact_schema_version, do: @artifact_schema

  defp encode_artifact(ref, evidence) do
    %{
      "artifact_schema" => @artifact_schema,
      "ref" => Ref.to_string(ref),
      "evidence" => Evidence.to_data(evidence)
    }
    |> Value.encode!()
  end

  defp build_snapshot(definition_ref, as_of, evidence) do
    evidence = Enum.sort_by(evidence, &{&1.observed_at, Ref.to_string(Evidence.ref(&1))})
    refs = Enum.map(evidence, &(Evidence.ref(&1) |> Ref.to_string()))

    %{
      definition_ref: definition_ref,
      as_of: as_of,
      evidence: evidence,
      evidence_refs: refs,
      digest:
        Value.digest!(%{
          "definition_ref" => DefinitionRef.to_string(definition_ref),
          "as_of" => as_of,
          "evidence_refs" => refs
        })
    }
  end

  defp verify_snapshot_evidence(evidence, definition_ref, as_of) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      snapshot_evidence_result(item, definition_ref, as_of)
    end)
  end

  defp snapshot_evidence_result(item, definition_ref, as_of) do
    case verify_snapshot_item(item, definition_ref, as_of) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp verify_snapshot_item(%Evidence{} = item, definition_ref, as_of) do
    cond do
      item.definition_ref != definition_ref ->
        {:error, :experience_snapshot_definition_mismatch}

      item.observed_at > as_of ->
        {:error, :experience_snapshot_future_evidence}

      Evidence.expired?(item, as_of) ->
        {:error, :experience_snapshot_expired_evidence}

      true ->
        Evidence.verify(item)
    end
  end

  defp verify_snapshot_item(_value, _definition_ref, _as_of),
    do: {:error, :invalid_experience_snapshot_evidence}

  defp delete_refs(store, refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, deleted} ->
      delete_ref(store, ref, deleted)
    end)
    |> reverse_deleted()
  end

  defp delete_ref(store, ref, deleted) do
    case adapter_delete(store, ref) do
      :ok -> {:cont, {:ok, [ref | deleted]}}
      :not_found -> {:cont, {:ok, deleted}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp reverse_deleted({:ok, deleted}), do: {:ok, Enum.reverse(deleted)}
  defp reverse_deleted({:error, _reason} = error), do: error

  defp unique_snapshot_evidence(evidence) do
    refs = Enum.map(evidence, &(Evidence.ref(&1) |> Ref.to_string()))

    if length(refs) == length(Enum.uniq(refs)),
      do: :ok,
      else: {:error, :duplicate_experience_snapshot_evidence}
  end

  defp restore_snapshot_evidence(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, result} ->
      case Evidence.from_data(value) do
        {:ok, evidence} ->
          {:cont, {:ok, [evidence | result]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_experience_snapshot_evidence, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end)
  end

  defp decode_artifact(encoded, ref) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded),
         %{"artifact_schema" => @artifact_schema, "ref" => supplied, "evidence" => evidence} <-
           data,
         true <- supplied == Ref.to_string(ref),
         {:ok, evidence} <- Evidence.from_data(evidence),
         :ok <- Ref.verify(ref, evidence) do
      {:ok, evidence}
    else
      false -> {:error, :experience_artifact_ref_mismatch}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_experience_artifact}
    end
  end

  defp decode_entries(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{key, encoded}, index}, {:ok, result} when is_binary(key) and is_binary(encoded) ->
        with {:ok, ref} <- Ref.parse(key),
             {:ok, evidence} <- decode_artifact(encoded, ref) do
          {:cont, {:ok, [evidence | result]}}
        else
          {:error, reason} -> {:halt, {:error, {:invalid_experience_store_entry, index, reason}}}
        end

      {value, index}, _acc ->
        {:halt, {:error, {:invalid_experience_store_entry, index, value}}}
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_experience_evidence_ref, ref}}
  end

  defp normalize_ref(value), do: Ref.parse(value)

  defp normalize_definition_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_experience_definition_ref, ref}}
  end

  defp normalize_definition_ref(value), do: DefinitionRef.parse(value)

  defp timestamp(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp timestamp(value), do: {:error, {:invalid_experience_snapshot_timestamp, value}}

  defp limit(value) when is_integer(value) and value > 0 and value <= @max_list, do: {:ok, value}
  defp limit(value), do: {:error, {:invalid_experience_snapshot_limit, value}}

  defp entry_limit(entries) when length(entries) <= @max_list, do: :ok
  defp entry_limit(_entries), do: {:error, {:experience_store_entry_limit_exceeded, @max_list}}

  defp options(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_experience_store_options}
  end

  defp ensure_adapter(module) do
    callbacks = [identity: 1, durability: 1, get: 2, put: 3, list: 1, delete: 2]

    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end),
       do: :ok,
       else: {:error, {:invalid_experience_store_adapter, module}}
  end

  defp adapter_get({module, opts}, key) do
    with {:ok, result} <- invoke(module, :get, fn -> module.get(key, opts) end) do
      case result do
        :not_found -> :not_found
        {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
        {:error, _reason} = error -> error
        value -> {:error, {:invalid_experience_store_get_reply, value}}
      end
    end
  end

  defp adapter_put({module, opts}, key, encoded) do
    with {:ok, result} <- invoke(module, :put, fn -> module.put(key, encoded, opts) end) do
      case result do
        :ok -> :ok
        {:ok, status} when status in [:created, :existing] -> :ok
        {:error, _reason} = error -> error
        value -> {:error, {:invalid_experience_store_put_reply, value}}
      end
    end
  end

  defp adapter_list({module, opts}) do
    with {:ok, result} <- invoke(module, :list, fn -> module.list(opts) end) do
      case result do
        {:ok, entries} when is_list(entries) -> {:ok, entries}
        {:error, _reason} = error -> error
        value -> {:error, {:invalid_experience_store_list_reply, value}}
      end
    end
  end

  defp adapter_delete({module, opts}, key) do
    with {:ok, result} <- invoke(module, :delete, fn -> module.delete(key, opts) end) do
      case result do
        :ok -> :ok
        :not_found -> :not_found
        {:error, _reason} = error -> error
        value -> {:error, {:invalid_experience_store_delete_reply, value}}
      end
    end
  end

  defp invoke(module, function, callback) do
    {:ok, callback.()}
  rescue
    exception -> {:error, {:experience_store_exception, module, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:experience_store_failure, module, function, kind, reason}}
  end
end
