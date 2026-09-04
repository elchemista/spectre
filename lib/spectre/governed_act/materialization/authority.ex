defmodule Spectre.GovernedAct.Materialization.Authority do
  @moduledoc false

  alias Spectre.Act
  alias Spectre.GovernedAct.{AuthorityChange, DispatchState, State}
  alias Spectre.GovernedAct.Materialization.Dispatch

  @spec cancellation_events(State.t(), Act.t(), String.t(), atom()) ::
          {:ok, [map()]} | {:error, term()}
  def cancellation_events(%State{} = projection, %Act{} = cause_act, mandate_ref, reason) do
    cascade? =
      reason == :mandate_restricted or AuthorityChange.cascades?(projection, mandate_ref)

    with {:ok, pending} <- DispatchState.pending(projection) do
      pending
      |> Enum.reduce_while({:ok, []}, fn {pending_act, _mandate}, {:ok, reversed} ->
        with {:ok, affected?} <-
               AuthorityChange.affects?(
                 projection,
                 pending_act.mandate_ref,
                 mandate_ref,
                 cascade?
               ),
             {:ok, events} <- events_for_pending(pending_act, cause_act, reason, affected?) do
          {:cont, {:ok, Enum.reverse(events, reversed)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> reverse_ok()
    end
  end

  @doc false
  @spec cancellation_events([Act.t()], Act.t(), atom()) ::
          {:ok, [map()]} | {:error, term()}
  def cancellation_events(acts, %Act{} = cause_act, reason) when is_list(acts) do
    Enum.reduce_while(acts, {:ok, []}, fn
      %Act{} = act, {:ok, reversed} ->
        case events_for_pending(act, cause_act, reason, true) do
          {:ok, events} -> {:cont, {:ok, Enum.reverse(events, reversed)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_pending_dispatch_act}}
    end)
    |> reverse_ok()
  end

  defp events_for_pending(_pending_act, _cause_act, _reason, false), do: {:ok, []}

  defp events_for_pending(pending_act, cause_act, reason, true),
    do: Dispatch.cancellation(pending_act, cause_act, reason)

  defp reverse_ok({:ok, reversed}), do: {:ok, Enum.reverse(reversed)}
  defp reverse_ok({:error, _reason} = error), do: error
end
