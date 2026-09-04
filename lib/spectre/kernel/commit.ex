defmodule Spectre.Kernel.Commit do
  @moduledoc """
  Pure construction of the atomic Admission payload set.

  Despite its name, this module does not append to a ledger.  It converts a
  validated Decision and its optional Act into ordered `Spectre.Domain.Event`
  payloads for a sequencer to commit atomically.  A Decision is always first;
  only an admitted Decision may carry an Act.

  Executor-mediated Acts add `dispatch_ready`. Execution mode comes from the
  frozen executor route, not from an effect-row dimension: a protected read or
  disclosure may need an executor without declaring `attempt`. Ledger-internal
  governed consequences finish at Admission and cannot enter the Grant path.
  """

  alias Spectre.{Act, Decision}
  alias Spectre.Domain.{Event, Projection}
  alias Spectre.GovernedAct.Admission.Binding
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Commit.Materialization

  @type payload :: map()

  @doc "Builds the ordered event payloads for one Admission transaction."
  @spec payloads(Projection.t(), Decision.t(), Act.t() | nil) ::
          {:ok, [payload()]} | {:error, term()}
  def payloads(%State{} = projection, %Decision{} = decision, act)
      when is_nil(act) or is_struct(act, Act) do
    with {:ok, decision} <- Decision.new(decision),
         {:ok, act} <- normalize_act(act),
         {:ok, payloads} <- build_payloads(projection, decision, act) do
      {:ok, payloads}
    end
  end

  def payloads(_projection, _decision, _act), do: {:error, :invalid_admission_records}

  defp build_payloads(projection, %Decision{outcome: :admitted} = decision, %Act{} = act) do
    with :ok <- linked?(decision, act),
         :ok <- GovernedExecution.validate(act),
         {:ok, decision_event} <- Event.record(:decision, decision),
         {:ok, act_event} <- Event.record(:act, act),
         {:ok, meter_events} <- meter_events(act),
         {:ok, governance_events} <- Materialization.events(projection, act) do
      dispatch_events =
        if GovernedExecution.executor_mediated?(act), do: [Event.dispatch_ready(act)], else: []

      {:ok, [decision_event, act_event] ++ meter_events ++ governance_events ++ dispatch_events}
    end
  end

  defp build_payloads(_projection, %Decision{outcome: :admitted}, nil),
    do: {:error, :admitted_decision_missing_act}

  defp build_payloads(_projection, %Decision{outcome: outcome} = decision, nil)
       when outcome != :admitted do
    with {:ok, event} <- Event.record(:decision, decision), do: {:ok, [event]}
  end

  defp build_payloads(_projection, %Decision{outcome: outcome}, %Act{}) when outcome != :admitted,
    do: {:error, {:non_admitted_decision_has_act, outcome}}

  defp normalize_act(nil), do: {:ok, nil}
  defp normalize_act(%Act{} = act), do: Act.new(act)

  defp linked?(decision, act) do
    case Binding.mismatch(decision, act) do
      nil -> :ok
      {field, expected, actual} -> {:error, {:decision_act_mismatch, field, expected, actual}}
    end
  end

  defp meter_events(%Act{reservations: reservations}) when map_size(reservations) == 0,
    do: {:ok, []}

  defp meter_events(%Act{} = act) do
    if GovernedExecution.executor_mediated?(act) do
      with {:ok, event} <- Event.meter(:reserve, act), do: {:ok, [event]}
    else
      with {:ok, reservation} <- Event.meter(:reserve, act),
           {:ok, settlement} <- Event.meter(:settle, act) do
        {:ok, [reservation, settlement]}
      end
    end
  end
end
