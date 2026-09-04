defmodule Spectre.GovernedAct.Transition.Scope do
  @moduledoc """
  Transition for durable Scope openings.

  A Scope is an application-facing context boundary, but its opening is still a
  governed fact. This module checks parentage, principals, disposition
  authorities, SubmissionContext reconstruction, and the optional authorizing
  Act before adding the restored opening to disposable state.
  """

  alias Spectre.Act
  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{Index, State}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Scope.Opening

  def apply(
        %State{} = projection,
        %Event{type: "scope_opened", identity: identity, data: data},
        _revision
      ) do
    with {:ok, opening} <- Record.decode(Opening, data),
         :ok <- Record.match_identity(identity, opening.ref),
         :ok <- Index.unique(projection.scopes, identity, :scope),
         :ok <- validate_scope_opening(projection, opening) do
      {:ok, %{projection | scopes: Map.put(projection.scopes, identity, opening)}}
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_scope_event, type}}

  defp validate_scope_opening(projection, opening) do
    with :ok <- scope_domain_matches(projection, opening),
         :ok <- scope_parent_exists(projection, opening),
         :ok <- scope_principals_exist(projection, opening),
         :ok <- scope_disposition_authorities_exist(projection, opening),
         :ok <- validate_opening_submission_context(opening),
         :ok <- validate_scope_opening_source(projection, opening) do
      :ok
    end
  end

  defp validate_scope_opening_source(_projection, %Opening{source_act_ref: nil}), do: :ok

  defp validate_scope_opening_source(projection, %Opening{} = opening) do
    with {:ok, act} <- Index.fetch_act(projection, opening.source_act_ref),
         {:ok, draft} <- Opening.governed_draft(opening) do
      cond do
        act.class != "scope.open" ->
          {:error, {:scope_opening_act_class_mismatch, opening.ref, act.ref}}

        not Act.row?(act, [:write, :govern]) ->
          {:error, {:scope_opening_act_row_mismatch, opening.ref, act.ref}}

        Act.reservations?(act) ->
          {:error, {:scope_opening_act_has_reservations, opening.ref, act.ref}}

        not GovernedExecution.ledger_internal?(act) ->
          {:error, {:scope_opening_act_not_ledger_internal, opening.ref, act.ref}}

        act.consequence != %{"scope_open" => draft} ->
          {:error, {:scope_opening_consequence_mismatch, opening.ref, act.ref}}

        act.scope_ref != opening.parent_ref ->
          {:error, {:scope_opening_parent_act_mismatch, opening.ref, act.ref}}

        act.accountable_ref != opening.accountable_ref ->
          {:error, {:scope_opening_accountable_act_mismatch, opening.ref, act.ref}}

        opening.ref not in act.target_refs ->
          {:error, {:scope_opening_target_missing, opening.ref, act.ref}}

        opening.opened_at != act.committed_at ->
          {:error, {:scope_opening_commit_time_mismatch, opening.ref, act.ref}}

        opening.host_generation != act.host_generation ->
          {:error, {:scope_opening_generation_act_mismatch, opening.ref, act.ref}}

        opening.ingress_ref != act.ingress_ref ->
          {:error, {:scope_opening_ingress_act_mismatch, opening.ref, act.ref}}

        true ->
          :ok
      end
    end
  end

  defp scope_domain_matches(projection, opening) do
    if opening.domain_ref == projection.domain_ref,
      do: :ok,
      else: {:error, {:scope_domain_mismatch, opening.ref, opening.domain_ref}}
  end

  defp scope_parent_exists(_projection, %Opening{parent_ref: nil}), do: :ok

  defp scope_parent_exists(projection, %Opening{} = opening) do
    if Map.has_key?(projection.scopes, opening.parent_ref),
      do: :ok,
      else: {:error, {:scope_parent_not_found, opening.ref, opening.parent_ref}}
  end

  defp scope_principals_exist(projection, opening) do
    refs =
      [opening.opened_by_ref, opening.accountable_ref]
      |> Enum.reject(&is_nil/1)

    case Enum.find(refs, &(not Map.has_key?(projection.principals, &1))) do
      nil -> :ok
      ref -> {:error, {:scope_principal_not_found, opening.ref, ref}}
    end
  end

  defp scope_disposition_authorities_exist(projection, opening) do
    case Enum.find(opening.disposition_authority_refs, fn ref ->
           not Map.has_key?(projection.principals, ref) and
             not Map.has_key?(projection.mandates, ref)
         end) do
      nil -> :ok
      ref -> {:error, {:scope_disposition_authority_not_found, opening.ref, ref}}
    end
  end

  defp validate_opening_submission_context(opening) do
    Opening.submission_context(opening)
    |> case do
      {:ok, _context} -> :ok
      {:error, reason} -> {:error, {:invalid_scope_submission_context, opening.ref, reason}}
    end
  end
end
