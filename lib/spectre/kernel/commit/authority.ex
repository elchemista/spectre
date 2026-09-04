defmodule Spectre.Kernel.Commit.Authority do
  @moduledoc false

  alias Spectre.Act
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{AuthorityChange, DispatchState, State}

  @spec cancellation_events(State.t(), Act.t(), String.t(), atom()) ::
          {:ok, [map()]} | {:error, term()}
  def cancellation_events(%State{} = projection, %Act{} = cause_act, mandate_ref, reason) do
    cascade? =
      reason == :mandate_restricted or AuthorityChange.cascades?(projection, mandate_ref)

    projection
    |> DispatchState.pending_refs()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, reversed} ->
      with {:ok, pending_act} <- Map.fetch(projection.acts, act_ref),
           {:ok, affected?} <-
             AuthorityChange.affects?(
               projection,
               pending_act.mandate_ref,
               mandate_ref,
               cascade?
             ),
           {:ok, events} <- events_for_pending(pending_act, cause_act, reason, affected?) do
        {:cont, {:ok, Enum.reverse(events, reversed)}}
      else
        :error -> {:halt, {:error, {:dispatch_act_not_found, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp events_for_pending(_pending_act, _cause_act, _reason, false), do: {:ok, []}

  defp events_for_pending(pending_act, cause_act, reason, true) do
    with {:ok, cancelled} <- Event.dispatch_cancelled(pending_act, cause_act, reason),
         {:ok, release_events} <- release_events(pending_act) do
      {:ok, [cancelled | release_events]}
    end
  end

  defp release_events(%Act{reservations: reservations}) when map_size(reservations) == 0,
    do: {:ok, []}

  defp release_events(%Act{} = act) do
    with {:ok, event} <- Event.meter(:release, act), do: {:ok, [event]}
  end

  defp reverse_ok({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_ok({:error, _reason} = error), do: error
end
