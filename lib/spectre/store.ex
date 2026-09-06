defmodule Spectre.Store do
  @moduledoc """
  Small versioned store contract for application data, not governed history.

  Use the same adapter for immutable Definition/asset publication and mutable
  Mind checkpoints, caches or experience data. Values cross the boundary as
  bounded canonical bytes; readers reject malformed revisions and encodings.
  `compare_and_swap/4` serializes writers for one key, not a Domain. It cannot
  commit an Act, restore authentication or substitute for `Spectre.Ledger.Store`.

  Missing keys have revision zero. Every successful write (including deletion)
  advances exactly one integer revision. A deletion retains a revision-only
  tombstone: a stale writer cannot exploit delete/recreate to bypass CAS.
  Ambiguous writes are explicit and never retried by this wrapper.

  Adapters receive `get(key, opts)` and
  `compare_and_swap(key, expected_revision, encoded_or_deleted, opts)`.
  Configure a module or `{module, opts}`; `Spectre.Store.Memory` is provided for
  local use/tests. Durable application backends implement this same contract.
  No storage backend is an access-control boundary against host code.
  """

  alias Spectre.{Adapter, Portable}
  alias Spectre.Canonical.Value

  @type config :: module() | {module(), keyword()}
  @type stored :: binary() | :deleted
  @type read_result ::
          :not_found | {:deleted, pos_integer()} | {:ok, pos_integer(), term()} | {:error, term()}
  @callback get(String.t(), keyword()) ::
              :not_found | {:ok, pos_integer(), stored()} | {:error, term()}
  @callback compare_and_swap(String.t(), non_neg_integer(), stored(), keyword()) ::
              {:ok, pos_integer()} | {:error, :conflict | {:ambiguous, term()} | term()}

  @doc "Validates host wiring without performing I/O."
  @spec normalize(config()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def normalize(module) when is_atom(module), do: normalize({module, []})

  def normalize({module, opts}) do
    with true <- Portable.keyword?(opts),
         :ok <- Adapter.validate(module, get: 2, compare_and_swap: 4) do
      {:ok, {module, opts}}
    else
      false -> {:error, :invalid_store_options}
      {:error, _} = error -> error
    end
  end

  def normalize(_config), do: {:error, :invalid_store}

  @doc "Loads canonical data, preserving deletion fences and explicit backend errors."
  @spec get(config(), String.t()) :: read_result()
  def get(store, key) do
    with :ok <- key(key),
         {:ok, {module, opts}} <- normalize(store),
         {:ok, reply} <- Adapter.invoke(module, :get, [key, opts]) do
      decode_reply(reply)
    end
  end

  @doc "Writes portable data if and only if the exact prior revision still matches."
  @spec compare_and_swap(config(), String.t(), non_neg_integer(), term()) ::
          {:ok, pos_integer()} | {:error, term()}
  def compare_and_swap(store, key, expected_revision, value) do
    with {:ok, encoded} <- Value.encode(value), do: write(store, key, expected_revision, encoded)
  end

  @doc "Removes a value but retains a revision fence against stale writers."
  @spec delete(config(), String.t(), non_neg_integer()) :: {:ok, pos_integer()} | {:error, term()}
  def delete(store, key, expected_revision), do: write(store, key, expected_revision, :deleted)

  @doc "Publishes immutable content, accepting only a byte-identical prior publication."
  @spec put_new(config(), String.t(), term()) :: :ok | {:error, term()}
  def put_new(store, key, value) do
    case compare_and_swap(store, key, 0, value) do
      {:ok, 1} -> :ok
      {:error, :conflict} -> identical_publication(store, key, value)
      {:error, _} = error -> error
    end
  end

  defp identical_publication(store, key, expected) do
    case get(store, key) do
      {:ok, _revision, value} when value === expected -> :ok
      {:error, _} = error -> error
      _different -> {:error, :immutable_store_conflict}
    end
  end

  defp write(store, key, expected, encoded) when is_integer(expected) and expected >= 0 do
    with :ok <- key(key), {:ok, {module, opts}} <- normalize(store) do
      case Adapter.invoke(module, :compare_and_swap, [key, expected, encoded, opts]) do
        {:ok, {:ok, revision}} when revision === expected + 1 -> {:ok, revision}
        {:ok, {:error, _} = error} -> error
        {:ok, _malformed} -> {:error, {:ambiguous, :invalid_store_write_reply}}
        {:error, reason} -> {:error, {:ambiguous, reason}}
      end
    end
  end

  defp write(_store, _key, _expected, _encoded), do: {:error, :invalid_store_revision}

  defp decode_reply(:not_found), do: :not_found

  defp decode_reply({:ok, revision, :deleted}) when is_integer(revision) and revision > 0,
    do: {:deleted, revision}

  defp decode_reply({:ok, revision, encoded})
       when is_integer(revision) and revision > 0 and is_binary(encoded) do
    with {:ok, value} <- Value.decode(encoded), do: {:ok, revision, value}
  end

  defp decode_reply({:error, _} = error), do: error
  defp decode_reply(_reply), do: {:error, :invalid_store_read_reply}

  defp key(key) when is_binary(key) and byte_size(key) in 1..1024, do: :ok
  defp key(_key), do: {:error, :invalid_store_key}
end
