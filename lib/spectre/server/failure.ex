defmodule Spectre.Server.Failure do
  @moduledoc false

  def capture(function) do
    {:ok, function.()}
  rescue
    exception ->
      {:error,
       %{
         kind: :exception,
         module: exception.__struct__,
         message: Exception.message(exception) |> String.slice(0, 1_000)
       }}
  catch
    kind, reason ->
      {:error, %{kind: kind, message: inspect(reason, limit: 10, printable_limit: 1_000)}}
  end

  def quarantine(state, callback, event, reason) do
    id = state.processing_result || event_id(event) || Spectre.Identity.uuid7()

    failure = %{
      id: id,
      callback: callback,
      interaction: event_id(event),
      reason: reason,
      attempts: 1,
      recorded_at: System.system_time(:millisecond),
      source: source_reference(Map.get(state.inbox, state.processing_result))
    }

    letters =
      state.dead_letters
      |> Map.put(id, failure)
      |> bounded(Keyword.get(state.opts, :max_dead_letters, 100))

    state = %{
      state
      | inbox: Map.delete(state.inbox, state.processing_result),
        seen_events: Map.put(state.seen_events, id, true),
        processing_result: nil,
        dead_letters: letters
    }

    state = Spectre.Server.Inbox.mark_seen(state, id)
    {state, failure}
  end

  defp bounded(letters, limit) when map_size(letters) <= limit, do: letters

  defp bounded(letters, limit) do
    letters
    |> Enum.sort_by(fn {id, value} -> {value.recorded_at, id} end)
    |> Enum.take(-max(1, limit))
    |> Map.new()
  end

  defp event_id(nil), do: nil
  defp event_id(event), do: event.id

  defp source_reference(%{worker: worker, result: {:governed, result}}) do
    %{
      command_id: Map.get(worker, :command_id),
      continuation: worker.tag,
      decision_ref: record_ref(Map.get(result, :decision)),
      act_ref: record_ref(Map.get(result, :act)),
      outcome_ref: record_ref(Map.get(result, :outcome))
    }
  end

  defp source_reference(_), do: nil
  defp record_ref(%{ref: ref}), do: ref
  defp record_ref(_), do: nil
end
