defmodule Spectre.Scope.View do
  @moduledoc """
  Read-only application view derived from one Domain projection.

  A view is disposable and carries no authority, Grant, credential or executor
  handle.  Every collection is selected from the exact Scope and returned in a
  deterministic order so callers never need to inspect the kernel projection
  directly.
  """

  alias Spectre.Domain.Projection
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.{DispatchState, State}
  alias Spectre.Scope.Opening

  @enforce_keys [
    :revision,
    :opening,
    :decisions,
    :acts,
    :attempts,
    :outcomes,
    :duties,
    :evidence,
    :declassifications,
    :presentations,
    :erasures,
    :dispatch_cancellations,
    :pending_act_refs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          opening: Opening.t(),
          decisions: [Spectre.Decision.t()],
          acts: [Spectre.Act.t()],
          attempts: [Spectre.Attempt.t()],
          outcomes: [Spectre.Outcome.t()],
          duties: [Spectre.Duty.t()],
          evidence: [Spectre.Evidence.t()],
          declassifications: [Spectre.Declassification.t()],
          presentations: [Spectre.Presentation.t()],
          erasures: [Spectre.Erasure.t()],
          dispatch_cancellations: [
            %{
              required(:act_ref) => String.t(),
              required(:cause_ref) => String.t(),
              required(:reason) => atom(),
              required(:cancelled_at) => non_neg_integer()
            }
          ],
          pending_act_refs: [String.t()]
        }

  @doc "Builds a capability-free view for an already opened Scope."
  @spec from_projection(Projection.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_projection(%State{} = projection, scope_ref)
      when is_binary(scope_ref) and scope_ref != "" do
    with {:ok, opening} <- scope_opening(projection, scope_ref) do
      {records, act_refs} = scope_records(projection, scope_ref)

      collections =
        records
        |> Map.put(:decisions, records_for_scope(projection.decisions, scope_ref))
        |> Map.put(:evidence, Map.values(evidence_index(projection, scope_ref, records)))
        |> Map.new(fn {field, values} -> {field, stable_records(values)} end)

      {:ok,
       struct!(
         __MODULE__,
         Map.merge(collections, %{
           revision: projection.revision,
           opening: opening,
           dispatch_cancellations: dispatch_cancellations(projection, act_refs),
           pending_act_refs: pending_act_refs(projection, act_refs)
         })
       )}
    end
  end

  def from_projection(%State{}, scope_ref), do: {:error, {:invalid_scope_ref, scope_ref}}
  def from_projection(_projection, _scope_ref), do: {:error, :invalid_domain_projection}

  @doc false
  @spec evidence(Projection.t(), String.t(), [String.t()]) ::
          {:ok, [Spectre.Evidence.t()]} | {:error, term()}
  def evidence(%State{} = projection, scope_ref, refs) when is_list(refs) do
    with {:ok, _opening} <- scope_opening(projection, scope_ref) do
      {records, _act_refs} = scope_records(projection, scope_ref)
      available = evidence_index(projection, scope_ref, records)
      select_evidence(available, refs)
    end
  end

  defp select_evidence(available, refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, selected} ->
      case Map.fetch(available, ref) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | selected]}}
        :error -> {:halt, {:error, {:evidence_outside_scope, ref}}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      {:error, _reason} = error -> error
    end
  end

  defp scope_opening(projection, scope_ref) do
    case Map.fetch(projection.scopes, scope_ref) do
      {:ok, %Opening{} = opening} -> {:ok, opening}
      :error -> {:error, {:scope_not_open, scope_ref}}
      _invalid -> {:error, {:invalid_scope_opening, scope_ref}}
    end
  end

  # Both the full application view and Turn input use these exact causal
  # relations. Keep selection unordered; only the public view needs sorting.
  # No new persistent index or independently maintained visibility rule exists.
  defp scope_records(projection, scope_ref) do
    acts = records_for_scope(projection.acts, scope_ref)
    act_refs = ref_set(acts)
    attempts = records_for_acts(projection.attempts, act_refs)
    presentation_refs = acts |> Enum.map(& &1.presentation_ref) |> present_ref_set()

    presentations =
      select(projection.presentations, fn presentation ->
        presentation.scope_ref == scope_ref or MapSet.member?(presentation_refs, presentation.ref)
      end)

    records = %{
      acts: acts,
      attempts: attempts,
      outcomes: records_for_attempts(projection.outcomes, act_refs, ref_set(attempts)),
      duties: records_for_duties(projection.duties, projection.evidence, scope_ref, act_refs),
      presentations: presentations,
      declassifications: records_for_source_acts(projection.declassifications, act_refs),
      erasures: records_for_scope(projection.erasures, scope_ref)
    }

    {records, act_refs}
  end

  defp records_for_scope(index, scope_ref) do
    select(index, &(&1.scope_ref == scope_ref))
  end

  defp records_for_acts(index, act_refs) do
    select(index, &MapSet.member?(act_refs, &1.act_ref))
  end

  defp records_for_source_acts(index, act_refs) do
    select(index, &MapSet.member?(act_refs, &1.source_act_ref))
  end

  defp records_for_attempts(index, act_refs, attempt_refs) do
    select(index, fn outcome ->
      MapSet.member?(act_refs, outcome.act_ref) and
        MapSet.member?(attempt_refs, outcome.attempt_ref)
    end)
  end

  defp records_for_duties(index, evidence, scope_ref, act_refs) do
    select(index, fn duty ->
      MapSet.member?(act_refs, duty.act_ref) or
        scope_cause?(duty.cause_key, scope_ref) or
        duty_evidence_bound_to_scope?(duty, evidence, scope_ref)
    end)
  end

  defp duty_evidence_bound_to_scope?(duty, evidence, scope_ref) do
    duty.evidence_refs
    |> Enum.any?(fn evidence_ref ->
      case Map.get(evidence, evidence_ref) do
        nil -> false
        record -> Map.get(record.bindings, "scope_ref") == scope_ref
      end
    end)
  end

  defp evidence_index(projection, scope_ref, records) do
    index = projection.evidence

    seeds =
      Enum.concat([
        bound_evidence_refs(index, scope_ref, records),
        record_refs(records.acts, [:evidence_refs, :target_refs]),
        record_refs(records.outcomes, [:evidence_refs]),
        record_refs(records.duties, [:evidence_refs]),
        record_refs(records.declassifications, [:evidence_ref, :parent_refs]),
        record_refs(records.erasures, [:target_ref, :affected_refs])
      ])

    refs =
      index
      |> evidence_ref_closure(seeds)
      |> MapSet.difference(ErasureAnalysis.unavailable_evidence_refs(projection))
      |> MapSet.to_list()

    Map.take(index, refs)
  end

  # Approval Evidence points to a Presentation through its closed binding. The
  # Presentation deliberately does not own or interpret arbitrary application
  # data, so this is its only structural Evidence relation.
  defp bound_evidence_refs(index, scope_ref, records) do
    presentation_refs = ref_set(records.presentations)
    act_refs = ref_set(records.acts)

    Enum.reduce(index, [], fn {_ref, evidence}, refs ->
      bindings = evidence.bindings

      if Map.get(bindings, "scope_ref") == scope_ref or
           MapSet.member?(presentation_refs, Map.get(bindings, "presentation_ref")) or
           MapSet.member?(act_refs, Map.get(bindings, "show_act_ref")),
         do: [evidence.ref | refs],
         else: refs
    end)
  end

  defp evidence_ref_closure(index, seeds) do
    seeds
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> expand_evidence_refs(index, MapSet.new())
  end

  defp expand_evidence_refs([], _index, seen), do: seen

  defp expand_evidence_refs([ref | rest], index, seen) do
    if MapSet.member?(seen, ref) do
      expand_evidence_refs(rest, index, seen)
    else
      parents =
        case Map.fetch(index, ref) do
          {:ok, evidence} -> evidence.parent_refs
          :error -> []
        end

      expand_evidence_refs(parents ++ rest, index, MapSet.put(seen, ref))
    end
  end

  defp record_refs(records, fields) do
    Enum.flat_map(records, fn record ->
      Enum.flat_map(fields, fn key -> List.wrap(Map.get(record, key)) end)
    end)
  end

  defp pending_act_refs(projection, act_refs) do
    projection
    |> DispatchState.pending_refs()
    |> MapSet.intersection(act_refs)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp dispatch_cancellations(projection, act_refs) do
    projection
    |> DispatchState.cancellations()
    |> Enum.flat_map(fn {act_ref, cancellation} ->
      if MapSet.member?(act_refs, act_ref),
        do: [Map.put(cancellation, :act_ref, act_ref)],
        else: []
    end)
    |> Enum.sort_by(& &1.act_ref)
  end

  defp scope_cause?({:scope_promise_overdue, scope_ref}, scope_ref), do: true
  defp scope_cause?(_cause_key, _scope_ref), do: false

  defp ref_set(records), do: MapSet.new(records, & &1.ref)

  defp present_ref_set(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  defp select(index, predicate) do
    Enum.reduce(index, [], fn {_ref, record}, selected ->
      if predicate.(record), do: [record | selected], else: selected
    end)
  end

  defp stable_records(records), do: Enum.sort_by(records, & &1.ref)
end
