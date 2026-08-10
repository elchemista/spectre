defmodule Spectre.Governance.Review do
  @moduledoc """
  Host review commit for a composed Candidate.

  Review accepts only a Candidate Ref, re-reads it and both Definitions from
  the Store, verifies supplied replay/regression/semantic receipts, creates the
  evaluation-delta receipt, projects a mechanical human report, and publishes
  a new evaluated or rejected Candidate Ref.
  """

  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Store
  alias Spectre.Gate.Receipt
  alias Spectre.Gate.Receipt.Ref, as: ReceiptRef
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Projection.HumanReport

  @builtin_checkers %{
    structural: {"spectre.gate.structural", 1},
    authority: {"spectre.gate.authority", 1},
    closure: {"spectre.gate.closure", 1},
    prompt_budget: {"spectre.gate.prompt_budget", 1},
    applicability: {"spectre.gate.applicability", 1},
    evaluation_delta: {"spectre.gate.evaluation-delta", 1}
  }

  @doc "Records gate evidence and returns an immutable reviewed Candidate Ref and report."
  @spec evaluate(
          Store.config(),
          CandidateRef.t() | String.t(),
          EvaluationDelta.t(),
          [Receipt.t()],
          keyword()
        ) ::
          {:ok, CandidateRef.t(), HumanReport.t()} | {:error, term()}
  def evaluate(store, candidate_ref, delta, receipts, opts \\ [])

  def evaluate(store, candidate_ref, %EvaluationDelta{} = delta, receipts, opts)
      when is_list(receipts) and is_list(opts) do
    with {:ok, delta} <- validate_delta(delta),
         {:ok, candidate} <- fetch_candidate(store, candidate_ref, opts),
         %CandidateState{state: :composed} = governance <- candidate.governance,
         :ok <- verify_delta(governance, delta),
         {:ok, supplied} <- normalize_receipts(receipts, governance),
         {:ok, delta_receipt} <- delta_receipt(governance, delta, opts),
         all_new = supplied ++ [delta_receipt],
         {:ok, new_refs} <- publish_receipts(store, all_new, opts),
         refs = Enum.uniq(governance.gate_receipt_refs ++ new_refs),
         {:ok, stored_receipts} <- fetch_receipts(store, refs, opts),
         {:ok, state} <- gate_state(governance, stored_receipts, opts),
         {:ok, parent_artifact} <- fetch_definition(store, governance.parent_definition_ref, opts),
         {:ok, candidate_artifact} <-
           fetch_definition(store, governance.candidate_definition_ref, opts),
         {:ok, report} <-
           HumanReport.project(parent_artifact.definition, candidate_artifact.definition,
             evaluation_delta: delta,
             lineage_refs: governance.lineage_refs,
             gate_receipt_refs: refs
           ),
         :ok <- HumanReport.verify(report),
         {:ok, governance} <-
           CandidateState.transition(governance, state,
             gate_receipt_refs: refs,
             report_digest: report.digest,
             lineage_refs: append_ref(governance.lineage_refs, candidate_ref)
           ),
         {:ok, reviewed} <- advance_candidate(candidate, candidate_ref, governance, opts),
         {:ok, reviewed_ref} <- Store.publish_candidate(store, reviewed, store_opts(opts)) do
      {:ok, reviewed_ref, report}
    else
      :not_found -> {:error, :governance_candidate_not_found}
      %CandidateState{state: state} -> {:error, {:candidate_not_composed, state}}
      nil -> {:error, :candidate_is_not_governed}
      {:error, _reason} = error -> error
    end
  end

  def evaluate(_store, _candidate_ref, delta, _receipts, _opts),
    do: {:error, {:invalid_governance_review_delta, shape(delta)}}

  defp fetch_candidate(store, ref, opts) do
    case Store.fetch_candidate(store, ref, store_opts(opts)) do
      {:ok, candidate} -> {:ok, candidate}
      other -> other
    end
  end

  defp validate_delta(delta),
    do: delta |> EvaluationDelta.to_data() |> EvaluationDelta.from_data()

  defp fetch_definition(store, ref, opts) do
    case Store.fetch(store, ref, store_opts(opts)) do
      {:ok, artifact} -> {:ok, artifact}
      :not_found -> {:error, {:governance_definition_not_found, ref}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_delta(governance, delta) do
    actual_ids = delta.candidate_owned_results |> Enum.map(& &1["case_id"]) |> Enum.sort()

    if actual_ids == governance.candidate_case_ids,
      do: :ok,
      else:
        {:error,
         {:evaluation_delta_candidate_cases_mismatch, governance.candidate_case_ids, actual_ids}}
  end

  defp normalize_receipts(receipts, governance) do
    receipts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%Receipt{gate_class: gate} = receipt, _index}, {:ok, normalized}
      when gate in [:replay, :regression, :semantic_live] ->
        case Receipt.verify_binding(receipt, governance) do
          :ok -> {:cont, {:ok, [receipt | normalized]}}
          {:error, _reason} = error -> {:halt, error}
        end

      {%Receipt{gate_class: gate}, index}, _acc ->
        {:halt, {:error, {:review_cannot_supply_gate_class, index, gate}}}

      {value, index}, _acc ->
        {:halt, {:error, {:invalid_review_gate_receipt, index, shape(value)}}}
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp delta_receipt(governance, delta, opts) do
    issued_at = Keyword.get(opts, :reviewed_at, System.system_time(:millisecond))

    Receipt.new(%{
      gate_class: :evaluation_delta,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: "spectre.gate.evaluation-delta",
      checker_version: 1,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: nil,
      issued_at: issued_at,
      expires_at: nil,
      status: if(delta.passed, do: :passed, else: :failed),
      result_digest: EvaluationDelta.digest(delta),
      provenance: %{source: :evaluation_delta, candidate_case_weight: 0}
    })
  end

  defp publish_receipts(store, receipts, opts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, refs} ->
      case Store.publish_gate_receipt(store, receipt, store_opts(opts)) do
        {:ok, ref} -> {:cont, {:ok, [ReceiptRef.to_string(ref) | refs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _reason} = error -> error
    end)
  end

  defp fetch_receipts(store, refs, opts) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, receipts} ->
      case Store.fetch_gate_receipt(store, ref, store_opts(opts)) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        :not_found -> {:halt, {:error, {:gate_receipt_not_found, ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      {:error, _reason} = error -> error
    end)
  end

  defp gate_state(governance, receipts, opts) do
    grouped = Enum.group_by(receipts, & &1.gate_class)

    result =
      Enum.reduce_while(
        governance.required_gates,
        :ok,
        &review_gate(&1, &2, grouped, governance, opts)
      )

    case result do
      :ok -> {:ok, :evaluated}
      {:error, {:gate_receipt_failed, _gate}} -> {:ok, :rejected}
      {:error, _reason} = error -> error
    end
  end

  defp review_gate(gate, :ok, grouped, governance, opts) do
    case Map.get(grouped, gate, []) do
      [receipt] -> review_receipt(receipt, governance, opts)
      [] -> {:halt, {:error, {:required_gate_receipt_missing, gate}}}
      _several -> {:halt, {:error, {:ambiguous_gate_receipts, gate}}}
    end
  end

  defp review_receipt(receipt, governance, opts) do
    case Receipt.verify(receipt, governance, verification_opts(opts)) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp advance_candidate(candidate, parent_ref, governance, opts) do
    with {:ok, parent_ref} <- normalize_candidate_ref(parent_ref) do
      candidate
      |> Map.from_struct()
      |> Map.put(:parent_ref, parent_ref)
      |> Map.put(:governance, governance)
      |> Map.put(:created_at, Keyword.get(opts, :reviewed_at, System.system_time(:millisecond)))
      |> Candidate.new()
    end
  end

  defp normalize_candidate_ref(%CandidateRef{} = ref), do: {:ok, ref}
  defp normalize_candidate_ref(value), do: CandidateRef.parse(value)

  defp append_ref(refs, %CandidateRef{} = ref), do: append_ref(refs, CandidateRef.to_string(ref))
  defp append_ref(refs, ref), do: Enum.uniq(refs ++ [ref])

  defp verification_opts(opts) do
    custom = Keyword.get(opts, :checker_versions, %{})
    versions = if is_map(custom), do: Map.merge(custom, @builtin_checkers), else: custom

    opts
    |> Keyword.take([:now])
    |> Keyword.put(:checker_versions, versions)
  end

  defp store_opts(opts),
    do: Keyword.take(opts, [:checkpoint_store, :component_registry, :now])

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
