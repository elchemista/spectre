defmodule Spectre.GAM.Domain.Projection.Persistence do
  @moduledoc false
  alias Spectre.GAM.Domain.Projection.{Rows, Store}
  alias Spectre.GAM.GovernedAct.State

  def initialize(%{projection_store: nil} = state), do: {:ok, state}

  def initialize(state) do
    current = state.projection
    empty = State.new(current.domain_ref, current.constitution)

    with {:ok, handle} <- Store.open(state.projection_store, current.domain_ref),
         :ok <-
           Store.commit(
             state.projection_store,
             handle,
             Rows.cursor(empty),
             Rows.cursor(current),
             Rows.changes(empty, current)
           ) do
      {:ok, %{state | projection_handle: handle}}
    end
  end

  def advance(%{projection_store: nil}, _next), do: :ok
  def advance(%{projection: projection}, projection), do: :ok

  def advance(state, next) do
    Store.commit(
      state.projection_store,
      state.projection_handle,
      Rows.cursor(state.projection),
      Rows.cursor(next),
      Rows.changes(state.projection, next)
    )
  end
end
