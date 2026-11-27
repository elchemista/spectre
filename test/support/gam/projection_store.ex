defmodule Spectre.Test.GAM.ProjectionStore do
  @moduledoc false
  @behaviour ExGAM.Domain.Projection.Store
  alias ExGAM.Domain.Projection.{IndexRows, Rows}
  alias ExGAM.Ledger.Entry

  def start_link, do: Agent.start_link(fn -> %{} end)

  @impl true
  def open(domain, opts) do
    handle = %{domain: domain, generation: Integer.to_string(System.unique_integer([:positive]))}

    value = %{
      handle: handle,
      cursor: %{revision: 0, head_digest: Entry.genesis_digest()},
      rows: %{}
    }

    Agent.update(opts[:server], &Map.put(&1, domain, value))
    {:ok, handle}
  end

  @impl true
  def head(domain, opts) do
    Agent.get(opts[:server], fn state ->
      case Map.fetch(state, domain) do
        {:ok, value} -> {:ok, Map.take(value, [:handle, :cursor])}
        :error -> :not_found
      end
    end)
  end

  @impl true
  def commit(handle, before, next, changes, opts) do
    encoded =
      Enum.map(changes, fn
        {:put, key, value} ->
          {:ok, bytes} = Rows.encode(value)
          {:put, key, bytes}

        change ->
          change
      end)

    Agent.get_and_update(opts[:server], fn state ->
      case state[handle.domain] do
        %{handle: ^handle, cursor: ^before} = current ->
          rows = apply_changes(current.rows, encoded)

          {:ok, Map.put(state, handle.domain, %{current | rows: rows, cursor: next})}

        _ ->
          {{:error, :stale_domain_projection}, state}
      end
    end)
  end

  defp apply_changes(rows, changes) do
    Enum.reduce(changes, rows, fn
      {:put, key, bytes}, rows -> Map.put(rows, key, bytes)
      {:delete, key}, rows -> Map.delete(rows, key)
    end)
  end

  @impl true
  def fetch(handle, cursor, keys, opts),
    do: read(handle, cursor, opts, fn rows -> {:ok, Map.take(rows, keys)} end)

  @impl true
  def select(handle, cursor, collection, selection, opts),
    do: page(handle, cursor, collection, Keyword.merge(opts, selection))

  @impl true
  def page(handle, cursor, collection, opts) do
    read(handle, cursor, opts, fn rows ->
      found =
        rows
        |> Enum.filter(&matches?(&1, collection, opts))
        |> order(collection, opts[:nearest])

      after_key = opts[:after]
      found = if after_key, do: Enum.drop_while(found, &(elem(&1, 0) <= after_key)), else: found
      limit = opts[:limit] || 50
      page = Enum.take(found, limit)
      next = if length(found) > limit, do: page |> List.last() |> elem(0), else: nil
      {:ok, page, next}
    end)
  end

  defp matches?({{name, _}, _}, collection, _) when name != collection, do: false

  defp matches?({{_name, key}, _}, collection, opts) do
    group =
      if collection == :record_refs, do: elem(key, 0), else: IndexRows.group(collection, key)

    position = IndexRows.position(collection, key)
    group_matches?(group, opts) and in_range?(position, opts)
  end

  defp group_matches?(group, opts),
    do: not Keyword.has_key?(opts, :group) or group === opts[:group]

  defp in_range?(position, opts) do
    after_first?(position, opts[:from]) and before_last?(position, opts[:through])
  end

  defp after_first?(_, nil), do: true
  defp after_first?(position, first), do: is_integer(position) and position >= first
  defp before_last?(_, nil), do: true
  defp before_last?(position, last), do: is_integer(position) and position <= last

  defp order(rows, collection, true) do
    rows
    |> Enum.sort_by(fn {{_, key}, _} -> {IndexRows.position(collection, key), key} end)
    |> Enum.take(1)
  end

  defp order(rows, _, _), do: Enum.sort_by(rows, &elem(&1, 0))

  defp read(handle, cursor, opts, fun) do
    Agent.get(opts[:server], fn state ->
      case state[handle.domain] do
        %{handle: ^handle, cursor: ^cursor, rows: rows} -> fun.(rows)
        _ -> {:error, :stale_domain_projection}
      end
    end)
  end
end

defmodule Spectre.Test.GAM.ProjectionLedger do
  @moduledoc false
  alias ExGAM.Ledger.Store
  defdelegate append(domain, id, payloads, revision, opts), to: Store.Mock
  defdelegate load(domain, opts), to: Store.Mock
  defdelegate load_from(domain, cursor, opts), to: Store.Mock
  defdelegate lookup_batch(domain, id, opts), to: Store.Mock
  defdelegate export(domain, opts), to: Store.Mock
  def head(domain, opts), do: Store.head(underlying(opts), domain, [])

  def read_batch(domain, revision, opts),
    do: Store.read_batch(underlying(opts), domain, revision, [])

  defp underlying(opts), do: :sys.get_state(opts[:server]).store
end
