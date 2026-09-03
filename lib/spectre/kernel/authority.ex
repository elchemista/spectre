defmodule Spectre.Kernel.Authority do
  @moduledoc """
  Pure resolution of the authority that may cover a candidate.

  Authority is resolved exclusively from the candidate, the authenticated
  `SubmissionContext`, the current authority view and trusted time. Evidence is
  deliberately absent from this API: facts may satisfy a mandate's conditions,
  but they cannot create or select the mandate itself.

  Every ledger record is decoded before it reaches this module. The resolver
  therefore consumes typed Candidates and Mandates plus the closed
  `Spectre.Kernel.Authority.Facts` container; accepting alternate storage
  shapes here would make authority semantics depend on map-key guesses.
  """

  alias Spectre.{Act, Candidate, Declassification, Mandate, Portable, Row}
  alias Spectre.Kernel.Authority.{Attenuation, Effective, Facts}
  alias Spectre.Mandate.Ancestry

  @retained_revocation_class "mandate.revoke"
  @retained_revocation_purpose_ref "spectre:purpose:retained-mandate-revocation:v1"
  @kernel_executor_ref "spectre:kernel:ledger"
  @kernel_contract_ref "spectre:kernel:ledger:v1"

  @typedoc "The authority-relevant subset shared by a live or replayed submission context."
  @type context :: %{
          required(:domain_ref) => String.t(),
          required(:scope_ref) => String.t(),
          required(:authenticated_principal_ref) => String.t(),
          required(:authentication_ref) => String.t(),
          required(:ingress_ref) => String.t(),
          required(:host_generation) => non_neg_integer()
        }

  @type effective :: Effective.t()

  @type resolution ::
          {:ok, effective()}
          | :none
          | {:ambiguous, [effective()]}

  @doc """
  Resolves the one current mandate which covers `candidate`.

  `:none` includes an unauthenticated or self-contradicting submission context.
  Multiple independently eligible mandates are returned explicitly instead of
  being selected by order, evidence, or caller preference.
  """
  @spec resolve(Candidate.t(), context(), Facts.t(), integer()) :: resolution()
  def resolve(%Candidate{} = candidate, context, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    eligible =
      view.mandates
      |> Map.values()
      |> Enum.flat_map(fn mandate ->
        case authorize(candidate, context, mandate, view, time) do
          {:ok, effective_mandate} -> [effective_mandate]
          {:error, _reason} -> []
        end
      end)
      |> Enum.sort_by(&mandate_sort_key/1)

    case eligible do
      [] -> :none
      [mandate] -> {:ok, mandate}
      mandates -> {:ambiguous, mandates}
    end
  end

  def resolve(_candidate, _context, _view, _time), do: :none

  @doc """
  Explains whether one mandate is eligible without consulting Evidence.

  This function is useful to auditors and to tests which need a stable reason
  for exclusion. It does not check whether mandate Evidence conditions are met
  or whether a Meter currently has sufficient available quantity.
  """
  @spec eligible?(Candidate.t(), context(), Mandate.t(), Facts.t(), integer()) ::
          :ok | {:error, term()}
  def eligible?(%Candidate{} = candidate, context, %Mandate{} = mandate, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    case authorize(candidate, context, mandate, view, time) do
      {:ok, _effective_mandate} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def eligible?(_candidate, _context, _mandate, _view, _time),
    do: {:error, :invalid_authority_input}

  @doc """
  Validates one durable Mandate and returns the exact authority used by Decision.

  Usually that is the Mandate itself. A `retained_controller` revocation is the
  one narrow exception recorded by the Mandate: while it is current, a named
  controller may revoke that exact Mandate through the ledger kernel. The
  returned map narrows every field to that single consequence; it is not a new
  durable Mandate and cannot authorize any other Candidate.
  """
  @spec authorize(Candidate.t(), context(), Mandate.t(), Facts.t(), integer()) ::
          {:ok, effective()} | {:error, term()}
  def authorize(%Candidate{} = candidate, context, %Mandate{} = mandate, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    with :ok <- authenticated_context(context),
         :ok <- exact_mandate_in_view(mandate, view),
         :ok <- matching_scope_context(candidate, context) do
      if retained_revocation_request?(candidate, mandate) do
        retained_revocation_authority(candidate, context, mandate, view, time)
      else
        ordinary_authority(candidate, context, mandate, view, time)
      end
    end
  end

  def authorize(_candidate, _context, _mandate, _view, _time),
    do: {:error, :invalid_authority_input}

  defp ordinary_authority(candidate, context, mandate, view, time) do
    with :ok <-
           restriction_status_for(mandate, view, MapSet.new(), :mandate),
         :ok <- meter_debt_status_for(mandate, view, MapSet.new(), :mandate),
         :ok <- containment_status(candidate, view),
         :ok <- matching_principal(candidate, context, mandate),
         :ok <- covered_executor(candidate, mandate),
         :ok <- requested_mandate(candidate, mandate),
         :ok <- current_at(mandate, time),
         :ok <- not_revoked(mandate, view, time),
         :ok <- matching_scope(candidate, context, mandate),
         :ok <- covered_values(:subjects, candidate, mandate),
         :ok <- covered_values(:targets, candidate, mandate),
         :ok <- covered_class(candidate, mandate),
         :ok <- declassification_owners_authorized(candidate, mandate, view),
         :ok <- covered_row(candidate, mandate),
         :ok <- covered_disclosure(candidate, mandate),
         :ok <- covered_purpose(candidate, mandate),
         :ok <- matching_accountable(candidate, mandate) do
      {:ok, Effective.from_mandate(mandate)}
    end
  end

  @doc "Returns whether a Mandate branch is blocked by an unresolved Meter debt."
  @spec meter_debt_status(Mandate.t(), Facts.t()) ::
          :ok | {:error, term()}
  def meter_debt_status(%Mandate{} = mandate, %Facts{} = view),
    do: meter_debt_status_for(mandate, view, MapSet.new(), :mandate)

  def meter_debt_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc "Returns whether a Mandate or one of its authority ancestors has been superseded."
  @spec restriction_status(Mandate.t(), Facts.t()) ::
          :ok | {:error, term()}
  def restriction_status(%Mandate{} = mandate, %Facts{} = view),
    do: restriction_status_for(mandate, view, MapSet.new(), :mandate)

  def restriction_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc false
  @spec containment_status(Candidate.t() | Act.t(), Facts.t()) ::
          :ok | {:error, term()}
  def containment_status(candidate, %Facts{} = view)
      when is_struct(candidate, Candidate) or is_struct(candidate, Act) do
    with {:ok, digest} <- Candidate.effect_digest(candidate) do
      if MapSet.member?(view.blocked_effect_digests, digest),
        do: {:error, :consequence_retry_contained},
        else: :ok
    end
  end

  def containment_status(_candidate, _view), do: {:error, :invalid_authority_input}

  @doc """
  Verifies that a child Mandate is a subtractive restriction of its parent.

  Quantitative transfer still has to be applied through `Kernel.Meter.delegate/3`;
  this function checks declared ceilings, not mutable balances. It also requires
  the parent's conditions to be preserved or strengthened and the recorded
  revocation policy to remain identical. Equality is intentionally used for
  opaque purpose parameters and revocation policies because the core has no
  safe domain-independent way to infer a broader restriction relation. It never
  creates the child or changes either Mandate.
  """
  @spec delegation_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  defdelegate delegation_within?(parent, child, time), to: Attenuation

  @doc """
  Verifies that a successor is a strict, non-quantitative restriction.

  Restriction keeps the same authority lineage and Meter allocation while
  narrowing at least one decidable boundary. Moving or shrinking quantities is
  deliberately left to delegation/devolution, so replacing a Mandate cannot
  silently mint, destroy or strand an in-flight allocation.
  """
  @spec restriction_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  defdelegate restriction_within?(predecessor, successor, time), to: Attenuation

  @doc "Verifies that every label owner explicitly granted within a Mandate lineage."
  @spec owners_authorize_mandate?(
          Mandate.t(),
          [String.t()],
          Facts.t()
        ) ::
          :ok | {:error, term()}
  def owners_authorize_mandate?(%Mandate{} = mandate, owner_refs, %Facts{} = view)
      when is_list(owner_refs) do
    with {:ok, owner_refs} <- Portable.normalize_refs(owner_refs, :label_owner_refs),
         true <- owner_refs != [],
         :ok <- exact_mandate_in_view(mandate, view),
         {:ok, lineage} <- mandate_lineage(mandate, view, MapSet.new(), []) do
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

  def owners_authorize_mandate?(_mandate, _owner_refs, _view),
    do: {:error, :invalid_declassification_authority}

  defp authenticated_context(context) do
    required = [
      :domain_ref,
      :scope_ref,
      :authenticated_principal_ref,
      :authentication_ref,
      :ingress_ref,
      :host_generation
    ]

    case Enum.find(required, &(not present?(Map.get(context, &1)))) do
      nil ->
        if is_integer(context.host_generation) and context.host_generation >= 0,
          do: :ok,
          else: {:error, :invalid_host_generation}

      :authenticated_principal_ref ->
        {:error, :unauthenticated_submission}

      field ->
        {:error, {:incomplete_submission_context, field}}
    end
  end

  defp matching_scope_context(candidate, context) do
    if candidate.scope_ref == context.scope_ref,
      do: :ok,
      else: {:error, :candidate_scope_mismatch}
  end

  defp matching_principal(candidate, context, mandate) do
    authenticated = context.authenticated_principal_ref
    claimed = candidate.proposer_ref

    cond do
      not present?(claimed) ->
        {:error, :candidate_proposer_missing}

      present?(claimed) and claimed != authenticated ->
        {:error, :proposer_claim_mismatch}

      mandate.holder_ref == authenticated ->
        :ok

      true ->
        {:error, :principal_not_mandate_holder}
    end
  end

  defp retained_revocation_request?(candidate, mandate) do
    candidate.class == @retained_revocation_class and
      candidate.requested_mandate_ref == mandate.ref and
      mandate.revocation["mode"] == :retained_controller
  end

  defp retained_revocation_authority(candidate, context, mandate, view, time) do
    controller_ref = context.authenticated_principal_ref

    with :ok <- current_at(mandate, time),
         :ok <- not_directly_revoked(mandate, view, time),
         :ok <- retained_controller(candidate, controller_ref, mandate),
         :ok <- exact_retained_revocation(candidate, context, mandate) do
      {:ok, Effective.retained_revocation(mandate, candidate, controller_ref)}
    end
  end

  defp retained_controller(candidate, controller_ref, mandate) do
    claimed = candidate.proposer_ref
    controllers = mandate.revocation["controller_refs"]

    cond do
      not present?(claimed) -> {:error, :candidate_proposer_missing}
      claimed != controller_ref -> {:error, :proposer_claim_mismatch}
      controller_ref not in controllers -> {:error, :principal_not_revocation_controller}
      true -> :ok
    end
  end

  defp exact_retained_revocation(candidate, context, mandate) do
    expected_consequence = %{
      "mandate_revoke" => %{"mandate_ref" => mandate.ref}
    }

    checks = [
      {candidate.consequence == expected_consequence, :revocation_consequence_mismatch},
      {candidate.executor_ref == @kernel_executor_ref, :retained_revocation_executor_mismatch},
      {candidate.executor_contract_ref == @kernel_contract_ref,
       :retained_revocation_contract_mismatch},
      {candidate.scope_ref == context.scope_ref, :candidate_scope_mismatch},
      {candidate.subject_refs == [], :retained_revocation_subjects_not_empty},
      {candidate.target_refs == [mandate.ref], :retained_revocation_targets_mismatch},
      {candidate.purpose_ref == @retained_revocation_purpose_ref,
       :retained_revocation_purpose_mismatch},
      {candidate.purpose_params == %{}, :retained_revocation_purpose_parameters_not_empty},
      {candidate.evidence_refs == [], :retained_revocation_evidence_not_empty},
      {is_nil(candidate.disclosure), :retained_revocation_disclosure_present},
      {is_nil(candidate.presentation_ref), :retained_revocation_presentation_present},
      {candidate.meter_requests == %{}, :retained_revocation_meter_request_present},
      {candidate.observation_window_ms == 0, :retained_revocation_observation_window_present},
      {candidate.accountable_ref == mandate.accountable_ref, :accountable_claim_mismatch},
      {Row.dimensions(candidate.row) == [:govern], :retained_revocation_row_mismatch}
    ]

    case Enum.find(checks, fn {valid?, _reason} -> not valid? end) do
      nil -> :ok
      {false, reason} -> {:error, reason}
    end
  end

  defp requested_mandate(candidate, mandate) do
    if is_nil(candidate.requested_mandate_ref) or candidate.requested_mandate_ref == mandate.ref,
      do: :ok,
      else: {:error, :different_mandate_requested}
  end

  defp covered_executor(candidate, mandate) do
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

  defp matching_scope(candidate, _context, mandate) do
    if candidate.scope_ref in mandate.scope_refs,
      do: :ok,
      else: {:error, :scope_outside_mandate}
  end

  defp covered_values(kind, candidate, mandate) do
    {requested, allowed} =
      case kind do
        :subjects -> {candidate.subject_refs, mandate.subject_refs}
        :targets -> {candidate.target_refs, mandate.target_refs}
      end

    allowed = MapSet.new(allowed)

    if Enum.all?(requested, &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, {kind, :outside_mandate}}
  end

  defp covered_class(candidate, mandate) do
    if candidate.class in mandate.classes, do: :ok, else: {:error, :class_outside_mandate}
  end

  defp declassification_owners_authorized(candidate, mandate, view) do
    case {candidate.class, candidate.consequence} do
      {"data.declassify", %{"evidence_declassification" => draft} = consequence}
      when map_size(consequence) == 1 ->
        with {:ok, decoded} <- Declassification.decode_draft(draft),
             :ok <-
               Declassification.validate_producer(
                 decoded.evidence,
                 candidate.proposer_ref
               ) do
          owners_authorize_mandate?(mandate, decoded.removed_owner_refs, view)
        end

      {"data.declassify", _invalid} ->
        {:error, :invalid_declassification_consequence}

      {_other_class, _consequence} ->
        :ok
    end
  end

  defp covered_row(candidate, mandate) do
    if Row.subset?(candidate.row, mandate.ceiling),
      do: :ok,
      else: {:error, :row_exceeds_mandate_ceiling}
  end

  defp covered_disclosure(candidate, mandate) do
    case {candidate.row.disclose, candidate.disclosure} do
      {false, nil} ->
        :ok

      {true, disclosure} when not is_nil(disclosure) ->
        if Spectre.Disclosure.labels_covered?(disclosure, mandate.disclosable_labels) do
          :ok
        else
          {:error, :disclosure_labels_outside_mandate}
        end

      _invalid ->
        {:error, :candidate_disclosure_row_mismatch}
    end
  end

  defp covered_purpose(candidate, mandate) do
    cond do
      not present?(candidate.purpose_ref) ->
        {:error, :candidate_purpose_missing}

      candidate.purpose_ref != mandate.purpose_ref ->
        {:error, :purpose_outside_mandate}

      candidate.purpose_params != mandate.purpose_params ->
        {:error, :purpose_parameters_outside_mandate}

      true ->
        :ok
    end
  end

  defp matching_accountable(candidate, mandate) do
    cond do
      not present?(candidate.accountable_ref) -> {:error, :candidate_accountable_missing}
      candidate.accountable_ref == mandate.accountable_ref -> :ok
      true -> {:error, :accountable_claim_mismatch}
    end
  end

  defp current_at(mandate, time) do
    cond do
      time < mandate.not_before ->
        {:error, :mandate_not_yet_valid}

      time >= mandate.expires_at ->
        {:error, :mandate_expired}

      true ->
        :ok
    end
  end

  defp not_revoked(mandate, view, time) do
    with {:ok, status} <- Ancestry.status(view.mandates, view.revocations, mandate, time) do
      case status do
        :current -> :ok
        {:revoked, :direct, _ref} -> {:error, :mandate_revoked}
        {:revoked, :ancestor, _ref} -> {:error, :mandate_ancestor_revoked}
      end
    end
  end

  defp not_directly_revoked(mandate, view, time) do
    with {:ok, revoked?} <- Ancestry.directly_revoked?(view.revocations, mandate, time) do
      if revoked?, do: {:error, :mandate_revoked}, else: :ok
    end
  end

  defp meter_debt_status_for(mandate, view, visited, level) do
    ref = mandate.ref

    cond do
      MapSet.member?(visited, ref) ->
        {:error, :mandate_ancestry_cycle}

      MapSet.member?(view.blocked_mandate_refs, ref) ->
        case level do
          :mandate -> {:error, :mandate_meter_debt}
          :ancestor -> {:error, :mandate_ancestor_meter_debt}
        end

      true ->
        meter_debt_parent_status(mandate, view, MapSet.put(visited, ref))
    end
  end

  defp meter_debt_parent_status(mandate, view, visited) do
    case mandate.parent_ref do
      nil ->
        :ok

      parent_ref ->
        with {:ok, parent} <- mandate_by_ref(view, parent_ref) do
          meter_debt_status_for(parent, view, visited, :ancestor)
        end
    end
  end

  defp restriction_status_for(mandate, view, visited, level) do
    ref = mandate.ref

    cond do
      MapSet.member?(visited, ref) ->
        {:error, :mandate_ancestry_cycle}

      Map.has_key?(view.mandate_successors, ref) ->
        case level do
          :mandate -> {:error, :mandate_superseded}
          :ancestor -> {:error, :mandate_ancestor_superseded}
        end

      true ->
        restriction_parent_status(mandate, view, MapSet.put(visited, ref))
    end
  end

  defp restriction_parent_status(mandate, view, visited) do
    case mandate.parent_ref do
      nil ->
        :ok

      parent_ref ->
        with {:ok, parent} <- mandate_by_ref(view, parent_ref) do
          restriction_status_for(parent, view, visited, :ancestor)
        end
    end
  end

  defp mandate_by_ref(view, ref) do
    case Map.fetch(view.mandates, ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_mandate_ancestor, ref}}
      :error -> {:error, {:mandate_ancestor_missing, ref}}
    end
  end

  defp mandate_lineage(mandate, view, visited, lineage) do
    ref = mandate.ref

    cond do
      MapSet.member?(visited, ref) ->
        {:error, :mandate_ancestry_cycle}

      is_nil(mandate.parent_ref) ->
        {:ok, Enum.reverse([mandate | lineage])}

      true ->
        with {:ok, parent} <- mandate_by_ref(view, mandate.parent_ref) do
          mandate_lineage(parent, view, MapSet.put(visited, ref), [mandate | lineage])
        end
    end
  end

  defp exact_mandate_in_view(mandate, view) do
    case Map.fetch(view.mandates, mandate.ref) do
      {:ok, ^mandate} -> :ok
      {:ok, _other} -> {:error, :mandate_snapshot_not_pinned}
      :error -> {:error, :mandate_not_in_authority_view}
    end
  end

  defp mandate_sort_key(mandate), do: {mandate.ref, mandate.revision}

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
