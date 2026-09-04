defmodule Spectre.GovernedAct.Batch.World do
  @moduledoc """
  Enforces durable separation between world-side execution stages.

  Admission, capability consumption and observation cannot prove one another
  merely by appearing in the same atomic batch. Attempt requires an already
  durable dispatch, and Outcome requires an already durable Attempt.
  """

  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{DispatchState, State}

  @doc false
  @spec validate(State.t(), [Event.t()]) :: :ok | {:error, term()}
  def validate(%State{} = before, events) when is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      result =
        case event.type do
          "attempt_started" -> validate_prior_dispatch(before, event)
          "outcome_recorded" -> validate_prior_attempt(before, event)
          _other -> :ok
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_prior_dispatch(before, event) do
    act_ref = event.data["act_ref"]

    if DispatchState.pending?(before, act_ref),
      do: :ok,
      else: {:error, {:attempt_without_prior_durable_dispatch, event.identity, act_ref}}
  end

  defp validate_prior_attempt(before, event) do
    attempt_ref = event.data["attempt_ref"]
    act_ref = event.data["act_ref"]

    case Map.fetch(before.attempts, attempt_ref) do
      {:ok, %{act_ref: ^act_ref}} ->
        :ok

      {:ok, _different} ->
        {:error, {:outcome_prior_attempt_mismatch, event.identity, attempt_ref}}

      :error ->
        {:error, {:outcome_without_prior_durable_attempt, event.identity, attempt_ref}}
    end
  end
end
