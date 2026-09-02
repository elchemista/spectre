defmodule Spectre.Kernel.Authority do
  @moduledoc """
  Pure resolution of the authority that may cover a candidate.

  Authority is resolved exclusively from the candidate, the authenticated
  `SubmissionContext`, the current authority view and trusted time. Evidence is
  deliberately absent from this API: facts may satisfy a mandate's conditions,
  but they cannot create or select the mandate itself.

  The resolver accepts structs or maps so the pure kernel does not depend on a
  storage representation. The expected authority view contains a `:mandates`
  map (keyed by mandate ref) or list and an optional `:revoked`/`:revocations`
  collection.
  """

  alias Spectre.{Candidate, Condition, Declassification, Disclosure, Mandate, Portable, Row}

  @retained_revocation_class "mandate.revoke"
  @retained_revocation_purpose_ref "spectre:purpose:retained-mandate-revocation:v1"
  @kernel_executor_ref "spectre:kernel:ledger"
  @kernel_contract_ref "spectre:kernel:ledger:v1"

  @typedoc "A portable candidate, submission context, mandate or authority view."
  @type portable_record :: map()

  @type resolution ::
          {:ok, portable_record()}
          | :none
          | {:ambiguous, [portable_record()]}

  @doc """
  Resolves the one current mandate which covers `candidate`.

  `:none` includes an unauthenticated or self-contradicting submission context.
  Multiple independently eligible mandates are returned explicitly instead of
  being selected by order, evidence, or caller preference.
  """
  @spec resolve(
          portable_record(),
          portable_record(),
          portable_record() | [portable_record()],
          term()
        ) ::
          resolution()
  def resolve(candidate, context, view, time)
      when is_map(candidate) and is_map(context) and (is_map(view) or is_list(view)) do
    eligible =
      view
      |> current_mandates()
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
  @spec eligible?(
          portable_record(),
          portable_record(),
          portable_record(),
          portable_record() | [portable_record()],
          term()
        ) ::
          :ok | {:error, term()}
  def eligible?(candidate, context, mandate, view, time)
      when is_map(candidate) and is_map(context) and is_map(mandate) do
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
  @spec authorize(
          portable_record(),
          portable_record(),
          portable_record(),
          portable_record() | [portable_record()],
          term()
        ) :: {:ok, portable_record()} | {:error, term()}
  def authorize(candidate, context, mandate, view, time)
      when is_map(candidate) and is_map(context) and is_map(mandate) do
    with {:ok, mandate} <- normalize_mandate(mandate),
         :ok <- authenticated_context(context),
         :ok <- valid_mandate_identity(mandate),
         :ok <- exact_mandate_in_view(mandate, view),
         :ok <- matching_host_generation(context, view),
         :ok <- matching_domain(candidate, context, mandate) do
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
      {:ok, mandate}
    end
  end

  @doc "Returns whether a Mandate branch is blocked by an unresolved Meter debt."
  @spec meter_debt_status(portable_record(), portable_record() | [portable_record()]) ::
          :ok | {:error, term()}
  def meter_debt_status(mandate, view)
      when is_map(mandate) and (is_map(view) or is_list(view)) do
    with {:ok, mandate} <- normalize_mandate(mandate) do
      meter_debt_status_for(mandate, view, MapSet.new(), :mandate)
    end
  end

  def meter_debt_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc "Returns whether a Mandate or one of its authority ancestors has been superseded."
  @spec restriction_status(portable_record(), portable_record() | [portable_record()]) ::
          :ok | {:error, term()}
  def restriction_status(mandate, view)
      when is_map(mandate) and (is_map(view) or is_list(view)) do
    with {:ok, mandate} <- normalize_mandate(mandate) do
      restriction_status_for(mandate, view, MapSet.new(), :mandate)
    end
  end

  def restriction_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc false
  @spec containment_status(portable_record(), portable_record() | [portable_record()]) ::
          :ok | {:error, term()}
  def containment_status(candidate, view)
      when is_map(candidate) and (is_map(view) or is_list(view)) do
    with {:ok, digest} <- Candidate.effect_digest(candidate) do
      case get(view, [:blocked_effect_digests], MapSet.new()) do
        %MapSet{} = blocked ->
          if MapSet.member?(blocked, digest),
            do: {:error, :consequence_retry_contained},
            else: :ok

        blocked when is_list(blocked) ->
          if digest in blocked,
            do: {:error, :consequence_retry_contained},
            else: :ok

        _invalid ->
          {:error, :invalid_effect_containment_view}
      end
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
  @spec delegation_within?(portable_record(), portable_record(), term()) ::
          :ok | {:error, term()}
  def delegation_within?(parent, child, time) when is_map(parent) and is_map(child) do
    with {:ok, parent} <- normalize_delegation_mandate(parent, :parent),
         {:ok, child} <- normalize_delegation_mandate(child, :child),
         :ok <- delegation_depth_within(parent, child),
         :ok <- current_at(parent, time),
         :ok <- child_parent_matches(parent, child),
         :ok <- child_grantor_matches(parent, child),
         :ok <- child_accountable_matches(parent, child),
         :ok <- child_values_within(:executor_refs, parent, child),
         :ok <- child_values_within(:executor_contract_refs, parent, child),
         :ok <- child_values_within(:scope_refs, parent, child),
         :ok <- child_values_within(:subject_refs, parent, child),
         :ok <- child_values_within(:target_refs, parent, child),
         :ok <- child_labels_within(parent, child),
         :ok <- child_values_within(:classes, parent, child),
         :ok <- child_row_within(parent, child),
         :ok <- child_purpose_within(parent, child),
         :ok <- child_conditions_within(parent, child),
         :ok <- child_time_within(parent, child),
         :ok <- child_meters_within(parent, child) do
      child_revocation_within(parent, child)
    end
  end

  def delegation_within?(_parent, _child, _time), do: {:error, :invalid_delegation}

  @doc """
  Verifies that a successor is a strict, non-quantitative restriction.

  Restriction keeps the same authority lineage and Meter allocation while
  narrowing at least one decidable boundary. Moving or shrinking quantities is
  deliberately left to delegation/devolution, so replacing a Mandate cannot
  silently mint, destroy or strand an in-flight allocation.
  """
  @spec restriction_within?(portable_record(), portable_record(), term()) ::
          :ok | {:error, term()}
  def restriction_within?(predecessor, successor, time)
      when is_map(predecessor) and is_map(successor) do
    with {:ok, predecessor} <- normalize_restriction_mandate(predecessor, :predecessor),
         {:ok, successor} <- normalize_restriction_mandate(successor, :successor),
         :ok <- current_at(predecessor, time),
         :ok <- current_at(successor, time),
         :ok <- restriction_revision(predecessor, successor),
         :ok <- restriction_lineage(predecessor, successor),
         :ok <- restriction_roles(predecessor, successor),
         :ok <- child_values_within(:executor_refs, predecessor, successor),
         :ok <- child_values_within(:executor_contract_refs, predecessor, successor),
         :ok <- child_values_within(:scope_refs, predecessor, successor),
         :ok <- child_values_within(:subject_refs, predecessor, successor),
         :ok <- child_values_within(:target_refs, predecessor, successor),
         :ok <- child_labels_within(predecessor, successor),
         :ok <- child_values_within(:classes, predecessor, successor),
         :ok <- child_row_within(predecessor, successor),
         :ok <- child_purpose_within(predecessor, successor),
         :ok <- child_conditions_within(predecessor, successor),
         :ok <- child_time_within(predecessor, successor),
         :ok <- restriction_delegation_within(predecessor, successor),
         :ok <- restriction_fixed_policy(predecessor, successor),
         :ok <- strict_restriction(predecessor, successor) do
      :ok
    end
  end

  def restriction_within?(_predecessor, _successor, _time),
    do: {:error, :invalid_mandate_restriction}

  @doc "Verifies that every label owner explicitly granted within a Mandate lineage."
  @spec owners_authorize_mandate?(
          portable_record(),
          [String.t()],
          portable_record() | [portable_record()]
        ) ::
          :ok | {:error, term()}
  def owners_authorize_mandate?(mandate, owner_refs, view)
      when is_map(mandate) and is_list(owner_refs) and (is_map(view) or is_list(view)) do
    with {:ok, mandate} <- normalize_mandate(mandate),
         {:ok, owner_refs} <- Portable.normalize_refs(owner_refs, :label_owner_refs),
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

    case Enum.find(required, &(not present?(get(context, [&1])))) do
      nil ->
        if is_integer(get(context, [:host_generation])) and get(context, [:host_generation]) >= 0,
          do: :ok,
          else: {:error, :invalid_host_generation}

      :authenticated_principal_ref ->
        {:error, :unauthenticated_submission}

      field ->
        {:error, {:incomplete_submission_context, field}}
    end
  end

  defp valid_mandate_identity(mandate) do
    ref = mandate_ref(mandate)
    revision = revision(mandate)

    if present?(ref) and is_integer(revision) and revision > 0,
      do: :ok,
      else: {:error, :invalid_mandate_identity}
  end

  defp matching_host_generation(context, view) do
    context_generation = get(context, [:host_generation])
    view_generation = get(view, [:host_generation, :generation])

    if not present?(view_generation) or context_generation == view_generation,
      do: :ok,
      else: {:error, :stale_host_generation}
  end

  defp matching_domain(candidate, context, mandate) do
    context_domain = get(context, [:domain_ref])
    candidate_domain = get(candidate, [:domain_ref])
    mandate_domain = get(mandate, [:domain_ref])

    cond do
      present?(candidate_domain) and present?(context_domain) and
          candidate_domain != context_domain ->
        {:error, :candidate_domain_mismatch}

      present?(mandate_domain) and present?(context_domain) and mandate_domain != context_domain ->
        {:error, :mandate_domain_mismatch}

      true ->
        :ok
    end
  end

  defp matching_principal(candidate, context, mandate) do
    authenticated = get(context, [:authenticated_principal_ref, :principal_ref])
    claimed = get(candidate, [:proposer_ref, :principal_ref])
    holder = get(mandate, [:holder_ref, :holder])

    cond do
      not present?(claimed) ->
        {:error, :candidate_proposer_missing}

      present?(claimed) and claimed != authenticated ->
        {:error, :proposer_claim_mismatch}

      present?(holder) and holder == authenticated ->
        :ok

      true ->
        {:error, :principal_not_mandate_holder}
    end
  end

  defp retained_revocation_request?(candidate, mandate) do
    get(candidate, [:class]) == @retained_revocation_class and
      get(candidate, [:requested_mandate_ref, :mandate_ref]) == mandate.ref and
      revocation_mode(mandate.revocation) == :retained_controller
  end

  defp retained_revocation_authority(candidate, context, mandate, view, time) do
    controller_ref = get(context, [:authenticated_principal_ref, :principal_ref])

    with :ok <- current_at(mandate, time),
         :ok <- not_directly_revoked(mandate, view, time),
         :ok <- retained_controller(candidate, controller_ref, mandate),
         :ok <- exact_retained_revocation(candidate, context, mandate) do
      {:ok, narrow_retained_revocation(mandate, candidate, controller_ref)}
    end
  end

  defp retained_controller(candidate, controller_ref, mandate) do
    claimed = get(candidate, [:proposer_ref, :principal_ref])
    controllers = get(mandate.revocation, [:controller_refs], [])

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
      {get(candidate, [:consequence]) == expected_consequence, :revocation_consequence_mismatch},
      {get(candidate, [:executor_ref]) == @kernel_executor_ref,
       :retained_revocation_executor_mismatch},
      {get(candidate, [:executor_contract_ref]) == @kernel_contract_ref,
       :retained_revocation_contract_mismatch},
      {get(candidate, [:scope_ref]) == get(context, [:scope_ref]), :candidate_scope_mismatch},
      {listify(get(candidate, [:subject_refs], [])) == [],
       :retained_revocation_subjects_not_empty},
      {listify(get(candidate, [:target_refs], [])) == [mandate.ref],
       :retained_revocation_targets_mismatch},
      {get(candidate, [:purpose_ref]) == @retained_revocation_purpose_ref,
       :retained_revocation_purpose_mismatch},
      {get(candidate, [:purpose_params], %{}) == %{},
       :retained_revocation_purpose_parameters_not_empty},
      {listify(get(candidate, [:evidence_refs], [])) == [],
       :retained_revocation_evidence_not_empty},
      {is_nil(get(candidate, [:disclosure])), :retained_revocation_disclosure_present},
      {is_nil(get(candidate, [:presentation_ref])), :retained_revocation_presentation_present},
      {get(candidate, [:meter_requests], %{}) == %{}, :retained_revocation_meter_request_present},
      {get(candidate, [:observation_window_ms], 0) == 0,
       :retained_revocation_observation_window_present},
      {get(candidate, [:accountable_ref]) == mandate.accountable_ref,
       :accountable_claim_mismatch},
      {exact_govern_row?(get(candidate, [:row])), :retained_revocation_row_mismatch}
    ]

    case Enum.find(checks, fn {valid?, _reason} -> not valid? end) do
      nil -> :ok
      {false, reason} -> {:error, reason}
    end
  end

  defp narrow_retained_revocation(mandate, candidate, controller_ref) do
    mandate
    |> Map.from_struct()
    |> Map.merge(%{
      grantor_ref: controller_ref,
      holder_ref: controller_ref,
      accountable_ref: mandate.accountable_ref,
      executor_refs: [@kernel_executor_ref],
      executor_contract_refs: [@kernel_contract_ref],
      scope_refs: [get(candidate, [:scope_ref])],
      subject_refs: [],
      target_refs: [mandate.ref],
      disclosable_labels: [],
      classes: [@retained_revocation_class],
      ceiling: get(candidate, [:row]),
      purpose_ref: @retained_revocation_purpose_ref,
      purpose_params: %{},
      conditions: [],
      meters: %{},
      delegation: %{"allowed" => false, "max_depth" => 0}
    })
  end

  defp exact_govern_row?(row) do
    case Row.new(row) do
      {:ok, row} -> Row.dimensions(row) == [:govern]
      {:error, _reason} -> false
    end
  end

  defp requested_mandate(candidate, mandate) do
    requested = get(candidate, [:requested_mandate_ref, :mandate_ref])
    requested_revision = get(candidate, [:requested_mandate_revision, :mandate_revision])
    actual = mandate_ref(mandate)
    actual_revision = revision(mandate)

    cond do
      present?(requested) and requested != actual ->
        {:error, :different_mandate_requested}

      present?(requested_revision) and requested_revision != actual_revision ->
        {:error, :different_mandate_revision_requested}

      true ->
        :ok
    end
  end

  defp covered_executor(candidate, mandate) do
    executor_ref = get(candidate, [:executor_ref])
    contract_ref = get(candidate, [:executor_contract_ref])
    executors = get(mandate, [:executor_refs], [])
    contracts = get(mandate, [:executor_contract_refs], [])

    cond do
      not present?(executor_ref) ->
        {:error, :candidate_executor_missing}

      not constraint_covers?(executors, executor_ref) ->
        {:error, :executor_outside_mandate}

      not present?(contract_ref) ->
        {:error, :candidate_executor_contract_missing}

      not constraint_covers?(contracts, contract_ref) ->
        {:error, :executor_contract_outside_mandate}

      true ->
        :ok
    end
  end

  defp matching_scope(candidate, context, mandate) do
    candidate_scope = get(candidate, [:scope_ref])
    context_scope = get(context, [:scope_ref])
    requested_scope = candidate_scope || context_scope
    allowed = get(mandate, [:scope_refs, :scopes, :scope_ref, :scope])

    cond do
      present?(candidate_scope) and present?(context_scope) and candidate_scope != context_scope ->
        {:error, :candidate_scope_mismatch}

      not present?(requested_scope) ->
        :ok

      constraint_covers?(allowed, requested_scope) ->
        :ok

      true ->
        {:error, :scope_outside_mandate}
    end
  end

  defp covered_values(kind, candidate, mandate) do
    {candidate_fields, mandate_fields} =
      case kind do
        :subjects -> {[:subject_refs, :subjects], [:subject_refs, :subjects]}
        :targets -> {[:target_refs, :targets], [:target_refs, :targets]}
      end

    requested = candidate |> get(candidate_fields, []) |> listify()
    allowed = get(mandate, mandate_fields)

    if Enum.all?(requested, &constraint_covers?(allowed, &1)),
      do: :ok,
      else: {:error, {kind, :outside_mandate}}
  end

  defp covered_class(candidate, mandate) do
    class = get(candidate, [:class, :consequence_class])
    classes = get(mandate, [:classes, :consequence_classes])

    # An unknown or absent class is classified by Decision, not silently turned
    # into a different class during mandate selection.
    cond do
      unknown_class?(class) -> :ok
      constraint_covers?(classes, class) -> :ok
      true -> {:error, :class_outside_mandate}
    end
  end

  defp declassification_owners_authorized(candidate, mandate, view) do
    case {get(candidate, [:class, :consequence_class]), get(candidate, [:consequence])} do
      {"data.declassify", %{"evidence_declassification" => draft} = consequence}
      when map_size(consequence) == 1 ->
        with {:ok, decoded} <- Declassification.decode_draft(draft) do
          owners_authorize_mandate?(mandate, decoded.removed_owner_refs, view)
        end

      {"data.declassify", _invalid} ->
        {:error, :invalid_declassification_consequence}

      {_other_class, _consequence} ->
        :ok
    end
  end

  defp covered_row(candidate, mandate) do
    requested = get(candidate, [:row])
    ceiling = get(mandate, [:ceiling, :row_ceiling])

    if row_subset?(requested, ceiling),
      do: :ok,
      else: {:error, :row_exceeds_mandate_ceiling}
  end

  defp covered_disclosure(candidate, mandate) do
    disclosure = get(candidate, [:disclosure])
    disclose? = get(get(candidate, [:row], %{}), [:disclose], false)

    case {disclose?, disclosure} do
      {false, nil} ->
        :ok

      {true, disclosure} ->
        with {:ok, disclosure} <- Disclosure.new(disclosure),
             true <-
               Disclosure.labels_covered?(
                 disclosure,
                 get(mandate, [:disclosable_labels], [])
               ) do
          :ok
        else
          false -> {:error, :disclosure_labels_outside_mandate}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :candidate_disclosure_row_mismatch}
    end
  end

  defp covered_purpose(candidate, mandate) do
    requested_ref = get(candidate, [:purpose_ref])
    allowed_ref = get(mandate, [:purpose_ref])
    requested_params = get(candidate, [:purpose_params], %{})
    allowed_params = get(mandate, [:purpose_params], %{})

    cond do
      not present?(requested_ref) ->
        {:error, :candidate_purpose_missing}

      requested_ref != allowed_ref ->
        {:error, :purpose_outside_mandate}

      requested_params != allowed_params ->
        {:error, :purpose_parameters_outside_mandate}

      true ->
        :ok
    end
  end

  defp matching_accountable(candidate, mandate) do
    claimed = get(candidate, [:accountable_ref])
    accountable = get(mandate, [:accountable_ref, :accountable])

    cond do
      not present?(claimed) -> {:error, :candidate_accountable_missing}
      claimed == accountable -> :ok
      true -> {:error, :accountable_claim_mismatch}
    end
  end

  defp current_at(mandate, time) do
    not_before = get(mandate, [:not_before, :valid_from])
    expires_at = get(mandate, [:expires_at, :valid_until])

    cond do
      present?(not_before) and not comparable_at_or_after?(time, not_before) ->
        {:error, :mandate_not_yet_valid}

      present?(expires_at) and not comparable_before?(time, expires_at) ->
        {:error, :mandate_expired}

      get(mandate, [:status]) in [:inactive, :revoked, :expired] ->
        {:error, :mandate_inactive}

      true ->
        :ok
    end
  end

  defp not_revoked(mandate, view, time) do
    ref = mandate_ref(mandate)

    if revocation_effective?(ref, mandate, view, time) do
      {:error, :mandate_revoked}
    else
      ancestor_revocation_status(mandate, view, time, MapSet.new([ref]))
    end
  end

  defp not_directly_revoked(mandate, view, time) do
    if revocation_effective?(mandate.ref, mandate, view, time),
      do: {:error, :mandate_revoked},
      else: :ok
  end

  defp meter_debt_status_for(mandate, view, visited, level) do
    ref = mandate_ref(mandate)

    cond do
      MapSet.member?(visited, ref) ->
        {:error, :mandate_ancestry_cycle}

      meter_debt_blocked?(view, ref) ->
        case level do
          :mandate -> {:error, :mandate_meter_debt}
          :ancestor -> {:error, :mandate_ancestor_meter_debt}
        end

      true ->
        meter_debt_parent_status(mandate, view, MapSet.put(visited, ref))
    end
  end

  defp meter_debt_parent_status(mandate, view, visited) do
    case get(mandate, [:parent_ref, :parent]) do
      nil ->
        :ok

      parent_ref ->
        with {:ok, parent} <- mandate_by_ref(view, parent_ref) do
          meter_debt_status_for(parent, view, visited, :ancestor)
        end
    end
  end

  defp meter_debt_blocked?(view, ref) when is_map(view) do
    case get(view, [:blocked_mandate_refs], MapSet.new()) do
      %MapSet{} = refs -> MapSet.member?(refs, ref)
      refs when is_list(refs) -> ref in refs
      refs when is_map(refs) -> Map.has_key?(refs, ref) or Map.has_key?(refs, stringify(ref))
      _invalid -> true
    end
  end

  defp meter_debt_blocked?(_view, _ref), do: false

  defp restriction_status_for(mandate, view, visited, level) do
    ref = mandate_ref(mandate)

    cond do
      MapSet.member?(visited, ref) ->
        {:error, :mandate_ancestry_cycle}

      mandate_superseded?(view, ref) ->
        case level do
          :mandate -> {:error, :mandate_superseded}
          :ancestor -> {:error, :mandate_ancestor_superseded}
        end

      true ->
        restriction_parent_status(mandate, view, MapSet.put(visited, ref))
    end
  end

  defp restriction_parent_status(mandate, view, visited) do
    case get(mandate, [:parent_ref, :parent]) do
      nil ->
        :ok

      parent_ref ->
        with {:ok, parent} <- mandate_by_ref(view, parent_ref) do
          restriction_status_for(parent, view, visited, :ancestor)
        end
    end
  end

  defp mandate_superseded?(view, ref) when is_map(view) do
    case get(view, [:mandate_successors, :successors], %{}) do
      successors when is_map(successors) ->
        Map.has_key?(successors, ref) or Map.has_key?(successors, stringify(ref))

      _other ->
        false
    end
  end

  defp mandate_superseded?(_view, _ref), do: false

  defp ancestor_revocation_status(mandate, view, time, visited) do
    parent_ref = get(mandate, [:parent_ref, :parent])

    cond do
      not present?(parent_ref) ->
        :ok

      MapSet.member?(visited, parent_ref) ->
        {:error, :mandate_ancestry_cycle}

      true ->
        with {:ok, parent} <- mandate_by_ref(view, parent_ref),
             :ok <- delegation_within?(parent, mandate, time),
             :ok <- ancestor_not_cascade_revoked(parent, view, time) do
          ancestor_revocation_status(parent, view, time, MapSet.put(visited, parent_ref))
        end
    end
  end

  defp ancestor_not_cascade_revoked(parent, view, time) do
    ref = mandate_ref(parent)

    if revocation_effective?(ref, parent, view, time) and cascade_revocation?(parent),
      do: {:error, :mandate_ancestor_revoked},
      else: :ok
  end

  defp cascade_revocation?(mandate) do
    configured = get(mandate, [:revocation], %{})

    case revocation_mode(configured) do
      :cascade -> true
      :retained_controller -> false
      _invalid -> true
    end
  end

  defp revocation_mode(nil), do: nil
  defp revocation_mode(:cascade), do: :cascade
  defp revocation_mode(:retained_controller), do: :retained_controller
  defp revocation_mode("cascade"), do: :cascade
  defp revocation_mode("retained_controller"), do: :retained_controller

  defp revocation_mode(value) when is_map(value),
    do: value |> get([:mode, :policy]) |> revocation_mode()

  defp revocation_mode(_value), do: :invalid

  defp revocation_effective?(ref, mandate, view, time) do
    local_time = get(mandate, [:revoked_at])
    info = revocation_info(view, ref)

    local_effective =
      present?(local_time) and (not present?(time) or comparable_at_or_after?(time, local_time))

    local_effective or revocation_info_effective?(info, time)
  end

  defp revocation_info_effective?(nil, _time), do: false
  defp revocation_info_effective?(false, _time), do: false
  defp revocation_info_effective?(true, _time), do: true

  defp revocation_info_effective?(at, time) when is_integer(at) do
    not present?(time) or comparable_at_or_after?(time, at)
  end

  defp revocation_info_effective?(info, time) when is_map(info) do
    effective_at = get(info, [:effective_at, :revoked_at, :at])
    active = get(info, [:active, :revoked], true)

    active != false and
      (not present?(effective_at) or not present?(time) or
         comparable_at_or_after?(time, effective_at))
  end

  defp revocation_info_effective?(_info, _time), do: true

  defp revocation_info(view, ref) when is_map(view) do
    revoked = get(view, [:revoked, :revocations], %{})

    cond do
      match?(%MapSet{}, revoked) -> if MapSet.member?(revoked, ref), do: true
      is_list(revoked) -> if ref in revoked, do: true
      is_map(revoked) -> Map.get(revoked, ref) || Map.get(revoked, stringify(ref))
      true -> nil
    end
  end

  defp revocation_info(_view, _ref), do: nil

  defp current_mandates(view) do
    mandates =
      cond do
        is_list(view) -> view
        is_map(view) -> get(view, [:mandates], [])
      end

    mandates
    |> case do
      mandates when is_list(mandates) -> mandates
      mandates when is_map(mandates) -> Map.values(mandates)
      _other -> []
    end
    |> Enum.filter(&is_map/1)
  end

  defp normalize_mandate(mandate) do
    case Mandate.new(mandate) do
      {:ok, mandate} -> {:ok, mandate}
      {:error, reason} -> {:error, {:invalid_mandate, reason}}
    end
  end

  defp normalize_delegation_mandate(mandate, side) do
    case Mandate.new(mandate) do
      {:ok, mandate} -> {:ok, mandate}
      {:error, reason} -> {:error, {:invalid_delegation_mandate, side, reason}}
    end
  end

  defp normalize_restriction_mandate(mandate, side) do
    case Mandate.new(mandate) do
      {:ok, mandate} -> {:ok, mandate}
      {:error, reason} -> {:error, {:invalid_restriction_mandate, side, reason}}
    end
  end

  defp restriction_revision(predecessor, successor) do
    if successor.revision == predecessor.revision + 1,
      do: :ok,
      else: {:error, :restriction_revision_not_sequential}
  end

  defp restriction_lineage(predecessor, successor) do
    if successor.parent_ref == predecessor.parent_ref,
      do: :ok,
      else: {:error, :restriction_lineage_changed}
  end

  defp restriction_roles(predecessor, successor) do
    fields = [:grantor_ref, :holder_ref, :accountable_ref]

    case Enum.find(fields, &(Map.fetch!(predecessor, &1) != Map.fetch!(successor, &1))) do
      nil -> :ok
      field -> {:error, {:restriction_role_changed, field}}
    end
  end

  defp restriction_delegation_within(predecessor, successor) do
    parent = predecessor.delegation
    child = successor.delegation

    allowed? =
      case {parent, child} do
        {%{"allowed" => false, "max_depth" => 0}, %{"allowed" => false, "max_depth" => 0}} ->
          true

        {%{"allowed" => true, "max_depth" => parent_depth},
         %{"allowed" => false, "max_depth" => 0}} ->
          parent_depth > 0

        {%{"allowed" => true, "max_depth" => parent_depth},
         %{"allowed" => true, "max_depth" => child_depth}} ->
          child_depth > 0 and child_depth <= parent_depth

        _other ->
          false
      end

    if allowed?, do: :ok, else: {:error, {:delegation_expanded, :delegation}}
  end

  defp restriction_fixed_policy(predecessor, successor) do
    cond do
      successor.meters != predecessor.meters ->
        {:error, {:restriction_changed, :meters}}

      successor.revocation != predecessor.revocation ->
        {:error, {:restriction_changed, :revocation}}

      true ->
        :ok
    end
  end

  defp strict_restriction(predecessor, successor) do
    fields = [
      :executor_refs,
      :executor_contract_refs,
      :scope_refs,
      :subject_refs,
      :target_refs,
      :disclosable_labels,
      :classes,
      :ceiling,
      :conditions,
      :not_before,
      :expires_at,
      :delegation
    ]

    if Enum.any?(fields, &(Map.fetch!(predecessor, &1) != Map.fetch!(successor, &1))),
      do: :ok,
      else: {:error, :mandate_restriction_must_be_strict}
  end

  defp mandate_by_ref(view, ref) do
    case Enum.filter(current_mandates(view), &(mandate_ref(&1) == ref)) do
      [mandate] ->
        case normalize_mandate(mandate) do
          {:ok, mandate} -> {:ok, mandate}
          {:error, reason} -> {:error, {:invalid_mandate_ancestor, ref, reason}}
        end

      [] ->
        {:error, {:mandate_ancestor_missing, ref}}

      _duplicates ->
        {:error, {:mandate_revision_ambiguous, ref}}
    end
  end

  defp mandate_lineage(mandate, view, visited, lineage) do
    ref = mandate_ref(mandate)

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

  defp mandate_ref(mandate), do: get(mandate, [:ref, :mandate_ref, :id])
  defp revision(mandate), do: get(mandate, [:revision], 0)

  defp exact_mandate_in_view(mandate, view) do
    ref = mandate_ref(mandate)

    case Enum.filter(current_mandates(view), &(mandate_ref(&1) == ref)) do
      [view_mandate] ->
        with {:ok, view_mandate} <- normalize_mandate(view_mandate),
             true <- revision(view_mandate) == revision(mandate),
             true <- Mandate.canonical(view_mandate) == Mandate.canonical(mandate) do
          :ok
        else
          {:error, _reason} = error -> error
          false -> {:error, :mandate_snapshot_not_pinned}
        end

      [] ->
        {:error, :mandate_not_in_authority_view}

      _duplicates ->
        {:error, :mandate_revision_ambiguous}
    end
  end

  defp delegation_depth_within(parent, child) do
    parent_policy = get(parent, [:delegation], %{})
    child_policy = get(child, [:delegation], %{})
    parent_allowed = get(parent_policy, [:allowed], false)
    parent_depth = get(parent_policy, [:max_depth], 0)
    child_depth = get(child_policy, [:max_depth], 0)

    cond do
      parent_allowed != true ->
        {:error, :delegation_not_allowed}

      parent_depth <= 0 ->
        {:error, :delegation_depth_exhausted}

      child_depth > parent_depth - 1 ->
        {:error, :delegation_depth_expanded}

      true ->
        :ok
    end
  end

  defp child_parent_matches(parent, child) do
    if get(child, [:parent_ref, :parent]) == mandate_ref(parent),
      do: :ok,
      else: {:error, :delegation_parent_mismatch}
  end

  defp child_grantor_matches(parent, child) do
    if get(child, [:grantor_ref, :grantor]) == get(parent, [:holder_ref, :holder]),
      do: :ok,
      else: {:error, :delegation_grantor_mismatch}
  end

  defp child_accountable_matches(parent, child) do
    if get(child, [:accountable_ref, :accountable]) ==
         get(parent, [:accountable_ref, :accountable]),
       do: :ok,
       else: {:error, :delegation_accountable_expanded}
  end

  defp child_values_within(field, parent, child) do
    allowed = get(parent, [field])
    requested = child |> get([field], []) |> listify()

    if Enum.all?(requested, &constraint_covers?(allowed, &1)),
      do: :ok,
      else: {:error, {:delegation_expanded, field}}
  end

  defp child_labels_within(parent, child) do
    with {:ok, parent_labels} <-
           Spectre.Evidence.normalize_labels(get(parent, [:disclosable_labels], [])),
         {:ok, child_labels} <-
           Spectre.Evidence.normalize_labels(get(child, [:disclosable_labels], [])) do
      parent_keys = MapSet.new(parent_labels, & &1.ref)

      if Enum.all?(
           child_labels,
           &MapSet.member?(parent_keys, &1.ref)
         ),
         do: :ok,
         else: {:error, {:delegation_expanded, :disclosable_labels}}
    end
  end

  defp child_row_within(parent, child) do
    if row_subset?(get(child, [:ceiling, :row_ceiling]), get(parent, [:ceiling, :row_ceiling])),
      do: :ok,
      else: {:error, {:delegation_expanded, :ceiling}}
  end

  defp child_purpose_within(parent, child) do
    if get(child, [:purpose_ref]) == get(parent, [:purpose_ref]) and
         get(child, [:purpose_params], %{}) == get(parent, [:purpose_params], %{}) do
      :ok
    else
      {:error, {:delegation_expanded, :purpose}}
    end
  end

  defp child_conditions_within(parent, child) do
    child_conditions = get(child, [:conditions], [])

    parent
    |> get([:conditions], [])
    |> Enum.reduce_while(:ok, fn parent_condition, :ok ->
      case matching_child_condition(parent_condition, child_conditions) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp matching_child_condition(parent_condition, child_conditions) do
    candidates =
      Enum.filter(child_conditions, fn child_condition ->
        get(child_condition, [:proposition]) == get(parent_condition, [:proposition])
      end)

    results =
      Enum.map(candidates, fn child_condition ->
        Condition.attenuation(parent_condition, child_condition)
      end)

    cond do
      :ok in results ->
        :ok

      results == [] ->
        {:error, {:delegation_expanded, :conditions, condition_ref(parent_condition)}}

      true ->
        {:error,
         {:delegation_expanded, :conditions, condition_ref(parent_condition),
          first_condition_reason(results)}}
    end
  end

  defp first_condition_reason(results) do
    Enum.find_value(results, :condition_not_preserved, fn
      {:error, reason} -> reason
      :ok -> nil
    end)
  end

  defp condition_ref(condition), do: get(condition, [:ref, :condition_ref])

  defp child_time_within(parent, child) do
    parent_start = get(parent, [:not_before, :valid_from])
    parent_end = get(parent, [:expires_at, :valid_until])
    child_start = get(child, [:not_before, :valid_from])
    child_end = get(child, [:expires_at, :valid_until])

    if comparable_at_or_after?(child_start, parent_start) and
         (child_end == parent_end or comparable_before?(child_end, parent_end)) do
      :ok
    else
      {:error, {:delegation_expanded, :time_window}}
    end
  end

  defp child_meters_within(parent, child) do
    parent_meters = get(parent, [:meters, :resources], %{})
    child_meters = get(child, [:meters, :resources], %{})

    invalid =
      if is_map(parent_meters) and is_map(child_meters) do
        Enum.find(child_meters, fn {ref, quantity} ->
          parent_quantity = Map.get(parent_meters, ref) || Map.get(parent_meters, stringify(ref))

          not (is_integer(quantity) and quantity >= 0 and is_integer(parent_quantity) and
                 quantity <= parent_quantity)
        end)
      else
        :invalid
      end

    if is_nil(invalid),
      do: :ok,
      else: {:error, {:delegation_expanded, :meters, invalid}}
  end

  # Revocation is governance authority in its own right. Without a declared
  # domain-specific order over policies, equality is the only closed relation
  # that proves the child neither loses a controller nor invents one.
  defp child_revocation_within(parent, child) do
    if get(child, [:revocation]) == get(parent, [:revocation]),
      do: :ok,
      else: {:error, {:delegation_expanded, :revocation}}
  end

  defp mandate_sort_key(mandate) do
    {stringify(mandate_ref(mandate)), revision(mandate)}
  end

  defp constraint_covers?(allowed, _requested) when allowed in [:any, :*], do: true
  defp constraint_covers?(%MapSet{} = allowed, requested), do: MapSet.member?(allowed, requested)
  defp constraint_covers?(allowed, requested) when is_list(allowed), do: requested in allowed
  defp constraint_covers?(allowed, requested), do: present?(allowed) and allowed == requested

  defp row_subset?(requested, ceiling), do: Row.subset?(requested, ceiling)

  defp unknown_class?(class), do: class in [nil, :unknown, :unknown_class]

  defp comparable_at_or_after?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left >= right
      _other -> false
    end
  end

  defp comparable_before?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left < right
      _other -> false
    end
  end

  defp timestamp(value) when is_integer(value), do: {:ok, value}
  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.to_unix(value, :millisecond)}

  defp timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> then(&{:ok, &1})
  end

  defp timestamp(_value), do: :error

  defp listify(nil), do: []
  defp listify(%MapSet{} = value), do: MapSet.to_list(value)
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp get(map, fields, default \\ nil)

  defp get(map, fields, default) when is_map(map) do
    Enum.find_value(fields, default, fn field ->
      case fetch(map, field) do
        {:ok, nil} -> nil
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      value -> value
    end
  end

  defp get(_other, _fields, default), do: default

  defp fetch(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
