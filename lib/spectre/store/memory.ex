defmodule Spectre.Store.Memory do
  @moduledoc """
  Volatile, compressed ETS implementation of `Spectre.Store`.

  One host-supervised owner serializes CAS writes. Readers access the protected
  table directly, so large canonical values do not pass through the owner's
  mailbox or heap. Use `{__MODULE__, server: pid}`. Stopping the owner releases
  all values; this adapter does not claim durability or crash recovery.
  """

  use GenServer
  @behaviour Spectre.Store

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @impl true
  def init(:ok),
    do: {:ok, :ets.new(__MODULE__, [:set, :protected, :compressed, read_concurrency: true])}

  @impl Spectre.Store
  def get(key, opts) do
    table = GenServer.call(Keyword.fetch!(opts, :server), :table)

    case :ets.lookup(table, key) do
      [] -> :not_found
      [{^key, revision, value}] -> {:ok, revision, value}
    end
  end

  @impl Spectre.Store
  def compare_and_swap(key, expected_revision, value, opts),
    do: GenServer.call(Keyword.fetch!(opts, :server), {:cas, key, expected_revision, value})

  @impl true
  def handle_call(:table, _from, table), do: {:reply, table, table}

  def handle_call({:cas, key, expected, value}, _from, table) do
    actual =
      case :ets.lookup(table, key) do
        [] -> 0
        [{^key, revision, _}] -> revision
      end

    if is_integer(expected) and expected >= 0 and expected === actual and
         (is_binary(value) or value == :deleted) do
      :ets.insert(table, {key, actual + 1, value})
      {:reply, {:ok, actual + 1}, table}
    else
      {:reply, {:error, :conflict}, table}
    end
  end
end
