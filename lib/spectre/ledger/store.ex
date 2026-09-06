defmodule Spectre.Ledger.Store do
  @moduledoc """
  Adapter contract and guarded invocation facade for Domain ledgers.

  Store adapters must make each batch atomically visible, enforce
  `expected_revision`, and treat an uncertain append acknowledgement as
  `{:error, :ambiguous}`. A successful append may only be returned after the
  adapter's advertised durability boundary has acknowledged the batch.

  `Spectre.Ledger.Store.Support` contains portable shape and option helpers for
  adapter authors. It deliberately does not abstract transactions, locks,
  encoding, recovery or durability: those guarantees stay visible in each
  concrete store.
  """

  alias Spectre.Adapter

  @type config :: module() | {module(), keyword()}
  @type domain_ref :: Spectre.Ledger.domain_ref()
  @type batch_id :: Spectre.Ledger.batch_id()

  @callback append(domain_ref(), batch_id(), [map()], non_neg_integer(), keyword()) ::
              {:ok, non_neg_integer()}
              | {:error, :conflict}
              | {:error, :ambiguous}
              | {:error, term()}

  @callback load(domain_ref(), keyword()) ::
              :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}

  @callback load_from(domain_ref(), non_neg_integer(), keyword()) ::
              :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}

  @optional_callbacks load_from: 3

  @doc "Captures the committed head without loading historical entries."
  @callback head(domain_ref(), keyword()) ::
              :not_found | {:ok, Spectre.Ledger.cursor()} | {:error, term()}

  @doc """
  Reads exactly one complete batch beginning at `first_revision`.

  This is the paging unit: a batch is already bounded by Entry's admission
  limits and must never be split across semantic folds. Implementations must
  use indexed reads, not load the entire ledger and slice it. The returned
  snapshot describes the batch end, not the current Domain head. Its chain
  must still be verified against the caller's trusted predecessor.
  """
  @callback read_batch(domain_ref(), pos_integer(), keyword()) ::
              :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}

  @optional_callbacks head: 2, read_batch: 3

  @doc "Whether an adapter implements native batch paging and a lightweight head read."
  @spec batch_reads?(config()) :: boolean()
  def batch_reads?(store) do
    with {:ok, {module, _opts}} <- normalize(store),
         :ok <- Adapter.validate(module, head: 2, read_batch: 3) do
      true
    else
      _unsupported -> false
    end
  end

  @doc "Reads the advertised head; it does not authenticate a projection checkpoint."
  @spec head(config(), domain_ref(), keyword()) ::
          :not_found | {:ok, Spectre.Ledger.cursor()} | {:error, term()}
  def head(store, domain_ref, opts \\ []) do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :head, 2) do
      invoke_read(module, :head, [domain_ref, Keyword.merge(adapter_opts, opts)])
      |> normalize_head()
    end
  end

  defp normalize_head({:ok, %{revision: revision, head_digest: digest} = cursor})
       when is_integer(revision) and revision > 0 do
    if Spectre.Portable.sha256_digest?(digest),
      do: {:ok, Map.take(cursor, [:revision, :head_digest])},
      else: {:error, :invalid_ledger_head}
  end

  defp normalize_head(:not_found), do: :not_found
  defp normalize_head({:error, _} = error), do: error
  defp normalize_head(_), do: {:error, :invalid_ledger_head}

  @doc "Reads one indexed batch; unsupported adapters return an explicit error."
  @spec read_batch(config(), domain_ref(), pos_integer(), keyword()) ::
          :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}
  def read_batch(store, domain_ref, first_revision, opts \\ [])

  def read_batch(store, domain_ref, first_revision, opts)
      when is_integer(first_revision) and first_revision > 0 do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :read_batch, 3) do
      invoke_read(module, :read_batch, [
        domain_ref,
        first_revision,
        Keyword.merge(adapter_opts, opts)
      ])
      |> normalize_load(module)
    end
  end

  def read_batch(_store, _domain_ref, _revision, _opts),
    do: {:error, :invalid_ledger_cursor}

  @callback lookup_batch(domain_ref(), batch_id(), keyword()) ::
              :not_found | {:ok, Spectre.Ledger.batch_info()} | {:error, term()}

  @callback export(domain_ref(), keyword()) ::
              :not_found | {:ok, map()} | {:error, term()}

  @doc "Normalizes a Store module or `{module, options}` pair."
  @spec normalize(config()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, {module, []}}

  def normalize({module, opts}) when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, :invalid_ledger_store_options}
  end

  def normalize(_value), do: {:error, :invalid_ledger_store}

  @doc false
  @spec append(config(), domain_ref(), batch_id(), [map()], non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append(store, domain_ref, batch_id, payloads, expected_revision, opts) do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :append, 5) do
      invoke_append(module, [
        domain_ref,
        batch_id,
        payloads,
        expected_revision,
        Keyword.merge(adapter_opts, opts)
      ])
    end
  end

  @doc false
  @spec load(config(), domain_ref(), keyword()) ::
          :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}
  def load(store, domain_ref, opts) do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :load, 2) do
      invoke_read(module, :load, [domain_ref, Keyword.merge(adapter_opts, opts)])
      |> normalize_load(module)
    end
  end

  @doc """
  Reads a coherent suffix after a revision, with the captured ledger head.

  Native adapters can use their revision index. Adapters without this optional
  callback fall back to a verified full read. The caller must verify the suffix
  against its trusted predecessor; use `Spectre.Ledger.load_from/4` for that.
  """
  @spec load_from(config(), domain_ref(), non_neg_integer(), keyword()) ::
          :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}
  def load_from(store, domain_ref, revision, opts)
      when is_integer(revision) and revision >= 0 do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :load, 2) do
      read_suffix(module, domain_ref, revision, Keyword.merge(adapter_opts, opts))
    end
  end

  def load_from(_store, _domain_ref, _revision, _opts),
    do: {:error, :invalid_ledger_cursor}

  defp read_suffix(module, domain_ref, revision, opts) do
    if function_exported?(module, :load_from, 3) do
      invoke_read(module, :load_from, [domain_ref, revision, opts]) |> normalize_load(module)
    else
      with {:ok, snapshot} <- Spectre.Ledger.load(module, domain_ref, opts) do
        {:ok, %{snapshot | entries: Enum.drop(snapshot.entries, revision)}}
      end
    end
  end

  @doc false
  @spec lookup_batch(config(), domain_ref(), batch_id(), keyword()) ::
          :not_found | {:ok, Spectre.Ledger.batch_info()} | {:error, term()}
  def lookup_batch(store, domain_ref, batch_id, opts) do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :lookup_batch, 3) do
      invoke_read(module, :lookup_batch, [
        domain_ref,
        batch_id,
        Keyword.merge(adapter_opts, opts)
      ])
      |> normalize_lookup(module)
    end
  end

  @doc false
  @spec export(config(), domain_ref(), keyword()) ::
          :not_found | {:ok, map()} | {:error, term()}
  def export(store, domain_ref, opts) do
    with {:ok, {module, adapter_opts}} <- normalize(store),
         :ok <- validate_options(opts),
         :ok <- ensure_callback(module, :export, 2) do
      invoke_read(module, :export, [domain_ref, Keyword.merge(adapter_opts, opts)])
      |> normalize_export(module)
    end
  end

  @spec invoke_append(module(), [term()]) :: {:ok, non_neg_integer()} | {:error, term()}
  defp invoke_append(module, args) do
    case Adapter.invoke(module, :append, args) do
      {:ok, reply} -> normalize_append(reply)
      {:error, _reason} -> {:error, :ambiguous}
    end
  end

  @spec invoke_read(module(), atom(), [term()]) :: term()
  defp invoke_read(module, function, args) do
    case Adapter.invoke(module, function, args) do
      {:ok, reply} ->
        reply

      {:error, {:adapter_callback_exception, _, _, exception}} ->
        {:error, {:ledger_store_exception, module, function, exception}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {:ledger_store_failure, module, function, kind}}
    end
  end

  @spec normalize_append(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp normalize_append({:ok, revision}) when is_integer(revision) and revision >= 0,
    do: {:ok, revision}

  defp normalize_append({:error, :conflict}), do: {:error, :conflict}
  defp normalize_append({:error, :ambiguous}), do: {:error, :ambiguous}
  defp normalize_append({:error, _reason} = error), do: error
  defp normalize_append(_malformed), do: {:error, :ambiguous}

  @spec normalize_load(term(), module()) ::
          :not_found | {:ok, Spectre.Ledger.snapshot()} | {:error, term()}
  defp normalize_load(:not_found, _module), do: :not_found
  defp normalize_load({:ok, snapshot}, _module) when is_map(snapshot), do: {:ok, snapshot}
  defp normalize_load({:error, _reason} = error, _module), do: error

  defp normalize_load(_reply, module),
    do: {:error, {:invalid_ledger_store_reply, module, :load}}

  @spec normalize_lookup(term(), module()) ::
          :not_found | {:ok, Spectre.Ledger.batch_info()} | {:error, term()}
  defp normalize_lookup(:not_found, _module), do: :not_found
  defp normalize_lookup({:ok, info}, _module) when is_map(info), do: {:ok, info}
  defp normalize_lookup({:error, _reason} = error, _module), do: error

  defp normalize_lookup(_reply, module),
    do: {:error, {:invalid_ledger_store_reply, module, :lookup_batch}}

  @spec normalize_export(term(), module()) :: :not_found | {:ok, map()} | {:error, term()}
  defp normalize_export(:not_found, _module), do: :not_found
  defp normalize_export({:ok, data}, _module) when is_map(data), do: {:ok, data}
  defp normalize_export({:error, _reason} = error, _module), do: error

  defp normalize_export(_reply, module),
    do: {:error, {:invalid_ledger_store_reply, module, :export}}

  @spec ensure_callback(module(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp ensure_callback(module, function, arity) do
    case Adapter.validate(module, [{function, arity}]) do
      :ok ->
        :ok

      {:error, {:adapter_module_not_loaded, _module}} ->
        {:error, {:ledger_store_not_loaded, module}}

      {:error, {:adapter_callback_missing, _module, _function, _arity}} ->
        {:error, {:ledger_store_callback_missing, module, function, arity}}

      {:error, _reason} ->
        {:error, {:ledger_store_not_loaded, module}}
    end
  end

  @spec validate_options(term()) :: :ok | {:error, term()}
  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_ledger_store_options}
  end

  defp validate_options(_opts), do: {:error, :invalid_ledger_store_options}
end
