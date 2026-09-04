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

  alias Spectre.Canonical.Value
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  @frame_magic "SPDL"
  @frame_version 1
  @frame_header_size 4 + 1 + 8 + 32
  @frame_format "spectre-ledger-batch-frame"
  @frame_fields ~w(format format_version domain_ref batch_id identity_digest expected_revision entries)
  @default_max_frame_bytes 64 * 1_024 * 1_024
  @max_frame_bytes_ceiling 1_024 * 1_024 * 1_024
  @server_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @init_options [:path, :directory, :tail_policy, :max_frame_bytes]
  @start_options @server_options ++ @init_options
  @read_options [:server, :timeout]
  @append_options @read_options ++ [:recorded_at, :fault_injection, :fault]

  @type domain_state :: %{
          revision: non_neg_integer(),
          head_digest: Entry.digest(),
          entries_rev: [Entry.t()],
          batches: %{optional(String.t()) => Ledger.batch_info()},
          recovery: map() | nil
        }

  @type state :: %{
          directory: String.t(),
          ownership_name: term(),
          tail_policy: :reject | :truncate,
          max_frame_bytes: pos_integer(),
          domains: %{optional(String.t()) => domain_state()}
        }

  @doc """
  Starts a serialized disk Store.

  `:path` (or `:directory`) is required. `:tail_policy` defaults to `:reject`.
  `:max_frame_bytes` defaults to 64 MiB and is bounded to 1 GiB.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with :ok <- validate_options(opts, @start_options) do
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
         :ok <- ensure_directory(directory),
         {:ok, ownership_name} <- acquire_directory(directory) do
      {:ok,
       %{
         directory: directory,
         ownership_name: ownership_name,
         tail_policy: tail_policy,
         max_frame_bytes: max_frame_bytes,
         domains: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
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
          domain_ref,
          batch_id,
          payloads,
          expected_revision,
          recorded_at,
          identity,
          fault
        )
      else
        {:error, _reason} = error -> {error, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:load, domain_ref}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} -> {:reply, {:ok, Support.snapshot(domain_ref, domain)}, state}
      {:not_found, state} -> {:reply, :not_found, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup_batch, domain_ref, batch_id}, _from, state) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} ->
        reply =
          case Map.fetch(domain.batches, batch_id) do
            {:ok, info} -> {:ok, info}
            :error -> :not_found
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
        state = put_in(state, [:domains, domain_ref], domain)
        reply = domain_ref |> Support.snapshot(domain) |> Ledger.export_snapshot()
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
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :before_commit | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, state()}
  defp append_batch(
         state,
         domain,
         domain_ref,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    case Support.append_status(domain, batch_id, identity, expected_revision, fault) do
      {:existing, revision} ->
        {{:ok, revision}, state}

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
        persist_batch(
          state,
          domain,
          domain_ref,
          batch_id,
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
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, state()}
  defp persist_batch(
         state,
         domain,
         domain_ref,
         batch_id,
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
           encode_frame(
             domain_ref,
             batch_id,
             identity,
             expected_revision,
             entries,
             state.max_frame_bytes
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
    case write_frame(state, domain_ref, frame) do
      :ok ->
        install_persisted_batch(
          state,
          commit.domain,
          domain_ref,
          commit.batch_id,
          commit.identity,
          commit.expected_revision,
          commit.entries,
          commit.fault
        )

      {:error, :ambiguous} ->
        {{:error, :ambiguous}, invalidate_domain(state, domain_ref)}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec install_persisted_batch(
          state(),
          domain_state(),
          String.t(),
          String.t(),
          Entry.digest(),
          non_neg_integer(),
          [Entry.t()],
          nil | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, :ambiguous}, state()}
  defp install_persisted_batch(
         state,
         domain,
         domain_ref,
         batch_id,
         identity,
         expected_revision,
         entries,
         fault
       ) do
    {committed, last} =
      Support.install_batch(domain, batch_id, identity, expected_revision, entries)

    state = put_in(state, [:domains, domain_ref], committed)
    reply = if fault == :after_commit, do: {:error, :ambiguous}, else: {:ok, last.revision}
    {reply, state}
  end

  @spec ensure_loaded_for_append(state(), String.t()) ::
          {:ok, domain_state(), state()} | {:error, term()}
  defp ensure_loaded_for_append(state, domain_ref) do
    case load_domain_state(state, domain_ref) do
      {:ok, domain, state} -> {:ok, domain, state}
      {:not_found, state} -> {:ok, Support.empty_domain(), state}
      {:error, reason, _state} -> {:error, reason}
    end
  end

  @spec load_domain_state(state(), String.t()) ::
          {:ok, domain_state(), state()}
          | {:not_found, state()}
          | {:error, term(), state()}
  defp load_domain_state(state, domain_ref) do
    case Map.fetch(state.domains, domain_ref) do
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
  defp invalidate_domain(state, domain_ref),
    do: %{state | domains: Map.delete(state.domains, domain_ref)}

  @spec encode_frame(
          String.t(),
          String.t(),
          Entry.digest(),
          non_neg_integer(),
          [Entry.t()],
          pos_integer()
        ) :: {:ok, binary()} | {:error, term()}
  defp encode_frame(
         domain_ref,
         batch_id,
         identity,
         expected_revision,
         entries,
         max_frame_bytes
       ) do
    data = %{
      "format" => @frame_format,
      "format_version" => @frame_version,
      "domain_ref" => domain_ref,
      "batch_id" => batch_id,
      "identity_digest" => identity,
      "expected_revision" => expected_revision,
      "entries" => Enum.map(entries, &Entry.to_data/1)
    }

    case Value.encode(data, max_bytes: max_frame_bytes) do
      {:ok, encoded} ->
        checksum = :crypto.hash(:sha256, encoded)

        {:ok,
         <<@frame_magic, @frame_version, byte_size(encoded)::unsigned-big-64,
           checksum::binary-size(32), encoded::binary>>}

      {:error, {:canonical_value_too_large, size, _limit}} ->
        {:error, {:ledger_frame_too_large, size, max_frame_bytes}}

      {:error, reason} ->
        {:error, {:invalid_ledger_frame, reason}}
    end
  end

  @spec write_frame(state(), String.t(), binary()) :: :ok | {:error, term()}
  defp write_frame(state, domain_ref, frame) do
    path = domain_path(state.directory, domain_ref)

    with {:ok, directory_sync_required?} <- directory_sync_required?(path) do
      case :file.open(String.to_charlist(path), [:raw, :binary, :append]) do
        {:ok, io} ->
          result = write_and_sync(io, frame)
          close_result = :file.close(io)

          case {result, close_result, directory_sync_required?} do
            {:ok, :ok, false} ->
              :ok

            {:ok, :ok, true} ->
              case sync_directory(state.directory) do
                :ok -> :ok
                {:error, _reason} -> {:error, :ambiguous}
              end

            _uncertain ->
              {:error, :ambiguous}
          end

        {:error, reason} ->
          {:error, {:ledger_disk_open_failed, reason}}
      end
    end
  end

  @spec write_and_sync(:file.io_device(), binary()) :: :ok | {:error, term()}
  defp write_and_sync(io, frame) do
    with :ok <- :file.write(io, frame),
         :ok <- :file.sync(io) do
      :ok
    else
      {:error, _reason} = error -> error
      _reply -> {:error, :invalid_disk_write_reply}
    end
  end

  @spec read_domain(state(), String.t()) :: :not_found | {:ok, domain_state()} | {:error, term()}
  defp read_domain(state, domain_ref) do
    path = domain_path(state.directory, domain_ref)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: 0}} ->
        :not_found

      {:ok, %File.Stat{type: :regular, size: size}} ->
        with {:ok, domain} <- scan_domain_file(path, domain_ref, size, state),
             :ok <- durability_barrier(path, state.directory) do
          {:ok, domain}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:invalid_ledger_disk_file_type, type}}

      {:error, :enoent} ->
        :not_found

      {:error, reason} ->
        {:error, {:ledger_disk_stat_failed, reason}}
    end
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
        try do
          scan_frames(
            io,
            domain_ref,
            Support.empty_domain(),
            0,
            file_size,
            state.tail_policy,
            state.max_frame_bytes
          )
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
        with {:ok, length, checksum} <- decode_header(header, offset, max_frame_bytes),
             {:ok, encoded} <- read_frame_body(io, length, offset),
             :ok <- verify_checksum(encoded, checksum, offset),
             {:ok, data} <- decode_frame_data(encoded, max_frame_bytes, offset),
             {:ok, domain} <- apply_frame(data, domain_ref, domain, offset) do
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

  @spec decode_header(binary(), non_neg_integer(), pos_integer()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  defp decode_header(
         <<@frame_magic, @frame_version, length::unsigned-big-64, checksum::binary-size(32)>>,
         offset,
         max_frame_bytes
       ) do
    cond do
      length == 0 -> {:error, {:invalid_ledger_frame_length, offset, length}}
      length > max_frame_bytes -> {:error, {:ledger_frame_too_large, offset, length}}
      true -> {:ok, length, checksum}
    end
  end

  defp decode_header(<<@frame_magic, version, _rest::binary>>, offset, _max),
    do: {:error, {:unsupported_ledger_frame_version, offset, version}}

  defp decode_header(_header, offset, _max),
    do: {:error, {:invalid_ledger_frame_header, offset}}

  @spec read_frame_body(:file.io_device(), pos_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:incomplete, term()} | {:error, term()}
  defp read_frame_body(io, length, offset) do
    case :file.read(io, length) do
      {:ok, encoded} when byte_size(encoded) == length -> {:ok, encoded}
      {:ok, _partial} -> {:incomplete, {:ledger_frame_body, offset}}
      :eof -> {:incomplete, {:ledger_frame_body, offset}}
      {:error, reason} -> {:error, {:ledger_disk_read_failed, offset, reason}}
    end
  end

  @spec verify_checksum(binary(), binary(), non_neg_integer()) :: :ok | {:error, term()}
  defp verify_checksum(encoded, checksum, offset) do
    if :crypto.hash(:sha256, encoded) == checksum,
      do: :ok,
      else: {:error, {:ledger_frame_checksum_mismatch, offset}}
  end

  @spec decode_frame_data(binary(), pos_integer(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp decode_frame_data(encoded, max_frame_bytes, offset) do
    case Value.decode(encoded, max_bytes: max_frame_bytes) do
      {:ok, data} when is_map(data) and not is_struct(data) -> {:ok, data}
      {:ok, _value} -> {:error, {:invalid_ledger_frame_payload, offset}}
      {:error, reason} -> {:error, {:invalid_ledger_frame_encoding, offset, reason}}
    end
  end

  @spec apply_frame(map(), String.t(), domain_state(), non_neg_integer()) ::
          {:ok, domain_state()} | {:error, term()}
  defp apply_frame(data, domain_ref, domain, offset) do
    with :ok <- validate_frame_keys(data, offset),
         :ok <- validate_frame_header(data, domain_ref, offset),
         batch_id when is_binary(batch_id) and batch_id != "" <- Map.get(data, "batch_id"),
         identity when is_binary(identity) <- Map.get(data, "identity_digest"),
         true <- Support.valid_digest?(identity),
         expected_revision when is_integer(expected_revision) and expected_revision >= 0 <-
           Map.get(data, "expected_revision"),
         true <- expected_revision == domain.revision,
         false <- Map.has_key?(domain.batches, batch_id),
         raw_entries when is_list(raw_entries) and raw_entries != [] <- Map.get(data, "entries"),
         {:ok, verified} <-
           Entry.verify_chain(raw_entries,
             domain_ref: domain_ref,
             start_revision: domain.revision,
             prev_digest: domain.head_digest
           ),
         :ok <- Support.validate_batch_coordinates(verified.entries, domain_ref, batch_id),
         payloads <- Enum.map(verified.entries, & &1.payload),
         {:ok, expected_identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
         true <- identity == expected_identity do
      {committed, _last} =
        Support.install_batch(
          domain,
          batch_id,
          identity,
          expected_revision,
          verified.entries
        )

      {:ok, committed}
    else
      false -> {:error, {:invalid_or_duplicate_ledger_frame, offset}}
      nil -> {:error, {:invalid_ledger_frame, offset}}
      {:error, reason} -> {:error, {:invalid_ledger_frame, offset, reason}}
      _invalid -> {:error, {:invalid_ledger_frame, offset}}
    end
  end

  @spec validate_frame_keys(map(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_frame_keys(data, offset) do
    unknown = Map.keys(data) -- @frame_fields
    missing = @frame_fields -- Map.keys(data)

    cond do
      unknown != [] -> {:error, {:unknown_ledger_frame_fields, offset}}
      missing != [] -> {:error, {:missing_ledger_frame_field, offset, List.first(missing)}}
      true -> :ok
    end
  end

  @spec validate_frame_header(map(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_frame_header(
         %{
           "format" => @frame_format,
           "format_version" => @frame_version,
           "domain_ref" => domain_ref
         },
         domain_ref,
         _offset
       ),
       do: :ok

  defp validate_frame_header(_data, _domain_ref, offset),
    do: {:error, {:ledger_frame_binding_mismatch, offset}}

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

  @spec domain_path(String.t(), String.t()) :: String.t()
  defp domain_path(directory, domain_ref) do
    filename =
      domain_ref
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> Kernel.<>(".ledger")

    Path.join(directory, filename)
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

  @spec ensure_directory(String.t()) :: :ok | {:error, term()}
  defp ensure_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %File.Stat{type: :directory}} <- File.stat(directory),
         :ok <- sync_directory_chain(directory) do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_ledger_disk_path_type, type}}
      {:error, reason} -> {:error, {:ledger_disk_directory_failed, reason}}
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

  @spec directory_sync_required?(String.t()) :: {:ok, boolean()} | {:error, term()}
  defp directory_sync_required?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size == 0}
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_ledger_disk_file_type, type}}
      {:error, :enoent} -> {:ok, true}
      {:error, reason} -> {:error, {:ledger_disk_stat_failed, reason}}
    end
  end

  @spec durability_barrier(String.t(), String.t()) :: :ok | {:error, term()}
  defp durability_barrier(path, directory) do
    with :ok <- sync_file(path),
         :ok <- sync_directory(directory) do
      :ok
    end
  end

  @spec sync_file(String.t()) :: :ok | {:error, term()}
  defp sync_file(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:ledger_disk_sync_failed, reason}}
          {_sync, {:error, reason}} -> {:error, {:ledger_disk_close_failed, reason}}
          _invalid -> {:error, :invalid_ledger_disk_sync_reply}
        end

      {:error, reason} ->
        {:error, {:ledger_disk_open_failed, reason}}
    end
  end

  @spec sync_directory_chain(String.t()) :: :ok | {:error, term()}
  defp sync_directory_chain(directory) do
    directory
    |> directory_chain()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case sync_directory(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec directory_chain(String.t()) :: [String.t()]
  defp directory_chain(directory) do
    Stream.unfold(directory, fn
      nil ->
        nil

      current ->
        parent = Path.dirname(current)

        if parent == current,
          do: {current, nil},
          else: {current, parent}
    end)
    |> Enum.to_list()
  end

  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:ledger_disk_directory_sync_failed, reason}}
          {_sync, {:error, reason}} -> {:error, {:ledger_disk_directory_close_failed, reason}}
          _invalid -> {:error, :invalid_ledger_disk_directory_sync_reply}
        end

      {:error, reason} ->
        {:error, {:ledger_disk_directory_open_failed, reason}}
    end
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
