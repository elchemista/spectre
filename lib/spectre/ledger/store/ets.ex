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
  alias Spectre.Ledger.Store.Support

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
           {:ok, recorded_at} <- Support.recorded_at(opts),
           {:ok, fault} <- Support.fault_phase(opts) do
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
        [{^domain_ref, domain}] -> {:ok, Support.snapshot(domain_ref, domain)}
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
        [{^domain_ref, domain}] ->
          domain_ref |> Support.snapshot(domain) |> Ledger.export_snapshot()

        [] ->
          :not_found
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
    case Support.append_status(domain, batch_id, identity, expected_revision, fault) do
      {:existing, revision} ->
        {{:ok, revision}, state}

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
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
        {committed, last} =
          Support.install_batch(domain, batch_id, identity, expected_revision, entries)

        true = :ets.insert(state.table, {domain_ref, committed})
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

  defp lookup_domain(table, domain_ref) do
    case :ets.lookup(table, domain_ref) do
      [{^domain_ref, domain}] -> domain
      [] -> Support.empty_domain()
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
