defmodule Spectre.Router.SemanticCache do
  @moduledoc """
  Reviewable semantic routing memory, recovered from the 0.3 cache mechanism.

  Supervise `Spectre.Router.SemanticCache.Memory` for the bounded ETS/Vettore
  implementation. Pass its server name here, or `{MyAdapter, options}` for a
  different backend implementing `execute/2`. Storage never lives in a Domain's
  ledger projection. The host owns persistence, tenant isolation and permissions
  for editing, promotion and import.

  `put/2` always quarantines a new example. Only `verify/3` makes an online
  example eligible for routing. An exact hit needs no embedding; on a miss,
  `lookup/3` uses an explicitly supplied vector or calls `embed/2` on the host's
  embedding adapter. A remote embedding call must itself follow the application's
  governed execution policy; configuring this helper grants no permission.

  Cache approval is NOT GAM consent, Evidence verification or a reusable Decision.
  Every selected proposal still crosses the current kernel and durable commit.
  """

  alias Spectre.Adapter
  alias Spectre.Router.SemanticCache.Memory

  @type cache :: GenServer.server() | {module(), keyword()}
  @type operation ::
          :info
          | :snapshot
          | :clear
          | {:get, String.t()}
          | {:examples, keyword()}
          | {:put, map() | keyword()}
          | {:update, String.t(), pos_integer(), map() | keyword()}
          | {:verify, String.t(), pos_integer()}
          | {:delete, String.t(), pos_integer()}
          | {:import, [map()], :offline_dataset | :static_route_example}
          | {:restore, map()}
          | {:exact, String.t(), keyword()}
          | {:search, [number()], keyword()}

  @doc "Executes a cache operation atomically; backends must preserve review and binding checks."
  @callback execute(operation(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Returns identity, embedding profile, capacity and example count, without copying examples."
  def info(cache), do: execute(cache, :info)

  @doc "Lists a bounded page (`limit: 100`, maximum 500), optionally filtered by source/approval."
  def examples(cache, opts \\ []), do: execute(cache, {:examples, opts})

  @doc "Fetches one example with its review revision."
  def get_example(cache, id), do: execute(cache, {:get, id})

  @doc "Adds an unverified example. Attributes are text, label, optional id and saved embedding."
  def put(cache, attrs), do: execute(cache, {:put, attrs})

  @doc "Edits the reviewed revision; withdraws approval and invalidates an embedding if text changes."
  def update_example(cache, id, revision, attrs),
    do: execute(cache, {:update, id, revision, attrs})

  @doc "Changes a label without silently promoting the edited example."
  def relabel(cache, id, revision, label),
    do: update_example(cache, id, revision, %{label: label})

  @doc "Promotes exactly the revision inspected by the reviewer. Authorization belongs to the host."
  def verify(cache, id, revision), do: execute(cache, {:verify, id, revision})

  @doc "Deletes exactly one reviewed revision; this is cache deletion, not ledger erasure."
  def delete(cache, id, revision), do: execute(cache, {:delete, id, revision})

  @doc "Exports approval state and vectors with namespace, Definition and embedding profile bindings."
  def snapshot(cache), do: execute(cache, :snapshot)

  @doc "Atomically restores a matching snapshot into an empty cache; never embeds its examples."
  def load_snapshot(cache, snapshot), do: execute(cache, {:restore, snapshot})

  @doc """
  Imports explicitly trusted, reviewed offline examples atomically. This is an
  administrative operation, not the online learning path. Imported examples are
  read-only; replacing a dataset requires an explicit clear/reload by the host.
  No embedding is generated for a row lacking one; it remains exact-match only.
  """
  def import_examples(cache, examples, source \\ :offline_dataset),
    do: execute(cache, {:import, examples, source})

  @doc "Clears all examples and derived indexes. Does not delete a host's snapshots or datasets."
  def clear(cache), do: execute(cache, :clear)

  @doc """
  Returns scored examples, exact first and then semantic. Options: `labels`,
  `limit` (1..32), `binding`, `embedding` (a saved query vector), or
  `embed: {Module, options}` implementing `embed(text, options)`.
  `binding` pins the cache to the namespace/Definition/profile returned by `info/1`.
  The embedding callback runs in the caller, never in the cache owner or Sequencer.
  """
  def lookup(cache, text, opts \\ []) do
    with {:ok, matches} <- execute(cache, {:exact, text, opts}) do
      if matches == [], do: semantic_lookup(cache, text, opts), else: {:ok, matches}
    end
  end

  defp semantic_lookup(cache, text, opts) do
    case Keyword.fetch(opts, :embedding) do
      {:ok, embedding} -> execute(cache, {:search, embedding, opts})
      :error -> embed_and_search(cache, text, opts)
    end
  end

  defp embed_and_search(cache, text, opts) do
    case Keyword.get(opts, :embed) do
      nil ->
        {:ok, []}

      {module, adapter_opts} when is_list(adapter_opts) ->
        with :ok <- Adapter.validate(module, embed: 2),
             {:ok, reply} <- Adapter.invoke(module, :embed, [text, adapter_opts]) do
          embedding_reply(cache, reply, opts)
        end

      _invalid ->
        {:error, :invalid_cache_embed_adapter}
    end
  end

  defp embedding_reply(cache, {:ok, embedding}, opts),
    do: execute(cache, {:search, embedding, opts})

  defp embedding_reply(_cache, {:error, _} = error, _opts), do: error
  defp embedding_reply(_cache, _reply, _opts), do: {:error, :invalid_cache_embed_reply}

  defp execute({module, opts}, operation) when is_atom(module) and is_list(opts) do
    with :ok <- Adapter.validate(module, execute: 2),
         {:ok, reply} <- Adapter.invoke(module, :execute, [operation, opts]) do
      case reply do
        {:ok, _} = ok -> ok
        {:error, _} = error -> error
        _invalid -> {:error, :invalid_cache_adapter_reply}
      end
    end
  end

  defp execute(server, operation), do: execute({Memory, [server: server]}, operation)
end
