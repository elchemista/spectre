defmodule Spectre.Governance.Approval do
  @moduledoc """
  Separate host approval commit for a reviewed Candidate.

  Approval always re-reads an evaluated Candidate from the Store, applies the
  risk policy, publishes an approval receipt, and emits a new approved
  Candidate Ref. It never performs activation.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Store
  alias Spectre.Gate.Receipt
  alias Spectre.Gate.Receipt.Ref, as: ReceiptRef
  alias Spectre.Governance.Approval.Policy
  alias Spectre.Governance.CandidateState

  @doc "Approves a reviewed Candidate and returns a distinct approved Ref."
  @spec approve(Store.config(), CandidateRef.t() | String.t(), keyword()) ::
          {:ok, CandidateRef.t()} | {:error, term()}
  def approve(store, candidate_ref, opts \\ [])

  def approve(store, candidate_ref, opts) when is_list(opts) do
    with {:ok, approved_at} <- transition_time(opts, :approved_at, :rejected_at, :approval),
         {:ok, candidate} <- fetch_candidate(store, candidate_ref, opts),
         %CandidateState{state: :evaluated} = governance <- candidate.governance,
         {:ok, policy} <- policy(Keyword.get(opts, :policy)),
         {:ok, required_mode} <- Policy.required_mode(policy, governance.risk),
         {:ok, mode} <- mode(Keyword.get(opts, :mode, required_mode)),
         true <- Policy.allows?(policy, governance.risk, mode),
         {:ok, actor_ref} <- actor(Keyword.get(opts, :actor_ref), mode),
         {:ok, receipt} <- approval_receipt(governance, mode, actor_ref, approved_at, opts),
         {:ok, receipt_ref} <- Store.publish_gate_receipt(store, receipt, store_opts(opts)),
         receipt_ref_string = ReceiptRef.to_string(receipt_ref),
         {:ok, governance} <-
           CandidateState.transition(governance, :approved,
             gate_receipt_refs: Enum.uniq(governance.gate_receipt_refs ++ [receipt_ref_string]),
             approval_receipt_ref: receipt_ref_string,
             lineage_refs: append_ref(governance.lineage_refs, candidate_ref)
           ),
         {:ok, approved} <- advance_candidate(candidate, candidate_ref, governance, approved_at),
         {:ok, approved_ref} <- Store.publish_candidate(store, approved, store_opts(opts)) do
      {:ok, approved_ref}
    else
      :not_found -> {:error, :governance_candidate_not_found}
      %CandidateState{state: state} -> {:error, {:candidate_not_evaluated, state}}
      nil -> {:error, :candidate_is_not_governed}
      false -> {:error, :candidate_risk_requires_human_approval}
      {:error, _reason} = error -> error
    end
  end

  def approve(_store, _candidate_ref, opts),
    do: {:error, {:invalid_governance_approval_options, opts}}

  @doc "Records an explicit host rejection of an evaluated Candidate."
  @spec reject(Store.config(), CandidateRef.t() | String.t(), keyword()) ::
          {:ok, CandidateRef.t()} | {:error, term()}
  def reject(store, candidate_ref, opts \\ [])

  def reject(store, candidate_ref, opts) when is_list(opts) do
    with {:ok, rejected_at} <- transition_time(opts, :rejected_at, :approved_at, :rejection),
         {:ok, candidate} <- fetch_candidate(store, candidate_ref, opts),
         %CandidateState{state: :evaluated} = governance <- candidate.governance,
         {:ok, actor_ref} <- rejection_actor(Keyword.get(opts, :actor_ref)),
         {:ok, reason} <- rejection_reason(Keyword.get(opts, :reason)),
         {:ok, receipt} <- rejection_receipt(governance, actor_ref, reason, rejected_at),
         {:ok, receipt_ref} <- Store.publish_gate_receipt(store, receipt, store_opts(opts)),
         receipt_ref_string = ReceiptRef.to_string(receipt_ref),
         {:ok, governance} <-
           CandidateState.transition(governance, :rejected,
             gate_receipt_refs: Enum.uniq(governance.gate_receipt_refs ++ [receipt_ref_string]),
             approval_receipt_ref: receipt_ref_string,
             lineage_refs: append_ref(governance.lineage_refs, candidate_ref)
           ),
         {:ok, rejected} <- advance_candidate(candidate, candidate_ref, governance, rejected_at),
         {:ok, rejected_ref} <- Store.publish_candidate(store, rejected, store_opts(opts)) do
      {:ok, rejected_ref}
    else
      :not_found -> {:error, :governance_candidate_not_found}
      %CandidateState{state: state} -> {:error, {:candidate_not_evaluated, state}}
      nil -> {:error, :candidate_is_not_governed}
      {:error, _reason} = error -> error
    end
  end

  def reject(_store, _candidate_ref, opts),
    do: {:error, {:invalid_governance_rejection_options, opts}}

  defp fetch_candidate(store, ref, opts), do: Store.fetch_candidate(store, ref, store_opts(opts))

  defp policy(nil), do: {:ok, Policy.default()}
  defp policy(%Policy{} = policy), do: Policy.new(policy)
  defp policy(value), do: Policy.new(value)

  defp mode(value) when value in [:automatic, :human], do: {:ok, value}
  defp mode("automatic"), do: {:ok, :automatic}
  defp mode("human"), do: {:ok, :human}
  defp mode(value), do: {:error, {:invalid_governance_approval_mode, value}}

  defp actor(nil, :automatic), do: {:ok, "spectre:auto-approval"}
  defp actor(value, _mode) when is_binary(value) and value != "", do: {:ok, value}
  defp actor(value, mode), do: {:error, {:invalid_governance_approval_actor, mode, value}}

  defp approval_receipt(governance, mode, actor_ref, issued_at, opts) do
    result = %{risk: governance.risk, mode: mode, actor_ref: actor_ref}

    Receipt.new(%{
      gate_class: :approval,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: "spectre.approval.#{mode}",
      checker_version: 1,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: nil,
      issued_at: issued_at,
      expires_at: Keyword.get(opts, :expires_at),
      status: :passed,
      result_digest: Value.digest!(result),
      provenance: %{
        source: :host_approval,
        mode: mode,
        actor_ref: actor_ref,
        risk: governance.risk
      }
    })
  end

  defp rejection_actor(value) when is_binary(value) and value != "", do: {:ok, value}
  defp rejection_actor(value), do: {:error, {:invalid_governance_rejection_actor, value}}

  defp rejection_reason(value) when is_binary(value) and value != "", do: {:ok, value}
  defp rejection_reason(value), do: {:error, {:invalid_governance_rejection_reason, value}}

  defp rejection_receipt(governance, actor_ref, reason, issued_at) do
    result = %{risk: governance.risk, actor_ref: actor_ref, reason: reason}

    Receipt.new(%{
      gate_class: :approval,
      candidate_digest: governance.proposal_digest,
      parent_definition_ref: governance.parent_definition_ref,
      candidate_definition_ref: governance.candidate_definition_ref,
      closure_digest: governance.closure_digest,
      checker_id: "spectre.approval.rejected",
      checker_version: 1,
      evaluation_cases_digest: governance.evaluation_cases_digest,
      profile_ref: nil,
      issued_at: issued_at,
      expires_at: nil,
      status: :failed,
      result_digest: Value.digest!(result),
      provenance: %{
        source: :host_rejection,
        actor_ref: actor_ref,
        risk: governance.risk,
        reason: reason
      }
    })
  end

  defp advance_candidate(candidate, parent_ref, governance, created_at) do
    with {:ok, parent_ref} <- normalize_candidate_ref(parent_ref) do
      candidate
      |> Map.from_struct()
      |> Map.put(:parent_ref, parent_ref)
      |> Map.put(:governance, governance)
      |> Map.put(:created_at, created_at)
      |> Candidate.new()
    end
  end

  defp transition_time(opts, field, forbidden, kind) do
    if Keyword.has_key?(opts, forbidden) do
      {:error, {:ambiguous_governance_transition_timestamp, kind}}
    else
      {:ok, Keyword.get(opts, field, System.system_time(:millisecond))}
    end
  end

  defp normalize_candidate_ref(%CandidateRef{} = ref), do: {:ok, ref}
  defp normalize_candidate_ref(value), do: CandidateRef.parse(value)

  defp append_ref(refs, %CandidateRef{} = ref), do: append_ref(refs, CandidateRef.to_string(ref))
  defp append_ref(refs, ref), do: Enum.uniq(refs ++ [ref])

  defp store_opts(opts),
    do: Keyword.take(opts, [:checkpoint_store, :component_registry, :now])
end
