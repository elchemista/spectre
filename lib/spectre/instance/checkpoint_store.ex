defmodule Spectre.Instance.CheckpointStore do
  @moduledoc """
  Durable adapter boundary for the complete canonical Agent checkpoint.

  Stores should implement `compare_and_swap/5`. The expected revision is the
  last checkpoint acknowledged by the adapter and the new revision is embedded
  in the encoded checkpoint as well. An adapter that cannot determine whether
  a write committed must return `{:error, {:ambiguous, reason}}`; Spectre will
  not retry that write automatically.
  """

  alias Spectre.Instance.Erasure.Request, as: ErasureRequest
  alias Spectre.Instance.Erasure.Status, as: ErasureStatus
  alias Spectre.Instance.Ref

  @type config :: module() | {module(), keyword()} | false | nil

  @callback load(Ref.t(), keyword()) ::
              :not_found | {:ok, String.t() | map()} | {:error, term()}

  @callback compare_and_swap(
              Ref.t(),
              String.t(),
              non_neg_integer(),
              non_neg_integer(),
              keyword()
            ) :: :ok | {:ok, term()} | {:error, term()}

  @callback migrate_instance_key(
              Ref.t(),
              Ref.t(),
              String.t() | map(),
              String.t(),
              keyword()
            ) :: :ok | {:ok, :moved | :aliased} | {:error, term()}

  @callback erase(Ref.t(), ErasureRequest.t(), keyword()) ::
              {:ok, :erased | :already_erased} | {:error, term()}

  @callback erasure_status(Ref.t(), keyword()) ::
              :not_erased | {:ok, ErasureStatus.t()} | {:error, term()}

  @optional_callbacks load: 2,
                      compare_and_swap: 5,
                      migrate_instance_key: 5,
                      erase: 3,
                      erasure_status: 2

  @doc """
  Normalizes a user-facing store configuration into `nil` (checkpointing
  disabled) or a canonical `{module, opts}` tuple.

  Returns `{:error, {:invalid_checkpoint_store, value}}` for anything else.
  """
  @spec normalize(config()) :: {:ok, nil | {module(), keyword()}} | {:error, term()}
  def normalize(value) when value in [nil, false], do: {:ok, nil}

  def normalize(module) when is_atom(module) and not is_nil(module),
    do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts),
      do: {:ok, {module, opts}}

  def normalize(value), do: {:error, {:invalid_checkpoint_store, value}}

  @doc """
  Loads the checkpoint for `ref` from a normalized store configuration.

  Returns `:not_found` when checkpointing is disabled or the adapter does not
  export `load/2`. Adapter exceptions and throws are captured and returned as
  `{:error, term()}`; invalid adapter replies are rejected as well.
  """
  @spec load(nil | {module(), keyword()}, Ref.t(), keyword()) ::
          :not_found | {:ok, String.t() | map()} | {:error, term()}
  def load(nil, _ref, _opts), do: :not_found

  def load({module, store_opts}, %Ref{} = ref, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :load, 2) ->
        :not_found

      true ->
        module.load(ref, Keyword.merge(store_opts, opts))
        |> normalize_load(module)
    end
  rescue
    exception -> {:error, {:checkpoint_load_exception, module, exception.__struct__}}
  catch
    kind, reason -> {:error, {:checkpoint_load_failure, module, kind, reason}}
  end

  @doc """
  Persists an encoded checkpoint through the adapter's `compare_and_swap/5`.

  `expected` is the last acknowledged revision and `revision` the one being
  written. Adapter exceptions, throws, and invalid replies are mapped to
  `{:error, {:ambiguous, reason}}` because the write may still have committed.
  """
  @spec persist(
          {module(), keyword()},
          Ref.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok | {:error, term()}
  def persist({module, store_opts}, %Ref{} = ref, checkpoint, expected, revision, opts)
      when is_binary(checkpoint) and is_integer(expected) and expected >= 0 and
             is_integer(revision) and revision >= 0 do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :compare_and_swap, 5) ->
        {:error, {:checkpoint_store_callback_missing, module, :compare_and_swap, 5}}

      true ->
        module.compare_and_swap(
          ref,
          checkpoint,
          expected,
          revision,
          Keyword.merge(store_opts, opts)
        )
        |> normalize_persist(module)
    end
  rescue
    exception ->
      {:error, {:ambiguous, {:checkpoint_persist_exception, module, exception.__struct__}}}
  catch
    kind, reason -> {:error, {:ambiguous, {:checkpoint_persist_failure, module, kind, reason}}}
  end

  @doc """
  Returns whether a normalized store implements the complete erasure boundary.

  Both mutation and status read-back are required: core never reports success
  from a delete callback that it cannot verify independently.
  """
  @spec erasure_capability(nil | {module(), keyword()}) :: :ok | {:error, term()}
  def erasure_capability(nil), do: {:error, :instance_checkpoint_store_required}

  def erasure_capability({module, store_opts}) when is_atom(module) and is_list(store_opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :erase, 3) ->
        {:error, {:checkpoint_store_erasure_unsupported, module, :erase, 3}}

      not function_exported?(module, :erasure_status, 2) ->
        {:error, {:checkpoint_store_erasure_unsupported, module, :erasure_status, 2}}

      true ->
        :ok
    end
  end

  @doc """
  Atomically removes or marks absent one exact checkpoint identity.

  An adapter must leave a private marker that makes subsequent `load/3`
  return `:not_found`, rejects stale CAS writes, and remains observable through
  `erasure_status/3`.
  """
  @spec erase(
          {module(), keyword()},
          Ref.t(),
          ErasureRequest.t(),
          keyword()
        ) :: {:ok, :erased | :already_erased} | {:error, term()}
  def erase({module, store_opts} = store, %Ref{} = ref, %ErasureRequest{} = request, opts) do
    with :ok <- erasure_capability(store),
         :ok <- ErasureRequest.validate(request),
         true <- request.instance_key == ref.key,
         reply <- module.erase(ref, request, Keyword.merge(store_opts, opts)) do
      normalize_erase(reply, module)
    else
      false -> {:error, :instance_erasure_request_ref_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    exception ->
      {:error, {:ambiguous, {:checkpoint_erase_exception, module, exception.__struct__}}}
  catch
    kind, reason ->
      {:error, {:ambiguous, {:checkpoint_erase_failure, module, kind, reason}}}
  end

  @doc "Reads and validates the privacy-safe projection of an erasure marker."
  @spec erasure_status({module(), keyword()}, Ref.t(), keyword()) ::
          :not_erased | {:ok, ErasureStatus.t()} | {:error, term()}
  def erasure_status({module, store_opts} = store, %Ref{} = ref, opts) do
    with :ok <- erasure_capability(store),
         reply <- module.erasure_status(ref, Keyword.merge(store_opts, opts)) do
      normalize_erasure_status(reply, module, ref)
    end
  rescue
    exception ->
      {:error, {:checkpoint_erasure_status_exception, module, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:checkpoint_erasure_status_failure, module, kind, reason}}
  end

  @doc false
  @spec ensure_not_erased(nil | {module(), keyword()}, Ref.t(), keyword()) ::
          :ok | {:error, term()}
  def ensure_not_erased(nil, %Ref{}, _opts), do: :ok

  def ensure_not_erased({module, store_opts} = store, %Ref{} = ref, opts)
      when is_atom(module) and is_list(store_opts) do
    case erasure_capability(store) do
      :ok ->
        case erasure_status(store, ref, opts) do
          :not_erased -> :ok
          {:ok, %ErasureStatus{}} -> {:error, :instance_erased}
          {:error, reason} -> {:error, {:instance_erasure_status_failed, reason}}
        end

      {:error, {:checkpoint_store_erasure_unsupported, ^module, _callback, _arity}} ->
        :ok

      {:error, {:checkpoint_store_not_loaded, ^module}} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Atomically migrates a validated legacy Instance key to its stable key.

  The adapter receives both the exact legacy checkpoint observed by core and
  the migrated schema-2 checkpoint it must expose under `stable_ref`. It must
  reject an existing divergent target and either move the source or leave a
  controlled alias. Core verifies the target byte-for-byte after success.
  """
  @spec migrate_instance_key(
          {module(), keyword()},
          Ref.t(),
          Ref.t(),
          String.t() | map(),
          String.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def migrate_instance_key(
        {module, store_opts} = store,
        %Ref{} = legacy_ref,
        %Ref{} = stable_ref,
        legacy_checkpoint,
        migrated_checkpoint,
        opts
      )
      when (is_binary(legacy_checkpoint) or is_map(legacy_checkpoint)) and
             is_binary(migrated_checkpoint) do
    with :ok <- ensure_migration_callback(module),
         reply <-
           module.migrate_instance_key(
             legacy_ref,
             stable_ref,
             legacy_checkpoint,
             migrated_checkpoint,
             Keyword.merge(store_opts, opts)
           ),
         :ok <- normalize_migration(reply, module),
         {:ok, ^migrated_checkpoint} <- load(store, stable_ref, opts) do
      :ok
    else
      {:ok, _different} -> {:error, :instance_key_migration_readback_mismatch}
      :not_found -> {:error, :instance_key_migration_not_visible}
      {:error, _reason} = error -> error
    end
  rescue
    exception ->
      {:error, {:ambiguous, {:instance_key_migration_exception, module, exception.__struct__}}}
  catch
    kind, reason ->
      {:error, {:ambiguous, {:instance_key_migration_failure, module, kind, reason}}}
  end

  @spec normalize_load(term(), module()) ::
          :not_found | {:ok, String.t() | map()} | {:error, term()}
  defp normalize_load(:not_found, _module), do: :not_found

  defp normalize_load({:ok, value}, _module) when is_binary(value) or is_map(value),
    do: {:ok, value}

  defp normalize_load({:error, _reason} = error, _module), do: error

  defp normalize_load(value, module),
    do: {:error, {:invalid_checkpoint_load_reply, module, value}}

  @spec normalize_persist(term(), module()) :: :ok | {:error, term()}
  defp normalize_persist(:ok, _module), do: :ok
  defp normalize_persist({:ok, _receipt}, _module), do: :ok
  defp normalize_persist({:error, _reason} = error, _module), do: error

  defp normalize_persist(value, module),
    do: {:error, {:ambiguous, {:invalid_checkpoint_persist_reply, module, value}}}

  defp normalize_erase({:ok, status}, _module) when status in [:erased, :already_erased],
    do: {:ok, status}

  defp normalize_erase({:error, _reason} = error, _module), do: error

  defp normalize_erase(value, module),
    do: {:error, {:ambiguous, {:invalid_checkpoint_erase_reply, module, value}}}

  defp normalize_erasure_status(:not_erased, _module, _ref), do: :not_erased

  defp normalize_erasure_status({:ok, %ErasureStatus{} = status}, _module, ref) do
    case ErasureStatus.validate(status, ref) do
      :ok -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_erasure_status({:error, _reason} = error, _module, _ref), do: error

  defp normalize_erasure_status(value, module, _ref),
    do: {:error, {:invalid_checkpoint_erasure_status_reply, module, value}}

  defp ensure_migration_callback(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :migrate_instance_key, 5) ->
        {:error, {:checkpoint_store_callback_missing, module, :migrate_instance_key, 5}}

      true ->
        :ok
    end
  end

  defp normalize_migration(:ok, _module), do: :ok

  defp normalize_migration({:ok, status}, _module) when status in [:moved, :aliased],
    do: :ok

  defp normalize_migration({:error, _reason} = error, _module), do: error

  defp normalize_migration(value, module),
    do: {:error, {:ambiguous, {:invalid_checkpoint_migration_reply, module, value}}}
end
