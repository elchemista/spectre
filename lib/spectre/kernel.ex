defmodule Spectre.Kernel do
  @moduledoc """
  Pure admission orchestration for the governed-act runtime.

  `evaluate/4` joins already-authenticated ingress context with the current
  domain projection and an explicit trusted time.  It performs no I/O, reads no
  ambient clock, appends nothing and cannot create a Grant.  Its only outputs
  are durable `Spectre.Decision` and, exclusively for an admitted decision, an
  immutable `Spectre.Act`.

  The order is intentional: the surface classifies first, authority is resolved
  without Evidence, then Evidence and Presentation are recognized, and finally
  `Spectre.Kernel.Decision` applies resource accounting through
  `Spectre.Kernel.Meter`.
  """

  alias Spectre.{
    Act,
    Candidate,
    Decision,
    Disclosure,
    Evidence,
    Governance,
    HostProfile,
    Presentation,
    Row,
    SubmissionContext,
    Surface
  }

  alias Spectre.Domain.Projection
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Authority
  alias Spectre.Kernel.Decision, as: DecisionEngine
  alias Spectre.Kernel.Decision.Context, as: DecisionContext
  alias Spectre.Kernel.Recognition

  @type result :: {:ok, Decision.t(), Act.t() | nil} | {:error, term()}

  @doc """
  Evaluates one portable Candidate against one immutable projection snapshot.

  Domain routing errors are rejected as API errors because they must not be
  written into the wrong ledger.  Candidate claims that disagree with the
  authenticated principal or scope instead produce a durable refused Decision.
  An undeclared class produces `:unknown_class`; a declared class whose Row does
  not match the Candidate exactly is refused before authority resolution.
  """
  @spec evaluate(Candidate.t(), SubmissionContext.t(), Projection.t(), integer()) :: result()
  def evaluate(
        %Candidate{} = candidate,
        %SubmissionContext{} = context,
        %State{} = projection,
        time
      )
      when is_integer(time) do
    with {:ok, candidate} <- Candidate.new(candidate),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- matching_domain(context, projection),
         {:ok, surface, profile} <- foundations(projection),
         decision_view = decision_view(projection, surface, profile),
         {:ok, decision, act} <-
           evaluate_candidate(candidate, context, projection, surface, decision_view, time) do
      {:ok, decision, act}
    end
  end

  def evaluate(%Candidate{}, %SubmissionContext{}, %State{}, time),
    do: {:error, {:invalid_trusted_time, time}}

  def evaluate(_candidate, _context, _projection, _time),
    do: {:error, :invalid_admission_input}

  defp evaluate_candidate(candidate, context, projection, surface, view, time) do
    with :ok <- authenticated_claims(candidate, context) do
      case Surface.classify(surface, candidate.class) do
        {:error, :unknown_class} ->
          forced_decision(candidate, context, view, time, :unknown_class, [
            {:unknown_class, candidate.class}
          ])

        {:ok, declared_row} ->
          evaluate_declared(candidate, context, projection, surface, declared_row, view, time)
      end
    else
      {:error, reason} -> forced_decision(candidate, context, view, time, :refused, [reason])
    end
  end

  defp evaluate_declared(candidate, context, projection, surface, declared_row, view, time) do
    if candidate.row == declared_row do
      with :ok <- Surface.validate_consequence(surface, candidate),
           :ok <- Governance.execution_boundary(candidate),
           :ok <- validate_presentation_requirement(surface, candidate),
           :ok <- validate_evidence_availability(candidate, projection),
           :ok <- validate_disclosure(candidate, projection),
           :ok <- Surface.validate_facts(surface, candidate, projection, time) do
        authority_view = Projection.authority_view(projection)

        # Evidence is deliberately not present in this call or in authority_view.
        resolution = Authority.resolve(candidate, context, authority_view, time)

        {recognition, recognition_evidence_refs} =
          recognize(candidate, resolution, projection, declared_row, time)

        decision_attrs =
          candidate
          |> DecisionEngine.decide(
            resolution,
            recognition,
            recognition_evidence_refs,
            view,
            time
          )
          |> bind_submission_context(context, candidate)

        with {:ok, decision} <- Decision.new(decision_attrs),
             {:ok, act} <- maybe_build_act(candidate, decision, time) do
          validate_transition(
            candidate,
            context,
            projection,
            surface,
            view,
            decision,
            act,
            time
          )
        end
      else
        {:error, reason} -> forced_decision(candidate, context, view, time, :refused, [reason])
      end
    else
      forced_decision(candidate, context, view, time, :refused, [
        {:candidate_row_mismatch,
         %{
           candidate: Row.dimensions(candidate.row),
           declared: Row.dimensions(declared_row)
         }}
      ])
    end
  end

  defp validate_transition(
         candidate,
         context,
         projection,
         surface,
         view,
         %Decision{outcome: :admitted} = decision,
         %Act{} = act,
         time
       ) do
    case Surface.validate_transition(surface, candidate, decision, act, projection) do
      :ok -> {:ok, decision, act}
      {:error, reason} -> forced_decision(candidate, context, view, time, :refused, [reason])
    end
  end

  defp validate_transition(
         _candidate,
         _context,
         _projection,
         _surface,
         _view,
         %Decision{} = decision,
         nil,
         _time
       ),
       do: {:ok, decision, nil}

  defp validate_disclosure(%Candidate{disclosure: nil}, _projection), do: :ok

  defp validate_disclosure(%Candidate{disclosure: disclosure}, projection) do
    Disclosure.verify_sources(disclosure, projection.evidence)
  end

  defp validate_presentation_requirement(surface, candidate) do
    case {
      Surface.presentation_required?(surface, candidate.class),
      candidate.presentation_ref,
      candidate.consent
    } do
      {true, nil, _consent} ->
        {:error, {:presentation_required, candidate.class}}

      {true, _presentation_ref, nil} ->
        {:error, {:consent_material_required, candidate.class}}

      {false, presentation_ref, nil} when not is_nil(presentation_ref) ->
        {:error, {:consent_material_required, candidate.class}}

      _valid ->
        :ok
    end
  end

  defp validate_evidence_availability(candidate, projection) do
    ErasureAnalysis.validate_evidence_available(projection, candidate.evidence_refs)
  end

  defp forced_decision(candidate, context, view, time, outcome, reasons) do
    attrs =
      candidate
      |> DecisionEngine.decide(:none, nil, [], view, time)
      |> Map.merge(%{
        outcome: outcome,
        reasons: reasons,
        mandate_ref: nil,
        mandate_revision: nil,
        recognition_refs: [],
        recognition_evidence_refs: [],
        reservations: %{},
        authorizer_ref: nil
      })
      |> bind_submission_context(context, candidate)

    with {:ok, decision} <- Decision.new(attrs), do: {:ok, decision, nil}
  end

  defp recognize(candidate, {:ok, mandate}, projection, _declared_row, time) do
    available_evidence =
      projection
      |> ErasureAnalysis.available_evidence()
      |> Map.values()

    {_declared_evidence, missing_refs} =
      resolve_evidence(candidate.evidence_refs, projection.evidence)

    {recognized, basis_refs} =
      Recognition.check_with_basis(mandate.conditions, available_evidence, time)

    evidence_result =
      recognized
      |> include_missing_evidence(missing_refs)
      |> include_undeclared_evidence(basis_refs, candidate.evidence_refs)

    {presentation_result, presentation_basis_refs} =
      recognize_presentation(candidate, projection, available_evidence, time)

    {
      combine_recognition(evidence_result, presentation_result),
      normalize_evidence_refs(basis_refs ++ presentation_basis_refs)
    }
  end

  defp recognize(_candidate, _resolution, _projection, _declared_row, _time), do: {nil, []}

  defp resolve_evidence(refs, evidence_index) do
    Enum.reduce(refs, {[], []}, fn ref, {found, missing} ->
      case Map.fetch(evidence_index, ref) do
        {:ok, evidence} -> {[evidence | found], missing}
        :error -> {found, [ref | missing]}
      end
    end)
    |> then(fn {found, missing} -> {Enum.reverse(found), Enum.reverse(missing)} end)
  end

  defp include_missing_evidence(result, []), do: result

  defp include_missing_evidence(:satisfied, missing),
    do: {:undecidable, [{:missing_evidence_refs, missing}]}

  defp include_missing_evidence({:undecidable, reasons}, missing),
    do: {:undecidable, [{:missing_evidence_refs, missing} | List.wrap(reasons)]}

  defp include_missing_evidence({:unsatisfied, reasons}, missing),
    do: {:undecidable, [{:missing_evidence_refs, missing} | List.wrap(reasons)]}

  defp include_undeclared_evidence(result, basis_refs, declared_refs) do
    missing = basis_refs -- declared_refs

    case {result, missing} do
      {result, []} ->
        result

      {:satisfied, missing} ->
        {:undecidable, [{:recognition_basis_not_declared, missing}]}

      {{:unsatisfied, reasons}, missing} ->
        {:unsatisfied, [{:recognition_basis_not_declared, missing} | List.wrap(reasons)]}

      {{:undecidable, reasons}, missing} ->
        {:undecidable, [{:recognition_basis_not_declared, missing} | List.wrap(reasons)]}
    end
  end

  defp recognize_presentation(
         %Candidate{class: "presentation.show"} = candidate,
         projection,
         _evidence,
         time
       ) do
    with {:ok, presentation_ref} <- Presentation.show_presentation_ref(candidate.consequence),
         {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
         {:ok, presentation} <- rebuild_presentation(presentation),
         :ok <- Presentation.validate_show(candidate, presentation),
         true <- presentation.prepared_at <= time do
      {:satisfied, []}
    else
      :error -> {{:undecidable, [:presentation_show_material_not_found]}, []}
      false -> {{:unsatisfied, [:presentation_show_precedes_preparation]}, []}
      {:error, reason} -> {{:unsatisfied, [{:invalid_presentation_show, reason}]}, []}
    end
  end

  defp recognize_presentation(%Candidate{presentation_ref: nil}, _projection, _evidence, _time),
    do: {:satisfied, []}

  defp recognize_presentation(candidate, projection, evidence, time) do
    case Map.fetch(projection.presentations, candidate.presentation_ref) do
      :error ->
        {{:undecidable, [{:presentation_not_found, candidate.presentation_ref}]}, []}

      {:ok, presentation} ->
        validate_presentation(candidate, presentation, projection, evidence, time)
    end
  end

  defp validate_presentation(candidate, presentation, projection, evidence, time) do
    with {:ok, presentation} <- rebuild_presentation(presentation),
         true <- presentation.ref == candidate.presentation_ref,
         :ok <- Presentation.validate_candidate(candidate, presentation),
         true <- presentation.prepared_at <= time do
      {approval_result, approval_refs, basis_refs} =
        recognize_presentation_approval(presentation, projection, evidence, time)

      result =
        if presentation.candidate_binding_ref ==
             Candidate.presentation_binding_ref(candidate, approval_refs) do
          approval_result
        else
          {:unsatisfied, [:presentation_candidate_binding_mismatch]}
        end

      {
        include_undeclared_evidence(result, basis_refs, candidate.evidence_refs),
        basis_refs
      }
    else
      {:error, reason} -> {{:undecidable, [{:invalid_presentation, reason}]}, []}
      false -> {{:unsatisfied, [:presentation_candidate_binding_mismatch]}, []}
    end
  end

  defp recognize_presentation_approval(presentation, projection, evidence, time) do
    matching = Enum.filter(evidence, &approval_for_presentation?(&1, presentation.ref))

    current =
      Enum.reduce(matching, [], fn approval, valid ->
        case approval_basis(approval, presentation, projection, evidence, time) do
          {:ok, basis_refs} -> [{approval, basis_refs} | valid]
          :invalid -> valid
        end
      end)

    result =
      cond do
        Enum.any?(current, fn {approval, _refs} -> approval.stance == :contradicts end) ->
          {:unsatisfied, [:presentation_approval_contradicted]}

        Enum.any?(current, fn {approval, _refs} -> approval.stance == :supports end) ->
          :satisfied

        matching == [] ->
          {:undecidable, [:presentation_approval_evidence_required]}

        true ->
          {:undecidable, [:presentation_approval_not_current_or_final]}
      end

    approval_refs = current |> Enum.map(fn {approval, _refs} -> approval.ref end) |> Enum.sort()

    basis_refs =
      current
      |> Enum.flat_map(fn {_approval, refs} -> refs end)
      |> normalize_evidence_refs()

    {result, approval_refs, basis_refs}
  end

  defp approval_for_presentation?(%Evidence{} = evidence, presentation_ref) do
    case Presentation.approval_refs(evidence) do
      {:ok, ^presentation_ref, _show_act_ref} -> true
      _other -> false
    end
  end

  defp approval_basis(approval, presentation, projection, evidence, time) do
    with {:ok, _presentation_ref, show_act_ref} <- Presentation.approval_refs(approval),
         {:ok, show_act} <- Map.fetch(projection.acts, show_act_ref),
         {:ok, basis_refs} <-
           Presentation.validate_response_with_basis(
             approval,
             presentation,
             show_act,
             Map.values(projection.outcomes),
             evidence,
             time
           ) do
      {:ok, basis_refs}
    else
      _invalid -> :invalid
    end
  end

  defp rebuild_presentation(%Presentation{} = presentation), do: Presentation.new(presentation)
  defp rebuild_presentation(value) when is_map(value), do: Presentation.from_canonical(value)
  defp rebuild_presentation(_value), do: {:error, :invalid_presentation_record}

  defp combine_recognition(:satisfied, :satisfied), do: :satisfied

  defp combine_recognition({:unsatisfied, left}, {:unsatisfied, right}),
    do: {:unsatisfied, List.wrap(left) ++ List.wrap(right)}

  defp combine_recognition({:unsatisfied, reasons}, _right),
    do: {:unsatisfied, List.wrap(reasons)}

  defp combine_recognition(_left, {:unsatisfied, reasons}),
    do: {:unsatisfied, List.wrap(reasons)}

  defp combine_recognition({:undecidable, left}, {:undecidable, right}),
    do: {:undecidable, List.wrap(left) ++ List.wrap(right)}

  defp combine_recognition({:undecidable, reasons}, :satisfied),
    do: {:undecidable, List.wrap(reasons)}

  defp combine_recognition(:satisfied, {:undecidable, reasons}),
    do: {:undecidable, List.wrap(reasons)}

  defp maybe_build_act(_candidate, %Decision{outcome: outcome}, _time)
       when outcome != :admitted,
       do: {:ok, nil}

  defp maybe_build_act(candidate, %Decision{outcome: :admitted} = decision, time) do
    Act.new(%{
      decision_ref: decision.ref,
      candidate_identity_key: candidate.identity_key,
      candidate_digest: candidate.material_digest,
      submission_context_ref: decision.submission_context_ref,
      authenticated_principal_ref: decision.authenticated_principal_ref,
      authentication_ref: decision.authentication_ref,
      ingress_ref: decision.ingress_ref,
      host_generation: decision.host_generation,
      class: candidate.class,
      row: candidate.row,
      consequence: candidate.consequence,
      consent: candidate.consent,
      material_digest: candidate.material_digest,
      requested_mandate_ref: candidate.requested_mandate_ref,
      proposer_ref: decision.proposer_ref,
      executor_ref: decision.executor_ref,
      authorizer_ref: decision.authorizer_ref,
      accountable_ref: decision.accountable_ref,
      scope_ref: decision.scope_ref,
      subject_refs: candidate.subject_refs,
      target_refs: candidate.target_refs,
      purpose_ref: candidate.purpose_ref,
      purpose_params: candidate.purpose_params,
      mandate_ref: decision.mandate_ref,
      mandate_revision: decision.mandate_revision,
      evidence_refs: candidate.evidence_refs,
      disclosure: candidate.disclosure,
      recognition_refs: decision.recognition_refs,
      recognition_evidence_refs: decision.recognition_evidence_refs,
      presentation_ref: candidate.presentation_ref,
      reservations: decision.reservations,
      host_profile_ref: decision.host_profile_ref,
      surface_revision: decision.surface_revision,
      executor_contract_ref: candidate.executor_contract_ref,
      observation_window_ms: candidate.observation_window_ms,
      committed_at: time
    })
  end

  defp matching_domain(context, projection) do
    if context.domain_ref == projection.domain_ref,
      do: :ok,
      else: {:error, {:submission_domain_mismatch, context.domain_ref, projection.domain_ref}}
  end

  defp authenticated_claims(candidate, context) do
    cond do
      candidate.proposer_ref != context.authenticated_principal_ref ->
        {:error, :proposer_context_mismatch}

      candidate.scope_ref != context.scope_ref ->
        {:error, :scope_context_mismatch}

      true ->
        :ok
    end
  end

  defp foundations(%State{
         surface: %Surface{} = surface,
         host_profile: %HostProfile{} = profile
       }) do
    with {:ok, surface} <- Surface.new(surface),
         {:ok, profile} <- HostProfile.new(profile) do
      {:ok, surface, profile}
    end
  end

  defp foundations(%State{surface: nil}), do: {:error, :surface_not_initialized}
  defp foundations(%State{host_profile: nil}), do: {:error, :host_profile_not_initialized}
  defp foundations(_projection), do: {:error, :invalid_admission_foundations}

  defp decision_view(projection, surface, profile) do
    %DecisionContext{
      meter_accounts: Projection.meter_view(projection),
      surface: surface,
      host_profile_ref: profile.ref,
      surface_revision: surface.revision,
      authority_revision: projection.revision
    }
  end

  defp bind_submission_context(attrs, context, candidate) do
    Map.merge(attrs, %{
      candidate_class: candidate.class,
      submission_context_ref: context.ref,
      domain_ref: context.domain_ref,
      channel_ref: context.channel_ref,
      session_ref: context.session_ref,
      authenticated_principal_ref: context.authenticated_principal_ref,
      authentication_ref: context.authentication_ref,
      ingress_ref: context.ingress_ref,
      host_generation: context.host_generation
    })
  end

  defp normalize_evidence_refs(refs), do: refs |> Enum.uniq() |> Enum.sort()
end
