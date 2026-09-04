defmodule Spectre.Attempt.Reconciler do
  @moduledoc false

  alias Spectre.Domain.{Event, Projection}
  alias Spectre.Duty
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{DispatchState, State}
  alias Spectre.{Act, Mandate, Portable}

  @type plan :: %{
          required(:payloads) => [map()],
          required(:batch_id) => String.t() | nil
        }

  @spec missing_openings(State.t(), integer()) :: [Derive.cause()]
  def missing_openings(%State{} = state, time),
    do: Derive.missing_openings(state, state.constitution, time)

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
    projection
    |> DispatchState.pending_refs()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn act_ref, {:ok, expired} ->
      with {:ok, %Act{} = act} <- Map.fetch(projection.acts, act_ref),
           {:ok, %Mandate{} = mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
           true <- act.mandate_revision == mandate.revision,
           false <- DispatchState.attempted?(projection, act.ref) do
        if mandate.expires_at <= time,
          do: {:cont, {:ok, [{act, mandate} | expired]}},
          else: {:cont, {:ok, expired}}
      else
        :error -> {:halt, {:error, {:dispatch_expiration_record_not_found, act_ref}}}
        false -> {:halt, {:error, {:dispatch_expiration_mandate_mismatch, act_ref}}}
        true -> {:halt, {:error, {:dispatch_expiration_after_attempt, act_ref}}}
        _invalid -> {:halt, {:error, {:invalid_dispatch_expiration, act_ref}}}
      end
    end)
    |> reverse_result()
  end

  defp expiration_events(expirations) do
    Enum.reduce_while(expirations, {:ok, []}, fn {act, mandate}, {:ok, events} ->
      with {:ok, expiration} <- Event.dispatch_cancelled(act, mandate, :mandate_expired),
           {:ok, releases} <- release_events(act) do
        {:cont, {:ok, Enum.reverse(releases, [expiration | events])}}
      else
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
           {:ok, cancellation} <- Event.dispatch_cancelled(act, duty, :disputed_evidence),
           {:ok, releases} <- release_events(act) do
        reversed = Enum.reverse(releases, [cancellation, duty_event | events])
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
    |> Derive.materialization_attrs(required_at(cause, time))
    |> Duty.new()
  end

  defp suspension_events(projection, causes, terminal_refs) do
    causes
    |> Enum.map(&cause_act_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&MapSet.member?(terminal_refs, &1))
    |> Enum.filter(
      &(Spectre.GovernedAct.MeterState.reservation_status(projection, &1) == :reserved)
    )
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

  defp release_events(%Act{reservations: reservations}) when map_size(reservations) == 0,
    do: {:ok, []}

  defp release_events(%Act{} = act) do
    with {:ok, release} <- Event.meter(:release, act), do: {:ok, [release]}
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

  defp required_at(cause, fallback) do
    case Map.get(cause, :required_at) do
      value when is_integer(value) -> value
      _missing -> fallback
    end
  end

  defp cause_act_ref(cause) do
    cause
    |> Map.get(:causal_refs, %{})
    |> Map.get("act_ref")
  end
end
