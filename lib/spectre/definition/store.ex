defmodule Spectre.Definition.Store do
  @moduledoc """
  Immutable persistence boundary for canonical Definitions and Manifest V2.

  Adapters store one opaque canonical artifact per `Definition.Ref`. Core owns
  artifact encoding, publication receipts, integrity verification, parent
  checks, and idempotency read-back. An adapter must never replace different
  bytes under an existing key.

  A configured `Spectre.Instance.CheckpointStore` is a durable boundary. Such a
  runtime may use only a Definition Store whose `durability/1` returns
  `:durable`; the bundled in-memory store is intentionally `:volatile`.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Instance.CheckpointStore

  @artifact_schema 1
  @candidate_artifact_schema 1
  @receipt_schema 1

  @type durability :: :volatile | :durable
  @type config :: module() | {module(), keyword()}

  @type receipt :: %{
          required(:schema_version) => pos_integer(),
          required(:publication_id) => String.t(),
          required(:definition_ref) => String.t(),
          required(:manifest_digest) => String.t(),
          required(:store_id) => term(),
          required(:durability) => durability()
        }

  @type artifact :: %{
          required(:definition) => Canonical.t(),
          required(:manifest) => Manifest.t(),
          required(:receipt) => receipt()
        }

  @callback identity(keyword()) :: term()
  @callback durability(keyword()) :: durability()
  @callback get(String.t(), keyword()) ::
              :not_found | {:ok, binary()} | {:error, term()}
  @callback put(String.t(), binary(), keyword()) ::
              :ok | {:ok, :created | :existing} | {:error, term()}

  @doc "Normalizes a Store module or `{module, opts}` configuration."
  @spec normalize(config()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, {:invalid_definition_store, {module, :non_keyword_options}}}
  end

  def normalize(value), do: {:error, {:invalid_definition_store, value}}

  @doc "Returns the adapter's declared durability after validating its callbacks."
  @spec durability(config()) :: {:ok, durability()} | {:error, term()}
  def durability(store) do
    with {:ok, {module, opts}} <- normalize(store),
         :ok <- ensure_adapter(module),
         {:ok, value} <- invoke(module, :durability, [opts]),
         true <- value in [:volatile, :durable] do
      {:ok, value}
    else
      false -> {:error, :invalid_definition_store_durability}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the portable logical identity of the configured Store."
  @spec identity(config()) :: {:ok, term()} | {:error, term()}
  def identity(store) do
    with {:ok, {module, opts}} <- normalize(store),
         :ok <- ensure_adapter(module),
         {:ok, identity} <- invoke(module, :identity, [opts]),
         :ok <- validate_store_identity(identity) do
      {:ok, identity}
    end
  end

  @doc """
  Atomically publishes Definition bytes, Manifest bytes, and a core receipt.

  Parent Definitions must already resolve. A successful adapter write is read
  back and compared byte-for-byte before the publication receipt is returned.
  Publishing the same artifact twice is idempotent; different bytes under the
  same Ref are an immutable conflict.
  """
  @spec publish(config(), Canonical.t(), Manifest.t(), keyword()) ::
          {:ok, receipt()} | {:error, term()}
  def publish(store, %Canonical{} = canonical, %Manifest{} = manifest, opts \\ [])
      when is_list(opts) do
    registry = Keyword.get(opts, :component_registry, ContractRegistry.default())

    with {:ok, normalized} <- normalize(store),
         :ok <- validate_durability_pair(Keyword.get(opts, :checkpoint_store), normalized),
         :ok <- Manifest.verify(manifest, canonical, registry),
         :ok <- ensure_parents(normalized, manifest.parent_refs, opts),
         {:ok, durability} <- durability(normalized),
         {:ok, store_id} <- identity(normalized),
         receipt = publication_receipt(canonical, manifest, store_id, durability),
         encoded = encode_artifact(canonical, manifest, receipt),
         :ok <- adapter_put(normalized, Ref.to_string(manifest.definition_ref), encoded),
         :ok <- verify_readback(normalized, Ref.to_string(manifest.definition_ref), encoded) do
      {:ok, receipt}
    end
  end

  @doc """
  Publishes one immutable bootstrap Candidate after re-reading its Definition.

  The Candidate is stored under its content-addressed `Candidate.Ref`. Its
  Manifest digest and publication id must match the verified Definition
  artifact already present in the same trusted Store.
  """
  @spec publish_candidate(config(), Candidate.t(), keyword()) ::
          {:ok, CandidateRef.t()} | {:error, term()}
  def publish_candidate(store, %Candidate{} = candidate, opts \\ []) when is_list(opts) do
    ref = Candidate.ref(candidate)
    key = candidate_key(ref)
    encoded = encode_candidate_artifact(candidate, ref)

    with {:ok, normalized} <- normalize(store),
         :ok <- validate_durability_pair(Keyword.get(opts, :checkpoint_store), normalized),
         :ok <- verify_candidate_binding(normalized, candidate, opts),
         :ok <- ensure_candidate_parent(normalized, candidate.parent_ref, opts),
         :ok <- adapter_put(normalized, key, encoded),
         :ok <- verify_readback(normalized, key, encoded) do
      {:ok, ref}
    end
  end

  @doc """
  Re-reads and verifies a bootstrap Candidate and its bound Definition.

  Supplying an in-memory Candidate struct is never an activation authority;
  callers must pass the returned Ref to this function or to
  `Spectre.Instance.activate/3`.
  """
  @spec fetch_candidate(config(), CandidateRef.t() | String.t(), keyword()) ::
          :not_found | {:ok, Candidate.t()} | {:error, term()}
  def fetch_candidate(store, ref, opts \\ []) when is_list(opts) do
    with {:ok, normalized} <- normalize(store),
         {:ok, ref} <- normalize_candidate_ref(ref),
         {:ok, encoded} <- adapter_get(normalized, candidate_key(ref)),
         {:ok, candidate} <- decode_candidate_artifact(encoded, ref),
         :ok <- verify_candidate_binding(normalized, candidate, opts),
         :ok <- ensure_candidate_parent(normalized, candidate.parent_ref, opts) do
      {:ok, candidate}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches and fully verifies one published artifact.

  Verification covers the lookup key, canonical Definition Ref, Manifest
  digest/binding, publication receipt, and current component registry.
  """
  @spec fetch(config(), Ref.t() | String.t(), keyword()) ::
          :not_found | {:ok, artifact()} | {:error, term()}
  def fetch(store, ref, opts \\ []) when is_list(opts) do
    registry = Keyword.get(opts, :component_registry, ContractRegistry.default())

    with {:ok, normalized} <- normalize(store),
         {:ok, ref} <- normalize_ref(ref),
         key = Ref.to_string(ref),
         {:ok, encoded} <- adapter_get(normalized, key),
         {:ok, artifact} <- decode_artifact(encoded, ref, registry) do
      {:ok, artifact}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Rejects a durable Checkpoint Store paired with a volatile Definition Store.
  """
  @spec validate_durability_pair(CheckpointStore.config(), config()) ::
          :ok | {:error, term()}
  def validate_durability_pair(checkpoint_store, definition_store) do
    with {:ok, checkpoint_store} <- CheckpointStore.normalize(checkpoint_store),
         {:ok, store_durability} <- durability(definition_store) do
      validate_pair(checkpoint_store, store_durability)
    end
  end

  @doc "Returns the publication artifact schema version."
  @spec artifact_schema_version() :: pos_integer()
  def artifact_schema_version, do: @artifact_schema

  @doc "Returns the publication receipt schema version."
  @spec receipt_schema_version() :: pos_integer()
  def receipt_schema_version, do: @receipt_schema

  @doc "Returns the immutable Candidate artifact schema version."
  @spec candidate_artifact_schema_version() :: pos_integer()
  def candidate_artifact_schema_version, do: @candidate_artifact_schema

  @spec publication_receipt(Canonical.t(), Manifest.t(), term(), durability()) :: receipt()
  defp publication_receipt(canonical, manifest, store_id, durability) do
    base = %{
      schema_version: @receipt_schema,
      definition_ref: canonical |> Canonical.ref() |> Ref.to_string(),
      manifest_digest: Manifest.digest(manifest),
      store_id: store_id,
      durability: durability
    }

    Map.put(base, :publication_id, Value.digest!(base))
  end

  @spec encode_candidate_artifact(Candidate.t(), CandidateRef.t()) :: binary()
  defp encode_candidate_artifact(candidate, ref) do
    {:ok, encoded_candidate} = Candidate.encode(candidate)

    Value.encode!(%{
      "schema_version" => @candidate_artifact_schema,
      "candidate_ref" => CandidateRef.to_string(ref),
      "candidate" => encoded_candidate
    })
  end

  @spec decode_candidate_artifact(binary(), CandidateRef.t()) ::
          {:ok, Candidate.t()} | {:error, term()}
  defp decode_candidate_artifact(encoded, expected_ref) do
    with {:ok,
          %{
            "schema_version" => @candidate_artifact_schema,
            "candidate_ref" => stored_ref,
            "candidate" => encoded_candidate
          }} <- Value.decode(encoded),
         true <- stored_ref == CandidateRef.to_string(expected_ref),
         {:ok, candidate} <- Candidate.decode(encoded_candidate),
         :ok <- CandidateRef.verify(expected_ref, candidate) do
      {:ok, candidate}
    else
      false ->
        {:error, :candidate_store_lookup_mismatch}

      {:ok, %{"schema_version" => version}} ->
        {:error, {:unsupported_candidate_store_artifact_schema, version}}

      {:ok, value} ->
        {:error, {:invalid_candidate_store_artifact, shape(value)}}

      {:error, reason} ->
        {:error, {:candidate_store_artifact_invalid, reason}}
    end
  end

  @spec verify_candidate_binding({module(), keyword()}, Candidate.t(), keyword()) ::
          :ok | {:error, term()}
  defp verify_candidate_binding(store, candidate, opts) do
    case fetch(store, candidate.definition_ref, opts) do
      {:ok, artifact} ->
        cond do
          Manifest.digest(artifact.manifest) != candidate.manifest_digest ->
            {:error, :candidate_manifest_digest_mismatch}

          artifact.receipt.publication_id != candidate.publication_id ->
            {:error, :candidate_publication_receipt_mismatch}

          true ->
            :ok
        end

      :not_found ->
        {:error, {:candidate_definition_not_found, Ref.to_string(candidate.definition_ref)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec ensure_candidate_parent({module(), keyword()}, CandidateRef.t() | nil, keyword()) ::
          :ok | {:error, term()}
  defp ensure_candidate_parent(_store, nil, _opts), do: :ok

  defp ensure_candidate_parent(store, %CandidateRef{} = parent_ref, opts) do
    case fetch_candidate(store, parent_ref, Keyword.put(opts, :skip_candidate_parent, true)) do
      {:ok, _candidate} -> :ok
      :not_found -> {:error, {:missing_candidate_parent, CandidateRef.to_string(parent_ref)}}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_artifact(Canonical.t(), Manifest.t(), receipt()) :: binary()
  defp encode_artifact(canonical, manifest, receipt) do
    Value.encode!(%{
      "schema_version" => @artifact_schema,
      "definition_ref" => receipt.definition_ref,
      "canonicalization_version" => canonical.canonicalization_version,
      "definition_contract_version" => canonical.contract_version,
      "definition" => Canonical.encode!(canonical),
      "manifest" => Manifest.encode!(manifest),
      "receipt" => receipt_to_data(receipt)
    })
  end

  @spec decode_artifact(binary(), Ref.t(), ContractRegistry.t()) ::
          {:ok, artifact()} | {:error, term()}
  defp decode_artifact(encoded, expected_ref, registry) do
    with {:ok, data} <- Value.decode(encoded),
         {:ok, fields} <- artifact_fields(data),
         :ok <- validate_artifact_header(fields, expected_ref),
         {:ok, canonical} <- Canonical.decode(fields.definition),
         :ok <- Ref.verify(expected_ref, canonical),
         {:ok, manifest} <- Manifest.decode(fields.manifest),
         :ok <- Manifest.verify(manifest, canonical, registry),
         {:ok, receipt} <- receipt_from_data(fields.receipt),
         :ok <- verify_receipt(receipt, canonical, manifest) do
      {:ok, %{definition: canonical, manifest: manifest, receipt: receipt}}
    else
      {:error, reason} -> {:error, {:definition_store_artifact_invalid, reason}}
    end
  end

  @spec artifact_fields(term()) :: {:ok, map()} | {:error, term()}
  defp artifact_fields(%{
         "schema_version" => schema,
         "definition_ref" => definition_ref,
         "canonicalization_version" => canonicalization_version,
         "definition_contract_version" => contract_version,
         "definition" => definition,
         "manifest" => manifest,
         "receipt" => receipt
       })
       when is_binary(definition) and is_binary(manifest) do
    {:ok,
     %{
       schema: schema,
       definition_ref: definition_ref,
       canonicalization_version: canonicalization_version,
       contract_version: contract_version,
       definition: definition,
       manifest: manifest,
       receipt: receipt
     }}
  end

  defp artifact_fields(value), do: {:error, {:invalid_definition_store_artifact, shape(value)}}

  @spec validate_artifact_header(map(), Ref.t()) :: :ok | {:error, term()}
  defp validate_artifact_header(fields, expected_ref) do
    cond do
      fields.schema != @artifact_schema ->
        {:error, {:unsupported_definition_store_artifact_schema, fields.schema}}

      fields.definition_ref != Ref.to_string(expected_ref) ->
        {:error,
         {:definition_store_lookup_mismatch, Ref.to_string(expected_ref), fields.definition_ref}}

      fields.canonicalization_version != expected_ref.canonicalization_version ->
        {:error, :definition_store_canonicalization_version_mismatch}

      fields.contract_version != expected_ref.contract_version ->
        {:error, :definition_store_contract_version_mismatch}

      true ->
        :ok
    end
  end

  @spec receipt_to_data(receipt()) :: map()
  defp receipt_to_data(receipt) do
    %{
      "schema_version" => receipt.schema_version,
      "publication_id" => receipt.publication_id,
      "definition_ref" => receipt.definition_ref,
      "manifest_digest" => receipt.manifest_digest,
      "store_id" => receipt.store_id,
      "durability" => receipt.durability
    }
  end

  @spec receipt_from_data(term()) :: {:ok, receipt()} | {:error, term()}
  defp receipt_from_data(%{
         "schema_version" => schema_version,
         "publication_id" => publication_id,
         "definition_ref" => definition_ref,
         "manifest_digest" => manifest_digest,
         "store_id" => store_id,
         "durability" => durability
       }) do
    receipt = %{
      schema_version: schema_version,
      publication_id: publication_id,
      definition_ref: definition_ref,
      manifest_digest: manifest_digest,
      store_id: store_id,
      durability: durability
    }

    with true <- schema_version == @receipt_schema,
         true <- durability in [:volatile, :durable],
         :ok <- validate_store_identity(store_id) do
      {:ok, receipt}
    else
      false -> {:error, {:invalid_definition_publication_receipt, receipt}}
      {:error, _reason} = error -> error
    end
  end

  defp receipt_from_data(value),
    do: {:error, {:invalid_definition_publication_receipt, shape(value)}}

  @spec verify_receipt(receipt(), Canonical.t(), Manifest.t()) :: :ok | {:error, term()}
  defp verify_receipt(receipt, canonical, manifest) do
    expected = publication_receipt(canonical, manifest, receipt.store_id, receipt.durability)

    if receipt == expected,
      do: :ok,
      else: {:error, {:stale_definition_publication_receipt, receipt, expected}}
  end

  @spec ensure_parents({module(), keyword()}, [Ref.t()], keyword()) ::
          :ok | {:error, term()}
  defp ensure_parents(store, parent_refs, opts) do
    Enum.reduce_while(parent_refs, :ok, fn ref, :ok ->
      case fetch(store, ref, opts) do
        {:ok, _artifact} -> {:cont, :ok}
        :not_found -> {:halt, {:error, {:missing_definition_parent, Ref.to_string(ref)}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec verify_readback({module(), keyword()}, String.t(), binary()) ::
          :ok | {:error, term()}
  defp verify_readback(store, key, expected) do
    case adapter_get(store, key) do
      {:ok, ^expected} -> :ok
      {:ok, _different} -> {:error, {:definition_store_immutable_conflict, key}}
      :not_found -> {:error, {:definition_store_write_not_visible, key}}
      {:error, _reason} = error -> error
    end
  end

  @spec adapter_put({module(), keyword()}, String.t(), binary()) :: :ok | {:error, term()}
  defp adapter_put({module, opts}, key, encoded) do
    with :ok <- ensure_adapter(module),
         {:ok, reply} <- invoke(module, :put, [key, encoded, opts]) do
      normalize_put_reply(reply, module)
    end
  end

  @spec normalize_put_reply(term(), module()) :: :ok | {:error, term()}
  defp normalize_put_reply(:ok, _module), do: :ok
  defp normalize_put_reply({:ok, status}, _module) when status in [:created, :existing], do: :ok
  defp normalize_put_reply({:error, _reason} = error, _module), do: error

  defp normalize_put_reply(value, module),
    do: {:error, {:invalid_definition_store_put_reply, module, value}}

  @spec adapter_get({module(), keyword()}, String.t()) ::
          :not_found | {:ok, binary()} | {:error, term()}
  defp adapter_get({module, opts}, key) do
    with :ok <- ensure_adapter(module),
         {:ok, reply} <- invoke(module, :get, [key, opts]) do
      normalize_get_reply(reply, module)
    end
  end

  @spec normalize_get_reply(term(), module()) ::
          :not_found | {:ok, binary()} | {:error, term()}
  defp normalize_get_reply(:not_found, _module), do: :not_found
  defp normalize_get_reply({:ok, encoded}, _module) when is_binary(encoded), do: {:ok, encoded}
  defp normalize_get_reply({:error, _reason} = error, _module), do: error

  defp normalize_get_reply(value, module),
    do: {:error, {:invalid_definition_store_get_reply, module, value}}

  @spec ensure_adapter(module()) :: :ok | {:error, term()}
  defp ensure_adapter(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:definition_store_not_loaded, module}}

      missing =
          Enum.find([identity: 1, durability: 1, get: 2, put: 3], fn {function, arity} ->
            not function_exported?(module, function, arity)
          end) ->
        {function, arity} = missing
        {:error, {:definition_store_callback_missing, module, function, arity}}

      true ->
        :ok
    end
  end

  @spec invoke(module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp invoke(module, function, arguments) do
    {:ok, apply(module, function, arguments)}
  rescue
    exception ->
      {:error, {:definition_store_exception, module, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:definition_store_failure, module, function, kind, reason}}
  end

  @spec validate_store_identity(term()) :: :ok | {:error, term()}
  defp validate_store_identity(identity) do
    case Value.validate(identity) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_definition_store_identity, reason}}
    end
  end

  @spec normalize_ref(Ref.t() | String.t()) :: {:ok, Ref.t()} | {:error, term()}
  defp normalize_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_definition_store_ref, ref}}
  end

  defp normalize_ref(value) when is_binary(value), do: Ref.parse(value)
  defp normalize_ref(value), do: {:error, {:invalid_definition_store_ref, value}}

  @spec normalize_candidate_ref(CandidateRef.t() | String.t()) ::
          {:ok, CandidateRef.t()} | {:error, term()}
  defp normalize_candidate_ref(%CandidateRef{} = ref) do
    if CandidateRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_candidate_store_ref, ref}}
  end

  defp normalize_candidate_ref(value) when is_binary(value), do: CandidateRef.parse(value)
  defp normalize_candidate_ref(value), do: {:error, {:invalid_candidate_store_ref, value}}

  @spec candidate_key(CandidateRef.t()) :: String.t()
  defp candidate_key(%CandidateRef{} = ref), do: "candidate/" <> CandidateRef.to_string(ref)

  @spec validate_pair(nil | {module(), keyword()}, durability()) :: :ok | {:error, term()}
  defp validate_pair(nil, _store_durability), do: :ok
  defp validate_pair({_module, _opts}, :durable), do: :ok

  defp validate_pair({_module, _opts}, :volatile),
    do: {:error, :durable_checkpoint_requires_durable_definition_store}

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
