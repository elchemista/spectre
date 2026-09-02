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
  alias Spectre.Scope.Opening

  @enforce_keys [
    :domain_ref,
    :scope_ref,
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
    :pending_act_refs
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          scope_ref: String.t(),
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
          pending_act_refs: [String.t()]
        }

  @doc "Builds a capability-free view for an already opened Scope."
  @spec from_projection(Projection.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_projection(%Projection{} = projection, scope_ref)
      when is_binary(scope_ref) and scope_ref != "" do
    with {:ok, %Opening{} = opening} <- Map.fetch(projection.scopes, scope_ref) do
      decisions = records_for_scope(projection.decisions, scope_ref)
      acts = records_for_scope(projection.acts, scope_ref)
      act_refs = ref_set(acts)
      attempts = records_for_acts(projection.attempts, act_refs)
      attempt_refs = ref_set(attempts)
      outcomes = records_for_attempts(projection.outcomes, act_refs, attempt_refs)
      duties = records_for_duties(projection.duties, scope_ref, act_refs)
      presentation_refs = acts |> Enum.map(& &1.presentation_ref) |> present_ref_set()

      presentations =
        projection.presentations
        |> records_for_scope(scope_ref)
        |> Kernel.++(records_by_refs(projection.presentations, presentation_refs))
        |> Enum.uniq_by(&field(&1, :ref))
        |> stable_records()

      declassifications = records_for_source_acts(projection.declassifications, act_refs)
      erasures = records_for_scope(projection.erasures, scope_ref)

      evidence =
        records_for_evidence(
          projection.evidence,
          scope_ref,
          acts,
          outcomes,
          duties,
          presentations,
          declassifications,
          erasures
        )
        |> reject_unavailable_evidence(projection)

      {:ok,
       %__MODULE__{
         domain_ref: projection.domain_ref,
         scope_ref: scope_ref,
         revision: projection.revision,
         opening: opening,
         decisions: decisions,
         acts: acts,
         attempts: attempts,
         outcomes: outcomes,
         duties: duties,
         evidence: evidence,
         declassifications: declassifications,
         presentations: presentations,
         erasures: erasures,
         pending_act_refs: pending_act_refs(projection, act_refs)
       }}
    else
      :error -> {:error, {:scope_not_open, scope_ref}}
      _invalid -> {:error, {:invalid_scope_opening, scope_ref}}
    end
  end

  def from_projection(%Projection{}, scope_ref), do: {:error, {:invalid_scope_ref, scope_ref}}
  def from_projection(_projection, _scope_ref), do: {:error, :invalid_domain_projection}

  defp records_for_scope(index, scope_ref) do
    index
    |> values()
    |> Enum.filter(&(field(&1, :scope_ref) == scope_ref))
    |> stable_records()
  end

  defp records_for_acts(index, act_refs) do
    index
    |> values()
    |> Enum.filter(&MapSet.member?(act_refs, field(&1, :act_ref)))
    |> stable_records()
  end

  defp records_for_source_acts(index, act_refs) do
    index
    |> values()
    |> Enum.filter(&MapSet.member?(act_refs, field(&1, :source_act_ref)))
    |> stable_records()
  end

  defp records_for_attempts(index, act_refs, attempt_refs) do
    index
    |> values()
    |> Enum.filter(fn outcome ->
      MapSet.member?(act_refs, field(outcome, :act_ref)) and
        MapSet.member?(attempt_refs, field(outcome, :attempt_ref))
    end)
    |> stable_records()
  end

  defp records_for_duties(index, scope_ref, act_refs) do
    index
    |> values()
    |> Enum.filter(fn duty ->
      MapSet.member?(act_refs, field(duty, :act_ref)) or
        scope_cause?(field(duty, :cause_key), scope_ref)
    end)
    |> stable_records()
  end

  defp records_for_evidence(
         index,
         scope_ref,
         acts,
         outcomes,
         duties,
         presentations,
         declassifications,
         erasures
       ) do
    direct = evidence_bound_to_scope(index, scope_ref)

    seeds =
      direct
      |> record_refs([:ref])
      |> Kernel.++(record_refs(acts, [:evidence_refs, :target_refs]))
      |> Kernel.++(record_refs(outcomes, [:evidence_refs]))
      |> Kernel.++(record_refs(duties, [:evidence_refs]))
      |> Kernel.++(record_refs(declassifications, [:evidence_ref, :parent_refs]))
      |> Kernel.++(record_refs(erasures, [:target_ref, :affected_refs]))
      |> Kernel.++(evidence_refs_for_presentations(index, presentations, acts))

    index
    |> evidence_ref_closure(seeds)
    |> then(&records_by_refs(index, &1))
  end

  defp evidence_bound_to_scope(index, scope_ref) do
    index
    |> values()
    |> Enum.filter(fn evidence ->
      bindings = field(evidence, :bindings, %{})
      field(bindings, :scope_ref) == scope_ref
    end)
  end

  defp reject_unavailable_evidence(evidence, projection) do
    unavailable = ErasureAnalysis.unavailable_evidence_refs(projection)
    Enum.reject(evidence, &MapSet.member?(unavailable, field(&1, :ref)))
  end

  # Approval Evidence points to a Presentation through its closed binding. The
  # Presentation deliberately does not own or interpret arbitrary application
  # data, so this is its only structural Evidence relation.
  defp evidence_refs_for_presentations(index, presentations, acts) do
    presentation_refs = ref_set(presentations)
    act_refs = ref_set(acts)

    index
    |> values()
    |> Enum.filter(fn evidence ->
      bindings = field(evidence, :bindings, %{})

      MapSet.member?(presentation_refs, field(bindings, :presentation_ref)) or
        MapSet.member?(act_refs, field(bindings, :show_act_ref))
    end)
    |> record_refs([:ref])
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
          {:ok, evidence} -> List.wrap(field(evidence, :parent_refs, []))
          :error -> []
        end

      expand_evidence_refs(parents ++ rest, index, MapSet.put(seen, ref))
    end
  end

  defp record_refs(records, fields) do
    Enum.flat_map(records, fn record ->
      Enum.flat_map(fields, fn key -> List.wrap(field(record, key)) end)
    end)
  end

  defp records_by_refs(index, refs) do
    refs
    |> Enum.flat_map(fn ref ->
      case Map.fetch(index, ref) do
        {:ok, record} -> [record]
        :error -> []
      end
    end)
    |> stable_records()
  end

  defp pending_act_refs(projection, act_refs) do
    projection.dispatch_ready
    |> MapSet.intersection(act_refs)
    |> MapSet.difference(MapSet.new(Map.keys(projection.attempts_by_act)))
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp scope_cause?({:scope_promise_overdue, scope_ref}, scope_ref), do: true
  defp scope_cause?(_cause_key, _scope_ref), do: false

  defp ref_set(records), do: records |> Enum.map(&field(&1, :ref)) |> present_ref_set()

  defp present_ref_set(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  defp values(index) when is_map(index), do: Map.values(index)
  defp values(_index), do: []

  defp stable_records(records), do: Enum.sort_by(records, &field(&1, :ref, ""))

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp field(_value, _key, default), do: default
end
