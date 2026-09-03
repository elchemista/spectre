defmodule Spectre.Duty.Derive do
  @moduledoc """
  Pure derivation of normative Duty causes from canonical facts.

  A Duty does not depend on a best-effort "open duty" append having succeeded.
  This module recomputes stable causes from Acts, Attempts and Outcomes, allowing
  recovery to retain containment and retry materialization idempotently.

  The principal built-in cause is an Attempt whose observation window elapsed
  without a definitive Outcome. Application gaps are declared by canonical
  Evidence from sources named by the Constitution; this module does not infer
  application quality or invent domain policy.

  The public boundary accepts only a replayed `Spectre.GovernedAct.State`.
  `Spectre.Duty.Derive.Facts` prepares the few indexes needed here while
  preserving every durable record as a struct. Canonical maps are therefore
  decoded exactly once during replay, never guessed inside the Duty algebra.
  """

  @definitive_outcomes [:succeeded, :failed, :definitive_no_effect]

  alias Spectre.{
    Act,
    Attempt,
    Candidate,
    Condition,
    Constitution,
    Erasure,
    Evidence,
    Outcome,
    Presentation
  }

  alias Spectre.Duty.Derive.Facts
  alias Spectre.Duty.EvidenceCause
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Recognition
  alias Spectre.Outcome.Attestation
  alias Spectre.Scope.Opening

  @type cause :: %{
          required(:cause_key) => term(),
          required(:cause_class) => atom() | String.t(),
          required(:causal_refs) => map(),
          optional(atom()) => term()
        }

  @doc """
  Returns every distinct Duty cause implied by replayed `state` at trusted
  `time`. Existing Duty records do not erase their cause, so the result remains
  useful to an auditor. Use `missing_openings/3` for recovery materialization.
  """
  @spec required_duties(State.t(), map(), integer()) :: [cause()]
  def required_duties(%State{} = state, constitution, time)
      when is_map(constitution) and is_integer(time) do
    state
    |> Facts.from_state()
    |> derive_required_duties(constitution, time)
  end

  def required_duties(_state, _constitution, _time), do: []

  defp derive_required_duties(%Facts{} = facts, constitution, time) do
    ambiguous = ambiguous_attempt_causes(facts, constitution, time)
    contradicted = contradicted_outcome_causes(facts, constitution, time)
    disputed = disputed_evidence_causes(facts, constitution, time)
    overdue_scopes = overdue_scope_causes(facts, constitution, time)
    erasure_debts = erasure_verifiability_causes(facts, constitution, time)
    evidence_causes = evidence_causes(facts, constitution, time)

    (ambiguous ++
       contradicted ++
       disputed ++
       overdue_scopes ++
       erasure_debts ++
       evidence_causes)
    |> Enum.reduce(%{}, fn cause, unique -> Map.put_new(unique, cause.cause_key, cause) end)
    |> Map.values()
    |> Enum.sort_by(&stable_sort_key(&1.cause_key))
  end

  @doc """
  Returns derived causes which have no durable Duty record yet.

  Both open and disposed records count as materialized. If an opening append was
  lost or ambiguous, its key is absent and the same cause is returned again.
  """
  @spec missing_openings(State.t(), map(), integer()) :: [cause()]
  def missing_openings(%State{} = state, constitution, time)
      when is_map(constitution) and is_integer(time) do
    facts = Facts.from_state(state)

    existing =
      facts.duties
      |> Enum.map(& &1.cause_key)
      |> MapSet.new()

    facts
    |> derive_required_duties(constitution, time)
    |> Enum.reject(&MapSet.member?(existing, &1.cause_key))
  end

  def missing_openings(_state, _constitution, _time), do: []

  @doc "Returns the stable identity of a derived cause."
  @spec cause_key(cause() | map()) :: term()
  def cause_key(cause) when is_map(cause), do: Map.get(cause, :cause_key)
  def cause_key(_cause), do: nil

  @doc false
  @spec available_evidence_at(State.t(), integer()) :: [Evidence.t()]
  def available_evidence_at(%State{} = state, time) when is_integer(time) do
    facts = Facts.from_state(state)
    unavailable = unavailable_evidence_at(facts, time)

    facts.evidence
    |> records_available_at(facts, :evidence, time)
    |> Enum.reject(&MapSet.member?(unavailable, &1.ref))
  end

  def available_evidence_at(_facts, _time), do: []

  @doc """
  Converts a cause into the exact attributes accepted by `Spectre.Duty.new/1`.

  The cause's `:required_at` becomes `opened_at`; the explicit time is only a
  fallback for an external cause without a canonical timestamp. A delayed
  append therefore cannot pretend that the historical gap started later.
  """
  @spec materialization_attrs(cause(), integer()) :: map()
  def materialization_attrs(cause, fallback_opened_at)
      when is_map(cause) and is_integer(fallback_opened_at) do
    causal_refs = Map.get(cause, :causal_refs, %{})
    opened_at = required_at(cause, fallback_opened_at)
    accountable = Map.get(cause, :accountable_ref)

    %{
      cause_key: Map.get(cause, :cause_key),
      class: Map.get(cause, :cause_class),
      act_ref: Map.get(cause, :act_ref) || Map.get(causal_refs, "act_ref"),
      attempt_ref: Map.get(causal_refs, "attempt_ref"),
      mandate_ref: Map.get(cause, :mandate_ref),
      subjects: Map.get(cause, :subject_refs, []),
      accountable: accountable,
      evidence_refs: Map.get(cause, :known_evidence_refs, []),
      missing: Map.get(cause, :missing_evidence, []),
      containment: Map.get(cause, :containment, %{}),
      closing_conditions: Map.get(cause, :closing_conditions, []),
      disposition_authority_refs: cause |> Map.get(:disposition_authority) |> authority_refs(),
      conflict_refs: Map.get(cause, :conflict_refs, conflict_refs(accountable, [], nil)),
      opened_at: opened_at,
      status: :open,
      disposition_act_ref: nil
    }
  end

  @doc """
  Derives the canonical built-in Duty cause for an ambiguous or contradicted Outcome.

  Both live observation and ledger recovery use this constructor. The cause time
  is the Outcome's trusted observation time, so delayed materialization cannot
  rewrite when the Duty became required.
  """
  @spec outcome_cause(Act.t(), Attempt.t(), Outcome.t(), map(), integer()) ::
          {:ok, cause()} | {:error, term()}
  def outcome_cause(
        %Act{} = act,
        %Attempt{} = attempt,
        %Outcome{} = outcome,
        constitution,
        recorded_at
      )
      when is_map(constitution) and is_integer(recorded_at) do
    status = outcome.status
    correction? = present?(outcome.contradicts_outcome_ref)

    with true <- status == :ambiguous or correction?,
         true <- attempt.act_ref == act.ref,
         true <- outcome.act_ref == act.ref,
         true <- outcome.attempt_ref == attempt.ref do
      kind = if correction?, do: :correction, else: :ambiguous
      build_outcome_cause(kind, act, attempt, outcome, constitution, recorded_at)
    else
      false -> {:error, :invalid_duty_outcome_cause}
    end
  end

  def outcome_cause(_act, _attempt, _outcome, _constitution, _recorded_at),
    do: {:error, :invalid_duty_outcome_cause}

  defp build_outcome_cause(:ambiguous, act, attempt, outcome, constitution, observed_at) do
    case observation_deadline(attempt, act) do
      {:ok, deadline} when observed_at > deadline ->
        {:ok, ambiguous_timeout_cause(act, attempt, [], deadline, constitution)}

      _before_or_without_deadline ->
        {:ok, outcome_duty_cause(:ambiguous, act, attempt, outcome, constitution, observed_at)}
    end
  end

  defp build_outcome_cause(:correction, act, attempt, outcome, constitution, observed_at) do
    {:ok, outcome_duty_cause(:correction, act, attempt, outcome, constitution, observed_at)}
  end

  defp ambiguous_attempt_causes(facts, constitution, time) do
    Enum.flat_map(facts.attempts, fn %Attempt{} = attempt ->
      act = Map.get(facts.acts_by_ref, attempt.act_ref)
      outcomes = Map.get(facts.outcomes_by_attempt, attempt.ref, [])

      with %Act{} = act <- act,
           {:ok, deadline} <- observation_deadline(attempt, act),
           ambiguous_outcome =
             first_outcome(facts, outcomes, :ambiguous, min(time, deadline)),
           ambiguous_at = outcome_time_value(facts, ambiguous_outcome),
           {:ok, required_at} <- ambiguity_required_at(ambiguous_at, deadline, time),
           false <-
             is_nil(ambiguous_at) and definitive_outcome_by?(facts, outcomes, deadline) do
        case ambiguous_outcome do
          nil ->
            timely_outcomes = Enum.filter(outcomes, &observed_by?(facts, &1, deadline))

            [
              ambiguous_timeout_cause(
                act,
                attempt,
                timely_outcomes,
                required_at,
                constitution
              )
            ]

          outcome ->
            case Facts.metadata(facts, :outcome, outcome.ref) do
              {:ok, metadata} ->
                case outcome_cause(act, attempt, outcome, constitution, metadata.recorded_at) do
                  {:ok, cause} -> [Map.put(cause, :required_at, required_at)]
                  {:error, _reason} -> []
                end

              {:error, :missing_event_metadata} ->
                []
            end
        end
      else
        _other -> []
      end
    end)
  end

  defp contradicted_outcome_causes(facts, constitution, time) do
    facts.outcomes
    |> Enum.filter(&(present?(&1.contradicts_outcome_ref) and observed_by?(facts, &1, time)))
    |> Enum.flat_map(fn %Outcome{} = outcome ->
      with %Act{} = act <- Map.get(facts.acts_by_ref, outcome.act_ref),
           %Attempt{} = attempt <- Map.get(facts.attempts_by_ref, outcome.attempt_ref),
           {:ok, metadata} <- Facts.metadata(facts, :outcome, outcome.ref),
           {:ok, cause} <-
             outcome_cause(act, attempt, outcome, constitution, metadata.recorded_at) do
        [cause]
      else
        _missing_or_invalid -> []
      end
    end)
  end

  defp disputed_evidence_causes(facts, constitution, time) do
    (mandate_evidence_dispute_causes(facts, constitution, time) ++
       presentation_evidence_dispute_causes(facts, constitution, time) ++
       outcome_evidence_dispute_causes(facts, constitution, time))
    |> deduplicate_evidence_disputes()
  end

  defp mandate_evidence_dispute_causes(facts, constitution, time) do
    Enum.flat_map(facts.acts, fn %Act{} = act ->
      with {:ok, mandate} <- Map.fetch(facts.mandates_by_ref, act.mandate_ref),
           {:ok, act_metadata} <- Facts.metadata(facts, :act, act.ref),
           true <- act.recognition_evidence_refs != [] do
        historical = evidence_recorded_through(facts, act_metadata.revision)

        mandate.conditions
        |> Enum.flat_map(fn condition ->
          condition_disputes(
            condition,
            act,
            act.recognition_evidence_refs,
            historical,
            facts,
            constitution,
            act.committed_at,
            act_metadata.revision,
            time
          )
        end)
      else
        _not_applicable -> []
      end
    end)
  end

  defp condition_disputes(
         condition,
         act,
         recognition_evidence_refs,
         historical,
         facts,
         constitution,
         committed_at,
         act_revision,
         time
       )
       when is_map(condition) do
    case Recognition.check_with_basis([condition], historical, committed_at) do
      {:satisfied, basis_refs} ->
        used_refs = Enum.filter(basis_refs, &(&1 in recognition_evidence_refs))
        used_refs = MapSet.new(used_refs)
        used = Enum.filter(historical, &MapSet.member?(used_refs, &1.ref))

        facts.evidence
        |> Enum.filter(
          &evidence_dispute?(
            &1,
            used,
            recognition_evidence_refs,
            condition,
            facts,
            act_revision,
            time
          )
        )
        |> Enum.map(
          &disputed_evidence_cause(
            act,
            condition,
            recognition_evidence_refs,
            &1,
            facts,
            constitution
          )
        )

      _not_satisfied ->
        []
    end
  end

  defp condition_disputes(
         _condition,
         _act,
         _recognition_evidence_refs,
         _historical,
         _all_evidence,
         _constitution,
         _committed_at,
         _act_revision,
         _time
       ),
       do: []

  defp evidence_dispute?(
         evidence,
         used,
         recognition_evidence_refs,
         condition,
         facts,
         act_revision,
         time
       ) do
    with false <- evidence.ref in recognition_evidence_refs,
         {:ok, metadata} <- Facts.metadata(facts, :evidence, evidence.ref),
         true <- metadata.revision > act_revision and metadata.recorded_at <= time,
         true <- opposite_to_used?(evidence, used) do
      Recognition.qualified?(
        evidence,
        condition,
        evidence_recorded_through(facts, metadata.revision),
        metadata.recorded_at
      )
    else
      _not_a_dispute -> false
    end
  end

  defp opposite_to_used?(evidence, used) do
    Enum.any?(used, fn prior ->
      prior.proposition == evidence.proposition and
        opposite_stance?(prior.stance, evidence.stance)
    end)
  end

  defp opposite_stance?(:supports, :contradicts), do: true
  defp opposite_stance?(:contradicts, :supports), do: true
  defp opposite_stance?(_left, _right), do: false

  defp disputed_evidence_cause(
         act,
         condition,
         recognition_evidence_refs,
         evidence,
         facts,
         constitution
       ) do
    condition_ref = condition.ref
    {:ok, metadata} = Facts.metadata(facts, :evidence, evidence.ref)
    contemporaneous = evidence_recorded_through(facts, metadata.revision)

    {_result, current_basis_refs} =
      Recognition.check_with_basis([condition], contemporaneous, metadata.recorded_at)

    known_evidence_refs =
      (recognition_evidence_refs ++ current_basis_refs ++ [evidence.ref])
      |> Enum.uniq()
      |> Enum.sort()

    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act.ref, condition_ref, evidence.ref},
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "condition_ref" => condition_ref,
        "evidence_ref" => evidence.ref
      },
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs: known_evidence_refs,
        missing_evidence: [:independent_resolution],
        closing_conditions: configured_closing_conditions(constitution, :disputed_evidence, []),
        required_at: metadata.recorded_at
      }
    )
  end

  defp presentation_evidence_dispute_causes(facts, constitution, time) do
    Enum.flat_map(facts.acts, fn %Act{} = act ->
      with presentation_ref when is_binary(presentation_ref) <- act.presentation_ref,
           true <- act.recognition_evidence_refs != [],
           {:ok, act_metadata} <- Facts.metadata(facts, :act, act.ref),
           {:ok, presentation} <- Map.fetch(facts.presentations_by_ref, presentation_ref),
           true <-
             Facts.recorded_through?(
               facts,
               :presentation,
               presentation.ref,
               act_metadata.revision
             ) do
        historical_evidence =
          facts.evidence
          |> records_recorded_through(facts, :evidence, act_metadata.revision)

        historical_outcomes =
          facts.outcomes
          |> records_recorded_through(facts, :outcome, act_metadata.revision)

        facts
        |> presentation_approval_contexts(
          presentation,
          act.recognition_evidence_refs,
          historical_evidence,
          historical_outcomes,
          act.committed_at,
          act_metadata.revision
        )
        |> Enum.flat_map(
          &presentation_context_disputes(
            &1,
            act,
            act.recognition_evidence_refs,
            facts,
            constitution,
            act_metadata.revision,
            time
          )
        )
      else
        _not_applicable -> []
      end
    end)
  end

  defp presentation_approval_contexts(
         facts,
         presentation,
         recognition_evidence_refs,
         historical_evidence,
         historical_outcomes,
         committed_at,
         act_revision
       ) do
    recognition_evidence_refs = MapSet.new(recognition_evidence_refs)

    historical_evidence
    |> Enum.filter(&MapSet.member?(recognition_evidence_refs, &1.ref))
    |> Enum.sort_by(& &1.ref)
    |> Enum.flat_map(fn approval ->
      with {:ok, approved_presentation_ref, show_act_ref} <-
             Presentation.approval_refs(approval),
           true <- approved_presentation_ref == presentation.ref,
           {:ok, show_act} <- Map.fetch(facts.acts_by_ref, show_act_ref),
           true <- Facts.recorded_through?(facts, :act, show_act.ref, act_revision),
           {:ok, basis_refs} <-
             Presentation.validate_approval_with_basis(
               approval,
               presentation,
               show_act,
               historical_outcomes,
               historical_evidence,
               committed_at
             ),
           true <- Enum.all?(basis_refs, &MapSet.member?(recognition_evidence_refs, &1)) do
        basis_refs_set = MapSet.new(basis_refs)
        basis_evidence = Enum.filter(historical_evidence, &MapSet.member?(basis_refs_set, &1.ref))

        [
          %{
            approval: approval,
            basis_evidence: basis_evidence,
            basis_refs: basis_refs,
            presentation: presentation,
            show_act: show_act
          }
        ]
      else
        _not_approval_or_invalid -> []
      end
    end)
  end

  defp presentation_context_disputes(
         context,
         act,
         recognition_evidence_refs,
         facts,
         constitution,
         act_revision,
         time
       ) do
    ordered_basis =
      Enum.sort_by(context.basis_evidence, fn item ->
        {if(item.ref == context.approval.ref, do: 0, else: 1), item.ref}
      end)

    recognition_evidence_refs_set = MapSet.new(recognition_evidence_refs)

    Enum.flat_map(facts.evidence, fn %Evidence{} = evidence ->
      with {:ok, evidence_revision, recorded_at} <-
             later_record(facts, evidence, act_revision, time),
           false <- MapSet.member?(recognition_evidence_refs_set, evidence.ref),
           %Evidence{} = prior <- Enum.find(ordered_basis, &opposite_evidence?(&1, evidence)),
           prefix_evidence <-
             facts.evidence
             |> records_recorded_through(facts, :evidence, evidence_revision),
           prefix_outcomes <-
             facts.outcomes
             |> records_recorded_through(facts, :outcome, evidence_revision),
           {:ok, counter_basis_refs} <-
             validate_presentation_counter(
               evidence,
               prior,
               context,
               prefix_evidence,
               prefix_outcomes,
               recorded_at
             ) do
        [
          presentation_disputed_evidence_cause(
            act,
            context,
            prior.ref,
            evidence.ref,
            recognition_evidence_refs ++ counter_basis_refs,
            constitution,
            recorded_at
          )
        ]
      else
        _not_a_dispute -> []
      end
    end)
  end

  defp validate_presentation_counter(
         evidence,
         %Evidence{ref: approval_ref},
         %{approval: %Evidence{ref: approval_ref}} = context,
         prefix_evidence,
         prefix_outcomes,
         recorded_at
       ) do
    Presentation.validate_approval_contradiction_with_basis(
      evidence,
      context.presentation,
      context.show_act,
      prefix_outcomes,
      prefix_evidence,
      recorded_at
    )
  end

  defp validate_presentation_counter(
         evidence,
         _prior,
         context,
         prefix_evidence,
         _prefix_outcomes,
         recorded_at
       ) do
    Presentation.validate_assumption_contradiction_with_basis(
      evidence,
      context.approval,
      context.presentation,
      prefix_evidence,
      recorded_at
    )
  end

  defp presentation_disputed_evidence_cause(
         act,
         context,
         prior_evidence_ref,
         evidence_ref,
         known_evidence_refs,
         constitution,
         required_at
       ) do
    presentation_ref = context.presentation.ref

    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act.ref, {:presentation, presentation_ref}, evidence_ref},
      %{
        "act_ref" => act.ref,
        "mandate_ref" => act.mandate_ref,
        "presentation_ref" => presentation_ref,
        "approval_evidence_ref" => context.approval.ref,
        "disputed_evidence_ref" => prior_evidence_ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs:
          normalize_refs(context.basis_refs ++ known_evidence_refs ++ [evidence_ref]),
        missing_evidence: [:independent_resolution],
        closing_conditions: configured_closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end

  defp outcome_evidence_dispute_causes(facts, constitution, time) do
    Enum.flat_map(facts.outcomes, fn %Outcome{} = outcome ->
      with true <- outcome.status in @definitive_outcomes,
           {:ok, outcome_metadata} <- Facts.metadata(facts, :outcome, outcome.ref),
           true <- outcome_metadata.recorded_at <= time,
           {:ok, act} <- Map.fetch(facts.acts_by_ref, outcome.act_ref),
           {:ok, attempt} <- Map.fetch(facts.attempts_by_ref, outcome.attempt_ref),
           true <- attempt.act_ref == act.ref,
           true <- outcome.evidence_refs != [],
           used_evidence when used_evidence != [] <-
             trusted_outcome_evidence(
               facts,
               outcome.evidence_refs,
               outcome,
               act,
               attempt,
               outcome_metadata.revision
             ) do
        Enum.flat_map(facts.evidence, fn evidence ->
          with {:ok, _evidence_revision, recorded_at} <-
                 later_record(facts, evidence, outcome_metadata.revision, time),
               false <- evidence.ref in outcome.evidence_refs,
               true <-
                 trusted_outcome_counter?(
                   evidence,
                   used_evidence,
                   act,
                   attempt,
                   recorded_at
                 ) do
            [
              outcome_disputed_evidence_cause(
                act,
                attempt,
                outcome,
                evidence.ref,
                outcome.evidence_refs,
                constitution,
                recorded_at
              )
            ]
          else
            _not_a_dispute -> []
          end
        end)
      else
        _not_applicable -> []
      end
    end)
  end

  defp trusted_outcome_evidence(
         facts,
         evidence_refs,
         outcome,
         act,
         attempt,
         outcome_revision
       ) do
    trusted =
      facts.evidence
      |> records_recorded_through(facts, :evidence, outcome_revision)
      |> Enum.filter(&(&1.ref in evidence_refs))
      |> Enum.filter(
        &trusted_outcome_attestation?(
          &1,
          outcome.status,
          act,
          attempt,
          outcome.observed_at
        )
      )

    if normalize_refs(Enum.map(trusted, & &1.ref)) == normalize_refs(evidence_refs),
      do: trusted,
      else: []
  end

  defp trusted_outcome_counter?(evidence, used_evidence, act, attempt, recorded_at) do
    Enum.any?(used_evidence, fn prior ->
      opposite_evidence?(prior, evidence) and
        trusted_executor_observation?(evidence, act, attempt, recorded_at)
    end)
  end

  defp trusted_outcome_attestation?(evidence, status, act, attempt, observed_at) do
    if status == :ambiguous,
      do: Attestation.causal?(evidence, act, attempt, observed_at),
      else: Attestation.supports?(evidence, status, act, attempt, observed_at)
  end

  defp trusted_executor_observation?(
         %Evidence{} = evidence,
         %Act{} = act,
         %Attempt{} = attempt,
         time
       ) do
    bindings = %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}

    evidence.provenance == :observed and
      evidence.provisional == false and
      evidence.assumptions == [] and
      evidence.parent_refs == [] and
      evidence.source_ref == act.executor_ref and
      evidence.issuer_ref == act.executor_ref and
      evidence.bindings == bindings and
      evidence.observed_at >= attempt.started_at and
      evidence_current_at?(evidence, time)
  end

  defp evidence_current_at?(%Evidence{} = evidence, time) do
    evidence.observed_at <= time and
      (is_nil(evidence.valid_from) or evidence.valid_from <= time) and
      (is_nil(evidence.valid_until) or time < evidence.valid_until) and
      (is_nil(evidence.freshness_ms) or time - evidence.observed_at <= evidence.freshness_ms)
  end

  defp outcome_disputed_evidence_cause(
         act,
         attempt,
         outcome,
         evidence_ref,
         outcome_evidence_refs,
         constitution,
         required_at
       ) do
    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act.ref, {:outcome, outcome.ref}, evidence_ref},
      %{
        "act_ref" => act.ref,
        "attempt_ref" => attempt.ref,
        "outcome_ref" => outcome.ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs:
          normalize_refs(act.recognition_evidence_refs ++ outcome_evidence_refs ++ [evidence_ref]),
        missing_evidence: [:independent_resolution],
        closing_conditions: configured_closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end

  defp deduplicate_evidence_disputes(causes) do
    causes
    |> Enum.sort_by(fn cause ->
      {
        dispute_lane_rank(cause.cause_key),
        stable_sort_key(cause.cause_key),
        stable_sort_key(cause.causal_refs)
      }
    end)
    |> Enum.reduce(%{}, fn cause, unique ->
      identity = {cause.causal_refs["act_ref"], cause.causal_refs["evidence_ref"]}

      Map.update(unique, identity, cause, fn existing ->
        Map.update!(existing, :known_evidence_refs, fn refs ->
          normalize_refs(refs ++ cause.known_evidence_refs)
        end)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&stable_sort_key(&1.cause_key))
  end

  defp dispute_lane_rank({:disputed_evidence, _act_ref, {:presentation, _ref}, _evidence_ref}),
    do: 1

  defp dispute_lane_rank({:disputed_evidence, _act_ref, {:outcome, _ref}, _evidence_ref}),
    do: 2

  defp dispute_lane_rank(_mandate_condition), do: 0

  defp opposite_evidence?(left, right) do
    left.proposition == right.proposition and opposite_stance?(left.stance, right.stance)
  end

  defp later_record(facts, %Evidence{} = evidence, minimum_revision, time) do
    with {:ok, metadata} <- Facts.metadata(facts, :evidence, evidence.ref),
         true <- metadata.revision > minimum_revision and metadata.recorded_at <= time do
      {:ok, metadata.revision, metadata.recorded_at}
    else
      _not_later -> :error
    end
  end

  defp records_recorded_through(records, facts, kind, revision) do
    Enum.filter(records, &Facts.recorded_through?(facts, kind, &1.ref, revision))
  end

  defp evidence_recorded_through(facts, revision),
    do: records_recorded_through(facts.evidence, facts, :evidence, revision)

  defp overdue_scope_causes(facts, constitution, time) do
    Enum.flat_map(facts.scopes, fn %Opening{} = opening ->
      eligible? =
        opening.kind in [:work, :vigil] and is_integer(opening.due_at) and
          time >= opening.due_at and match?(%Condition{}, opening.promise_condition)

      if eligible? and
           not scope_promise_satisfied?(opening.promise_condition, facts, opening.due_at) do
        source_act = Map.get(facts.acts_by_ref, opening.source_act_ref)

        [
          duty_cause(
            :scope_promise_overdue,
            {:scope_promise_overdue, opening.ref},
            %{"scope_ref" => opening.ref, "act_ref" => opening.source_act_ref},
            constitution,
            %{
              act: source_act,
              act_ref: opening.source_act_ref,
              mandate_ref: act_field(source_act, :mandate_ref),
              subject_refs: act_field(source_act, :subject_refs, []),
              accountable_ref: opening.accountable_ref,
              missing_evidence: [%{"condition_ref" => opening.promise_condition.ref}],
              closing_conditions: [Condition.canonical(opening.promise_condition)],
              disposition_authority: opening.disposition_authority_refs,
              required_at: opening.due_at
            }
          )
        ]
      else
        []
      end
    end)
  end

  defp scope_promise_satisfied?(condition, facts, due_at) do
    Recognition.check([condition], available_evidence(facts, due_at), due_at) == :satisfied
  end

  defp available_evidence(%Facts{} = facts, time) do
    unavailable = unavailable_evidence_at(facts, time)

    facts.evidence
    |> records_available_at(facts, :evidence, time)
    |> Enum.reject(&MapSet.member?(unavailable, &1.ref))
  end

  defp unavailable_evidence_at(facts, time) do
    prefix = %{
      evidence: facts.evidence |> records_available_at(facts, :evidence, time) |> index_by_ref(),
      presentations:
        facts.presentations
        |> records_available_at(facts, :presentation, time)
        |> index_by_ref(),
      acts: facts.acts |> records_available_at(facts, :act, time) |> index_by_ref(),
      attempts: facts.attempts |> records_available_at(facts, :attempt, time) |> index_by_ref(),
      outcomes: facts.outcomes |> records_available_at(facts, :outcome, time) |> index_by_ref(),
      duties: facts.duties |> records_available_at(facts, :duty, time) |> index_by_ref(),
      erasures: facts.erasures |> records_available_at(facts, :erasure, time) |> index_by_ref()
    }

    Spectre.Erasure.Analysis.unavailable_evidence_refs(prefix)
  end

  defp records_available_at(records, facts, kind, time),
    do: Enum.filter(records, &Facts.available_at?(facts, kind, &1.ref, time))

  defp index_by_ref(records), do: Map.new(records, &{&1.ref, &1})

  defp erasure_verifiability_causes(facts, constitution, time) do
    Enum.flat_map(facts.erasures, fn %Erasure{} = erasure ->
      with true <- erasure.reduces_verifiability,
           %Act{} = act <- Map.get(facts.acts_by_ref, erasure.source_act_ref),
           {:ok, attempt, outcome} <-
             succeeded_erasure_outcome(facts, erasure.source_act_ref, time) do
        [
          duty_cause(
            :erasure_reduces_verifiability,
            {:erasure_reduces_verifiability, erasure.ref, act.ref, attempt.ref, outcome.ref},
            %{
              "erasure_ref" => erasure.ref,
              "act_ref" => act.ref,
              "attempt_ref" => attempt.ref,
              "outcome_ref" => outcome.ref
            },
            constitution,
            %{
              act: act,
              act_ref: act.ref,
              mandate_ref: act.mandate_ref,
              subject_refs: act.subject_refs,
              accountable_ref: act.accountable_ref,
              known_evidence_refs: outcome.evidence_refs,
              missing_evidence: [:continued_verifiability],
              required_at: outcome.observed_at
            }
          )
        ]
      else
        _not_confirmed -> []
      end
    end)
  end

  defp succeeded_erasure_outcome(facts, act_ref, time) do
    outcomes =
      facts.outcomes
      |> Enum.filter(fn %Outcome{} = outcome ->
        outcome.act_ref == act_ref and outcome.status == :succeeded and
          observed_by?(facts, outcome, time)
      end)
      |> Enum.sort_by(&stable_sort_key/1)

    Enum.find_value(outcomes, :not_found, fn %Outcome{} = outcome ->
      case Map.get(facts.attempts_by_ref, outcome.attempt_ref) do
        nil -> nil
        attempt -> if attempt.act_ref == act_ref, do: {:ok, attempt, outcome}
      end
    end)
  end

  defp evidence_causes(facts, constitution, time) do
    Enum.flat_map(facts.evidence, fn %Evidence{} = evidence ->
      with {:ok, metadata} <- Facts.metadata(facts, :evidence, evidence.ref),
           true <- evidence_cause_known_by?(metadata.recorded_at, evidence, time),
           {:ok, marker} <- EvidenceCause.extract(evidence, constitution) do
        [
          duty_cause(
            marker.class,
            EvidenceCause.cause_key(evidence, marker),
            %{"evidence_ref" => evidence.ref},
            constitution,
            %{
              mandate_ref: marker.mandate_ref,
              subject_refs: marker.subject_refs,
              accountable_ref: marker.accountable_ref,
              known_evidence_refs: normalize_refs([evidence.ref | marker.related_evidence_refs]),
              missing_evidence: marker.missing,
              required_at: metadata.recorded_at
            }
          )
        ]
      else
        _not_a_cause_or_not_yet_known -> []
      end
    end)
  end

  defp evidence_cause_known_by?(recorded_at, %Evidence{} = evidence, time) do
    is_integer(recorded_at) and recorded_at <= time and evidence.observed_at <= time
  end

  defp duty_cause(class, key, causal_refs, constitution, attrs) do
    rule = duty_rule(constitution, class)
    accountable_ref = Map.get(attrs, :accountable_ref)
    act = Map.get(attrs, :act)

    configured_containment =
      Map.get(attrs, :containment) || Constitution.rule_value(rule, :containment, %{})

    containment =
      if class in [:ambiguous_outcome, :contradicted_outcome, :disputed_evidence] do
        hard_containment(configured_containment, Map.get(attrs, :act))
      else
        canonical_string_keys(configured_containment)
      end

    configured_conflicts =
      [
        Map.get(attrs, :mandate_ref)
        | listify(Constitution.rule_value(rule, :conflict_refs, []))
      ]

    conflict_refs = conflict_refs(accountable_ref, configured_conflicts, act)

    %{
      cause_key: key,
      cause_class: class,
      causal_refs: causal_refs,
      act_ref: Map.get(attrs, :act_ref),
      mandate_ref: Map.get(attrs, :mandate_ref),
      subject_refs: Map.get(attrs, :subject_refs, []),
      accountable_ref: accountable_ref,
      known_evidence_refs: Map.get(attrs, :known_evidence_refs, []),
      missing_evidence: Map.get(attrs, :missing_evidence, []),
      containment: containment,
      closing_conditions:
        Map.get(attrs, :closing_conditions) ||
          Constitution.rule_value(rule, :closing_conditions, []) || [],
      disposition_authority:
        Map.get(attrs, :disposition_authority) ||
          Constitution.rule_value(rule, :disposition_authority_refs),
      conflict_refs: conflict_refs,
      required_at: Map.get(attrs, :required_at),
      condition_met: Map.get(attrs, :condition_met, false),
      condition_evidence_ref: Map.get(attrs, :condition_evidence_ref)
    }
  end

  @doc false
  @spec conflict_refs(String.t() | nil, term(), Act.t() | nil) :: [String.t()]
  def conflict_refs(accountable_ref, configured_refs, act) do
    ([accountable_ref] ++ authority_refs(configured_refs) ++ causal_role_refs(act))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp causal_role_refs(%Act{} = act) do
    [
      act.mandate_ref,
      act.proposer_ref,
      act.authenticated_principal_ref,
      act.executor_ref,
      act.authorizer_ref,
      act.accountable_ref
    ] ++
      act.subject_refs ++ act.target_refs
  end

  defp causal_role_refs(_act), do: []

  defp outcome_duty_cause(
         :ambiguous,
         %Act{} = act,
         %Attempt{} = attempt,
         %Outcome{} = outcome,
         constitution,
         required_at
       ) do
    duty_cause(
      :ambiguous_outcome,
      {:ambiguous_outcome, act.ref, attempt.ref},
      %{
        "act_ref" => act.ref,
        "attempt_ref" => attempt.ref,
        "outcome_ref" => outcome.ref
      },
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs: outcome.evidence_refs,
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          configured_closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt.ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp outcome_duty_cause(
         :correction,
         %Act{} = act,
         %Attempt{} = attempt,
         %Outcome{} = outcome,
         constitution,
         required_at
       ) do
    duty_cause(
      :contradicted_outcome,
      {:contradicted_outcome, act.ref, attempt.ref, outcome.ref},
      %{
        "act_ref" => act.ref,
        "attempt_ref" => attempt.ref,
        "outcome_ref" => outcome.ref,
        "corrected_outcome_ref" => outcome.contradicts_outcome_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs: outcome.evidence_refs,
        missing_evidence: [:reconciliation],
        closing_conditions:
          configured_closing_conditions(constitution, :contradicted_outcome, []),
        required_at: required_at
      }
    )
  end

  defp ambiguous_timeout_cause(
         %Act{} = act,
         %Attempt{} = attempt,
         outcomes,
         required_at,
         constitution
       ) do
    duty_cause(
      :ambiguous_outcome,
      {:ambiguous_outcome, act.ref, attempt.ref},
      %{"act_ref" => act.ref, "attempt_ref" => attempt.ref},
      constitution,
      %{
        act: act,
        act_ref: act.ref,
        mandate_ref: act.mandate_ref,
        subject_refs: act.subject_refs,
        accountable_ref: act.accountable_ref,
        known_evidence_refs: outcome_evidence_refs(outcomes),
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          configured_closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt.ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp configured_closing_conditions(constitution, class, default) do
    constitution
    |> duty_rule(class)
    |> Constitution.rule_value(:closing_conditions, default)
  end

  defp hard_containment(configured, %Act{} = act) do
    consequence_digest =
      case Candidate.effect_digest(act) do
        {:ok, digest} -> digest
        {:error, _reason} -> nil
      end

    configured
    |> canonical_string_keys()
    |> ensure_plain_map()
    |> Map.merge(%{
      "consequence_digest" => consequence_digest,
      "meter_reservations" => act.reservations,
      "dispatch" => :blocked,
      "retry" => :forbidden
    })
  end

  defp hard_containment(configured, nil) do
    configured
    |> canonical_string_keys()
    |> ensure_plain_map()
    |> Map.merge(%{
      "consequence_digest" => nil,
      "meter_reservations" => %{},
      "dispatch" => :blocked,
      "retry" => :forbidden
    })
  end

  defp ensure_plain_map(value) when is_map(value) and not is_struct(value), do: value
  defp ensure_plain_map(_value), do: %{}

  defp canonical_string_keys(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {key, _value} ->
      {if(is_binary(key), do: 1, else: 0), stable_sort_key(key)}
    end)
    |> Enum.reduce(%{}, fn {key, item}, normalized ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      Map.put(normalized, key, canonical_string_keys(item))
    end)
  end

  defp canonical_string_keys(value) when is_list(value),
    do: Enum.map(value, &canonical_string_keys/1)

  defp canonical_string_keys(value), do: value

  defp observation_deadline(%Attempt{} = attempt, %Act{} = act),
    do: {:ok, attempt.started_at + act.observation_window_ms}

  defp definitive_outcome_by?(facts, outcomes, deadline) do
    Enum.any?(outcomes, fn outcome ->
      definitive_outcome?(outcome) and observed_by?(facts, outcome, deadline)
    end)
  end

  defp first_outcome(facts, outcomes, status, time) do
    outcomes
    |> Enum.filter(&(&1.status == status))
    |> Enum.filter(&observed_by?(facts, &1, time))
    |> Enum.min_by(
      fn outcome -> {outcome_time_value(facts, outcome), outcome.ref} end,
      fn -> nil end
    )
  end

  defp ambiguity_required_at(ambiguous_at, deadline, _time) when is_integer(ambiguous_at),
    do: {:ok, min(ambiguous_at, deadline)}

  defp ambiguity_required_at(nil, deadline, time) do
    if at_or_after?(time, deadline), do: {:ok, deadline}, else: :not_required
  end

  defp definitive_outcome?(%Outcome{status: status}), do: status in @definitive_outcomes

  defp observed_by?(facts, %Outcome{} = outcome, deadline) do
    case Facts.metadata(facts, :outcome, outcome.ref) do
      {:ok, metadata} -> metadata.recorded_at <= deadline
      {:error, :missing_event_metadata} -> false
    end
  end

  defp outcome_time_value(facts, %Outcome{} = outcome) do
    case Facts.metadata(facts, :outcome, outcome.ref) do
      {:ok, metadata} -> metadata.recorded_at
      {:error, :missing_event_metadata} -> nil
    end
  end

  defp outcome_time_value(_facts, nil), do: nil

  defp outcome_evidence_refs(outcomes) do
    outcomes
    |> Enum.flat_map(& &1.evidence_refs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp duty_rule(constitution, class) do
    Constitution.duty_rule(constitution, class)
  end

  defp authority_refs(nil), do: []
  defp authority_refs(value) when is_binary(value), do: [value]
  defp authority_refs(value) when is_list(value), do: Enum.filter(value, &is_binary/1)

  defp authority_refs(_value), do: []

  defp at_or_after?(left, right), do: is_integer(left) and is_integer(right) and left >= right

  defp required_at(cause, fallback) do
    case Map.get(cause, :required_at) do
      value when is_integer(value) -> value
      _missing -> fallback
    end
  end

  defp stable_sort_key(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp normalize_refs(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp listify(nil), do: []
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp act_field(act, field, default \\ nil)
  defp act_field(%Act{} = act, field, default), do: Map.get(act, field, default)
  defp act_field(nil, _field, default), do: default
end
