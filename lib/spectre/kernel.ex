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
    HostProfile,
    Presentation,
    Row,
    SubmissionContext,
    Surface
  }

  alias Spectre.Domain.Projection
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.Admission.Binding
  alias Spectre.GovernedAct.State
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
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
           :ok <- GovernedExecution.validate(candidate),
           :ok <- validate_presentation_requirement(surface, candidate),
           :ok <- validate_evidence_availability(candidate, projection),
           :ok <- validate_disclosure(candidate, projection),
           :ok <- Surface.validate_facts(surface, candidate, projection, time) do
        authority_view = Projection.authority_view(projection)

        # Evidence is deliberately not present in this call or in authority_view.
        resolution = Authority.resolve(candidate, context, authority_view, time)
        view = with_meter_accounts(view, projection, resolution)

        {recognition, recognition_evidence_refs} =
          recognize(candidate, resolution, projection, time)

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
             {:ok, act} <- maybe_build_act(candidate, decision) do
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

  defp recognize(candidate, {:ok, mandate}, projection, time) do
    available_evidence =
      projection
      |> ErasureAnalysis.available_evidence()
      |> Map.values()

    missing_refs = missing_evidence_refs(candidate.evidence_refs, projection.evidence)

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

  defp recognize(_candidate, _resolution, _projection, _time), do: {nil, []}

  defp missing_evidence_refs(refs, evidence_index),
    do: Enum.reject(refs, &Map.has_key?(evidence_index, &1))

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
    {status, approval_refs, basis_refs} =
      Presentation.classify_responses(
        presentation,
        projection.acts,
        Map.values(projection.outcomes),
        evidence,
        time
      )

    result =
      case status do
        :contradicted -> {:unsatisfied, [:presentation_approval_contradicted]}
        :supported -> :satisfied
        :missing -> {:undecidable, [:presentation_approval_evidence_required]}
        :unqualified -> {:undecidable, [:presentation_approval_not_current_or_final]}
      end

    {result, approval_refs, basis_refs}
  end

  defp rebuild_presentation(%Presentation{} = presentation), do: {:ok, presentation}
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

  defp maybe_build_act(_candidate, %Decision{outcome: outcome})
       when outcome != :admitted,
       do: {:ok, nil}

  defp maybe_build_act(candidate, %Decision{outcome: :admitted} = decision),
    do: Binding.act(candidate, decision)

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

  defp foundations(%State{} = projection) do
    case {State.surface(projection), State.host_profile(projection)} do
      {%Surface{} = surface, %HostProfile{} = profile} -> {:ok, surface, profile}
      {nil, _profile} -> {:error, :surface_not_initialized}
      {_surface, nil} -> {:error, :host_profile_not_initialized}
      _invalid -> {:error, :invalid_admission_foundations}
    end
  end

  defp decision_view(projection, surface, profile) do
    %DecisionContext{
      meter_accounts: %{},
      host_profile_ref: profile.ref,
      surface_revision: surface.revision,
      authority_revision: projection.revision
    }
  end

  defp with_meter_accounts(view, projection, {:ok, authority}) do
    accounts =
      case Projection.meter_accounts(projection, Authority.Effective.ref(authority)) do
        {:ok, accounts} -> accounts
        {:error, _reason} -> %{}
      end

    %{view | meter_accounts: accounts}
  end

  defp with_meter_accounts(view, _projection, _resolution), do: view

  defp bind_submission_context(attrs, context, candidate) do
    attrs
    |> Map.put(:candidate_class, candidate.class)
    |> Map.merge(SubmissionContext.decision_bindings(context))
  end

  defp normalize_evidence_refs(refs), do: refs |> Enum.uniq() |> Enum.sort()
end
