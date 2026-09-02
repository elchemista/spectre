defmodule Spectre.Ledger.Store.ETS do
  @moduledoc """
  Volatile ETS Store for Domain ledgers.

  One GenServer owns a protected ETS table and serializes compare-and-swap
  transitions. A batch becomes acknowledged only in the same callback that
  installs every linked Entry and its idempotency index. This adapter is
  intended for development, tests, and ephemeral Domains; it makes no
  durability claim across owner-process failure.

  `:fault_injection` (or `:fault`) may be set to `:before_commit` or
  `:after_commit`. Both return `{:error, :ambiguous}`; the latter installs the
  batch first, allowing recovery code to exercise identity lookup.
  """

  use GenServer

  @behaviour Spectre.Ledger.Store

  alias Spectre.Ledger
  alias Spectre.Ledger.Entry

  @start_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]
  @read_options [:server, :timeout]
  @append_options @read_options ++ [:recorded_at, :fault_injection, :fault]

  @type domain_state :: %{
          revision: non_neg_integer(),
          head_digest: Entry.digest(),
          entries_rev: [Entry.t()],
          batches: %{optional(String.t()) => Ledger.batch_info()},
          recovery: nil
        }

  @doc "Starts an empty volatile ledger Store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ [])

  def start_link(opts) when is_list(opts) do
    with :ok <- validate_options(opts, @start_options) do
      GenServer.start_link(__MODULE__, :ok, opts)
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
  def lookup_batch(domain_ref, batch_id, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:lookup_batch, domain_ref, batch_id}, timeout(opts, 30_000))
    end
  end

  @impl Spectre.Ledger.Store
  def export(domain_ref, opts) do
    with :ok <- validate_options(opts, @read_options),
         {:ok, server} <- server(opts) do
      GenServer.call(server, {:export, domain_ref}, timeout(opts, 30_000))
    end
  end

  @impl GenServer
  def init(:ok) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
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
           {:ok, recorded_at} <- recorded_at(opts),
           {:ok, fault} <- fault_phase(opts) do
        domain = lookup_domain(state.table, domain_ref)

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

    {reply, state} = reply_and_state
    {:reply, reply, state}
  end

  def handle_call({:load, domain_ref}, _from, state) do
    reply =
      case :ets.lookup(state.table, domain_ref) do
        [{^domain_ref, domain}] -> {:ok, snapshot(domain_ref, domain)}
        [] -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup_batch, domain_ref, batch_id}, _from, state) do
    reply =
      with [{^domain_ref, domain}] <- :ets.lookup(state.table, domain_ref),
           {:ok, info} <- Map.fetch(domain.batches, batch_id) do
        {:ok, info}
      else
        [] -> :not_found
        :error -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:export, domain_ref}, _from, state) do
    reply =
      case :ets.lookup(state.table, domain_ref) do
        [{^domain_ref, domain}] -> domain_ref |> snapshot(domain) |> Ledger.export_snapshot()
        [] -> :not_found
      end

    {:reply, reply, state}
  end

  @spec append_batch(
          map(),
          domain_state(),
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :before_commit | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, map()}
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
    case Map.fetch(domain.batches, batch_id) do
      {:ok, %{identity_digest: ^identity, expected_revision: ^expected_revision} = info} ->
        {{:ok, info.last_revision}, state}

      {:ok, _different} ->
        {{:error, {:batch_identity_conflict, batch_id}}, state}

      :error when expected_revision != domain.revision ->
        {{:error, :conflict}, state}

      :error when fault == :before_commit ->
        {{:error, :ambiguous}, state}

      :error ->
        commit_batch(
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

  @spec commit_batch(
          map(),
          domain_state(),
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          non_neg_integer(),
          Entry.digest(),
          nil | :after_commit
        ) :: {{:ok, non_neg_integer()} | {:error, term()}, map()}
  defp commit_batch(
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
        info = batch_info(batch_id, identity, expected_revision, entries, last)

        committed = %{
          domain
          | revision: last.revision,
            head_digest: last.digest,
            entries_rev: Enum.reverse(entries, domain.entries_rev),
            batches: Map.put(domain.batches, batch_id, info)
        }

        true = :ets.insert(state.table, {domain_ref, committed})
        reply = if fault == :after_commit, do: {:error, :ambiguous}, else: {:ok, last.revision}
        {reply, state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec batch_info(String.t(), Entry.digest(), non_neg_integer(), [Entry.t()], Entry.t()) ::
          Ledger.batch_info()
  defp batch_info(batch_id, identity, expected_revision, entries, last) do
    %{
      batch_id: batch_id,
      identity_digest: identity,
      expected_revision: expected_revision,
      first_revision: expected_revision + 1,
      last_revision: last.revision,
      entry_count: length(entries),
      head_digest: last.digest
    }
  end

  @spec empty_domain() :: domain_state()
  defp empty_domain do
    %{
      revision: 0,
      head_digest: Entry.genesis_digest(),
      entries_rev: [],
      batches: %{},
      recovery: nil
    }
  end

  @spec snapshot(String.t(), domain_state()) :: Ledger.snapshot()
  defp snapshot(domain_ref, domain) do
    %{
      domain_ref: domain_ref,
      revision: domain.revision,
      head_digest: domain.head_digest,
      entries: Enum.reverse(domain.entries_rev),
      recovery: domain.recovery
    }
  end

  @spec server(keyword()) :: {:ok, GenServer.server()} | {:error, term()}
  defp server(opts) when is_list(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> {:ok, server}
      :error -> {:error, :ledger_ets_store_server_required}
    end
  end

  defp lookup_domain(table, domain_ref) do
    case :ets.lookup(table, domain_ref) do
      [{^domain_ref, domain}] -> domain
      [] -> empty_domain()
    end
  end

  @spec timeout(keyword(), timeout()) :: timeout()
  defp timeout(opts, default), do: Keyword.get(opts, :timeout, default)

  @spec fault_phase(keyword()) ::
          {:ok, nil | :before_commit | :after_commit} | {:error, term()}
  defp fault_phase(opts) do
    value = Keyword.get(opts, :fault_injection, Keyword.get(opts, :fault))

    if value in [nil, :before_commit, :after_commit],
      do: {:ok, value},
      else: {:error, {:invalid_ledger_fault_injection, value}}
  end

  defp recorded_at(opts) do
    case Keyword.fetch(opts, :recorded_at) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _missing_or_invalid -> {:error, :ledger_recorded_at_required}
    end
  end

  defp validate_options(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- allowed do
        [] -> :ok
        unknown -> {:error, {:unknown_ledger_ets_options, unknown |> Enum.uniq() |> Enum.sort()}}
      end
    else
      {:error, :invalid_ledger_ets_options}
    end
  end

  defp validate_options(_opts, _allowed), do: {:error, :invalid_ledger_ets_options}
end
