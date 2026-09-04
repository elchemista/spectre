defmodule Spectre.GovernedAct.Batch.Effect do
  @moduledoc """
  Exact event grammar for consequences completed inside the ledger.

  A governance Act is not complete merely because its class is recognized.
  This validator proves that the immediately following event or events are the
  canonical materialization of the Act's exact consequence.
  """

  alias Spectre.{
    Act,
    Declassification,
    Definition,
    Erasure,
    Evidence,
    HostProfile,
    Mandate,
    Principal,
    Surface
  }

  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.Duty.Disposition
  alias Spectre.GovernedAct.Batch.Events
  alias Spectre.GovernedAct.Class, as: GovernedClass
  alias Spectre.Scope.Opening

  @doc false
  @spec exact?([Event.t()], Act.t(), non_neg_integer()) :: boolean() | :unsupported
  def exact?(
        events,
        %Act{
          class: "principal.register",
          consequence: %{"principal_registration" => canonical}
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 do
    with {:ok, principal} <- Record.decode(Principal, canonical) do
      Events.manual_at?(
        events,
        act_index + 1,
        "principal_registered",
        principal.ref,
        %{"act_ref" => act.ref, "principal" => Principal.canonical(principal)}
      )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act,
        act_index
      )
      when map_size(act.consequence) == 1 do
    with {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref) do
      Events.record_at?(events, act_index + 1, "mandate_issued", Mandate, mandate)
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{
          class: "mandate.revoke",
          consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 1 do
    Events.manual_at?(
      events,
      act_index + 1,
      "mandate_revoked",
      act.ref,
      %{"mandate_ref" => mandate_ref, "effective_at" => act.committed_at}
    )
  end

  def exact?(
        events,
        %Act{
          class: "mandate.restrict",
          consequence: %{
            "mandate_restrict" =>
              %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
          }
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref) do
      Events.embedded_at?(
        events,
        act_index + 1,
        "mandate_restricted",
        act.ref,
        predecessor_ref,
        "predecessor_ref",
        "successor",
        Mandate,
        successor
      )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{
          class: "mandate.devolve",
          consequence: %{
            "mandate_devolve" =>
              %{"child_mandate_ref" => child_ref, "amounts" => amounts} = command
          }
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    Events.manual_at?(
      events,
      act_index + 1,
      "meter_devolved",
      "meter_devolved:" <> act.ref,
      %{"act_ref" => act.ref, "child_mandate_ref" => child_ref, "amounts" => amounts}
    )
  end

  def exact?(
        events,
        %Act{
          class: "surface.revise",
          consequence: %{
            "surface_revision" =>
              %{"previous_ref" => previous_ref, "surface" => canonical} = command
          }
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, surface} <- Record.decode(Surface, canonical) do
      Events.embedded_at?(
        events,
        act_index + 1,
        "surface_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "surface",
        Surface,
        surface
      )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{
          class: "host_profile.revise",
          consequence: %{
            "host_profile_revision" =>
              %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
          }
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, profile} <- Record.decode(HostProfile, canonical) do
      Events.embedded_at?(
        events,
        act_index + 1,
        "host_profile_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "host_profile",
        HostProfile,
        profile
      )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{
          class: "definition.revise",
          consequence: %{
            "definition_revision" =>
              %{"previous_ref" => previous_ref, "definition" => canonical} = command
          }
        } = act,
        act_index
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, definition} <- Record.decode(Definition, canonical) do
      Events.embedded_at?(
        events,
        act_index + 1,
        "definition_revised",
        act.ref,
        previous_ref,
        "previous_ref",
        "definition",
        Definition,
        definition
      )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{class: "data.declassify", consequence: %{"evidence_declassification" => draft}} =
          act,
        act_index
      )
      when map_size(act.consequence) == 1 do
    with {:ok, decoded} <- Declassification.decode_draft(draft),
         {:ok, declassification} <-
           Declassification.from_draft(decoded.canonical, act.ref, act.committed_at) do
      Events.record_at?(
        events,
        act_index + 1,
        "declassification_recorded",
        Declassification,
        declassification
      ) and
        Events.record_at?(
          events,
          act_index + 2,
          "evidence_recorded",
          Evidence,
          decoded.evidence
        )
    else
      {:error, _reason} -> false
    end
  end

  def exact?(
        events,
        %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act,
        act_index
      )
      when map_size(act.consequence) == 1 do
    with {:ok, canonical} <- Erasure.request_draft(draft),
         true <- canonical == draft,
         {:ok, erasure} <- Erasure.from_request_draft(canonical, act.ref) do
      Events.record_at?(events, act_index + 1, "erasure_requested", Erasure, erasure)
    else
      _invalid -> false
    end
  end

  def exact?(
        events,
        %Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act,
        act_index
      )
      when map_size(act.consequence) == 1 do
    with {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at) do
      Events.record_at?(events, act_index + 1, "scope_opened", Opening, opening)
    else
      {:error, _reason} -> false
    end
  end

  def exact?(events, %Act{class: "duty.dispose"} = act, act_index),
    do: exact_duty_disposition?(events, act, act_index)

  def exact?(_events, %Act{} = act, _act_index) do
    cond do
      GovernedClass.batch_effect?(act.class) -> false
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
