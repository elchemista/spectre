defmodule Spectre.Attempt.Reconciler do
  @moduledoc false

  alias Spectre.{Act, Portable}
  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Duty
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{DispatchState, State}
  alias Spectre.GovernedAct.Materialization.Dispatch
  alias Spectre.GovernedAct.MeterState, as: MeterState

  @type plan :: %{
          required(:payloads) => [map()],
          required(:batch_id) => String.t() | nil
        }

  @spec missing_openings(State.t(), integer()) :: [Derive.cause()]
  def missing_openings(%State{} = state, time),
    do: Derive.missing_openings(state, time)

  @spec repair_plan(Projection.t(), integer()) :: {:ok, plan()} | {:error, term()}
  def repair_plan(%State{} = projection, time) when is_integer(time) do
    causes = missing_openings(projection, time)

    with {:ok, expirations} <- expired_dispatches(projection, time) do
      expired_refs = MapSet.new(expirations, fn {act, _mandate} -> act.ref end)

      {disputes, disputed_refs} =
        dispatch_dispute_causes(projection, causes, expired_refs)

      terminal_refs = MapSet.union(expired_refs, disputed_refs)

      with {:ok, payloads} <-
             repair_payloads(
               projection,
               expirations,
               disputes,
               causes,
               terminal_refs,
               time
             ),
           {:ok, batch_id} <- batch_id(projection, payloads) do
        {:ok, %{payloads: payloads, batch_id: batch_id}}
      end
    end
  end

  def repair_plan(%State{}, time),
    do: {:error, {:invalid_reconciliation_time, time}}

  def repair_plan(_projection, _time),
    do: {:error, :invalid_reconciliation_projection}

  defp repair_payloads(projection, expirations, disputes, causes, terminal_refs, time) do
    dispute_keys = MapSet.new(disputes, &Derive.cause_key/1)
    ordinary_causes = Enum.reject(causes, &MapSet.member?(dispute_keys, Derive.cause_key(&1)))

    with {:ok, expiration_events} <- expiration_events(expirations),
         {:ok, dispute_events} <- dispatch_dispute_events(projection, disputes, time),
         {:ok, suspensions} <- suspension_events(projection, causes, terminal_refs),
         {:ok, openings} <- opening_events(ordinary_causes, time) do
      {:ok, expiration_events ++ dispute_events ++ suspensions ++ openings}
    end
  end

  defp expired_dispatches(projection, time) do
    DispatchState.expired(projection, time)
  end

  defp expiration_events(expirations) do
    Enum.reduce_while(expirations, {:ok, []}, fn {act, mandate}, {:ok, events} ->
      case Dispatch.cancellation(act, mandate, :mandate_expired) do
        {:ok, payloads} -> {:cont, {:ok, Enum.reverse(payloads, events)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp dispatch_dispute_causes(projection, causes, excluded_refs) do
    causes
    |> Enum.sort_by(&(Derive.cause_key(&1) |> Portable.canonical_value!()))
    |> Enum.reduce({[], excluded_refs}, fn cause, {selected, seen_refs} ->
      act_ref = cause_act_ref(cause)

      if cause.cause_class == :disputed_evidence and
           DispatchState.pending?(projection, act_ref) and
           not MapSet.member?(seen_refs, act_ref) and
           not DispatchState.attempted?(projection, act_ref) do
        {[cause | selected], MapSet.put(seen_refs, act_ref)}
      else
        {selected, seen_refs}
      end
    end)
    |> then(fn {selected, seen_refs} -> {Enum.reverse(selected), seen_refs} end)
  end

  defp dispatch_dispute_events(projection, causes, time) do
    Enum.reduce_while(causes, {:ok, []}, fn cause, {:ok, events} ->
      act_ref = cause_act_ref(cause)

      with {:ok, %Act{} = act} <- Map.fetch(projection.acts, act_ref),
           {:ok, duty} <- materialize_duty(cause, time),
           {:ok, duty_event} <- Event.record(:duty, duty),
           {:ok, cancellation_payloads} <-
             Dispatch.cancellation(act, duty, :disputed_evidence) do
        reversed = Enum.reverse(cancellation_payloads, [duty_event | events])
        {:cont, {:ok, reversed}}
      else
        :error -> {:halt, {:error, {:reconciliation_act_not_found, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
        _invalid -> {:halt, {:error, {:invalid_reconciliation_act, act_ref}}}
      end
    end)
    |> reverse_result()
  end

  defp opening_events(causes, time) do
    Enum.reduce_while(causes, {:ok, []}, fn cause, {:ok, events} ->
      with {:ok, duty} <- materialize_duty(cause, time),
           {:ok, event} <- Event.record(:duty, duty) do
        {:cont, {:ok, [event | events]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp materialize_duty(cause, time) do
    cause
    |> Derive.materialization_attrs(time)
    |> Duty.new()
  end

  defp suspension_events(projection, causes, terminal_refs) do
    causes
    |> Enum.map(&cause_act_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(terminal_refs, &1))
    |> Enum.filter(&(MeterState.reservation_status(projection, &1) == :reserved))
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, events} ->
      with {:ok, %Act{} = act} <- Map.fetch(projection.acts, act_ref),
           {:ok, event} <- Event.meter(:suspend, act) do
        {:cont, {:ok, [event | events]}}
      else
        :error -> {:halt, {:error, {:reconciliation_act_not_found, act_ref}}}
        {:error, _reason} = error -> {:halt, error}
        _invalid -> {:halt, {:error, {:invalid_reconciliation_act, act_ref}}}
      end
    end)
    |> reverse_result()
  end

  defp batch_id(_projection, []), do: {:ok, nil}

  defp batch_id(projection, payloads) do
    Portable.digest(%{
      "head_digest" => projection.head_digest,
      "payloads" => payloads
    })
  end

  defp reverse_result({:ok, events}), do: {:ok, Enum.reverse(events)}
  defp reverse_result({:error, _reason} = error), do: error

  defp cause_act_ref(cause) do
    cause
    |> Map.get(:causal_refs, %{})
    |> Map.get("act_ref")
  end
end
