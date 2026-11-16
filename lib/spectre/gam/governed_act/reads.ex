defmodule Spectre.GAM.GovernedAct.Reads do
  @moduledoc false

  # These are read receipts for the current command, never durable authority.
  # A group enters this set only after its final page has been read at the
  # exact projection cursor. In particular, a missing page is not an empty set.
  def ensure(nil, _query), do: :ok

  def ensure(reads, {:row, collection, _} = query) do
    {:row, _, key} = query

    unless MapSet.member?(reads, query) or MapSet.member?(reads, {:loaded, {collection, key}}) or
             MapSet.member?(reads, {:page, collection, []}),
           do: throw({:projection_not_loaded, query})

    :ok
  end

  def ensure(reads, {:page, collection, _} = query) do
    unless MapSet.member?(reads, query) or MapSet.member?(reads, {:page, collection, []}),
      do: throw({:projection_not_loaded, query})

    :ok
  end

  def group(reads, collection, key),
    do: ensure(reads, {:page, collection, [group: key]})

  def read(%{read_index: %{selection: nil}} = state, _query), do: state
  def read(state, query), do: mark(state, MapSet.put(state.read_index.selection, query))

  def mark(projection, reads) do
    index = projection.read_index

    %{
      projection
      | read_index: %{
          index
          | selection: reads,
            erasure: %{index.erasure | selection: reads, counts: nil},
            authority: %{index.authority | selection: reads, counts: nil}
        }
    }
  end
end
