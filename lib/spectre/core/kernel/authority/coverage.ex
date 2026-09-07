defmodule Spectre.Kernel.Authority.Coverage do
  @moduledoc """
  Checks whether a Candidate stays within one Mandate's declared envelope.

  These checks compare immutable values: principal, executor, Scope, subjects,
  targets, class, Row, disclosure, purpose and accountability. Time, revocation,
  restriction and Meter debt belong to `Authority.Status` and are deliberately
  absent here.
  """

  alias Spectre.{Candidate, Declassification, Disclosure, Mandate, Portable, Row}
  alias Spectre.Kernel.Authority.{Facts, Status}

  @doc false
  @spec matching_principal(Candidate.t(), map(), Mandate.t()) :: :ok | {:error, term()}
  def matching_principal(%Candidate{} = candidate, context, %Mandate{} = mandate)
      when is_map(context) do
    authenticated = context.authenticated_principal_ref
    claimed = candidate.proposer_ref

    cond do
      not present?(claimed) -> {:error, :candidate_proposer_missing}
      claimed != authenticated -> {:error, :proposer_claim_mismatch}
      mandate.holder_ref == authenticated -> :ok
      true -> {:error, :principal_not_mandate_holder}
    end
  end

  @doc false
  @spec requested_mandate(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def requested_mandate(%Candidate{} = candidate, %Mandate{} = mandate) do
    if is_nil(candidate.requested_mandate_ref) or candidate.requested_mandate_ref == mandate.ref,
      do: :ok,
      else: {:error, :different_mandate_requested}
  end

  @doc false
  @spec covered_executor(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def covered_executor(%Candidate{} = candidate, %Mandate{} = mandate) do
    cond do
      not present?(candidate.executor_ref) ->
        {:error, :candidate_executor_missing}

      candidate.executor_ref not in mandate.executor_refs ->
        {:error, :executor_outside_mandate}

      not present?(candidate.executor_contract_ref) ->
        {:error, :candidate_executor_contract_missing}

      candidate.executor_contract_ref not in mandate.executor_contract_refs ->
        {:error, :executor_contract_outside_mandate}

      true ->
        :ok
    end
  end

  @doc false
  @spec matching_scope(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def matching_scope(%Candidate{} = candidate, %Mandate{} = mandate) do
    if candidate.scope_ref in mandate.scope_refs,
      do: :ok,
      else: {:error, :scope_outside_mandate}
  end

  @doc false
  @spec covered_values(:subjects | :targets, Candidate.t(), Mandate.t()) ::
          :ok | {:error, term()}
  def covered_values(:targets, %Candidate{class: "mandate.delegate"} = candidate, mandate) do
    # The authority being subdivided is not an external effect destination.
    # A content-addressed Mandate cannot include its own reference in its body.
    # Only this exact parent is implicit; all other targets stay explicitly bounded.
    covered_refs(candidate.target_refs, [mandate.ref | mandate.target_refs], :targets)
  end

  def covered_values(kind, %Candidate{} = candidate, %Mandate{} = mandate)
      when kind in [:subjects, :targets] do
    {requested, allowed} =
      case kind do
        :subjects -> {candidate.subject_refs, mandate.subject_refs}
        :targets -> {candidate.target_refs, mandate.target_refs}
      end

    covered_refs(requested, allowed, kind)
  end

  defp covered_refs(requested, allowed, kind) do
    allowed = MapSet.new(allowed)

    if Enum.all?(requested, &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, {kind, :outside_mandate}}
  end

  @doc false
  @spec covered_class(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def covered_class(%Candidate{} = candidate, %Mandate{} = mandate) do
    if candidate.class in mandate.classes, do: :ok, else: {:error, :class_outside_mandate}
  end

  @doc false
  @spec declassification_owners(Candidate.t(), Mandate.t(), Facts.t()) ::
          :ok | {:error, term()}
  def declassification_owners(%Candidate{} = candidate, %Mandate{} = mandate, %Facts{} = facts) do
    case {candidate.class, candidate.consequence} do
      {"data.declassify", %{"evidence_declassification" => draft} = consequence}
      when map_size(consequence) == 1 ->
        with {:ok, decoded} <- Declassification.decode_draft(draft),
             :ok <- Declassification.validate_producer(decoded.evidence, candidate.proposer_ref) do
          owners_authorize_mandate?(mandate, decoded.removed_owner_refs, facts)
        end

      {"data.declassify", _invalid} ->
        {:error, :invalid_declassification_consequence}

      {_other_class, _consequence} ->
        :ok
    end
  end

  @doc false
  @spec covered_row(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def covered_row(%Candidate{} = candidate, %Mandate{} = mandate) do
    if Row.subset?(candidate.row, mandate.ceiling),
      do: :ok,
      else: {:error, :row_exceeds_mandate_ceiling}
  end

  @doc false
  @spec covered_disclosure(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def covered_disclosure(%Candidate{} = candidate, %Mandate{} = mandate) do
    case {candidate.row.disclose, candidate.disclosure} do
      {false, nil} ->
        :ok

      {true, disclosure} when not is_nil(disclosure) ->
        if Disclosure.labels_covered?(disclosure, mandate.disclosable_labels),
          do: :ok,
          else: {:error, :disclosure_labels_outside_mandate}

      _invalid ->
        {:error, :candidate_disclosure_row_mismatch}
    end
  end

  @doc false
  @spec covered_purpose(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def covered_purpose(%Candidate{} = candidate, %Mandate{} = mandate) do
    cond do
      not present?(candidate.purpose_ref) ->
        {:error, :candidate_purpose_missing}

      candidate.purpose_ref != mandate.purpose_ref ->
        {:error, :purpose_outside_mandate}

      candidate.purpose_params !== mandate.purpose_params ->
        {:error, :purpose_parameters_outside_mandate}

      true ->
        :ok
    end
  end

  @doc false
  @spec matching_accountable(Candidate.t(), Mandate.t()) :: :ok | {:error, term()}
  def matching_accountable(%Candidate{} = candidate, %Mandate{} = mandate) do
    cond do
      not present?(candidate.accountable_ref) -> {:error, :candidate_accountable_missing}
      candidate.accountable_ref == mandate.accountable_ref -> :ok
      true -> {:error, :accountable_claim_mismatch}
    end
  end

  @doc false
  @spec owners_authorize_mandate?(Mandate.t(), [String.t()], Facts.t()) ::
          :ok | {:error, term()}
  def owners_authorize_mandate?(%Mandate{} = mandate, owner_refs, %Facts{} = facts)
      when is_list(owner_refs) do
    with {:ok, owner_refs} <- Portable.normalize_refs(owner_refs, :label_owner_refs),
         true <- owner_refs != [],
         :ok <- Status.exact_snapshot(mandate, facts),
         {:ok, lineage} <- Status.lineage(mandate, facts) do
      grantors = MapSet.new(lineage, & &1.grantor_ref)

      case Enum.find(owner_refs, &(not MapSet.member?(grantors, &1))) do
        nil -> :ok
        owner_ref -> {:error, {:label_owner_not_in_mandate_lineage, owner_ref}}
      end
    else
      false -> {:error, :declassification_label_owners_required}
      {:error, _reason} = error -> error
    end
  end

  def owners_authorize_mandate?(_mandate, _owner_refs, _facts),
    do: {:error, :invalid_declassification_authority}

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
