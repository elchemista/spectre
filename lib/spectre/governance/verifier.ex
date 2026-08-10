defmodule Spectre.Governance.Verifier do
  @moduledoc false

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Gate.Receipt
  alias Spectre.Gate.Receipt.Ref, as: GateReceiptRef
  alias Spectre.Governance.Approval.Policy
  alias Spectre.Governance.Authority
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.Constraints
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Instance.Activation
  alias Spectre.Projection.HumanReport

  @builtin_checkers %{
    structural: {"spectre.gate.structural", 1},
    authority: {"spectre.gate.authority", 1},
    closure: {"spectre.gate.closure", 1},
    prompt_budget: {"spectre.gate.prompt_budget", 1},
    applicability: {"spectre.gate.applicability", 1},
    evaluation_delta: {"spectre.gate.evaluation-delta", 1}
  }

  @spec verify_activation(
          Store.config(),
          %{candidate: Candidate.t(), resolution: map()},
          Activation.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def verify_activation(
        _store,
        %{candidate: %Candidate{source: source, governance: nil}},
        _current,
        _opts
      )
      when source in [:compiled, :trusted_host],
      do: :ok

  def verify_activation(_store, %{candidate: %Candidate{governance: nil}}, _current, _opts),
    do: {:error, :governed_candidate_requires_governance_state}

  def verify_activation(store, candidate_resolution, current, opts) when is_list(opts) do
    with %Activation{} = current <- current,
         :ok <- verify_current_base(candidate_resolution.candidate.governance, current),
         :ok <- verify_common(store, candidate_resolution, opts, :activation) do
      :ok
    else
      nil -> {:error, :governed_activation_requires_current_activation}
      {:error, _reason} = error -> error
    end
  end

  @spec verify_recovery(Store.config(), %{candidate: Candidate.t(), resolution: map()}, keyword()) ::
          :ok | {:error, term()}
  def verify_recovery(
        _store,
        %{candidate: %Candidate{source: source, governance: nil}},
        _opts
      )
      when source in [:compiled, :trusted_host],
      do: :ok

  def verify_recovery(_store, %{candidate: %Candidate{governance: nil}}, _opts),
    do: {:error, :governed_candidate_requires_governance_state}

  def verify_recovery(store, candidate_resolution, opts) when is_list(opts),
    do: verify_common(store, candidate_resolution, opts, :recovery)

  @spec verify_rollback(
          Store.config(),
          %{candidate: Candidate.t(), resolution: map()},
          Activation.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def verify_rollback(store, candidate_resolution, %Activation{} = current, opts)
      when is_list(opts) do
    target = candidate_resolution.resolution.definition_ref

    target_candidate =
      candidate_resolution.candidate |> Candidate.ref() |> CandidateRef.to_string()

    current_candidate = CandidateRef.to_string(current.candidate_ref)

    with false <- target == current.definition_ref,
         :ok <- candidate_ancestor(store, target_candidate, current_candidate, opts),
         :ok <- definition_ancestor(store, target, current.definition_ref, opts),
         :ok <- verify_common_or_bootstrap(store, candidate_resolution, opts, :rollback),
         {:ok, current_artifact} <-
           fetch_parent(store, Ref.to_string(current.definition_ref), opts),
         :ok <-
           rollback_authority(
             current_artifact.manifest,
             candidate_resolution.resolution.manifest,
             opts
           ) do
      :ok
    else
      true -> {:error, :rollback_target_already_active}
      {:error, _reason} = error -> error
    end
  end

  def verify_rollback(_store, _candidate_resolution, nil, _opts),
    do: {:error, :rollback_requires_current_activation}

  defp verify_common_or_bootstrap(
         _store,
         %{candidate: %Candidate{source: source, governance: nil}},
         _opts,
         _mode
       )
       when source in [:compiled, :trusted_host],
       do: :ok

  defp verify_common_or_bootstrap(
         _store,
         %{candidate: %Candidate{governance: nil}},
         _opts,
         _mode
       ),
       do: {:error, :governed_candidate_requires_governance_state}

  defp verify_common_or_bootstrap(store, candidate_resolution, opts, mode),
    do: verify_common(store, candidate_resolution, opts, mode)

  defp verify_current_base(governance, current) do
    cond do
      governance.base_activation_receipt != current.activation_receipt ->
        {:error, :stale_governance_activation_receipt}

      governance.base_candidate_ref != CandidateRef.to_string(current.candidate_ref) ->
        {:error, :stale_governance_candidate_ref}

      governance.parent_definition_ref != Ref.to_string(current.definition_ref) ->
        {:error, :stale_governance_definition_ref}

      governance.observed_authority_epoch != current.authority_epoch ->
        {:error, :stale_governance_authority_epoch}

      governance.observed_evidence_digest != ChangeSet.evidence_digest(current) ->
        {:error, :stale_governance_evidence_digest}

      true ->
        :ok
    end
  end

  defp verify_common(
         store,
         %{candidate: %Candidate{} = candidate, resolution: resolution},
         opts,
         mode
       ) do
    governance = candidate.governance

    with :ok <- candidate_state(candidate, governance),
         :ok <- verify_promotion_lineage(store, candidate, opts),
         :ok <- verify_resolution(candidate, governance, resolution),
         :ok <- verify_constitutional_constraints(governance, resolution),
         {:ok, parent} <- fetch_parent(store, governance.parent_definition_ref, opts),
         :ok <- verify_parent_manifest(parent.manifest, resolution.manifest, governance),
         :ok <- Authority.no_expansion(parent.manifest.authority, resolution.manifest.authority),
         :ok <-
           verify_migrations(
             governance.state_migrations,
             Keyword.get(opts, :registered_migrations, [])
           ),
         {:ok, receipts} <- fetch_receipts(store, governance.gate_receipt_refs, opts),
         :ok <- verify_report_evidence(governance, receipts),
         :ok <- verify_gate_set(governance, receipts, opts, mode) do
      verify_approval(governance, receipts, opts)
    end
  end

  defp candidate_state(%Candidate{source: :governed_host}, %CandidateState{
         state: :approved,
         report_digest: digest
       })
       when is_binary(digest),
       do: :ok

  defp candidate_state(%Candidate{source: source}, %CandidateState{state: state}),
    do: {:error, {:governed_candidate_not_activatable, source, state}}

  defp candidate_state(%Candidate{}, nil), do: {:error, :candidate_is_not_governed}

  defp verify_promotion_lineage(store, %Candidate{} = approved, opts) do
    with {:ok, evaluated} <- fetch_candidate_parent(store, approved, :approved, opts),
         {:ok, composed} <- fetch_candidate_parent(store, evaluated, :evaluated, opts),
         {:ok, base} <- fetch_candidate_parent(store, composed, :composed, opts),
         :ok <- promotion_states(approved, evaluated, composed),
         :ok <- same_proposal(approved, evaluated, composed),
         :ok <- promotion_ancestry(approved, evaluated, composed, base) do
      promotion_receipts(approved, evaluated, composed)
    end
  end

  defp fetch_candidate_parent(_store, %Candidate{parent_ref: nil}, stage, _opts),
    do: {:error, {:governance_candidate_parent_missing, stage}}

  defp fetch_candidate_parent(store, %Candidate{parent_ref: parent_ref}, stage, opts) do
    case Store.fetch_candidate(store, parent_ref, store_opts(opts)) do
      {:ok, candidate} -> {:ok, candidate}
      :not_found -> {:error, {:governance_candidate_parent_not_found, stage, parent_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp promotion_states(approved, evaluated, composed) do
    observed =
      Enum.map([approved, evaluated, composed], fn
        %Candidate{source: :governed_host, governance: %CandidateState{state: state}} ->
          state

        %Candidate{source: source, governance: governance} ->
          {source, governance && governance.state}
      end)

    if observed == [:approved, :evaluated, :composed],
      do: :ok,
      else: {:error, {:invalid_governance_promotion_states, observed}}
  end

  defp same_proposal(approved, evaluated, composed) do
    proposals = Enum.map([approved, evaluated, composed], & &1.governance.proposal_digest)
    definitions = Enum.map([approved, evaluated, composed], &Ref.to_string(&1.definition_ref))

    cond do
      length(Enum.uniq(proposals)) != 1 ->
        {:error, :governance_promotion_proposal_mismatch}

      length(Enum.uniq(definitions)) != 1 ->
        {:error, :governance_promotion_definition_mismatch}

      true ->
        :ok
    end
  end

  defp promotion_ancestry(approved, evaluated, composed, base) do
    base_ref = base |> Candidate.ref() |> CandidateRef.to_string()
    composed_ref = composed |> Candidate.ref() |> CandidateRef.to_string()
    evaluated_ref = evaluated |> Candidate.ref() |> CandidateRef.to_string()
    governance = approved.governance

    expected_lineage = [
      {composed.governance.lineage_refs, [base_ref]},
      {evaluated.governance.lineage_refs, Enum.sort([base_ref, composed_ref])},
      {
        approved.governance.lineage_refs,
        Enum.sort([base_ref, composed_ref, evaluated_ref])
      }
    ]

    cond do
      base_ref != governance.base_candidate_ref ->
        {:error, :governance_promotion_base_candidate_mismatch}

      Ref.to_string(base.definition_ref) != governance.parent_definition_ref ->
        {:error, :governance_promotion_parent_definition_mismatch}

      Enum.any?(expected_lineage, fn {observed, expected} -> observed != expected end) ->
        {:error, :governance_promotion_lineage_mismatch}

      true ->
        :ok
    end
  end

  defp promotion_receipts(approved, evaluated, composed) do
    composed_refs = MapSet.new(composed.governance.gate_receipt_refs)
    evaluated_refs = MapSet.new(evaluated.governance.gate_receipt_refs)
    approved_refs = MapSet.new(approved.governance.gate_receipt_refs)

    with :ok <- monotonic_receipts(composed_refs, evaluated_refs, approved_refs),
         :ok <- promotion_reports(approved, evaluated, composed) do
      promotion_approvals(approved, evaluated, composed)
    end
  end

  defp monotonic_receipts(composed, evaluated, approved) do
    if MapSet.subset?(composed, evaluated) and MapSet.subset?(evaluated, approved),
      do: :ok,
      else: {:error, :governance_promotion_receipts_not_monotonic}
  end

  defp promotion_reports(approved, evaluated, composed) do
    valid? =
      is_nil(composed.governance.report_digest) and
        is_binary(evaluated.governance.report_digest) and
        approved.governance.report_digest == evaluated.governance.report_digest

    if valid?, do: :ok, else: {:error, :governance_promotion_report_mismatch}
  end

  defp promotion_approvals(approved, evaluated, composed) do
    valid? =
      is_nil(composed.governance.approval_receipt_ref) and
        is_nil(evaluated.governance.approval_receipt_ref) and
        is_binary(approved.governance.approval_receipt_ref)

    if valid?, do: :ok, else: {:error, :governance_promotion_approval_mismatch}
  end

  defp verify_resolution(candidate, governance, resolution) do
    definition_ref = Ref.to_string(resolution.definition_ref)
    closure_digest = Closure.digest(resolution.manifest.execution_closure)

    evaluation_cases_digest =
      Value.digest!(%{
        "protected_corpus_digest" =>
          resolution.manifest.execution_closure.evaluation_corpus_digest,
        "candidate_cases" => governance.candidate_cases
      })

    change_set_ref = "changeset:sha256:" <> governance.change_set_digest

    cond do
      governance.candidate_definition_ref != definition_ref ->
        {:error, :governed_candidate_definition_mismatch}

      governance.closure_digest != closure_digest ->
        {:error, :governed_candidate_closure_mismatch}

      governance.evaluation_cases_digest != evaluation_cases_digest ->
        {:error, :governed_candidate_evaluation_cases_mismatch}

      governance.protected_cases_digest !=
          resolution.manifest.execution_closure.evaluation_corpus_digest ->
        {:error, :governed_candidate_protected_corpus_mismatch}

      change_set_ref not in candidate.provenance_refs or
          change_set_ref not in resolution.manifest.provenance_refs ->
        {:error, :governed_candidate_change_set_provenance_mismatch}

      true ->
        :ok
    end
  end

  defp verify_constitutional_constraints(governance, resolution) do
    with {:ok, constraints} <-
           Constraints.restore(
             governance.prompt_token_ceiling,
             governance.applicability_ceilings
           ) do
      Constraints.verify_definition(
        resolution.definition,
        resolution.manifest.authority,
        constraints
      )
    end
  end

  defp fetch_parent(store, ref, opts) do
    case Store.fetch(store, ref, store_opts(opts)) do
      {:ok, artifact} -> {:ok, artifact}
      :not_found -> {:error, {:governance_parent_definition_not_found, ref}}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_ancestor(store, target, current, opts) do
    walk_candidate_ancestors(store, target, current, MapSet.new(), opts, 0)
  end

  defp walk_candidate_ancestors(_store, target, target, _seen, _opts, _depth), do: :ok

  defp walk_candidate_ancestors(_store, _target, nil, _seen, _opts, _depth),
    do: {:error, :rollback_target_is_not_ancestor}

  defp walk_candidate_ancestors(_store, _target, _current, _seen, _opts, depth)
       when depth > 256,
       do: {:error, :rollback_candidate_lineage_depth_exceeded}

  defp walk_candidate_ancestors(store, target, current, seen, opts, depth) do
    if MapSet.member?(seen, current) do
      {:error, :rollback_candidate_lineage_cycle}
    else
      case Store.fetch_candidate(store, current, store_opts(opts)) do
        {:ok, candidate} ->
          parent = candidate.parent_ref && CandidateRef.to_string(candidate.parent_ref)

          walk_candidate_ancestors(
            store,
            target,
            parent,
            MapSet.put(seen, current),
            opts,
            depth + 1
          )

        :not_found ->
          {:error, {:rollback_lineage_candidate_not_found, current}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp definition_ancestor(store, target, current, opts) do
    walk_ancestors(store, Ref.to_string(target), [Ref.to_string(current)], MapSet.new(), opts, 0)
  end

  defp walk_ancestors(_store, _target, [], _seen, _opts, _depth),
    do: {:error, :rollback_target_is_not_ancestor}

  defp walk_ancestors(_store, _target, _pending, _seen, _opts, depth) when depth > 256,
    do: {:error, :rollback_lineage_depth_exceeded}

  defp walk_ancestors(_store, target, [target | _rest], _seen, _opts, _depth), do: :ok

  defp walk_ancestors(store, target, [ref | rest], seen, opts, depth) do
    if MapSet.member?(seen, ref) do
      walk_ancestors(store, target, rest, seen, opts, depth + 1)
    else
      case Store.fetch(store, ref, store_opts(opts)) do
        {:ok, artifact} ->
          parents = Enum.map(artifact.manifest.parent_refs, &Ref.to_string/1)
          walk_ancestors(store, target, rest ++ parents, MapSet.put(seen, ref), opts, depth + 1)

        :not_found ->
          {:error, {:rollback_lineage_definition_not_found, ref}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp rollback_authority(current, target, opts) do
    case Authority.no_expansion(current.authority, target.authority) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        if Keyword.get(opts, :allow_authority_restore?, false), do: :ok, else: error
    end
  end

  defp verify_parent_manifest(parent, candidate, governance) do
    parent_refs = Enum.map(candidate.parent_refs, &Ref.to_string/1)

    cond do
      Ref.to_string(parent.definition_ref) != governance.parent_definition_ref ->
        {:error, :governance_parent_definition_mismatch}

      governance.parent_definition_ref not in parent_refs ->
        {:error, :governance_manifest_parent_missing}

      true ->
        :ok
    end
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

  defp verify_gate_set(governance, receipts, opts, mode) do
    grouped = Enum.group_by(receipts, & &1.gate_class)

    with :ok <- unique_gate_classes(grouped),
         :ok <- reject_failed_receipts(receipts),
         :ok <- verify_attached_gate_receipts(receipts, governance, opts, mode) do
      Enum.reduce_while(
        governance.required_gates,
        :ok,
        &verify_gate(&1, &2, grouped, governance, opts, mode)
      )
    end
  end

  defp verify_report_evidence(%CandidateState{report: %HumanReport{} = report}, receipts) do
    with {:ok, delta} <- EvaluationDelta.from_data(report.evaluation_delta),
         [receipt] <- Enum.filter(receipts, &(&1.gate_class == :evaluation_delta)),
         true <- receipt.result_digest == EvaluationDelta.digest(delta) do
      :ok
    else
      [] -> {:error, {:required_gate_receipt_missing, :evaluation_delta}}
      [_first, _second | _rest] -> {:error, {:ambiguous_gate_receipts, :evaluation_delta}}
      false -> {:error, :governance_report_evaluation_delta_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp verify_report_evidence(%CandidateState{}, _receipts),
    do: {:error, :governance_candidate_report_missing}

  defp unique_gate_classes(grouped) do
    case Enum.find(grouped, fn {_gate, receipts} -> length(receipts) != 1 end) do
      nil -> :ok
      {gate, _receipts} -> {:error, {:ambiguous_gate_receipts, gate}}
    end
  end

  defp reject_failed_receipts(receipts) do
    case Enum.find(receipts, &(&1.status == :failed)) do
      nil -> :ok
      receipt -> {:error, {:gate_receipt_failed, receipt.gate_class}}
    end
  end

  defp verify_attached_gate_receipts(receipts, governance, opts, mode) do
    receipts
    |> Enum.reject(&(&1.gate_class == :approval))
    |> Enum.reduce_while(:ok, fn receipt, :ok ->
      case verify_gate_receipt_evidence(receipt, governance, opts, mode) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_gate(gate, :ok, grouped, governance, opts, mode) do
    case Map.get(grouped, gate, []) do
      [receipt] -> verify_gate_receipt(receipt, governance, opts, mode)
      [] -> {:halt, {:error, {:required_gate_receipt_missing, gate}}}
      _several -> {:halt, {:error, {:ambiguous_gate_receipts, gate}}}
    end
  end

  defp verify_gate_receipt(receipt, governance, opts, mode) do
    case verify_gate_receipt_evidence(receipt, governance, opts, mode) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp verify_gate_receipt_evidence(receipt, governance, opts, mode) do
    verification = verification_opts(opts)

    case Receipt.verify(receipt, governance, verification) do
      {:error, {:gate_receipt_expired, :semantic_live}} = error ->
        if expired_semantic_live_allowed?(mode, opts) do
          Receipt.verify(
            receipt,
            governance,
            Keyword.put(verification, :now, receipt.expires_at - 1)
          )
        else
          error
        end

      result ->
        result
    end
  end

  defp expired_semantic_live_allowed?(:recovery, opts),
    do: Keyword.get(opts, :allow_expired_semantic_live_recovery?, false) == true

  defp expired_semantic_live_allowed?(:rollback, opts),
    do: Keyword.get(opts, :allow_expired_semantic_live_rollback?, false) == true

  defp expired_semantic_live_allowed?(_mode, _opts), do: false

  defp verify_approval(governance, receipts, opts) do
    with [approval] <- Enum.filter(receipts, &(&1.gate_class == :approval)),
         true <-
           approval |> Receipt.ref() |> GateReceiptRef.to_string() ==
             governance.approval_receipt_ref,
         {:ok, mode} <- approval_mode(approval),
         :ok <- verify_approval_receipt(approval, governance, mode, opts),
         {:ok, policy} <- approval_policy(Keyword.get(opts, :approval_policy)),
         true <- Policy.allows?(policy, governance.risk, mode) do
      :ok
    else
      [] -> {:error, :approval_receipt_missing}
      [_first, _second | _rest] -> {:error, :ambiguous_approval_receipts}
      false -> {:error, :approval_policy_not_satisfied}
      {:error, _reason} = error -> error
    end
  end

  defp approval_mode(receipt) do
    case Map.get(receipt.provenance, :mode, Map.get(receipt.provenance, "mode")) do
      mode when mode in [:automatic, :human] -> {:ok, mode}
      "automatic" -> {:ok, :automatic}
      "human" -> {:ok, :human}
      value -> {:error, {:invalid_approval_receipt_mode, value}}
    end
  end

  defp verify_approval_receipt(receipt, governance, mode, opts) do
    expected_checker = {"spectre.approval.#{mode}", 1}
    expected_risk = Atom.to_string(governance.risk)

    with :ok <-
           Receipt.verify(
             receipt,
             governance,
             verification_opts(opts, %{approval: expected_checker})
           ),
         "host_approval" <- Map.get(receipt.provenance, "source"),
         actor when is_binary(actor) and actor != "" <-
           Map.get(receipt.provenance, "actor_ref"),
         ^expected_risk <- Map.get(receipt.provenance, "risk"),
         expected <- Value.digest!(%{risk: governance.risk, mode: mode, actor_ref: actor}),
         true <- receipt.result_digest == expected do
      :ok
    else
      false -> {:error, :approval_receipt_result_mismatch}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_approval_receipt_provenance}
    end
  end

  defp approval_policy(nil), do: {:ok, Policy.default()}
  defp approval_policy(%Policy{} = policy), do: Policy.new(policy)
  defp approval_policy(value), do: Policy.new(value)

  defp verify_migrations([], _registered), do: :ok

  defp verify_migrations(migrations, registered) when is_list(registered) do
    case Enum.find(migrations, fn migration ->
           ref = Map.get(migration, "migration_ref", Map.get(migration, :migration_ref))
           not Enum.any?(registered, &same_name?(&1, ref))
         end) do
      nil -> :ok
      migration -> {:error, {:candidate_state_migration_not_registered, migration}}
    end
  end

  defp verify_migrations(_migrations, value),
    do: {:error, {:invalid_registered_state_migrations, value}}

  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right), do: left == right

  defp verification_opts(opts, extra \\ %{}) do
    custom = Keyword.get(opts, :checker_versions, %{})

    versions =
      if is_map(custom) do
        custom
        |> Map.merge(@builtin_checkers)
        |> Map.merge(extra)
      else
        custom
      end

    opts
    |> Keyword.take([:now])
    |> Keyword.put(:checker_versions, versions)
  end

  defp store_opts(opts),
    do: Keyword.take(opts, [:checkpoint_store, :component_registry, :now])
end
