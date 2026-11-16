defmodule Spectre.Server.Inbox do
  @moduledoc false

  def mark_seen(state, id) do
    order = Enum.reject(state.seen_event_order, &(&1 == id)) ++ [id]
    limit = max(1, Keyword.get(state.opts, :max_seen_events, 4_096))
    {expired, retained} = Enum.split(order, max(0, length(order) - limit))
    seen = state.seen_events |> Map.put(id, true) |> Map.drop(expired)
    %{state | seen_events: seen, seen_event_order: retained}
  end
end
