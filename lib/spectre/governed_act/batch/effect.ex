defmodule Spectre.GovernedAct.Batch.Effect do
  @moduledoc """
  Exact event grammar for consequences completed inside the ledger.

  A governance Act is not complete merely because its class is recognized.
  The canonical suffix is derived by `Spectre.GovernedAct.Materialization`,
  the same pure semantics used by the commit driver, and compared with the
  decoded batch at the Act's exact position. Writer and replay therefore
  cannot acquire separate interpretations of a built-in consequence.
  """

  alias Spectre.Act
  alias Spectre.Domain.Event
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.Batch.Events
  alias Spectre.GovernedAct.{Class, Materialization}

  @doc false
  @spec exact?([Event.t()], Act.t(), non_neg_integer()) :: boolean() | :unsupported
  def exact?(events, %Act{class: "duty.dispose"} = act, act_index),
    do: exact_duty_disposition?(events, act, act_index)

  def exact?(events, %Act{} = act, act_index) do
    case Materialization.intrinsic_events(act) do
      {:ok, payloads} ->
        Events.payload_sequence?(events, payloads, act_index + 1)

      {:error, _reason} ->
        invalid_materialization_result(act)
    end
  end

  defp invalid_materialization_result(%Act{} = act) do
    cond do
      Class.batch_effect?(act.class) -> false
      act.row.delegate or act.row.govern -> :unsupported
      true -> true
    end
  end

  defp exact_duty_disposition?(events, act, act_index) do
    with {:ok, disposition} <- Disposition.from_consequence(act.consequence) do
      case disposition.meter_resolution do
        :none ->
          exact_duty_disposal_at?(events, act_index + 1, act, disposition)

        operation when operation in [:settle, :release] ->
          exact_duty_meter_resolution_at?(
            events,
            act_index + 1,
            act,
            disposition,
            operation
          ) and exact_duty_disposal_at?(events, act_index + 2, act, disposition)
      end
    else
      {:error, _reason} -> false
    end
  end

  defp exact_duty_meter_resolution_at?(events, index, act, disposition, operation) do
    case Events.at(events, index) do
      %{
        type: "meter_duty_resolved",
        identity: "meter_duty_resolved:" <> disposition_act_ref,
        data: data
      } ->
        disposition_act_ref == act.ref and data["disposition_act_ref"] == act.ref and
          data["duty_ref"] == disposition.duty_ref and data["operation"] == operation

      _missing_or_different ->
        false
    end
  end

  defp exact_duty_disposal_at?(events, index, act, disposition) do
    Events.manual_at?(
      events,
      index,
      "duty_disposed",
      act.ref,
      %{"cause_key" => disposition.cause_key, "disposition_act_ref" => act.ref}
    )
  end
end
