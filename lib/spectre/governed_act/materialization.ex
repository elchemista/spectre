defmodule Spectre.GovernedAct.Materialization do
  @moduledoc """
  Materializes built-in governed consequences into their atomic event suffix.

  Admission has already frozen and validated the Act before this module runs.
  These functions construct only the exact ledger records implied by that Act;
  application-defined executor effects never pass through this materializer.
  """

  alias Spectre.{
    Act,
    Declassification,
    Definition,
    Erasure,
    HostProfile,
    Mandate,
    Principal,
    Surface
  }

  alias Spectre.Domain.Event
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.Materialization.{Authority, Duty}
  alias Spectre.GovernedAct.State
  alias Spectre.Scope.Opening

  @spec events(State.t(), Act.t()) :: {:ok, [map()]} | {:error, term()}
  def events(
        %State{} = projection,
        %Act{
          class: "mandate.revoke",
          consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref}}
        } = act
      ) do
    with {:ok, materialized} <- intrinsic_events(act),
         {:ok, cancellations} <-
           Authority.cancellation_events(projection, act, mandate_ref, :mandate_revoked) do
      {:ok, materialized ++ cancellations}
    end
  end

  def events(
        %State{} = projection,
        %Act{
          class: "mandate.restrict",
          consequence: %{
            "mandate_restrict" => %{"predecessor_ref" => predecessor_ref}
          }
        } = act
      ) do
    with {:ok, materialized} <- intrinsic_events(act),
         {:ok, cancellations} <-
           Authority.cancellation_events(
             projection,
             act,
             predecessor_ref,
             :mandate_restricted
           ) do
      {:ok, materialized ++ cancellations}
    end
  end

  def events(
        %State{} = projection,
        %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act
      )
      when map_size(act.consequence) == 1 do
    with {:ok, erasure, event} <- erasure_event(act, draft),
         :ok <- ErasureAnalysis.requestable?(projection, erasure.target_ref),
         :ok <- ErasureAnalysis.validate_request(projection, draft) do
      {:ok, [event]}
    end
  end

  def events(%State{} = projection, %Act{class: "duty.dispose"} = act),
    do: Duty.events(projection, act)

  def events(%State{}, %Act{} = act), do: intrinsic_events(act)

  @doc false
  @spec intrinsic_events(Act.t()) :: {:ok, [map()]} | {:error, term()}
  def intrinsic_events(
        %Act{
          class: "principal.register",
          consequence: %{"principal_registration" => canonical}
        } = act
      )
      when map_size(act.consequence) == 1 do
    with true <- Act.row?(act, [:govern]),
         true <- not Act.reservations?(act),
         true <- GovernedExecution.ledger_internal?(act),
         {:ok, principal} <- Principal.from_canonical(canonical),
         true <- principal.ref in act.target_refs,
         {:ok, event} <- Event.principal_registered(act, principal) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_principal_registration}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{class: "mandate.delegate", consequence: %{"mandate_issue" => draft}} = act
      )
      when map_size(act.consequence) == 1 do
    with true <- Act.row?(act, [:delegate, :govern]),
         true <- not Act.reservations?(act),
         {:ok, mandate} <- Mandate.from_issue_draft(draft, act.ref),
         false <- Mandate.root?(mandate),
         {:ok, event} <- Event.record(:mandate, mandate) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_delegated_mandate_issue}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "mandate.devolve",
          consequence: %{
            "mandate_devolve" =>
              %{"child_mandate_ref" => child_mandate_ref, "amounts" => amounts} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- Act.row?(act, [:delegate, :govern]),
         true <- not Act.reservations?(act),
         {:ok, event} <- Event.meter_devolved(act, child_mandate_ref, amounts) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_meter_devolution}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "mandate.revoke",
          consequence: %{
            "mandate_revoke" => %{"mandate_ref" => mandate_ref} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 1 do
    with true <- Act.row?(act, [:govern]),
         true <- not Act.reservations?(act),
         {:ok, event} <- Event.mandate_revoked(act, mandate_ref) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_mandate_revocation}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "mandate.restrict",
          consequence: %{
            "mandate_restrict" =>
              %{"predecessor_ref" => predecessor_ref, "successor" => draft} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- Act.row?(act, [:govern]),
         true <- not Act.reservations?(act),
         true <- GovernedExecution.ledger_internal?(act),
         {:ok, successor} <- Mandate.from_issue_draft(draft, act.ref),
         {:ok, event} <- Event.mandate_restricted(act, predecessor_ref, successor) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_mandate_restriction}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "surface.revise",
          consequence: %{
            "surface_revision" =>
              %{"previous_ref" => previous_ref, "surface" => canonical} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- Act.row?(act, [:govern]),
         {:ok, surface} <- Surface.from_canonical(canonical),
         true <- canonical == Surface.canonical(surface),
         {:ok, event} <- Event.surface_revised(act, previous_ref, surface) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_surface_revision}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "host_profile.revise",
          consequence: %{
            "host_profile_revision" =>
              %{"previous_ref" => previous_ref, "host_profile" => canonical} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- Act.row?(act, [:govern]),
         {:ok, profile} <- HostProfile.from_canonical(canonical),
         true <- canonical == HostProfile.canonical(profile),
         {:ok, event} <- Event.host_profile_revised(act, previous_ref, profile) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_host_profile_revision}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{
          class: "definition.revise",
          consequence: %{
            "definition_revision" =>
              %{"previous_ref" => previous_ref, "definition" => canonical} = command
          }
        } = act
      )
      when map_size(act.consequence) == 1 and map_size(command) == 2 do
    with true <- Act.row?(act, [:govern]),
         true <- not Act.reservations?(act),
         {:ok, definition} <- Definition.from_canonical(canonical),
         true <- canonical == Definition.canonical(definition),
         true <- previous_ref == definition.previous_ref,
         {:ok, event} <- Event.definition_revised(act, definition) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_definition_revision}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{class: "data.declassify", consequence: %{"evidence_declassification" => draft}} =
          act
      )
      when map_size(act.consequence) == 1 do
    with true <- Act.row?(act, [:write, :govern]),
         true <- not Act.reservations?(act),
         true <- GovernedExecution.ledger_internal?(act),
         {:ok, decoded} <- Declassification.decode_draft(draft),
         true <- decoded.canonical == draft,
         :ok <- Declassification.validate_producer(decoded.evidence, act.proposer_ref),
         {:ok, required_targets} <-
           Declassification.required_target_refs(decoded.evidence, decoded.removed_labels),
         true <- Enum.all?(required_targets, &(&1 in act.target_refs)),
         {:ok, declassification} <-
           Declassification.from_draft(decoded.canonical, act.ref, act.committed_at),
         {:ok, declassification_event} <- Event.record(:declassification, declassification),
         {:ok, evidence_event} <- Event.record(:evidence, decoded.evidence) do
      {:ok, [declassification_event, evidence_event]}
    else
      false -> {:error, :invalid_evidence_declassification}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(
        %Act{class: "data.erase", consequence: %{"erasure_request" => draft}} = act
      )
      when map_size(act.consequence) == 1 do
    with {:ok, _erasure, event} <- erasure_event(act, draft), do: {:ok, [event]}
  end

  def intrinsic_events(%Act{class: "scope.open", consequence: %{"scope_open" => draft}} = act)
      when map_size(act.consequence) == 1 do
    with true <- Act.row?(act, [:write, :govern]),
         true <- not Act.reservations?(act),
         true <- GovernedExecution.ledger_internal?(act),
         {:ok, opening} <- Opening.from_governed_draft(draft, act.ref, act.committed_at),
         true <- opening.parent_ref == act.scope_ref,
         true <- opening.ref in act.target_refs,
         {:ok, event} <- Event.scope_opened(opening) do
      {:ok, [event]}
    else
      false -> {:error, :invalid_governed_scope_opening}
      {:error, _reason} = error -> error
    end
  end

  def intrinsic_events(%Act{row: %{delegate: true}}),
    do: {:error, :invalid_delegation_consequence}

  def intrinsic_events(%Act{row: %{govern: true}}),
    do: {:error, :unknown_governance_consequence}

  def intrinsic_events(%Act{}), do: {:ok, []}

  defp erasure_event(act, draft) do
    with true <- Act.row?(act, [:attempt, :write, :govern]),
         {:ok, canonical_draft} <- Erasure.request_draft(draft),
         true <- canonical_draft == draft,
         {:ok, erasure} <- Erasure.from_request_draft(canonical_draft, act.ref),
         true <- erasure.scope_ref == act.scope_ref,
         true <- erasure.target_ref in act.target_refs,
         true <- erasure.requested_at <= act.committed_at,
         {:ok, event} <- Event.record(:erasure, erasure) do
      {:ok, erasure, event}
    else
      false -> {:error, :invalid_erasure_request}
      {:error, _reason} = error -> error
    end
  end
end
