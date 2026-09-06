defmodule Spectre.GovernedAct.Transition.Authority do
  @moduledoc """
  Transitions for Mandate authority and its conserved Meter allocation.

  Issuance validates the authorizing source and delegates physical Meter
  balances. Restriction creates a forward-only successor without mutating its
  predecessor. Revocation records an explicit projection value; ancestry and
  cancellation consumers therefore share one typed representation.
  """

  alias Spectre.{Act, Mandate}
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{Index, MeterState, State, View}
  alias Spectre.GovernedAct.Transition.Foundation
  alias Spectre.Kernel.{Authority, Meter}
  alias Spectre.Kernel.Meter.Account
  alias Spectre.Mandate.{Ancestry, Revocation}

  def apply(
        %State{} = projection,
        %Event{type: "mandate_issued", identity: identity, data: data},
        _entry_revision
      ) do
    with {:ok, mandate} <-
           Index.restore_unique(projection.mandates, Mandate, identity, data, :mandate),
         :ok <- initial_mandate_revision(mandate),
         :ok <- validate_mandate_principals(projection, mandate),
         {:ok, meters} <- issue_mandate_meters(projection, mandate) do
      {:ok,
       %{
         projection
         | mandates: Map.put(projection.mandates, identity, mandate),
           meters: meters
       }}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "mandate_restricted", identity: identity, data: data},
        _revision
      ) do
    predecessor_ref = data["predecessor_ref"]
    act_ref = data["act_ref"]

    with {:ok, predecessor} <- Index.fetch_mandate(projection, predecessor_ref),
         {:ok, act} <- Index.fetch_act(projection, act_ref),
         {:ok, successor} <-
           Index.restore_unique(
             projection.mandates,
             Mandate,
             identity,
             data["successor"],
             :mandate
           ),
         :ok <- canonical_restriction_event(successor, data),
         :ok <- validate_mandate_principals(projection, successor),
         :ok <- validate_restriction_contract(act, predecessor, successor, data),
         :ok <- restrictable_predecessor(projection, predecessor, act.committed_at),
         :ok <- restriction_link_available(projection, predecessor.ref),
         {:ok, owner_ref} <- MeterState.owner(projection, predecessor.ref) do
      {:ok,
       %{
         projection
         | mandates: Map.put(projection.mandates, successor.ref, successor),
           mandate_successors:
             Map.put(projection.mandate_successors, predecessor.ref, successor.ref),
           meter_owner_aliases: Map.put(projection.meter_owner_aliases, successor.ref, owner_ref)
       }}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "mandate_revoked", identity: identity, data: data},
        _revision
      ) do
    mandate_ref = data["mandate_ref"]

    with {:ok, mandate} <- Index.fetch_mandate(projection, mandate_ref),
         false <- Map.has_key?(projection.revocations, mandate_ref),
         {:ok, governance_act} <- Index.fetch_act(projection, identity),
         :ok <- validate_revocation(governance_act, mandate, data) do
      with {:ok, revocation} <-
             Revocation.from_event(
               identity,
               data,
               Map.fetch!(mandate.revocation, "mode")
             ) do
        {:ok,
         %{projection | revocations: Map.put(projection.revocations, mandate_ref, revocation)}}
      end
    else
      true -> {:error, {:mandate_already_revoked, mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_authority_event, type}}

  defp initial_mandate_revision(%Mandate{revision: 1}), do: :ok

  defp initial_mandate_revision(%Mandate{ref: ref, revision: revision}),
    do: {:error, {:invalid_initial_mandate_revision, ref, revision}}

  defp validate_mandate_principals(projection, mandate) do
    refs =
      [mandate.grantor_ref, mandate.holder_ref, mandate.accountable_ref] ++
        Map.fetch!(mandate.revocation, "controller_refs")

    case Enum.find(refs, &(not Map.has_key?(projection.catalog.principals, &1))) do
      nil -> :ok
      ref -> {:error, {:mandate_principal_not_found, mandate.ref, ref}}
    end
  end

  defp issue_mandate_meters(projection, %Mandate{parent_ref: nil} = mandate) do
    with :ok <- Foundation.named_by_genesis(projection, :root_mandate_refs, mandate.ref),
         true <- mandate.source_ref == projection.catalog.genesis.ref do
      {:ok, MeterState.initialize(projection.meters, mandate)}
    else
      false -> {:error, {:invalid_root_mandate_source, mandate.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp issue_mandate_meters(projection, %Mandate{} = mandate) do
    with {:ok, parent} <- Index.fetch_mandate(projection, mandate.parent_ref),
         {:ok, source_act} <- Index.fetch_act(projection, mandate.source_ref),
         :ok <- validate_delegation_source(source_act, parent, mandate),
         :ok <- Authority.delegation_within?(parent, mandate, source_act.committed_at) do
      delegate_meters(projection, parent, mandate)
    end
  end

  defp validate_delegation_source(source_act, parent, child) do
    expected_draft =
      child
      |> Mandate.canonical()
      |> Map.drop(["ref", "source_ref"])

    with true <- source_act.class == "mandate.delegate",
         true <- Act.row?(source_act, [:delegate, :govern]),
         true <- not Act.reservations?(source_act),
         true <- source_act.mandate_ref == parent.ref,
         true <- source_act.mandate_revision == parent.revision,
         true <- Act.targets?(source_act, [parent.ref]),
         true <- source_act.consequence == %{"mandate_issue" => expected_draft} do
      :ok
    else
      false -> {:error, {:invalid_mandate_delegation_source, child.ref, source_act.ref}}
    end
  end

  defp delegate_meters(projection, parent, child) do
    with {:ok, parent_owner_ref} <- MeterState.owner(projection, parent.ref),
         {:ok, parent_accounts} <- MeterState.accounts(projection, parent.ref),
         child_accounts <- empty_meter_accounts(child),
         {:ok, parent_accounts, child_accounts} <-
           transfer_child_allocations(parent_accounts, child_accounts, child.meters) do
      {:ok,
       projection.meters
       |> Map.put(parent_owner_ref, parent_accounts)
       |> Map.put(child.ref, child_accounts)}
    end
  end

  defp empty_meter_accounts(mandate) do
    Map.new(mandate.meters, fn {meter_ref, _quantity} ->
      {meter_ref, Account.child(meter_ref)}
    end)
  end

  defp transfer_child_allocations(parent_accounts, child_accounts, allocations) do
    allocations
    |> Enum.sort_by(fn {meter_ref, _quantity} -> meter_ref end)
    |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
      {meter_ref, quantity}, {:ok, parents, children} ->
        with {:ok, parent_account} <- MeterState.account(parents, meter_ref),
             {:ok, child_account} <- MeterState.account(children, meter_ref),
             {:ok, parent_account, child_account} <-
               Meter.delegate(parent_account, child_account, quantity) do
          {:cont,
           {:ok, Map.put(parents, meter_ref, parent_account),
            Map.put(children, meter_ref, child_account)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp canonical_restriction_event(successor, data) do
    if data["successor"] == Mandate.canonical(successor),
      do: :ok,
      else: {:error, {:noncanonical_mandate_restriction, successor.ref}}
  end

  defp validate_restriction_contract(act, predecessor, successor, data) do
    expected_consequence = %{
      "mandate_restrict" => %{
        "predecessor_ref" => predecessor.ref,
        "successor" => successor |> Mandate.canonical() |> Map.drop(["ref", "source_ref"])
      }
    }

    cond do
      act.class != "mandate.restrict" ->
        {:error, {:mandate_restriction_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:mandate_restriction_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:mandate_restriction_act_has_reservations, act.ref}}

      not GovernedExecution.ledger_internal?(act) ->
        {:error, {:mandate_restriction_act_not_ledger_internal, act.ref}}

      not Act.targets?(act, [predecessor.ref]) ->
        {:error, {:mandate_restriction_act_target_missing, act.ref, predecessor.ref}}

      true ->
        validate_restriction_binding(act, predecessor, successor, data, expected_consequence)
    end
  end

  defp validate_restriction_binding(act, predecessor, successor, data, expected_consequence) do
    cond do
      data["act_ref"] != act.ref ->
        {:error, {:mandate_restriction_event_act_mismatch, successor.ref, act.ref}}

      data["predecessor_ref"] != predecessor.ref ->
        {:error, {:mandate_restriction_predecessor_mismatch, successor.ref, predecessor.ref}}

      successor.source_ref != act.ref ->
        {:error, {:mandate_restriction_source_mismatch, successor.ref, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:mandate_restriction_consequence_mismatch, act.ref, successor.ref}}

      true ->
        Authority.restriction_within?(predecessor, successor, act.committed_at)
    end
  end

  defp restriction_link_available(projection, predecessor_ref) do
    if Map.has_key?(projection.mandate_successors, predecessor_ref),
      do: {:error, {:mandate_already_has_successor, predecessor_ref}},
      else: :ok
  end

  defp restrictable_predecessor(projection, predecessor, time) do
    with :ok <- Authority.restriction_status(predecessor, View.authority(projection)),
         {:ok, false} <-
           Ancestry.terminal?(
             projection.mandates,
             projection.revocations,
             predecessor,
             time
           ) do
      :ok
    else
      {:ok, true} -> {:error, {:mandate_restriction_predecessor_inactive, predecessor.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_revocation(act, mandate, data) do
    controllers = Map.get(mandate.revocation, "controller_refs", [])
    effective_at = data["effective_at"]

    consequence = %{
      "mandate_revoke" => %{
        "mandate_ref" => data["mandate_ref"]
      }
    }

    cond do
      act.class != "mandate.revoke" ->
        {:error, {:revocation_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:revocation_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:revocation_act_has_reservations, act.ref}}

      not Act.targets?(act, [mandate.ref]) ->
        {:error, {:revocation_act_target_missing, act.ref, mandate.ref}}

      act.proposer_ref not in controllers ->
        {:error, {:revocation_controller_not_authorized, act.proposer_ref, mandate.ref}}

      effective_at !== act.committed_at ->
        {:error, {:invalid_revocation_effective_at, mandate.ref, effective_at}}

      act.consequence != consequence ->
        {:error, {:revocation_consequence_mismatch, act.ref, mandate.ref}}

      true ->
        :ok
    end
  end
end
