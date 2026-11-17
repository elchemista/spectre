defmodule Spectre.Server.Store.Projection do
  @moduledoc false
  @behaviour Spectre.GAM.Domain.Projection.Store
  alias Spectre.GAM.Domain.Projection.Store
  alias Spectre.GAM.Ledger

  # Shares the coordination provider reference without moving authority or
  # lifecycle ownership out of the existing Domain and host boundaries.
  @impl true
  @spec open(String.t(), keyword()) :: {:ok, Store.handle()} | {:error, term()}
  def open(domain, opts), do: invoke(opts, :projection_open, [domain])

  @impl true
  @spec head(String.t(), keyword()) ::
          {:ok, %{handle: Store.handle(), cursor: Ledger.cursor()}}
          | :not_found
          | {:error, term()}
  def head(domain, opts), do: invoke(opts, :projection_head, [domain])

  @impl true
  @spec commit(Store.handle(), Ledger.cursor(), Ledger.cursor(), Enumerable.t(), keyword()) ::
          :ok | {:error, term()}
  def commit(handle, before, after_cursor, changes, opts),
    do: invoke(opts, :projection_commit, [handle, before, after_cursor, changes])

  @impl true
  @spec fetch(Store.handle(), Ledger.cursor(), [Store.key()], keyword()) ::
          {:ok, %{optional(Store.key()) => binary()}} | {:error, term()}
  def fetch(handle, cursor, keys, opts),
    do: invoke(opts, :projection_fetch, [handle, cursor, keys])

  @impl true
  @spec page(Store.handle(), Ledger.cursor(), atom(), keyword()) ::
          {:ok, [{Store.key(), binary()}], term() | nil} | {:error, term()}
  def page(handle, cursor, collection, opts),
    do: invoke(opts, :projection_page, [handle, cursor, collection])

  @impl true
  @spec select(Store.handle(), Ledger.cursor(), atom(), keyword(), keyword()) ::
          {:ok, [{Store.key(), binary()}], term() | nil} | {:error, term()}
  def select(handle, cursor, collection, selection, opts),
    do: invoke(opts, :projection_select, [handle, cursor, collection, selection])

  defp invoke(opts, callback, args) do
    {{module, reference}, opts} = Keyword.pop!(opts, :store)
    apply(module, callback, [reference | args] ++ [opts])
  end
end
