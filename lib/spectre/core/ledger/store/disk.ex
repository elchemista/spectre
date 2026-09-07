defmodule Spectre.Ledger.Store.Disk do
  @moduledoc """
  File-backed, serialized Store for Domain ledgers.

  Each Domain is stored in a file named by the SHA-256 digest of its reference.
  Every atomic logical batch occupies one length-delimited frame containing a
  canonical payload and a raw SHA-256 checksum:

      magic | version | payload length | checksum | canonical batch payload

  A successful append is returned only after the complete frame and any new
  directory entry cross their filesystem durability barriers. Recovery accepts
  complete verified frames only and repeats that barrier before trusting a
  recovered commit. The default `tail_policy: :reject` reports an incomplete tail;
  `tail_policy: :truncate` explicitly removes only an incomplete final frame
  and records that recovery in the returned runtime snapshot. A checksum,
  canonical decoding, identity, or chain failure is corruption and is never
  truncated automatically.

  The process retains only Domain cursors and private compressed ETS indexes
  of batch identities/file offsets. Entry bodies remain on disk. Native batch
  reads fetch one frame; load/export explicitly materialize a complete result.
  `compressed: true` compresses new frame bodies losslessly when worthwhile.
  Both stored and expanded sizes are bounded by `:max_frame_bytes`; old plain
  frames remain readable regardless of the current write setting.

  One GenServer serializes every mutation for its directory. Directory ownership
  is registered globally, so a second Store in the same connected BEAM cluster
  is rejected. A filesystem shared by disconnected Erlang clusters still needs
  deployment-level fencing.

  `:fault_injection` (or `:fault`) accepts `:before_commit` and
  `:after_commit`. Both return `{:error, :ambiguous}`; the latter writes and
  syncs the batch first.
  """

  use GenServer

  @behaviour Spectre.Ledger.Store

  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Disk.{FileIO, Frame}
  alias Spectre.Ledger.Store.Support

  @frame_header_size Frame.header_size()
  @default_max_frame_bytes 64 * 1_024 * 1_024
  @max_frame_bytes_ceiling 1_024 * 1_024 * 1_024
  @server_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @init_options [:path, :directory, :tail_policy, :max_frame_bytes, :compressed]
  @start_options @server_options ++ @init_options
  @read_options [:server, :timeout]
  @append_options @read_options ++ [:recorded_at, :fault_injection, :fault]

  @type domain_state :: %{
          revision: non_neg_integer(),
          head_digest: Entry.digest(),
          index: :ets.tid(),
          file_bytes: non_neg_integer(),
          recovery: map() | nil
        }

  @type state :: %{
          directory: String.t(),
          ownership_name: term(),
          tail_policy: :reject | :truncate,
          max_frame_bytes: pos_integer(),
          compressed: boolean(),
          domains: %{optional(String.t()) => domain_state()}
        }

  @doc """
  Starts a serialized disk Store.

  `:path` (or `:directory`) is required. `:tail_policy` defaults to `:reject`.
  `:max_frame_bytes` defaults to 64 MiB and is bounded to 1 GiB.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with :ok <- validate_options(opts, @start_options),
         {:ok, _directory} <- directory(opts),
         {:ok, _policy} <- tail_policy(opts),
         {:ok, _max_bytes} <- max_frame_bytes(opts),
         :ok <- validate_compression(opts) do
      {server_opts, init_opts} = Keyword.split(opts, @server_options)

      GenServer.start_link(__MODULE__, init_opts, server_opts)
    end
  end

  def start_link(_opts), do: {:error, :invalid_ledger_disk_options}

  @impl Spectre.Ledger.Store
  def append(domain_ref, batch_id, payloads, expected_revision, opts) do
    with :ok <- validate_options(opts, @append_options),
         {:ok, server} <- server(opts) do
      GenServer.call(
        server,
        {:append, domain_ref, batch_id, payloads, expected_revision, opts},
        timeout(opts, :infinity)
      )
    end
  end

  @impl Spectre.Ledger.Store
  def load(domain_ref, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:load, domain_ref}, timeout(opts, :infinity))
    end
  end

  @impl Spectre.Ledger.Store
  def load_from(domain_ref, revision, opts)
      when is_integer(revision) and revision >= 0 do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:load_from, domain_ref, revision}, timeout(opts, :infinity))
    end
  end

  def load_from(_domain_ref, _revision, _opts), do: {:error, :invalid_ledger_cursor}

  @impl Spectre.Ledger.Store
  def head(domain_ref, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:head, domain_ref}, timeout(opts, :infinity))
    end
  end

  @impl Spectre.Ledger.Store
  def read_batch(domain_ref, first_revision, opts)
      when is_integer(first_revision) and first_revision > 0 do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:read_batch, domain_ref, first_revision}, timeout(opts, :infinity))
    end
  end

  def read_batch(_domain_ref, _revision, _opts), do: {:error, :invalid_ledger_cursor}

  @impl Spectre.Ledger.Store
  def lookup_batch(domain_ref, batch_id, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:lookup_batch, domain_ref, batch_id}, timeout(opts, :infinity))
    end
  end

  @impl Spectre.Ledger.Store
  def export(domain_ref, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:export, domain_ref}, timeout(opts, :infinity))
    end
  end

  @impl GenServer
  def init(opts) do
    with :ok <- validate_options(opts, @init_options),
         {:ok, directory} <- directory(opts),
         {:ok, tail_policy} <- tail_policy(opts),
         {:ok, max_frame_bytes} <- max_frame_bytes(opts),
         :ok <- validate_compression(opts),
         :ok <- FileIO.ensure_directory(directory),
         {:ok, ownership_name} <- acquire_directory(directory) do
      {:ok,
       %{
         directory: directory,
         ownership_name: ownership_name,
         tail_policy: tail_policy,
         max_frame_bytes: max_frame_bytes,
         compressed: Keyword.get(opts, :compressed, false),
         domains: %{}
       }}
    else
      # Initialization rejection is not a crash of a running Store. OTP's
      # error return preserves the diagnostic without killing a linked caller.
      {:error, _reason} = error -> error
    end
  end

  @impl GenServer
  def terminate(_reason, %{ownership_name: ownership_name}) do
    release_directory(ownership_name)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl GenServer
  def handle_call(
        {:append, domain_ref, batch_id, payloads, expected_revision, opts},
        _from,
        state
      ) do
    {reply, state} =
      with {:ok, identity} <-
             Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
           {:ok, recorded_at} <- Support.recorded_at(opts),
           {:ok, fault} <- Support.fault_phase(opts),
           {:ok, domain, state} <- ensure_loaded_for_append(state, domain_ref) do
        append_batch(
          state,
          domain,
          {domain_ref, batch_id},
          payloads,
          expected_revision,
          recorded_at,
          identity,
          fault
        )
      else
        {:error, _reason} = error -> {error, state}
      end

    state =
      case Map.get(state.domains, domain_ref) do
        %{revision: 0} -> invalidate_domain(state, domain_ref)
        _committed_or_absent -> state
      end

    {:reply, reply, state}
  end

  def handle_call({:load, domain_ref}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} -> {:reply, read_snapshot(state, domain_ref, domain, 0), state}
      {:not_found, state} -> {:reply, :not_found, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_from, domain_ref, revision}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} ->
        {:reply, read_snapshot(state, domain_ref, domain, revision), state}

      {:not_found, state} ->
        {:reply, :not_found, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:head, domain_ref}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, %{revision: 0}, state} ->
        {:reply, :not_found, invalidate_domain(state, domain_ref)}

      {:ok, domain, state} ->
        {:reply, {:ok, Map.take(domain, [:revision, :head_digest])}, state}

      {:not_found, state} ->
        {:reply, :not_found, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_batch, domain_ref, revision}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} ->
        {:reply, read_indexed_batch(state, domain_ref, domain, revision), state}

      {:not_found, state} ->
        {:reply, :not_found, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup_batch, domain_ref, batch_id}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} ->
        reply =
          case :ets.lookup(domain.index, {:batch, batch_id}) do
            [{_, info}] -> {:ok, info}
            [] -> :not_found
          end

        {:reply, reply, state}

      {:not_found, state} ->
        {:reply, :not_found, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:export, domain_ref}, _from, state) do
    # An audit export deliberately re-reads the framed file instead of trusting
    # the process cache. This keeps independent verification useful for
    # detecting on-disk corruption while the Store is running.
    case read_domain(state, domain_ref) do
      {:ok, domain} ->
        state = invalidate_domain(state, domain_ref)
        state = put_in(state, [:domains, domain_ref], domain)

        reply =
          with {:ok, snapshot} <- read_snapshot(state, domain_ref, domain, 0),
               do: Ledger.export_snapshot(snapshot)

        {:reply, reply, state}

      :not_found ->
        {:reply, :not_found, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @spec append_batch(
          state(),
          domain_state(),
          {String.t(), String.t()},
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :before_commit | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, state()}
  defp append_batch(
         state,
         domain,
         {domain_ref, batch_id},
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    batches =
      case :ets.lookup(domain.index, {:batch, batch_id}) do
        [{_, info}] -> %{batch_id => info}
        [] -> %{}
      end

    case Support.append_status(
           Map.put(domain, :batches, batches),
           batch_id,
           identity,
           expected_revision,
           fault
         ) do
      {:existing, revision} ->
        {{:ok, revision}, state}

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
        persist_batch(
          state,
          domain,
          {domain_ref, batch_id},
          payloads,
          expected_revision,
          recorded_at,
          identity,
          fault
        )
    end
  end

  @spec persist_batch(
          state(),
          domain_state(),
          {String.t(), String.t()},
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, state()}
  defp persist_batch(
         state,
         domain,
         {domain_ref, batch_id},
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    with {:ok, entries} <-
           Entry.build_batch(
             domain_ref,
             batch_id,
             payloads,
             expected_revision,
             recorded_at,
             domain.head_digest
           ),
         {:ok, frame} <-
           Frame.encode(
             domain_ref,
             batch_id,
             identity,
             expected_revision,
             entries,
             state.max_frame_bytes,
             state.compressed
           ) do
      commit = %{
        domain: domain,
        batch_id: batch_id,
        identity: identity,
        expected_revision: expected_revision,
        entries: entries,
        fault: fault
      }

      persist_frame(state, domain_ref, frame, commit)
    else
      {:error, _reason} = error -> {error, state}
    end
  end

  @spec persist_frame(state(), String.t(), binary(), map()) ::
          {{:ok, non_neg_integer()} | {:error, term()}, state()}
  defp persist_frame(state, domain_ref, frame, commit) do
    case FileIO.append(state.directory, domain_ref, frame) do
      :ok ->
        install_persisted_batch(state, domain_ref, commit, byte_size(frame))

      {:error, :ambiguous} ->
        {{:error, :ambiguous}, invalidate_domain(state, domain_ref)}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec install_persisted_batch(state(), String.t(), map(), pos_integer()) ::
          {{:ok, non_neg_integer()} | {:error, :ambiguous}, state()}
  defp install_persisted_batch(state, domain_ref, commit, frame_size) do
    last = List.last(commit.entries)
    info = Support.batch_info(commit.batch_id, commit.identity, commit.expected_revision, last)
    committed = install_index(commit.domain, info, commit.domain.file_bytes, frame_size)

    state = put_in(state, [:domains, domain_ref], committed)
    reply = if commit.fault == :after_commit, do: {:error, :ambiguous}, else: {:ok, last.revision}
    {reply, state}
  end

  @spec ensure_loaded_for_append(state(), String.t()) ::
          {:ok, domain_state(), state()} | {:error, term()}
  defp ensure_loaded_for_append(state, domain_ref) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} ->
        {:ok, domain, state}

      {:not_found, state} ->
        domain = empty_domain()
        {:ok, domain, put_in(state, [:domains, domain_ref], domain)}

      {:error, reason, _state} ->
        {:error, reason}
    end
  end

  @spec load_domain_state(state(), String.t()) ::
          {:ok, domain_state(), state()}
          | {:not_found, state()}
          | {:error, term(), state()}
  defp load_domain_state(state, domain_ref) do
    case Map.fetch(state.domains, domain_ref) do
      {:ok, %{revision: 0}} ->
        {:not_found, invalidate_domain(state, domain_ref)}

      {:ok, domain} ->
        {:ok, domain, state}

      :error ->
        case read_domain(state, domain_ref) do
          {:ok, domain} ->
            {:ok, domain, put_in(state, [:domains, domain_ref], domain)}

          :not_found ->
            {:not_found, state}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  @spec invalidate_domain(state(), String.t()) :: state()
  defp invalidate_domain(state, domain_ref) do
    case Map.get(state.domains, domain_ref) do
      nil -> :ok
      domain -> :ets.delete(domain.index)
    end

    %{state | domains: Map.delete(state.domains, domain_ref)}
  end

  defp empty_domain do
    %{
      revision: 0,
      head_digest: Entry.genesis_digest(),
      recovery: nil,
      file_bytes: 0,
      index: :ets.new(__MODULE__, [:set, :private, :compressed])
    }
  end

  defp install_index(domain, info, offset, size) do
    :ets.insert(domain.index, [
      {{:batch, info.batch_id}, info},
      {{:frame, info.first_revision}, {offset, size, info.batch_id}}
    ])

    %{
      domain
      | revision: info.last_revision,
        head_digest: info.head_digest,
        file_bytes: offset + size
    }
  end

  @spec read_domain(state(), String.t()) :: :not_found | {:ok, domain_state()} | {:error, term()}
  defp read_domain(state, domain_ref) do
    path = FileIO.path(state.directory, domain_ref)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        :not_found

      {:ok, %File.Stat{type: :regular, size: size}} ->
        with {:ok, domain} <- scan_domain_file(path, domain_ref, size, state) do
          confirm_recovered_index(FileIO.durability_barrier(path, state.directory), domain)
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_ledger_disk_file_type, type}}

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        {:error, {:ledger_disk_stat_failed, reason}}
    end
  end

  defp confirm_recovered_index(:ok, domain), do: {:ok, domain}

  defp confirm_recovered_index({:error, _} = error, domain) do
    :ets.delete(domain.index)
    error
  end

  @spec scan_domain_file(String.t(), String.t(), non_neg_integer(), state()) ::
          {:ok, domain_state()} | {:error, term()}
  defp scan_domain_file(path, domain_ref, file_size, state) do
    modes =
      if state.tail_policy == :truncate,
        do: [:raw, :binary, :read, :write],
        else: [:raw, :binary, :read]

    case :file.open(String.to_charlist(path), modes) do
      {:ok, io} ->
        domain = empty_domain()

        try do
          result =
            scan_frames(
              io,
              domain_ref,
              domain,
              0,
              file_size,
              state.tail_policy,
              state.max_frame_bytes
            )

          case result do
            {:ok, _} ->
              result

            {:error, _} ->
              :ets.delete(domain.index)
              result
          end
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, {:ledger_disk_read_failed, reason}}
    end
  end

  @spec scan_frames(
          :file.io_device(),
          String.t(),
          domain_state(),
          non_neg_integer(),
          non_neg_integer(),
          :reject | :truncate,
          pos_integer()
        ) :: {:ok, domain_state()} | {:error, term()}
  defp scan_frames(io, domain_ref, domain, offset, file_size, tail_policy, max_frame_bytes) do
    case :file.read(io, @frame_header_size) do
      :eof ->
        {:ok, domain}

      {:ok, header} when byte_size(header) < @frame_header_size ->
        recover_incomplete_tail(io, domain, offset, file_size, tail_policy)

      {:ok, header} ->
        with {:ok, length, checksum} <- Frame.header(header, offset, max_frame_bytes),
             {:ok, encoded} <- FileIO.read_body(io, length, offset),
             {:ok, data} <-
               Frame.decode_payload(encoded, checksum, domain_ref, offset, max_frame_bytes),
             {:ok, domain} <-
               apply_frame(data, domain_ref, domain, offset, @frame_header_size + length) do
          scan_frames(
            io,
            domain_ref,
            domain,
            offset + @frame_header_size + length,
            file_size,
            tail_policy,
            max_frame_bytes
          )
        else
          {:incomplete, _reason} ->
            recover_incomplete_tail(io, domain, offset, file_size, tail_policy)

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        {:error, {:ledger_disk_read_failed, offset, reason}}
    end
  end

  defp validate_compression(opts) do
    if is_boolean(Keyword.get(opts, :compressed, false)),
      do: :ok,
      else: {:error, :invalid_ledger_disk_compressed}
  end

  @spec apply_frame(map(), String.t(), domain_state(), non_neg_integer(), pos_integer()) ::
          {:ok, domain_state()} | {:error, term()}
  defp apply_frame(data, domain_ref, domain, offset, size) do
    with :ok <- frame_predecessor(data["expected_revision"], domain.revision, offset),
         {:ok, info, entries} <- Frame.decode_batch(data, domain_ref, offset),
         true <- info.expected_revision === domain.revision,
         true <- hd(entries).prev_digest === domain.head_digest,
         [] <- :ets.lookup(domain.index, {:batch, info.batch_id}) do
      {:ok, install_index(domain, info, offset, size)}
    else
      {:error, _} = error -> error
      _invalid -> {:error, {:invalid_or_duplicate_ledger_frame, offset}}
    end
  end

  defp frame_predecessor(expected, revision, offset)
       when is_integer(expected) and expected >= 0 do
    if expected === revision,
      do: :ok,
      else: {:error, {:invalid_or_duplicate_ledger_frame, offset}}
  end

  defp frame_predecessor(_expected, _revision, offset),
    do: {:error, {:invalid_ledger_frame, offset}}

  defp read_indexed_batch(state, domain_ref, domain, revision) do
    case :ets.lookup(domain.index, {:frame, revision}) do
      [] ->
        :not_found

      [{_, {offset, size, batch_id}}] ->
        [{_, expected}] = :ets.lookup(domain.index, {:batch, batch_id})

        with {:ok, frame} <- FileIO.pread(state.directory, domain_ref, offset, size),
             <<header::binary-size(@frame_header_size), encoded::binary>> <- frame,
             {:ok, length, checksum} <- Frame.header(header, offset, state.max_frame_bytes),
             true <- byte_size(encoded) === length,
             {:ok, data} <-
               Frame.decode_payload(encoded, checksum, domain_ref, offset, state.max_frame_bytes),
             {:ok, ^expected, entries} <- Frame.decode_batch(data, domain_ref, offset) do
          {:ok,
           %{
             domain_ref: domain_ref,
             revision: expected.last_revision,
             head_digest: expected.head_digest,
             entries: entries,
             recovery: domain.recovery
           }}
        else
          {:error, _} = error -> error
          _invalid -> {:error, {:ledger_disk_index_mismatch, revision}}
        end
    end
  end

  defp read_snapshot(state, domain_ref, domain, revision) do
    # Full load/export intentionally materializes its result. Recovery uses
    # read_batch instead. The writer retains only small indexed file offsets.
    with {:ok, entries} <- collect_batches(state, domain_ref, domain, revision, []) do
      {:ok,
       %{
         domain_ref: domain_ref,
         revision: domain.revision,
         head_digest: domain.head_digest,
         entries: entries,
         recovery: domain.recovery
       }}
    end
  end

  defp collect_batches(_state, _domain_ref, domain, revision, entries)
       when revision >= domain.revision, do: {:ok, Enum.reverse(entries)}

  defp collect_batches(state, domain_ref, domain, revision, entries) do
    case read_indexed_batch(state, domain_ref, domain, revision + 1) do
      {:ok, page} ->
        collect_batches(
          state,
          domain_ref,
          domain,
          page.revision,
          Enum.reverse(page.entries, entries)
        )

      :not_found ->
        {:error, :ledger_cursor_inside_batch}

      {:error, _} = error ->
        error
    end
  end

  @spec recover_incomplete_tail(
          :file.io_device(),
          domain_state(),
          non_neg_integer(),
          non_neg_integer(),
          :reject | :truncate
        ) :: {:ok, domain_state()} | {:error, term()}
  defp recover_incomplete_tail(_io, _domain, offset, _file_size, :reject),
    do: {:error, {:incomplete_ledger_tail, offset}}

  defp recover_incomplete_tail(io, domain, offset, file_size, :truncate) do
    with {:ok, ^offset} <- :file.position(io, offset),
         :ok <- :file.truncate(io),
         :ok <- :file.sync(io) do
      {:ok,
       %{
         domain
         | recovery: %{
             kind: :truncated_incomplete_tail,
             offset: offset,
             truncated_bytes: max(file_size - offset, 0)
           }
       }}
    else
      _failure -> {:error, :ambiguous}
    end
  end

  @spec directory(keyword()) :: {:ok, String.t()} | {:error, term()}
  defp directory(opts) do
    case Keyword.get(opts, :path, Keyword.get(opts, :directory)) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _value -> {:error, :ledger_disk_path_required}
    end
  end

  @spec tail_policy(keyword()) :: {:ok, :reject | :truncate} | {:error, term()}
  defp tail_policy(opts) do
    case Keyword.get(opts, :tail_policy, :reject) do
      policy when policy in [:reject, :truncate] -> {:ok, policy}
      value -> {:error, {:invalid_ledger_tail_policy, value}}
    end
  end

  @spec max_frame_bytes(keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp max_frame_bytes(opts) do
    case Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes) do
      value when is_integer(value) and value > 0 and value <= @max_frame_bytes_ceiling ->
        {:ok, value}

      value ->
        {:error, {:invalid_ledger_max_frame_bytes, value}}
    end
  end

  @spec acquire_directory(String.t()) :: {:ok, term()} | {:error, term()}
  defp acquire_directory(directory) do
    ownership_name = {__MODULE__, :directory_owner, directory}

    case :global.register_name(ownership_name, self()) do
      :yes -> {:ok, ownership_name}
      :no -> {:error, {:ledger_disk_directory_in_use, directory}}
    end
  catch
    :exit, reason -> {:error, {:ledger_disk_directory_lock_failed, reason}}
  end

  @spec release_directory(term()) :: :ok
  defp release_directory(ownership_name) do
    :global.unregister_name(ownership_name)
    :ok
  catch
    _kind, _reason -> :ok
  end

  @spec server(keyword()) :: {:ok, GenServer.server()} | {:error, term()}
  defp server(opts) when is_list(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> {:ok, server}
      :error -> {:error, :ledger_disk_store_server_required}
    end
  end

  @spec timeout(keyword(), timeout()) :: timeout()
  defp timeout(opts, default), do: Keyword.get(opts, :timeout, default)

  defp validate_options(opts, allowed) do
    Support.validate_options(
      opts,
      allowed,
      :invalid_ledger_disk_options,
      :unknown_ledger_disk_options
    )
  end
end
