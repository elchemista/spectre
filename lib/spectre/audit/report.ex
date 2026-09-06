defmodule Spectre.Audit.Report do
  @moduledoc """
  Pure renderer for a verified governed history.

  Reports are derived only after `Spectre.GovernedAct.Integrity` succeeds. The
  renderer never validates or repairs history and never reads runtime state;
  its input is the disposable result of replaying the exported ledger.

  Recorded `open_duties` are kept separate from `pending_duty_causes` derived
  after capture. Likewise, `expired_dispatches` describe pending deliveries
  that expire by observation time, not cancellations that were committed.
  Counts and Meter accounts always describe the captured ledger, not a
  simulated repair. These distinctions preserve an export's causal history.
  """

  alias Spectre.{Constitution, Declassification, Definition, Duty, Erasure, Genesis}
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{DispatchState, Index, MeterState, State}
  alias Spectre.{HostProfile, Mandate, Surface}
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
          required(:captured_at) => non_neg_integer(),
          required(:foundation) => map(),
          required(:act_contexts) => [map()],
          required(:meters) => map(),
          required(:meter_owners) => map(),
          required(:mandate_restrictions) => [map()],
          required(:meter_recontainments) => [map()],
          required(:dispatch_cancellations) => [map()],
          required(:open_duties) => [map()],
          required(:pending_duty_causes) => [Derive.cause()],
          required(:expired_dispatches) => [map()],
          required(:scopes) => [map()],
          required(:definitions) => [map()],
          required(:definition_heads) => [map()],
          required(:declassifications) => [map()],
          required(:erasures) => [map()],
          required(:counts) => map()
        }

  @doc "Builds the portable semantic audit report from verified folded state."
  @spec build(State.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def build(state, audited_at), do: build(state, audited_at, audited_at)

  @doc "Builds an observation report without mutating the verified captured state."
  @spec build(State.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, term()}
  def build(%State{} = state, captured_at, audited_at)
      when is_integer(captured_at) and captured_at >= 0 and
             is_integer(audited_at) and audited_at >= captured_at do
    with {:ok, act_contexts} <- act_contexts(state),
         {:ok, erasures} <- erasure_reports(state),
         {:ok, expired} <- DispatchState.expired(state, audited_at),
         {:ok, constitution_ref} <- Constitution.ref(state.constitution) do
      {:ok,
       %{
         format: @format,
         format_version: @format_version,
         domain_ref: state.domain_ref,
         ledger_revision: state.revision,
         head_digest: state.head_digest,
         constitution_ref: constitution_ref,
         audited_at: audited_at,
         captured_at: captured_at,
         foundation: foundation(state),
         act_contexts: act_contexts,
         mandate_restrictions: mandate_restrictions(state),
         meters: canonical_meters(state.meters),
         meter_owners: meter_owners(state),
         meter_recontainments: meter_recontainments(state),
         dispatch_cancellations: dispatch_cancellations(state),
         open_duties: open_duties(state),
         pending_duty_causes: Derive.missing_openings(state, audited_at),
         expired_dispatches:
           Enum.map(expired, fn {act, mandate} ->
             %{act_ref: act.ref, mandate_ref: mandate.ref, expired_at: mandate.expires_at}
           end),
         scopes: canonical_scopes(state),
         definitions: canonical_definitions(state),
         definition_heads: definition_heads(state),
         declassifications: canonical_declassifications(state),
         erasures: erasures,
         counts: counts(state)
       }}
    end
  end

  def build(_state, _captured_at, _audited_at),
    do: {:error, :invalid_audit_report_input}

  defp foundation(state) do
    %{
      genesis: Genesis.canonical(state.catalog.genesis),
      principals:
        state.catalog.principals
        |> Map.values()
        |> Enum.sort_by(& &1.ref)
        |> Enum.map(&Spectre.Principal.canonical/1),
      host_profile: state |> State.host_profile() |> HostProfile.canonical(),
      host_profile_history:
        state.catalog.host_profiles
        |> Map.values()
        |> Enum.sort_by(& &1.revision)
        |> Enum.map(&HostProfile.canonical/1),
      surface: state |> State.surface() |> Surface.canonical(),
      surface_history:
        state.catalog.surfaces
        |> Map.values()
        |> Enum.sort_by(& &1.revision)
        |> Enum.map(&Surface.canonical/1),
      principal_refs: Enum.sort(Map.keys(state.catalog.principals)),
      root_mandate_refs: Enum.sort(state.catalog.genesis.root_mandate_refs)
    }
  end

  defp act_contexts(state) do
    surfaces_by_revision =
      Map.new(state.catalog.surfaces, fn {_ref, surface} -> {surface.revision, surface} end)

    state.acts
    |> Map.values()
    |> Enum.reduce_while({:ok, []}, fn act, {:ok, contexts} ->
      with {:ok, metadata} <- metadata(state, act.ref),
           {:ok, host_profile} <-
             Index.fetch_required(
               state.catalog.host_profiles,
               act.host_profile_ref,
               :host_profile
             ),
           {:ok, surface} <- surface_at(surfaces_by_revision, act.surface_revision) do
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

  defp surface_at(surfaces_by_revision, revision) do
    case Map.fetch(surfaces_by_revision, revision) do
      {:ok, surface} -> {:ok, surface}
      :error -> {:error, {:surface_revision_not_found, revision}}
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
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {act_ref, record} ->
      {:ok, reservation} = MeterState.reservation(state, act_ref)

      %{
        act_ref: act_ref,
        mandate_ref: reservation.mandate_ref,
        outcome_ref: record.outcome_ref,
        cause_key: record.cause_key,
        amounts: reservation.amounts,
        recontained: record.recontained,
        deficits: record.deficits,
        status: if(is_nil(record.disposition_act_ref), do: :open, else: :disposed),
        disposition_act_ref: record.disposition_act_ref
      }
    end)
  end

  defp meter_owners(state) do
    Map.new(state.mandates, fn {mandate_ref, _mandate} ->
      {:ok, owner_ref} = MeterState.owner(state, mandate_ref)
      {mandate_ref, owner_ref}
    end)
  end

  defp dispatch_cancellations(state) do
    state
    |> DispatchState.cancellations()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {act_ref, cancellation} ->
      act = Map.fetch!(state.acts, act_ref)

      cancellation
      |> Map.put(:act_ref, act_ref)
      |> Map.put(:mandate_ref, act.mandate_ref)
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
    state.catalog.scopes
    |> Map.values()
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&Opening.canonical/1)
  end

  defp canonical_definitions(state) do
    state.catalog.definitions
    |> Map.values()
    |> Enum.sort_by(&{&1.namespace, &1.name, &1.revision})
    |> Enum.map(&Definition.canonical/1)
  end

  defp definition_heads(state) do
    state.catalog.definition_heads
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
    with {:ok, outcomes_by_act} <- outcomes_by_act(state) do
      reports =
        state.erasures
        |> Map.values()
        |> Enum.sort_by(& &1.ref)
        |> Enum.map(&erasure_report(&1, outcomes_by_act))

      {:ok, reports}
    end
  end

  defp erasure_report(%Erasure{} = erasure, outcomes_by_act) do
    outcomes = Map.get(outcomes_by_act, erasure.source_act_ref, [])

    status =
      case List.last(outcomes) do
        nil -> :requested
        outcome -> outcome.status
      end

    %{
      request: Erasure.canonical(erasure),
      status: status,
      outcome_refs: Enum.map(outcomes, & &1.ref)
    }
  end

  defp outcomes_by_act(state) do
    state.outcomes
    |> Map.values()
    |> Enum.reduce_while({:ok, %{}}, fn outcome, {:ok, by_act} ->
      case metadata(state, outcome.ref) do
        {:ok, metadata} ->
          entry = {metadata.revision, outcome}
          {:cont, {:ok, Map.update(by_act, outcome.act_ref, [entry], &[entry | &1])}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, by_act} ->
        {:ok,
         Map.new(by_act, fn {act_ref, outcomes} ->
           ordered =
             outcomes
             |> Enum.sort_by(fn {revision, outcome} -> {revision, outcome.ref} end)
             |> Enum.map(&elem(&1, 1))

           {act_ref, ordered}
         end)}

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
      principals: map_size(state.catalog.principals),
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
      scopes: map_size(state.catalog.scopes),
      definitions: map_size(state.catalog.definitions),
      erasures: map_size(state.erasures),
      meter_owners: map_size(state.mandates),
      meter_recontainments: map_size(state.meter_recontainments),
      meter_devolutions: MapSet.size(state.meter_devolutions),
      dispatch_cancellations: Enum.count(DispatchState.cancellations(state))
    }
  end

  defp metadata(state, ref) do
    Index.fetch_required(state.event_metadata, ref, :event_metadata)
  end
end
