defmodule Spectre.Server.Store.Page do
  @moduledoc """
  Shared namespace ordering and bounded keyset pages for coordination stores.

  Length-framed canonical key components make tuple prefixes contiguous without
  depending on UUID timestamps or retaining a second copy of the stored values.
  A cursor is bound to its prefix. Pages are live views, not snapshot isolation.
  """
  alias Spectre.GAM.Canonical.Value

  @doc "Returns a stable binary ordering key; tuple components support prefix lookup."
  def key(key) when is_tuple(key), do: <<1>> <> components(Tuple.to_list(key))
  def key(key), do: <<0>> <> components([key])

  defp components(items) do
    Enum.map_join(items, fn item ->
      bytes = Value.encode!(item)
      <<byte_size(bytes)::unsigned-big-32, bytes::binary>>
    end)
  end

  @doc false
  def index(keys), do: Enum.reduce(keys, :gb_trees.empty(), &put(&2, &1))
  @doc false
  def put(index, key), do: :gb_trees.enter(key(key), key, index)
  @doc false
  def delete(index, key), do: :gb_trees.delete_any(key(key), index)

  @doc "Validates a bounded page and its namespace-bound cursor."
  def options(prefix, opts) when is_tuple(prefix) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Keyword.keys(opts) -- [:after, :limit, :max_bytes] == [],
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 50),
         bytes when is_integer(bytes) and bytes in 1..16_777_216 <-
           Keyword.get(opts, :max_bytes, 1_048_576),
         :ok <- Value.validate(prefix),
         lower = key(prefix),
         {:ok, after_key} <- after_key(Keyword.get(opts, :after), lower) do
      {:ok, %{prefix: lower, after: after_key, limit: limit, max_bytes: bytes}}
    else
      _ -> {:error, :invalid_store_page}
    end
  rescue
    _ -> {:error, :invalid_store_page}
  end

  def options(_, _), do: {:error, :invalid_store_page}

  defp after_key(nil, _), do: {:ok, nil}

  defp after_key({:store_page, 1, prefix, last}, prefix) when is_binary(last) do
    if matches?(last, prefix), do: {:ok, last}, else: {:error, :invalid_store_cursor}
  end

  defp after_key(_, _), do: {:error, :invalid_store_cursor}

  @doc false
  def cursor(page, last), do: {:store_page, 1, page.prefix, last}

  @doc "Exclusive bytea range end for one encoded tuple prefix."
  def upper_bound(prefix), do: increment(prefix)
  defp increment(<<>>), do: nil

  defp increment(bytes) do
    head = binary_part(bytes, 0, byte_size(bytes) - 1)
    last = :binary.last(bytes)
    if last == 255, do: increment(head), else: head <> <<last + 1>>
  end

  @doc false
  def matches?(key, prefix),
    do: is_binary(key) and :binary.longest_common_prefix([key, prefix]) == byte_size(prefix)

  @doc "Reads a page from an ordered key index, fetching only the selected values."
  def read(index, fetch, prefix, opts) do
    with {:ok, page} <- options(prefix, opts) do
      iterator = :gb_trees.iterator_from(page.after || page.prefix, index)
      collect(iterator, fetch, page, [], 0, nil)
    end
  end

  defp collect(iterator, fetch, page, entries, bytes, last) do
    case :gb_trees.next(iterator) do
      :none ->
        {:ok, Enum.reverse(entries), nil}

      {order, key, next} ->
        cond do
          not matches?(order, page.prefix) -> {:ok, Enum.reverse(entries), nil}
          order == page.after -> collect(next, fetch, page, entries, bytes, last)
          length(entries) == page.limit -> {:ok, Enum.reverse(entries), cursor(page, last)}
          true -> take(next, fetch, page, entries, bytes, last, order, key)
        end
    end
  end

  defp take(next, fetch, page, entries, bytes, last, order, key) do
    entry = fetch.(key)
    size = :erlang.external_size({key, entry})

    cond do
      bytes + size <= page.max_bytes ->
        collect(next, fetch, page, [{key, entry} | entries], bytes + size, order)

      entries == [] ->
        {:error, :store_page_entry_too_large}

      true ->
        {:ok, Enum.reverse(entries), cursor(page, last)}
    end
  end
end
