defmodule Spectre.Server.Store.Disk do
  @moduledoc """
  Single-owner, versioned local snapshot store for Server coordination.

  Each mutation persists a checksummed canonical snapshot, syncs its temporary
  file, atomically renames it, and syncs the containing directory before reply.
  A failed durability barrier stops the owner: callers must reopen and inspect
  the recovered state instead of assuming the write was absent.

  Values must be portable data, without structs, processes, references or
  functions. A checkpoint adapter must explicitly encode its application state.
  Store an inbox and checkpoint together in one value to acquire them atomically.
  CAS revisions avoid lost updates between checkpoint writers. This is a local
  filesystem adapter, not a distributed transaction or a multi-host file lock.
  Revisions never repeat after deletion, including across restart. Capacity
  failures return `:store_capacity_exceeded` without acquiring a partial write.

  A mutation rewrites this bounded snapshot. Prefer one store per conversation
  or small coordination group; high-volume shared installations should provide
  an append-log or transactional `Spectre.Server.Store` implementation.
  """
  use GenServer
  @behaviour Spectre.Server.Store

  alias Spectre.GAM.Canonical.Value
  alias Spectre.GAM.Ledger.Store.Disk.FileIO
  alias Spectre.Server.Store.Page

  @magic "SPSS1"
  @default_max_bytes 16 * 1_024 * 1_024

  @spec child_spec(keyword()) :: Supervisor.child_spec()

  @doc """
  Starts a single local owner using the required `:path` to the snapshot file.

  Set `:name` to register the owner or `:max_bytes` to change its 16 MiB
  snapshot payload limit. An absent snapshot starts empty. A path with an
  existing owner or invalid snapshot stops startup with an error.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl Spectre.Server.Store
  def fetch(store, key), do: GenServer.call(store, {:fetch, key})
  @impl Spectre.Server.Store
  def put_new(store, key, value), do: GenServer.call(store, {:put_new, key, value}, :infinity)

  @impl Spectre.Server.Store
  def compare_and_swap(store, key, expected_revision, value),
    do: GenServer.call(store, {:cas, key, expected_revision, value}, :infinity)

  @impl Spectre.Server.Store
  def delete(store, key, expected_revision),
    do: GenServer.call(store, {:delete, key, expected_revision}, :infinity)

  @impl Spectre.Server.Store
  def list(store, prefix, opts \\ []),
    do: GenServer.call(store, {:list, prefix, opts}, :infinity)

  @impl true
  def init(opts) do
    with {:ok, path, max_bytes} <- options(opts),
         :ok <- FileIO.ensure_directory(Path.dirname(path)),
         {:ok, owner_key} <- owner_key(path),
         :yes <- :global.register_name(owner_key, self()),
         {:ok, entries, sequence} <- read(path, max_bytes) do
      {:ok,
       %{
         path: path,
         max_bytes: max_bytes,
         entries: entries,
         sequence: sequence,
         index: Page.index(Map.keys(entries))
       }}
    else
      :no -> {:stop, :store_path_in_use}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Resolve directory identity through the filesystem rather than the spelling
  # of its path. Symlinked ancestors must not create two local writers for the
  # same directory entry. Atomic snapshot replacement changes the file inode,
  # so the lock belongs to the physical parent and basename, not to that inode.
  defp owner_key(path) do
    case File.stat(Path.dirname(path)) do
      {:ok, %File.Stat{type: :directory, inode: inode, major_device: major, minor_device: minor}} ->
        {:ok, {__MODULE__, node(), major, minor, inode, Path.basename(path)}}

      {:ok, _stat} ->
        {:error, :invalid_store_directory}

      {:error, reason} ->
        {:error, {:store_directory_stat_failed, reason}}
    end
  end

  @impl true
  def handle_call({:fetch, key}, _from, state) do
    {:reply, Map.get(state.entries, key, :not_found) |> found(), state}
  end

  def handle_call({:list, prefix, opts}, _from, state),
    do: {:reply, Page.read(state.index, &Map.fetch!(state.entries, &1), prefix, opts), state}

  def handle_call({:put_new, key, value}, _from, state) do
    if Map.has_key?(state.entries, key) do
      {:reply, {:error, :exists}, state}
    else
      commit(state, key, value)
    end
  end

  def handle_call({:cas, key, expected, value}, _from, state) do
    case Map.get(state.entries, key) do
      %{revision: ^expected} -> commit(state, key, value)
      _ -> {:reply, {:error, :conflict}, state}
    end
  end

  def handle_call({:delete, key, expected}, _from, state) do
    case Map.get(state.entries, key) do
      %{revision: ^expected} ->
        persist(state, Map.delete(state.entries, key), :ok, Page.delete(state.index, key))

      _ ->
        {:reply, {:error, :conflict}, state}
    end
  end

  defp found(:not_found), do: :not_found
  defp found(entry), do: {:ok, entry}

  defp commit(state, key, value) do
    revision = state.sequence + 1
    entries = Map.put(state.entries, key, %{revision: revision, value: value})
    persist(state, entries, {:ok, revision}, Page.put(state.index, key))
  end

  defp persist(state, entries, reply, index) do
    sequence = state.sequence + 1

    case Value.encode(%{version: 2, entries: entries, sequence: sequence},
           max_bytes: state.max_bytes
         ) do
      {:ok, bytes} ->
        case write(state.path, bytes) do
          :ok -> {:reply, reply, %{state | entries: entries, sequence: sequence, index: index}}
          {:error, reason} -> {:stop, {:store_write_failed, reason}, {:error, reason}, state}
        end

      {:error, {:canonical_value_too_large, _used, _limit}} ->
        {:reply, {:error, :store_capacity_exceeded}, state}

      {:error, reason} ->
        {:reply, {:error, {:nonportable_store_value, reason}}, state}
    end
  end

  defp options(opts) do
    path = Keyword.get(opts, :path)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    if is_binary(path) and byte_size(path) > 0 and is_integer(max_bytes) and max_bytes > 0,
      do: {:ok, Path.expand(path), max_bytes},
      else: {:error, :invalid_store_options}
  end

  defp read(path, max_bytes) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{}, 0}

      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes + 37 ->
        with {:ok, <<@magic, digest::binary-size(32), bytes::binary>>} <- File.read(path),
             true <- :crypto.hash(:sha256, bytes) == digest,
             {:ok, snapshot} <- Value.decode(bytes, max_bytes: max_bytes),
             {:ok, entries, sequence} <- restore_snapshot(snapshot),
             :ok <- FileIO.durability_barrier(path, Path.dirname(path)) do
          {:ok, entries, sequence}
        else
          _ -> {:error, :invalid_store_snapshot}
        end

      {:ok, _stat} ->
        {:error, :invalid_store_snapshot}

      {:error, reason} ->
        {:error, {:store_read_failed, reason}}
    end
  end

  defp restore_snapshot(%{version: 1, entries: entries}) do
    if valid_entries?(entries),
      do:
        {:ok, entries,
         Enum.max(Enum.map(entries, fn {_key, entry} -> entry.revision end), fn -> 0 end)},
      else: {:error, :invalid_store_snapshot}
  end

  defp restore_snapshot(%{version: 2, entries: entries, sequence: sequence})
       when is_integer(sequence) and sequence >= 0 do
    if valid_entries?(entries) and
         Enum.all?(entries, fn {_key, entry} -> entry.revision <= sequence end),
       do: {:ok, entries, sequence},
       else: {:error, :invalid_store_snapshot}
  end

  defp restore_snapshot(_), do: {:error, :invalid_store_snapshot}

  defp valid_entries?(entries) when is_map(entries) do
    Enum.all?(entries, fn
      {_key, %{revision: revision, value: _value} = entry}
      when is_integer(revision) and revision > 0 and map_size(entry) == 2 ->
        true

      _ ->
        false
    end)
  end

  defp valid_entries?(_), do: false

  defp write(path, bytes) do
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    frame = @magic <> :crypto.hash(:sha256, bytes) <> bytes

    result =
      with {:ok, io} <-
             :file.open(String.to_charlist(temporary), [:raw, :binary, :write, :exclusive]) do
        write_result = with :ok <- :file.write(io, frame), do: :file.sync(io)
        close_result = :file.close(io)

        with :ok <- write_result,
             :ok <- close_result,
             :ok <- File.rename(temporary, path) do
          FileIO.durability_barrier(path, Path.dirname(path))
        end
      end

    File.rm(temporary)
    result
  end
end
