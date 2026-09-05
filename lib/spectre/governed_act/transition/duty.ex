defmodule Spectre.GovernedAct.Transition.Duty do
  @moduledoc """
  Replays the obligation lifecycle derived by the Governed Act Model.

  A Duty is materialized only when its causal prefix requires it. Disposition
  must itself be an admitted governed Act, and any suspended Meter reservation
  is resolved in the same causal lifecycle. Keeping these rules together makes
  the obligation boundary explicit without coupling it to ledger I/O.
  """

  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.Duty
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.{Index, State}
  alias Spectre.GovernedAct.Transition.Duty.Disposal
  alias Spectre.GovernedAct.Transition.Duty.Meter, as: DutyMeter
  alias Spectre.GovernedAct.Transition.Duty.Opening

  @spec apply(State.t(), Event.t(), non_neg_integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def apply(
        %State{} = state,
        %Event{type: "duty_opened", identity: identity, data: data},
        revision
      ),
      do: reduce("duty_opened", identity, data, revision, state)

  def apply(
        %State{} = state,
        %Event{type: "duty_disposed", identity: identity, data: data},
        revision
      ),
      do: reduce("duty_disposed", identity, data, revision, state)

  def apply(
        %State{} = state,
        %Event{type: "meter_duty_resolved", identity: identity, data: data},
        revision
      ),
      do: reduce("meter_duty_resolved", identity, data, revision, state)

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_duty_event, type}}

  defp reduce("meter_duty_resolved", _identity, data, _revision, projection),
    do: DutyMeter.resolve(projection, data)

  defp reduce("duty_opened", identity, data, _revision, projection) do
    with {:ok, duty} <-
           Index.restore_unique(projection.duty_refs, Duty, identity, data, :duty),
         :ok <- Opening.validate(projection, duty) do
      {:ok,
       %{
         projection
         | duties: Map.put(projection.duties, duty.cause_key, duty),
           duty_refs: Map.put(projection.duty_refs, duty.ref, duty.cause_key)
       }}
    end
  end

  defp reduce("duty_disposed", identity, data, _revision, projection) do
    cause_key = data["cause_key"]
    disposition_act_ref = data["disposition_act_ref"]

    with {:ok, duty} <- Index.fetch_duty_by_cause(projection, cause_key),
         :ok <- duty_open(duty),
         :ok <- Record.match_identity(identity, disposition_act_ref),
         {:ok, act} <- Index.fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(act.consequence),
         {:ok, _supporting} <- Disposal.validate(projection, act, duty, disposition),
         :ok <- DutyMeter.validate_disposed(projection, duty, disposition, act.ref),
         {:ok, updated} <-
           Spectre.Duty.new(%{
             duty
             | status: :disposed,
               disposition_act_ref: disposition_act_ref
           }) do
      {:ok, %{projection | duties: Map.put(projection.duties, cause_key, updated)}}
    end
  end

  defp duty_open(%Spectre.Duty{status: :open}), do: :ok
  defp duty_open(%Spectre.Duty{cause_key: cause_key}), do: {:error, {:duty_disposed, cause_key}}
end
