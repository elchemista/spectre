defmodule Spectre.Audit.Report do
  @moduledoc """
  Pure renderer for a verified governed history.

  Reports are derived only after `Spectre.GovernedAct.Integrity` succeeds. The
  renderer never validates or repairs history and never reads runtime state;
  its input is the disposable result of replaying the exported ledger.
  """

  alias Spectre.{Constitution, Declassification, Definition, Duty, Erasure, Genesis}
  alias Spectre.{HostProfile, Mandate, Surface}
  alias Spectre.GovernedAct.State
  alias Spectre.Scope.Opening

  @format "spectre-semantic-audit"
  @format_version 1

  @type t :: %{
          required(:format) => String.t(),
          required(:format_version) => pos_integer(),
          required(:domain_ref) => String.t(),
          required(:ledger_revision) => non_neg_integer(),
          required(:head_digest) => String.t(),
          required(:constitution_ref) => String.t(),
          required(:audited_at) => non_neg_integer(),
          required(:foundation) => map(),
          required(:act_contexts) => [map()],
          required(:meters) => map(),
          required(:meter_owners) => map(),
          required(:mandate_restrictions) => [map()],
          required(:meter_recontainments) => [map()],
          required(:dispatch_cancellations) => [map()],
          required(:open_duties) => [map()],
          required(:counts) => map()
        }

  @doc "Builds the portable semantic audit report from verified folded state."
  @spec build(State.t(), map(), map(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def build(%State{} = state, snapshot, constitution, audited_at)
      when is_map(snapshot) and is_map(constitution) and is_integer(audited_at) do
    with {:ok, act_contexts} <- act_contexts(state),
         {:ok, erasures} <- erasure_reports(state),
         {:ok, constitution_ref} <- Constitution.ref(constitution) do
      {:ok,
       %{
         format: @format,
         format_version: @format_version,
         domain_ref: state.domain_ref,
         ledger_revision: snapshot.revision,
         head_digest: snapshot.head_digest,
         constitution_ref: constitution_ref,
         audited_at: audited_at,
         foundation: foundation(state),
         act_contexts: act_contexts,
         mandate_restrictions: mandate_restrictions(state),
         meters: canonical_meters(state.meters),
         meter_owners: state.meter_owners,
         meter_recontainments: meter_recontainments(state),
         dispatch_cancellations: sorted_values(state.dispatch_cancellations, & &1.act_ref),
         open_duties: open_duties(state),
         scopes: canonical_scopes(state),
         definitions: canonical_definitions(state),
         definition_heads: definition_heads(state),
         declassifications: canonical_declassifications(state),
         erasures: erasures,
         counts: counts(state)
       }}
    end
  end

  def build(_state, _snapshot, _constitution, _audited_at),
    do: {:error, :invalid_audit_report_input}

  defp foundation(state) do
    %{
      genesis: Genesis.canonical(state.genesis),
      principals:
        state.principals
        |> Map.values()
        |> Enum.sort_by(& &1.ref)
        |> Enum.map(&Spectre.Principal.canonical/1),
      host_profile: HostProfile.canonical(state.host_profile),
      host_profile_history:
        state.host_profiles
        |> Map.values()
        |> Enum.sort_by(& &1.revision)
        |> Enum.map(&HostProfile.canonical/1),
      surface: Surface.canonical(state.surface),
      surface_history:
        state.surfaces
        |> Map.values()
        |> Enum.sort_by(& &1.revision)
        |> Enum.map(&Surface.canonical/1),
      principal_refs: Enum.sort(Map.keys(state.principals)),
      root_mandate_refs: Enum.sort(state.genesis.root_mandate_refs)
    }
  end

  defp act_contexts(state) do
    state.acts
    |> Map.values()
    |> Enum.reduce_while({:ok, []}, fn act, {:ok, contexts} ->
      with {:ok, metadata} <- metadata(state, "act_committed", act.ref),
           {:ok, host_profile} <- fetch(state.host_profiles, act.host_profile_ref, :host_profile),
           {:ok, surface} <- surface_at(state, act.surface_revision) do
        context = %{
          act_ref: act.ref,
          decision_ref: act.decision_ref,
          mandate_ref: act.mandate_ref,
          ledger_revision: metadata.revision,
          batch_id: metadata.batch_id,
          host_profile_ref: act.host_profile_ref,
          host_profile: HostProfile.canonical(host_profile),
          surface_ref: surface.ref,
          surface_revision: act.surface_revision,
          surface: Surface.canonical(surface)
        }

        {:cont, {:ok, [context | contexts]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, contexts} -> {:ok, Enum.sort_by(contexts, & &1.ledger_revision)}
      {:error, _reason} = error -> error
    end
  end

  defp surface_at(state, revision) do
    case Enum.find(state.surfaces, fn {_ref, surface} -> surface.revision == revision end) do
      {_ref, surface} -> {:ok, surface}
      nil -> {:error, {:surface_revision_not_found, revision}}
    end
  end

  defp mandate_restrictions(state) do
    state.mandate_successors
    |> Enum.map(fn {predecessor_ref, successor_ref} ->
      successor = Map.fetch!(state.mandates, successor_ref)

      %{
        act_ref: successor.source_ref,
        predecessor_ref: predecessor_ref,
        successor: Mandate.canonical(successor)
      }
    end)
    |> Enum.sort_by(&{&1.predecessor_ref, &1.successor["ref"]})
  end

  defp meter_recontainments(state) do
    state.meter_recontainments
    |> Map.values()
    |> Enum.sort_by(& &1.act_ref)
    |> Enum.map(fn record ->
      %{
        act_ref: record.act_ref,
        mandate_ref: record.mandate_ref,
        outcome_ref: record.outcome_ref,
        cause_key: record.cause_key,
        amounts: record.amounts,
        recontained: record.recontained,
        deficits: record.deficits,
        status: record.status,
        disposition_act_ref: record.disposition_act_ref
      }
    end)
  end

  defp open_duties(state) do
    state.duties
    |> Map.values()
    |> Enum.filter(&(&1.status == :open))
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&Duty.canonical/1)
  end

  defp canonical_scopes(state) do
    state.scopes
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&Opening.canonical/1)
  end

  defp canonical_definitions(state) do
    state.definitions
    |> Map.values()
    |> Enum.sort_by(&{&1.namespace, &1.name, &1.revision})
    |> Enum.map(&Definition.canonical/1)
  end

  defp definition_heads(state) do
    state.definition_heads
    |> Enum.map(fn {{namespace, name}, ref} ->
      %{namespace: namespace, name: name, ref: ref}
    end)
    |> Enum.sort_by(&{&1.namespace, &1.name})
  end

  defp canonical_declassifications(state) do
    state.declassifications
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&Declassification.canonical/1)
  end

  defp erasure_reports(state) do
    state.erasures
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn erasure, {:ok, reports} ->
      case erasure_report(state, erasure) do
        {:ok, report} -> {:cont, {:ok, [report | reports]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      {:error, _reason} = error -> error
    end
  end

  defp erasure_report(state, %Erasure{} = erasure) do
    with {:ok, outcomes} <- outcomes_for_act(state, erasure.source_act_ref) do
      status =
        case List.last(outcomes) do
          nil -> :requested
          outcome -> outcome.status
        end

      {:ok,
       %{
         request: Erasure.canonical(erasure),
         status: status,
         outcome_refs: Enum.map(outcomes, & &1.ref)
       }}
    end
  end

  defp outcomes_for_act(state, act_ref) do
    state.outcomes
    |> Map.values()
    |> Enum.filter(&(&1.act_ref == act_ref))
    |> Enum.reduce_while({:ok, []}, fn outcome, {:ok, outcomes} ->
      case metadata(state, "outcome_recorded", outcome.ref) do
        {:ok, metadata} -> {:cont, {:ok, [{metadata.revision, outcome} | outcomes]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, outcomes} ->
        {:ok,
         outcomes
         |> Enum.sort_by(fn {revision, outcome} -> {revision, outcome.ref} end)
         |> Enum.map(&elem(&1, 1))}

      {:error, _reason} = error ->
        error
    end
  end

  defp canonical_meters(meters) do
    Map.new(meters, fn {mandate_ref, accounts} ->
      canonical_accounts =
        Map.new(accounts, fn {meter_ref, account} ->
          fields = [:ceiling, :available, :reserved, :suspended, :spent, :delegated]
          {meter_ref, Map.new(fields, &{Atom.to_string(&1), Map.fetch!(account, &1)})}
        end)

      {mandate_ref, canonical_accounts}
    end)
  end

  defp counts(state) do
    %{
      principals: map_size(state.principals),
      mandates: map_size(state.mandates),
      mandate_restrictions: map_size(state.mandate_successors),
      revocations: map_size(state.revocations),
      declassifications: map_size(state.declassifications),
      evidence: map_size(state.evidence),
      presentations: map_size(state.presentations),
      decisions: map_size(state.decisions),
      acts: map_size(state.acts),
      attempts: map_size(state.attempts),
      outcomes: map_size(state.outcomes),
      duties: map_size(state.duties),
      scopes: map_size(state.scopes),
      definitions: map_size(state.definitions),
      erasures: map_size(state.erasures),
      meter_owners: map_size(state.meter_owners),
      meter_recontainments: map_size(state.meter_recontainments),
      meter_devolutions: MapSet.size(state.meter_devolutions),
      dispatch_cancellations: map_size(state.dispatch_cancellations)
    }
  end

  defp metadata(state, type, ref) do
    fetch(state.event_metadata, {type, ref}, :event_metadata)
  end

  defp sorted_values(map, sorter), do: map |> Map.values() |> Enum.sort_by(sorter)

  defp fetch(collection, key, kind) do
    case Map.fetch(collection, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {kind, :not_found, key}}
    end
  end
end
