defmodule Spectre.GovernedAct.Materialization.Dispatch do
  @moduledoc false

  alias Spectre.{Act, Duty, Mandate}
  alias Spectre.Domain.Event

  @type cause :: Act.t() | Duty.t() | Mandate.t()

  @doc false
  @spec cancellation(Act.t(), cause(), atom()) :: {:ok, [map()]} | {:error, term()}
  def cancellation(%Act{} = act, cause, reason) do
    with {:ok, cancelled} <- Event.dispatch_cancelled(act, cause, reason),
         {:ok, releases} <- release_events(act) do
      {:ok, [cancelled | releases]}
    end
  end

  defp release_events(%Act{reservations: reservations}) when map_size(reservations) == 0,
    do: {:ok, []}

  defp release_events(%Act{} = act) do
    with {:ok, event} <- Event.meter(:release, act), do: {:ok, [event]}
  end
end
