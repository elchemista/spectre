defmodule Spectre.Ledger.Store.ETS do
  @moduledoc """
  Volatile ETS Store for Domain ledgers.

  One GenServer owns a protected ETS table and serializes compare-and-swap
  transitions. A batch becomes acknowledged only in the same callback that
  installs every linked Entry and its idempotency index. This adapter is
  intended for development, tests, and ephemeral Domains; it makes no
  durability claim across owner-process failure.

  Cursors, Entries and batch identities occupy separate rows. Appending or
  looking up an identity never copies prior history onto the owner's heap;
  only load/export reconstruct a complete snapshot. One ETS insert publishes
  the new Entries, cursor and batch identity together.

  `:compressed` (default `false`) trades per-row encoding/decoding work for a
  smaller table. It does not change batch visibility or durability guarantees.

  `:fault_injection` (or `:fault`) may be set to `:before_commit` or
  `:after_commit`. Both return `{:error, :ambiguous}`; the latter installs the
  batch first, allowing recovery code to exercise identity lookup.
  """

  use GenServer

  @behaviour Spectre.Ledger.Store

  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  @start_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after, :compressed]
  @read_options [:server, :timeout]
  @append_options @read_options ++ [:recorded_at, :fault_injection, :fault]

  @type append_context :: %{
          revision: non_neg_integer(),
          head_digest: Entry.digest(),
          batches: %{optional(String.t()) => Ledger.batch_info()}
        }

  @doc "Starts an empty volatile ledger Store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    with :ok <- validate_options(opts, @start_options),
         compressed when is_boolean(compressed) <- Keyword.get(opts, :compressed, false) do
      GenServer.start_link(__MODULE__, compressed, Keyword.delete(opts, :compressed))
    else
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_ledger_ets_compressed}
    end
  end

  def start_link(_opts), do: {:error, :invalid_ledger_ets_options}

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
      GenServer.call(server, {:load, domain_ref}, timeout(opts, 30_000))
    end
  end

  @impl Spectre.Ledger.Store
  def load_from(domain_ref, revision, opts)
      when is_integer(revision) and revision >= 0 do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:load_from, domain_ref, revision}, timeout(opts, 30_000))
    end
  end

  def load_from(_domain_ref, _revision, _opts), do: {:error, :invalid_ledger_cursor}

  @impl Spectre.Ledger.Store
  def head(domain_ref, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:head, domain_ref}, timeout(opts, 30_000))
    end
  end

  @impl Spectre.Ledger.Store
  def read_batch(domain_ref, first_revision, opts)
      when is_integer(first_revision) and first_revision > 0 do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:read_batch, domain_ref, first_revision}, timeout(opts, 30_000))
    end
  end

  def read_batch(_domain_ref, _revision, _opts), do: {:error, :invalid_ledger_cursor}

  @impl Spectre.Ledger.Store
  def lookup_batch(domain_ref, batch_id, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:lookup_batch, domain_ref, batch_id}, timeout(opts, 30_000))
    end
  end

  @impl Spectre.Ledger.Store
  def export(domain_ref, opts) do
    # Capture one coherent snapshot under the owner's serialization, then hash
    # and encode in the caller. A host can use a short-lived Task for exports;
    # neither its temporary heap nor verification work belongs in the writer.
    with {:ok, snapshot} <- load(domain_ref, opts) do
      Ledger.export_snapshot(snapshot)
    end
  end

  @impl GenServer
  def init(compressed) do
    # Only this owner reads/writes the table; read_concurrency adds no benefit.
    options = if compressed, do: [:compressed, :set, :protected], else: [:set, :protected]
    table = :ets.new(__MODULE__, options)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(
        {:append, domain_ref, batch_id, payloads, expected_revision, opts},
        _from,
        state
      ) do
    reply_and_state =
      with {:ok, identity} <-
             Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision),
           {:ok, recorded_at} <- Support.recorded_at(opts),
           {:ok, fault} <- Support.fault_phase(opts) do
        domain = append_context(state.table, domain_ref, batch_id)

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

    {reply, state} = reply_and_state
    {:reply, reply, state}
  end

  def handle_call({:load, domain_ref}, _from, state) do
    {:reply, load_snapshot(state.table, domain_ref), state}
  end

  def handle_call({:load_from, domain_ref, revision}, _from, state) do
    {:reply, load_snapshot(state.table, domain_ref, revision), state}
  end

  def handle_call({:head, domain_ref}, _from, state) do
    {:reply, lookup(state.table, {:domain, domain_ref}), state}
  end

  def handle_call({:read_batch, domain_ref, first_revision}, _from, state) do
    reply =
      with {:ok, first} <- lookup(state.table, {:entry, domain_ref, first_revision}),
           :ok <- Entry.verify(first),
           true <- first.batch_index === 0 do
        last_revision = first_revision + first.batch_size - 1

        entries =
          Enum.map(first_revision..last_revision, fn revision ->
            :ets.lookup_element(state.table, {:entry, domain_ref, revision}, 2)
          end)

        {:ok,
         %{
           domain_ref: domain_ref,
           revision: last_revision,
           head_digest: List.last(entries).digest,
           entries: entries,
           recovery: nil
         }}
      else
        false -> {:error, :ledger_cursor_inside_batch}
        other -> other
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup_batch, domain_ref, batch_id}, _from, state) do
    {:reply, lookup(state.table, {:batch, domain_ref, batch_id}), state}
  end

  @spec append_batch(
          map(),
          append_context(),
          {String.t(), String.t()},
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :before_commit | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, map()}
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
    case Support.append_status(domain, batch_id, identity, expected_revision, fault) do
      {:existing, revision} ->
        {{:ok, revision}, state}

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
        commit_batch(
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

  @spec commit_batch(
          map(),
          append_context(),
          {String.t(), String.t()},
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, map()}
  defp commit_batch(
         state,
         domain,
         {domain_ref, batch_id},
         payloads,
         expected_revision,
         recorded_at,
         identity,
         fault
       ) do
    case Entry.build_batch(
           domain_ref,
           batch_id,
           payloads,
           expected_revision,
           recorded_at,
           domain.head_digest
         ) do
      {:ok, entries} ->
        last = List.last(entries)
        cursor = %{revision: last.revision, head_digest: last.digest}
        info = Support.batch_info(batch_id, identity, expected_revision, last)

        rows = [
          {{:domain, domain_ref}, cursor},
          {{:batch, domain_ref, batch_id}, info}
          | Enum.map(entries, &{{:entry, domain_ref, &1.revision}, &1})
        ]

        true = :ets.insert(state.table, rows)
        reply = if fault == :after_commit, do: {:error, :ambiguous}, else: {:ok, last.revision}
        {reply, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec server(keyword()) :: {:ok, GenServer.server()} | {:error, term()}
  defp server(opts) when is_list(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> {:ok, server}
      :error -> {:error, :ledger_ets_store_server_required}
    end
  end

  # The shared append classifier only needs the current cursor and the requested
  # identity. No historical entries or other batch identities enter this context.
  defp append_context(table, domain_ref, batch_id) do
    cursor =
      case lookup(table, {:domain, domain_ref}) do
        {:ok, cursor} -> cursor
        :not_found -> %{revision: 0, head_digest: Entry.genesis_digest()}
      end

    batches =
      case lookup(table, {:batch, domain_ref, batch_id}) do
        {:ok, info} -> %{batch_id => info}
        :not_found -> %{}
      end

    Map.put(cursor, :batches, batches)
  end

  defp load_snapshot(table, domain_ref, after_revision \\ 0) do
    case lookup(table, {:domain, domain_ref}) do
      {:ok, cursor} ->
        entries =
          Enum.map((after_revision + 1)..cursor.revision//1, fn revision ->
            :ets.lookup_element(table, {:entry, domain_ref, revision}, 2)
          end)

        {:ok, Map.merge(cursor, %{domain_ref: domain_ref, entries: entries, recovery: nil})}

      :not_found ->
        :not_found
    end
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  @spec timeout(keyword(), timeout()) :: timeout()
  defp timeout(opts, default), do: Keyword.get(opts, :timeout, default)

  defp validate_options(opts, allowed) do
    Support.validate_options(
      opts,
      allowed,
      :invalid_ledger_ets_options,
      :unknown_ledger_ets_options
    )
  end
end
