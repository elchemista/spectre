defmodule Spectre.Duty.Derive do
  @moduledoc """
  Pure derivation of normative Duty causes from canonical facts.

  A Duty does not depend on a best-effort "open duty" append having succeeded.
  This module recomputes stable causes from Acts, Attempts and Outcomes, allowing
  recovery to retain containment and retry materialization idempotently.

  The principal built-in cause is an Attempt whose observation window elapsed
  without a definitive Outcome. Additional domain gaps are accepted only when a
  canonical fact marks them explicitly; this module does not infer application
  quality or invent domain policy.
  """

  @definitive_outcomes [:succeeded, :failed, :definitive_no_effect]

  alias Spectre.{Act, Candidate, Evidence, Outcome, Presentation}
  alias Spectre.Kernel.Recognition

  @type cause :: %{
          required(:cause_key) => term(),
          required(:cause_class) => atom() | String.t(),
          required(:causal_refs) => map(),
          optional(atom()) => term()
        }

  @doc """
  Returns every distinct Duty cause implied by `facts` at trusted `time`.

  `facts` may be a projection exposing `:acts`, `:attempts`, `:outcomes`,
  `:duties` and `:gaps`, or a list of ledger entry envelopes. Existing Duty
  records do not erase their cause, so the result remains useful to an auditor.
  Use `missing_openings/3` for recovery materialization.
  """
  @spec required_duties(map() | list(), map(), term()) :: [cause()]
  def required_duties(facts, constitution, time) when is_map(constitution) do
    facts = normalize_facts(facts)

    ambiguous = ambiguous_attempt_causes(facts, constitution, time)
    contradicted = contradicted_outcome_causes(facts, constitution, time)
    disputed = disputed_evidence_causes(facts, constitution, time)
    overdue_scopes = overdue_scope_causes(facts, constitution, time)
    erasure_debts = erasure_verifiability_causes(facts, constitution, time)
    explicit = explicit_causes(facts, constitution, time)

    (ambiguous ++ contradicted ++ disputed ++ overdue_scopes ++ erasure_debts ++ explicit)
    |> Enum.reduce(%{}, fn cause, unique -> Map.put_new(unique, cause.cause_key, cause) end)
    |> Map.values()
    |> Enum.sort_by(&stable_sort_key(&1.cause_key))
  end

  def required_duties(_facts, _constitution, _time), do: []

  @doc """
  Returns derived causes which have no durable Duty record yet.

  Both open and disposed records count as materialized. If an opening append was
  lost or ambiguous, its key is absent and the same cause is returned again.
  """
  @spec missing_openings(map() | list(), map(), term()) :: [cause()]
  def missing_openings(facts, constitution, time) do
    normalized = normalize_facts(facts)

    existing =
      normalized.duties
      |> Enum.map(&get(&1, [:cause_key]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    facts
    |> required_duties(constitution, time)
    |> Enum.reject(&MapSet.member?(existing, &1.cause_key))
  end

  @doc "Returns the stable identity of a derived cause."
  @spec cause_key(cause() | map()) :: term()
  def cause_key(cause) when is_map(cause), do: get(cause, [:cause_key, :key])
  def cause_key(_cause), do: nil

  @doc """
  Converts a cause into the exact attributes accepted by `Spectre.Duty.new/1`.

  The cause's `:required_at` becomes `opened_at`; the explicit time is only a
  fallback for an external cause without a canonical timestamp. A delayed
  append therefore cannot pretend that the historical gap started later.
  """
  @spec materialization_attrs(cause(), integer()) :: map()
  def materialization_attrs(cause, fallback_opened_at)
      when is_map(cause) and is_integer(fallback_opened_at) do
    causal_refs = get(cause, [:causal_refs], %{})
    opened_at = required_at(cause, fallback_opened_at)
    accountable = get(cause, [:accountable_ref, :accountable])

    %{
      cause_key: get(cause, [:cause_key]),
      class: get(cause, [:cause_class, :class]),
      act_ref: get(cause, [:act_ref]) || get(causal_refs, [:act_ref]),
      attempt_ref: get(causal_refs, [:attempt_ref]),
      mandate_ref: get(cause, [:mandate_ref]),
      subjects: get(cause, [:subject_refs, :subjects], []),
      accountable: accountable,
      evidence_refs: get(cause, [:known_evidence_refs, :evidence_refs], []),
      missing: get(cause, [:missing_evidence, :missing], []),
      containment: get(cause, [:containment], %{}),
      closing_conditions: get(cause, [:closing_conditions, :closure_conditions], []),
      disposition_authority_refs:
        cause |> get([:disposition_authority, :disposition_authority_refs]) |> authority_refs(),
      conflict_refs: get(cause, [:conflict_refs], conflict_refs(accountable, [], nil)),
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
  @spec outcome_cause(map(), map(), map(), map()) :: {:ok, cause()} | {:error, term()}
  def outcome_cause(act, attempt, outcome, constitution)
      when is_map(act) and is_map(attempt) and is_map(outcome) and is_map(constitution) do
    act_ref = ref(act, :act)
    attempt_ref = ref(attempt, :attempt)
    outcome_ref = ref(outcome, :outcome)
    status = get(outcome, [:classification, :outcome, :status])
    correction? = present?(get(outcome, [:contradicts_outcome_ref]))

    with true <- status == :ambiguous or correction?,
         true <- present?(act_ref) and present?(attempt_ref) and present?(outcome_ref),
         true <- get(attempt, [:act_ref]) == act_ref,
         true <- get(outcome, [:act_ref]) == act_ref,
         true <- get(outcome, [:attempt_ref]) == attempt_ref,
         {:ok, required_at} <- outcome_time(outcome) do
      kind = if correction?, do: :correction, else: :ambiguous
      build_outcome_cause(kind, act, attempt, outcome, constitution, required_at)
    else
      false -> {:error, :invalid_duty_outcome_cause}
      :error -> {:error, :invalid_duty_outcome_time}
    end
  end

  def outcome_cause(_act, _attempt, _outcome, _constitution),
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
    Enum.flat_map(facts.attempts, fn attempt ->
      attempt_ref = ref(attempt, :attempt)
      act_ref = get(attempt, [:act_ref])
      act = Map.get(facts.acts_by_ref, act_ref)
      outcomes = outcomes_for(facts.outcomes, attempt_ref)

      with true <- present?(attempt_ref) and present?(act_ref),
           {:ok, deadline} <- observation_deadline(attempt, act),
           ambiguous_outcome = first_outcome(outcomes, :ambiguous, min_time(time, deadline)),
           ambiguous_at = outcome_time_value(ambiguous_outcome),
           {:ok, required_at} <- ambiguity_required_at(ambiguous_at, deadline, time),
           false <- is_nil(ambiguous_at) and definitive_outcome_by?(outcomes, deadline) do
        case ambiguous_outcome do
          nil ->
            timely_outcomes = Enum.filter(outcomes, &observed_by?(&1, deadline))

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
            case outcome_cause(act, attempt, outcome, constitution) do
              {:ok, cause} -> [Map.put(cause, :required_at, required_at)]
              {:error, _reason} -> []
            end
        end
      else
        _other -> []
      end
    end)
  end

  defp contradicted_outcome_causes(facts, constitution, time) do
    facts.outcomes
    |> Enum.filter(
      &(present?(get(&1, [:contradicts_outcome_ref])) and
          observed_by?(&1, time))
    )
    |> Enum.flat_map(fn outcome ->
      attempt_ref = get(outcome, [:attempt_ref])
      act_ref = get(outcome, [:act_ref]) || act_ref_for_attempt(facts, attempt_ref)
      outcome_ref = ref(outcome, :outcome)

      if present?(outcome_ref) and present?(act_ref) do
        act = Map.get(facts.acts_by_ref, act_ref, %{})

        case Map.get(facts.attempts_by_ref, attempt_ref) do
          nil ->
            []

          attempt ->
            case outcome_cause(act, attempt, outcome, constitution) do
              {:ok, cause} -> [cause]
              {:error, _reason} -> []
            end
        end
      else
        []
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
    Enum.flat_map(facts.acts, fn act ->
      with act_ref when is_binary(act_ref) <- ref(act, :act),
           mandate_ref when is_binary(mandate_ref) <- get(act, [:mandate_ref]),
           {:ok, mandate} <- Map.fetch(facts.mandates_by_ref, mandate_ref),
           {:ok, committed_at} <- timestamp(get(act, [:committed_at, :ledger_recorded_at])),
           {:ok, act_revision} <- ledger_revision(act),
           recognition_evidence_refs when recognition_evidence_refs != [] <-
             listify(get(act, [:recognition_evidence_refs], [])) do
        historical = evidence_recorded_through(facts.evidence, act_revision)

        mandate
        |> get([:conditions], [])
        |> listify()
        |> Enum.flat_map(fn condition ->
          condition_disputes(
            condition,
            act,
            recognition_evidence_refs,
            historical,
            facts.evidence,
            constitution,
            committed_at,
            act_revision,
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
         all_evidence,
         constitution,
         committed_at,
         act_revision,
         time
       )
       when is_map(condition) do
    case Recognition.check_with_basis([condition], historical, committed_at) do
      {:satisfied, basis_refs} ->
        used_refs = Enum.filter(basis_refs, &(&1 in recognition_evidence_refs))
        used = Enum.filter(historical, &(ref(&1, :evidence) in used_refs))

        all_evidence
        |> Enum.filter(
          &evidence_dispute?(
            &1,
            used,
            recognition_evidence_refs,
            condition,
            all_evidence,
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
            all_evidence,
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
         all_evidence,
         act_revision,
         time
       ) do
    with evidence_ref when is_binary(evidence_ref) <- ref(evidence, :evidence),
         false <- evidence_ref in recognition_evidence_refs,
         {:ok, recorded_at} <- ledger_time(evidence),
         {:ok, evidence_revision} <- ledger_revision(evidence),
         {:ok, current_time} <- timestamp(time),
         true <- evidence_revision > act_revision and recorded_at <= current_time,
         true <- opposite_to_used?(evidence, used) do
      Recognition.qualified?(
        evidence,
        condition,
        evidence_recorded_through(all_evidence, evidence_revision),
        recorded_at
      )
    else
      _not_a_dispute -> false
    end
  end

  defp opposite_to_used?(evidence, used) do
    proposition = get(evidence, [:proposition])
    stance = get(evidence, [:stance])

    Enum.any?(used, fn prior ->
      get(prior, [:proposition]) == proposition and
        opposite_stance?(get(prior, [:stance]), stance)
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
         all_evidence,
         constitution
       ) do
    act_ref = ref(act, :act)
    evidence_ref = ref(evidence, :evidence)
    condition_ref = get(condition, [:ref, :condition_ref])
    {:ok, required_at} = ledger_time(evidence)
    {:ok, evidence_revision} = ledger_revision(evidence)
    contemporaneous = evidence_recorded_through(all_evidence, evidence_revision)

    {_result, current_basis_refs} =
      Recognition.check_with_basis([condition], contemporaneous, required_at)

    known_evidence_refs =
      (recognition_evidence_refs ++ current_basis_refs ++ [evidence_ref])
      |> Enum.uniq()
      |> Enum.sort()

    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act_ref, condition_ref, evidence_ref},
      %{
        "act_ref" => act_ref,
        "mandate_ref" => get(act, [:mandate_ref]),
        "condition_ref" => condition_ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act_ref,
        mandate_ref: get(act, [:mandate_ref]),
        subject_refs: get(act, [:subject_refs, :subjects], []),
        accountable_ref: get(act, [:accountable_ref]),
        known_evidence_refs: known_evidence_refs,
        missing_evidence: [:independent_resolution],
        closing_conditions: configured_closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end

  defp presentation_evidence_dispute_causes(facts, constitution, time) do
    Enum.flat_map(facts.acts, fn act ->
      with act_ref when is_binary(act_ref) <- ref(act, :act),
           presentation_ref when is_binary(presentation_ref) <- get(act, [:presentation_ref]),
           recognition_evidence_refs when recognition_evidence_refs != [] <-
             listify(get(act, [:recognition_evidence_refs], [])),
           {:ok, committed_at} <- timestamp(get(act, [:committed_at, :ledger_recorded_at])),
           {:ok, act_revision} <- ledger_revision(act),
           {:ok, presentation_record} <-
             Map.fetch(facts.presentations_by_ref, presentation_ref),
           true <- recorded_through?(presentation_record, act_revision),
           {:ok, presentation} <- rebuild_presentation(presentation_record) do
        historical_evidence =
          facts.evidence
          |> records_recorded_through(act_revision)
          |> rebuild_evidence_records()

        historical_outcomes =
          facts.outcomes
          |> records_recorded_through(act_revision)
          |> rebuild_outcome_records()

        facts
        |> presentation_approval_contexts(
          presentation,
          recognition_evidence_refs,
          historical_evidence,
          historical_outcomes,
          committed_at,
          act_revision
        )
        |> Enum.flat_map(
          &presentation_context_disputes(
            &1,
            act,
            recognition_evidence_refs,
            facts,
            constitution,
            act_revision,
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
    historical_evidence
    |> Enum.filter(&(&1.ref in recognition_evidence_refs))
    |> Enum.sort_by(& &1.ref)
    |> Enum.flat_map(fn approval ->
      with {:ok, approved_presentation_ref, show_act_ref} <-
             Presentation.approval_refs(approval),
           true <- approved_presentation_ref == presentation.ref,
           {:ok, show_act_record} <- Map.fetch(facts.acts_by_ref, show_act_ref),
           true <- recorded_through?(show_act_record, act_revision),
           {:ok, show_act} <- rebuild_act(show_act_record),
           {:ok, basis_refs} <-
             Presentation.validate_approval_with_basis(
               approval,
               presentation,
               show_act,
               historical_outcomes,
               historical_evidence,
               committed_at
             ),
           true <- Enum.all?(basis_refs, &(&1 in recognition_evidence_refs)) do
        basis_evidence = Enum.filter(historical_evidence, &(&1.ref in basis_refs))

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

    Enum.flat_map(facts.evidence, fn evidence_record ->
      with {:ok, evidence_revision, recorded_at} <-
             later_record(evidence_record, act_revision, time),
           evidence_ref when is_binary(evidence_ref) <- ref(evidence_record, :evidence),
           false <- evidence_ref in recognition_evidence_refs,
           {:ok, evidence} <- rebuild_evidence(evidence_record),
           %Evidence{} = prior <- Enum.find(ordered_basis, &opposite_evidence?(&1, evidence)),
           prefix_evidence <-
             facts.evidence
             |> records_recorded_through(evidence_revision)
             |> rebuild_evidence_records(),
           prefix_outcomes <-
             facts.outcomes
             |> records_recorded_through(evidence_revision)
             |> rebuild_outcome_records(),
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
            evidence_ref,
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
    act_ref = ref(act, :act)
    presentation_ref = context.presentation.ref

    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act_ref, {:presentation, presentation_ref}, evidence_ref},
      %{
        "act_ref" => act_ref,
        "mandate_ref" => get(act, [:mandate_ref]),
        "presentation_ref" => presentation_ref,
        "approval_evidence_ref" => context.approval.ref,
        "disputed_evidence_ref" => prior_evidence_ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act_ref,
        mandate_ref: get(act, [:mandate_ref]),
        subject_refs: get(act, [:subject_refs, :subjects], []),
        accountable_ref: get(act, [:accountable_ref]),
        known_evidence_refs:
          normalize_refs(context.basis_refs ++ known_evidence_refs ++ [evidence_ref]),
        missing_evidence: [:independent_resolution],
        closing_conditions: configured_closing_conditions(constitution, :disputed_evidence, []),
        required_at: required_at
      }
    )
  end

  defp outcome_evidence_dispute_causes(facts, constitution, time) do
    Enum.flat_map(facts.outcomes, fn outcome ->
      status = get(outcome, [:classification, :outcome, :status])
      outcome_ref = ref(outcome, :outcome)
      act_ref = get(outcome, [:act_ref])
      attempt_ref = get(outcome, [:attempt_ref])

      with true <- status in @definitive_outcomes,
           true <- is_binary(outcome_ref) and is_binary(act_ref) and is_binary(attempt_ref),
           {:ok, outcome_revision} <- ledger_revision(outcome),
           {:ok, outcome_recorded_at} <- ledger_time(outcome),
           {:ok, current_time} <- timestamp(time),
           true <- outcome_recorded_at <= current_time,
           {:ok, act} <- Map.fetch(facts.acts_by_ref, act_ref),
           {:ok, attempt} <- Map.fetch(facts.attempts_by_ref, attempt_ref),
           true <- get(attempt, [:act_ref]) == act_ref,
           evidence_refs when evidence_refs != [] <- listify(get(outcome, [:evidence_refs], [])),
           used_evidence when used_evidence != [] <-
             trusted_outcome_evidence(
               facts.evidence,
               evidence_refs,
               outcome,
               act,
               attempt,
               outcome_revision
             ) do
        Enum.flat_map(facts.evidence, fn evidence ->
          with {:ok, _evidence_revision, recorded_at} <-
                 later_record(evidence, outcome_revision, time),
               evidence_ref when is_binary(evidence_ref) <- ref(evidence, :evidence),
               false <- evidence_ref in evidence_refs,
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
                evidence_ref,
                evidence_refs,
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
         all_evidence,
         evidence_refs,
         outcome,
         act,
         attempt,
         outcome_revision
       ) do
    trusted =
      all_evidence
      |> records_recorded_through(outcome_revision)
      |> Enum.filter(&(ref(&1, :evidence) in evidence_refs))
      |> Enum.filter(
        &trusted_outcome_attestation?(
          &1,
          get(outcome, [:classification, :outcome, :status]),
          act,
          attempt,
          get(outcome, [:observed_at])
        )
      )

    if normalize_refs(Enum.map(trusted, &ref(&1, :evidence))) == normalize_refs(evidence_refs),
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
    trusted_executor_observation?(evidence, act, attempt, observed_at) and
      get(evidence, [:proposition]) ==
        Outcome.proposition(
          status,
          ref(act, :act),
          ref(attempt, :attempt),
          get(act, [:executor_contract_ref])
        ) and
      get(evidence, [:stance]) == Outcome.evidence_stance(status)
  end

  defp trusted_executor_observation?(evidence, act, attempt, time) do
    bindings = %{"act_ref" => ref(act, :act), "attempt_ref" => ref(attempt, :attempt)}
    observed_at = get(evidence, [:observed_at])
    started_at = get(attempt, [:started_at])

    get(evidence, [:provenance]) == :observed and
      get(evidence, [:provisional], false) == false and
      get(evidence, [:parent_refs], []) == [] and
      get(evidence, [:source_ref]) == get(act, [:executor_ref]) and
      get(evidence, [:issuer_ref]) == get(act, [:executor_ref]) and
      get(evidence, [:bindings]) == bindings and
      is_integer(observed_at) and is_integer(started_at) and observed_at >= started_at and
      evidence_current_at?(evidence, time)
  end

  defp evidence_current_at?(evidence, time) do
    observed_at = get(evidence, [:observed_at])
    valid_from = get(evidence, [:valid_from])
    valid_until = get(evidence, [:valid_until])
    freshness_ms = get(evidence, [:freshness_ms])

    is_integer(time) and is_integer(observed_at) and observed_at <= time and
      (is_nil(valid_from) or valid_from <= time) and
      (is_nil(valid_until) or time < valid_until) and
      (is_nil(freshness_ms) or
         (is_integer(freshness_ms) and freshness_ms >= 0 and
            time - observed_at <= freshness_ms))
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
    act_ref = ref(act, :act)
    attempt_ref = ref(attempt, :attempt)
    outcome_ref = ref(outcome, :outcome)

    duty_cause(
      :disputed_evidence,
      {:disputed_evidence, act_ref, {:outcome, outcome_ref}, evidence_ref},
      %{
        "act_ref" => act_ref,
        "attempt_ref" => attempt_ref,
        "outcome_ref" => outcome_ref,
        "evidence_ref" => evidence_ref
      },
      constitution,
      %{
        act: act,
        act_ref: act_ref,
        mandate_ref: get(act, [:mandate_ref]),
        subject_refs: get(act, [:subject_refs, :subjects], []),
        accountable_ref: get(act, [:accountable_ref]),
        known_evidence_refs:
          normalize_refs(
            listify(get(act, [:recognition_evidence_refs], [])) ++
              outcome_evidence_refs ++ [evidence_ref]
          ),
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
      causal_refs = get(cause, [:causal_refs], %{})
      identity = {get(causal_refs, [:act_ref]), get(causal_refs, [:evidence_ref])}

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
    get(left, [:proposition]) == get(right, [:proposition]) and
      opposite_stance?(get(left, [:stance]), get(right, [:stance]))
  end

  defp later_record(record, minimum_revision, time) do
    with evidence_ref when is_binary(evidence_ref) <- ref(record, :evidence),
         {:ok, recorded_at} <- ledger_time(record),
         {:ok, revision} <- ledger_revision(record),
         {:ok, current_time} <- timestamp(time),
         true <- revision > minimum_revision and recorded_at <= current_time do
      {:ok, revision, recorded_at}
    else
      _not_later -> :error
    end
  end

  defp recorded_through?(record, revision) do
    case ledger_revision(record) do
      {:ok, record_revision} -> record_revision <= revision
      :error -> false
    end
  end

  defp records_recorded_through(records, revision) do
    Enum.filter(records, &recorded_through?(&1, revision))
  end

  defp evidence_recorded_through(evidence, revision) do
    records_recorded_through(evidence, revision)
  end

  defp rebuild_act(%Act{} = act), do: Act.new(act)

  defp rebuild_act(record) when is_map(record) do
    record
    |> without_ledger_metadata()
    |> Act.new()
  end

  defp rebuild_act(_record), do: {:error, :invalid_act}

  defp rebuild_presentation(%Presentation{} = presentation),
    do: Presentation.new(presentation)

  defp rebuild_presentation(record) when is_map(record) do
    record
    |> without_ledger_metadata()
    |> Presentation.new()
  end

  defp rebuild_presentation(_record), do: {:error, :invalid_presentation}

  defp rebuild_evidence(%Evidence{} = evidence), do: Evidence.new(evidence)

  defp rebuild_evidence(record) when is_map(record) do
    record
    |> without_ledger_metadata()
    |> Evidence.new()
  end

  defp rebuild_evidence(_record), do: {:error, :invalid_evidence}

  defp rebuild_evidence_records(records) do
    Enum.flat_map(records, fn record ->
      case rebuild_evidence(record) do
        {:ok, evidence} -> [evidence]
        {:error, _reason} -> []
      end
    end)
  end

  defp rebuild_outcome(record) when is_map(record) do
    record
    |> without_ledger_metadata()
    |> Outcome.new()
  end

  defp rebuild_outcome(_record), do: {:error, :invalid_outcome}

  defp rebuild_outcome_records(records) do
    Enum.flat_map(records, fn record ->
      case rebuild_outcome(record) do
        {:ok, outcome} -> [outcome]
        {:error, _reason} -> []
      end
    end)
  end

  defp without_ledger_metadata(record) do
    Map.drop(record, [
      :ledger_recorded_at,
      :ledger_revision,
      "ledger_recorded_at",
      "ledger_revision"
    ])
  end

  defp ledger_time(record), do: record |> get([:ledger_recorded_at]) |> timestamp()

  defp ledger_revision(record) do
    case get(record, [:ledger_revision]) do
      revision when is_integer(revision) and revision > 0 -> {:ok, revision}
      _missing -> :error
    end
  end

  defp overdue_scope_causes(facts, constitution, time) do
    Enum.flat_map(facts.scopes, fn opening ->
      kind = get(opening, [:kind])
      due_at = get(opening, [:due_at])
      condition = get(opening, [:promise_condition])
      opening_ref = ref(opening, :scope)

      eligible? =
        kind in [:work, :vigil] and present?(opening_ref) and is_integer(due_at) and
          at_or_after?(time, due_at) and is_map(condition)

      if eligible? and not scope_promise_satisfied?(condition, facts.evidence, due_at) do
        source_act = Map.get(facts.acts_by_ref, get(opening, [:source_act_ref]))

        [
          duty_cause(
            :scope_promise_overdue,
            {:scope_promise_overdue, opening_ref},
            %{"scope_ref" => opening_ref},
            constitution,
            %{
              act: source_act,
              accountable_ref: get(opening, [:accountable_ref]),
              missing_evidence: [%{"condition_ref" => get(condition, [:ref])}],
              closure_conditions: [canonical_condition(condition)],
              disposition_authority: get(opening, [:disposition_authority_refs], []),
              required_at: due_at
            }
          )
        ]
      else
        []
      end
    end)
  end

  defp scope_promise_satisfied?(condition, evidence, due_at) do
    timely =
      Enum.filter(evidence, fn item ->
        case timestamp(get(item, [:ledger_recorded_at, :recorded_at, :observed_at])) do
          {:ok, available_at} -> available_at <= due_at
          :error -> false
        end
      end)

    Recognition.check([condition], timely, due_at) == :satisfied
  end

  defp canonical_condition(%Spectre.Condition{} = condition),
    do: Spectre.Condition.canonical(condition)

  defp canonical_condition(condition), do: condition

  defp erasure_verifiability_causes(facts, constitution, time) do
    Enum.flat_map(facts.erasures, fn erasure ->
      act_ref = get(erasure, [:source_act_ref])
      act = Map.get(facts.acts_by_ref, act_ref)

      with true <- get(erasure, [:reduces_verifiability], false) == true,
           true <- present?(ref(erasure, :erasure)) and not is_nil(act),
           {:ok, attempt, outcome} <- succeeded_erasure_outcome(facts, act_ref, time) do
        erasure_ref = ref(erasure, :erasure)
        attempt_ref = ref(attempt, :attempt)
        outcome_ref = ref(outcome, :outcome)

        [
          duty_cause(
            :erasure_reduces_verifiability,
            {:erasure_reduces_verifiability, erasure_ref, act_ref, attempt_ref, outcome_ref},
            %{
              "erasure_ref" => erasure_ref,
              "act_ref" => act_ref,
              "attempt_ref" => attempt_ref,
              "outcome_ref" => outcome_ref
            },
            constitution,
            %{
              act: act,
              act_ref: act_ref,
              mandate_ref: get(act, [:mandate_ref]),
              subject_refs: get(act, [:subject_refs, :subjects], []),
              accountable_ref: get(act, [:accountable_ref]),
              known_evidence_refs: get(outcome, [:evidence_refs], []),
              missing_evidence: [:continued_verifiability],
              required_at: get(outcome, [:observed_at, :recorded_at])
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
      |> Enum.filter(fn outcome ->
        get(outcome, [:act_ref]) == act_ref and
          get(outcome, [:classification, :outcome, :status]) == :succeeded and
          observed_by?(outcome, time)
      end)
      |> Enum.sort_by(&stable_sort_key/1)

    Enum.find_value(outcomes, :not_found, fn outcome ->
      attempt_ref = get(outcome, [:attempt_ref])

      case Map.get(facts.attempts_by_ref, attempt_ref) do
        nil -> nil
        attempt -> if get(attempt, [:act_ref]) == act_ref, do: {:ok, attempt, outcome}
      end
    end)
  end

  defp explicit_causes(facts, constitution, time) do
    facts.gaps
    |> Enum.map(&active_explicit_cause(&1, constitution, time, facts.acts_by_ref))
    |> Enum.reject(&is_nil/1)
  end

  defp active_explicit_cause(gap, constitution, time, acts_by_ref) do
    if explicit_gap_active?(gap, time), do: explicit_cause(gap, constitution, acts_by_ref)
  end

  defp explicit_cause(gap, constitution, acts_by_ref) do
    class = get(gap, [:cause_class, :duty_class, :gap_class, :class])
    supplied_key = get(gap, [:cause_key, :key])
    causal_refs = get(gap, [:causal_refs, :refs], %{})
    primary_ref = get(gap, [:ref, :gap_ref, :evidence_ref, :act_ref, :attempt_ref])
    act_ref = get(gap, [:act_ref])

    cond do
      not present?(class) ->
        nil

      not present?(supplied_key) and not present?(primary_ref) and empty_map?(causal_refs) ->
        nil

      true ->
        key = supplied_key || {:explicit_gap, class, primary_ref || canonical_pairs(causal_refs)}

        duty_cause(class, key, causal_refs, constitution, %{
          act: Map.get(acts_by_ref, act_ref),
          act_ref: act_ref,
          mandate_ref: get(gap, [:mandate_ref]),
          subject_refs: get(gap, [:subject_refs, :subjects], []),
          accountable_ref: get(gap, [:accountable_ref]),
          known_evidence_refs: get(gap, [:known_evidence_refs, :evidence_refs], []),
          missing_evidence: get(gap, [:missing_evidence], []),
          containment: get(gap, [:containment]),
          closing_conditions: get(gap, [:closing_conditions, :closure_conditions]),
          disposition_authority: get(gap, [:disposition_authority]),
          required_at: get(gap, [:required_at, :occurred_at, :recorded_at])
        })
    end
  end

  defp duty_cause(class, key, causal_refs, constitution, attrs) do
    rule = duty_rule(constitution, class)
    accountable_ref = Map.get(attrs, :accountable_ref)
    act = Map.get(attrs, :act)

    configured_containment =
      Map.get(attrs, :containment) || get(rule, [:containment], %{})

    containment =
      if class in [:ambiguous_outcome, :contradicted_outcome, :disputed_evidence] do
        hard_containment(configured_containment, Map.get(attrs, :act))
      else
        canonical_string_keys(configured_containment)
      end

    conflict_refs =
      conflict_refs(accountable_ref, get(rule, [:conflict_refs], []), act)

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
        get(attrs, [:closing_conditions, :closure_conditions]) ||
          get(rule, [:closing_conditions, :closure_conditions], []) || [],
      disposition_authority:
        Map.get(attrs, :disposition_authority) ||
          get(rule, [:disposition_authority, :disposition_authority_refs]),
      conflict_refs: conflict_refs,
      required_at: Map.get(attrs, :required_at),
      condition_met: Map.get(attrs, :condition_met, false),
      condition_evidence_ref: Map.get(attrs, :condition_evidence_ref)
    }
  end

  @doc false
  @spec conflict_refs(String.t() | nil, term(), map() | nil) :: [String.t()]
  def conflict_refs(accountable_ref, configured_refs, act) do
    ([accountable_ref] ++ authority_refs(configured_refs) ++ causal_role_refs(act))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp causal_role_refs(act) when is_map(act) do
    [
      get(act, [:mandate_ref]),
      get(act, [:proposer_ref]),
      get(act, [:authenticated_principal_ref]),
      get(act, [:executor_ref]),
      get(act, [:authorizer_ref]),
      get(act, [:accountable_ref])
    ] ++
      listify(get(act, [:subject_refs, :subjects], [])) ++
      listify(get(act, [:target_refs, :targets], []))
  end

  defp causal_role_refs(_act), do: []

  defp outcome_duty_cause(:ambiguous, act, attempt, outcome, constitution, required_at) do
    attempt_ref = ref(attempt, :attempt)

    duty_cause(
      :ambiguous_outcome,
      {:ambiguous_outcome, ref(act, :act), attempt_ref},
      %{
        "act_ref" => ref(act, :act),
        "attempt_ref" => attempt_ref,
        "outcome_ref" => ref(outcome, :outcome)
      },
      constitution,
      %{
        act: act,
        act_ref: ref(act, :act),
        mandate_ref: get(act, [:mandate_ref]),
        subject_refs: get(act, [:subject_refs, :subjects], []),
        accountable_ref: get(act, [:accountable_ref]),
        known_evidence_refs: get(outcome, [:evidence_refs], []),
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          configured_closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt_ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp outcome_duty_cause(:correction, act, attempt, outcome, constitution, required_at) do
    act_ref = ref(act, :act)
    attempt_ref = ref(attempt, :attempt)
    outcome_ref = ref(outcome, :outcome)

    duty_cause(
      :contradicted_outcome,
      {:contradicted_outcome, act_ref, attempt_ref, outcome_ref},
      %{
        "act_ref" => act_ref,
        "attempt_ref" => attempt_ref,
        "outcome_ref" => outcome_ref,
        "corrected_outcome_ref" => get(outcome, [:contradicts_outcome_ref])
      },
      constitution,
      %{
        act: act,
        act_ref: act_ref,
        mandate_ref: get(act, [:mandate_ref]),
        subject_refs: get(act, [:subject_refs, :subjects], []),
        accountable_ref: get(act, [:accountable_ref]),
        known_evidence_refs: get(outcome, [:evidence_refs], []),
        missing_evidence: [:reconciliation],
        closing_conditions:
          configured_closing_conditions(constitution, :contradicted_outcome, []),
        required_at: required_at
      }
    )
  end

  defp ambiguous_timeout_cause(act, attempt, outcomes, required_at, constitution) do
    act_ref = ref(act || %{}, :act)
    attempt_ref = ref(attempt, :attempt)

    duty_cause(
      :ambiguous_outcome,
      {:ambiguous_outcome, act_ref, attempt_ref},
      %{"act_ref" => act_ref, "attempt_ref" => attempt_ref},
      constitution,
      %{
        act: act,
        act_ref: act_ref,
        mandate_ref: get(act || %{}, [:mandate_ref]),
        subject_refs: get(act || %{}, [:subject_refs, :subjects], []),
        accountable_ref: get(act || %{}, [:accountable_ref]),
        known_evidence_refs: outcome_evidence_refs(outcomes),
        missing_evidence: [:definitive_outcome],
        closing_conditions:
          configured_closing_conditions(constitution, :ambiguous_outcome, [
            %{"kind" => :definitive_outcome, "attempt_ref" => attempt_ref}
          ]),
        required_at: required_at
      }
    )
  end

  defp configured_closing_conditions(constitution, class, default) do
    constitution
    |> duty_rule(class)
    |> get([:closing_conditions, :closure_conditions], default)
  end

  defp hard_containment(configured, act) do
    consequence_digest =
      case Candidate.effect_digest(act || %{}) do
        {:ok, digest} -> digest
        {:error, _reason} -> nil
      end

    configured
    |> canonical_string_keys()
    |> ensure_plain_map()
    |> Map.merge(%{
      "consequence_digest" => consequence_digest,
      "meter_reservations" => get(act || %{}, [:reservations], []),
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

  defp observation_deadline(attempt, act) do
    explicit = get(attempt, [:observation_deadline, :observation_deadline_at])

    if present?(explicit) do
      timestamp(explicit)
    else
      started_at = get(attempt, [:started_at, :attempted_at, :recorded_at])
      window = get(act || %{}, [:observation_window_ms, :observation_window])

      with {:ok, started_at} <- timestamp(started_at),
           true <- is_integer(window) and window >= 0 do
        {:ok, started_at + window}
      else
        _other -> :error
      end
    end
  end

  defp definitive_outcome_by?(outcomes, deadline) do
    Enum.any?(outcomes, fn outcome ->
      definitive_outcome?(outcome) and observed_by?(outcome, deadline)
    end)
  end

  defp first_outcome(outcomes, status, time) do
    outcomes
    |> Enum.filter(&(get(&1, [:classification, :outcome, :status]) == status))
    |> Enum.filter(&observed_by?(&1, time))
    |> Enum.min_by(
      fn outcome -> {outcome_time_value(outcome), stable_sort_key(ref(outcome, :outcome))} end,
      fn -> nil end
    )
  end

  defp ambiguity_required_at(ambiguous_at, deadline, _time) when is_integer(ambiguous_at),
    do: {:ok, min(ambiguous_at, deadline)}

  defp ambiguity_required_at(nil, deadline, time) do
    if at_or_after?(time, deadline), do: {:ok, deadline}, else: :not_required
  end

  defp definitive_outcome?(outcome) do
    classification = get(outcome, [:classification, :outcome, :status])
    get(outcome, [:definitive], false) == true or classification in @definitive_outcomes
  end

  defp observed_by?(outcome, deadline) do
    case outcome_time(outcome) do
      {:ok, observed_at} -> observed_at <= deadline
      :error -> false
    end
  end

  defp outcome_time(outcome),
    do:
      outcome
      |> get([:ledger_recorded_at, :recorded_at, :observed_at, :committed_at])
      |> timestamp()

  defp outcome_time_value(outcome) do
    case outcome_time(outcome) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp min_time(time, deadline) do
    case timestamp(time) do
      {:ok, value} -> min(value, deadline)
      :error -> time
    end
  end

  defp outcomes_for(outcomes, attempt_ref) do
    Enum.filter(outcomes, &(get(&1, [:attempt_ref]) == attempt_ref))
  end

  defp outcome_evidence_refs(outcomes) do
    outcomes
    |> Enum.flat_map(&listify(get(&1, [:evidence_refs], [])))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&stable_sort_key/1)
  end

  defp duty_rule(constitution, class) do
    rules = get(constitution, [:duty_rules, :duties], %{})

    cond do
      is_map(rules) -> Map.get(rules, class) || Map.get(rules, to_string(class)) || %{}
      is_list(rules) -> Enum.find(rules, %{}, &(get(&1, [:class, :cause_class]) == class))
      true -> %{}
    end
  end

  defp explicit_gap_active?(gap, time) do
    required? = get(gap, [:duty_required, :required], true) != false
    effective_at = get(gap, [:required_at, :effective_at])

    required? and (not present?(effective_at) or at_or_after?(time, effective_at))
  end

  defp act_ref_for_attempt(facts, attempt_ref) do
    case Map.get(facts.attempts_by_ref, attempt_ref) do
      nil -> nil
      attempt -> get(attempt, [:act_ref])
    end
  end

  defp normalize_facts(facts) when is_map(facts) do
    event_times = get(facts, [:event_recorded_at], %{})
    event_revisions = get(facts, [:event_revisions], %{})

    from_entries =
      facts
      |> get([:entries], [])
      |> normalize_entries()

    acts =
      from_entries.acts
      |> merge_records(collection(facts, [:acts]), :act)
      |> attach_event_metadata(event_times, event_revisions, "act_committed", :act)

    attempts =
      from_entries.attempts
      |> merge_records(collection(facts, [:attempts]), :attempt)
      |> attach_event_metadata(event_times, event_revisions, "attempt_started", :attempt)

    outcomes =
      from_entries.outcomes
      |> merge_records(collection(facts, [:outcomes]), :outcome)
      |> attach_event_metadata(event_times, event_revisions, "outcome_recorded", :outcome)

    presentations =
      from_entries.presentations
      |> merge_records(collection(facts, [:presentations]), :presentation)
      |> attach_event_metadata(
        event_times,
        event_revisions,
        "presentation_recorded",
        :presentation
      )

    duties =
      from_entries.duties
      |> merge_records(collection(facts, [:duties]), :duty)
      |> attach_event_metadata(event_times, event_revisions, "duty_opened", :duty)

    scopes =
      from_entries.scopes
      |> merge_records(collection(facts, [:scopes]), :scope)
      |> attach_event_metadata(event_times, event_revisions, "scope_opened", :scope)

    evidence =
      from_entries.evidence
      |> merge_records(collection(facts, [:evidence]), :evidence)
      |> attach_event_metadata(event_times, event_revisions, "evidence_recorded", :evidence)

    mandates =
      from_entries.mandates
      |> merge_records(collection(facts, [:mandates]), :mandate)
      |> attach_event_metadata(event_times, event_revisions, "mandate_issued", :mandate)

    erasures =
      from_entries.erasures
      |> merge_records(collection(facts, [:erasures]), :erasure)
      |> attach_event_metadata(event_times, event_revisions, "erasure_requested", :erasure)

    gaps =
      from_entries.gaps
      |> Kernel.++(collection(facts, [:gaps, :duty_causes]))
      |> Kernel.++(explicitly_marked_records(facts))
      |> Enum.uniq_by(&stable_sort_key/1)

    %{
      acts: acts,
      attempts: attempts,
      outcomes: outcomes,
      presentations: presentations,
      duties: duties,
      scopes: scopes,
      evidence: evidence,
      mandates: mandates,
      erasures: erasures,
      gaps: gaps,
      acts_by_ref: index_by_ref(acts, :act),
      attempts_by_ref: index_by_ref(attempts, :attempt),
      presentations_by_ref: index_by_ref(presentations, :presentation),
      mandates_by_ref: index_by_ref(mandates, :mandate)
    }
  end

  defp normalize_facts(facts) when is_list(facts) do
    normalized = normalize_entries(facts)

    %{
      acts: normalized.acts,
      attempts: normalized.attempts,
      outcomes: normalized.outcomes,
      presentations: normalized.presentations,
      duties: normalized.duties,
      scopes: normalized.scopes,
      evidence: normalized.evidence,
      mandates: normalized.mandates,
      erasures: normalized.erasures,
      gaps: normalized.gaps,
      acts_by_ref: index_by_ref(normalized.acts, :act),
      attempts_by_ref: index_by_ref(normalized.attempts, :attempt),
      presentations_by_ref: index_by_ref(normalized.presentations, :presentation),
      mandates_by_ref: index_by_ref(normalized.mandates, :mandate)
    }
  end

  defp normalize_facts(_facts) do
    %{
      acts: [],
      attempts: [],
      outcomes: [],
      presentations: [],
      duties: [],
      scopes: [],
      evidence: [],
      mandates: [],
      erasures: [],
      gaps: [],
      acts_by_ref: %{},
      attempts_by_ref: %{},
      presentations_by_ref: %{},
      mandates_by_ref: %{}
    }
  end

  defp normalize_entries(entries) when is_list(entries) do
    initial = %{
      acts: [],
      attempts: [],
      outcomes: [],
      presentations: [],
      duties: [],
      scopes: [],
      evidence: [],
      mandates: [],
      erasures: [],
      gaps: []
    }

    Enum.reduce(entries, initial, &add_entry/2)
  end

  defp normalize_entries(_entries),
    do: %{
      acts: [],
      attempts: [],
      outcomes: [],
      presentations: [],
      duties: [],
      scopes: [],
      evidence: [],
      mandates: [],
      erasures: [],
      gaps: []
    }

  defp add_entry(entry, acc) do
    {kind, record} = normalize_entry(entry)
    add_record(acc, kind, record)
  end

  defp add_record(acc, :act, record), do: Map.update!(acc, :acts, &[record | &1])
  defp add_record(acc, :attempt, record), do: Map.update!(acc, :attempts, &[record | &1])
  defp add_record(acc, :outcome, record), do: Map.update!(acc, :outcomes, &[record | &1])

  defp add_record(acc, :presentation, record),
    do: Map.update!(acc, :presentations, &[record | &1])

  defp add_record(acc, :duty, record), do: Map.update!(acc, :duties, &[record | &1])
  defp add_record(acc, :scope, record), do: Map.update!(acc, :scopes, &[record | &1])
  defp add_record(acc, :evidence, record), do: Map.update!(acc, :evidence, &[record | &1])
  defp add_record(acc, :mandate, record), do: Map.update!(acc, :mandates, &[record | &1])
  defp add_record(acc, :erasure, record), do: Map.update!(acc, :erasures, &[record | &1])

  defp add_record(acc, kind, record) when kind in [:gap, :duty_cause, :duty_required],
    do: Map.update!(acc, :gaps, &[record | &1])

  defp add_record(acc, _kind, record) do
    if explicit_gap?(record), do: Map.update!(acc, :gaps, &[record | &1]), else: acc
  end

  defp collection(facts, fields) do
    case get(facts, fields, []) do
      values when is_list(values) -> Enum.filter(values, &is_map/1)
      values when is_map(values) -> values |> Map.values() |> Enum.filter(&is_map/1)
      _other -> []
    end
  end

  defp merge_records(left, right, kind) do
    (left ++ right)
    |> Enum.uniq_by(fn record ->
      ref(record, kind) || stable_sort_key(record)
    end)
  end

  defp attach_event_metadata(records, event_times, event_revisions, event_type, kind)
       when is_map(event_times) and is_map(event_revisions) do
    Enum.map(records, fn record ->
      case ref(record, kind) do
        nil ->
          record

        ref ->
          annotate_record(
            record,
            Map.get(event_times, {event_type, ref}),
            Map.get(event_revisions, {event_type, ref})
          )
      end
    end)
  end

  defp attach_event_metadata(
         records,
         _event_times,
         _event_revisions,
         _event_type,
         _kind
       ),
       do: records

  defp explicitly_marked_records(facts) do
    facts
    |> Map.values()
    |> Enum.flat_map(fn
      values when is_list(values) -> Enum.filter(values, &explicit_gap?/1)
      value when is_map(value) -> if explicit_gap?(value), do: [value], else: []
      _value -> []
    end)
  end

  defp explicit_gap?(record) when is_map(record) do
    get(record, [:duty_required], false) == true or
      present?(get(record, [:cause_class, :duty_class, :gap_class]))
  end

  defp explicit_gap?(_record), do: false

  defp normalize_entry(entry) when is_map(entry) do
    payload = get(entry, [:payload])
    recorded_at = get(entry, [:recorded_at])
    revision = get(entry, [:revision])

    cond do
      event_envelope?(payload) ->
        event_parts(payload, recorded_at, revision)

      event_envelope?(entry) ->
        event_parts(entry, recorded_at, revision)

      is_map(payload) ->
        record = annotate_record(payload, recorded_at, revision)
        {normalize_kind(get(entry, [:entry_type, :event_type, :type, :kind]), record), record}

      true ->
        record = get(entry, [:record, :data], entry)
        record = annotate_record(record, recorded_at, revision)
        {normalize_kind(get(entry, [:entry_type, :event_type, :type, :kind]), record), record}
    end
  end

  defp normalize_entry(_entry), do: {:unknown, %{}}

  defp event_envelope?(event) when is_map(event) do
    present?(get(event, [:type, :event_type])) and is_map(get(event, [:data]))
  end

  defp event_envelope?(_event), do: false

  defp event_parts(event, recorded_at, revision) do
    record = event |> get([:data], %{}) |> annotate_record(recorded_at, revision)
    {normalize_kind(get(event, [:type, :event_type]), record), record}
  end

  defp annotate_record(%{__struct__: _module} = record, recorded_at, revision) do
    record
    |> Map.from_struct()
    |> annotate_record(recorded_at, revision)
  end

  defp annotate_record(record, recorded_at, revision) when is_map(record) do
    record
    |> maybe_put_metadata(:ledger_recorded_at, recorded_at)
    |> maybe_put_metadata(:ledger_revision, revision)
  end

  defp annotate_record(record, _recorded_at, _revision), do: record

  defp maybe_put_metadata(record, key, value) when is_integer(value) and value >= 0,
    do: Map.put(record, key, value)

  defp maybe_put_metadata(record, _key, _value), do: record

  defp normalize_kind(nil, record), do: struct_kind(record)

  defp normalize_kind(kind, record) when is_atom(kind),
    do: kind |> Atom.to_string() |> normalize_kind(record)

  defp normalize_kind(kind, _record) when is_binary(kind) do
    case String.downcase(kind) do
      "act" -> :act
      "act_committed" -> :act
      "attempt" -> :attempt
      "attempt_started" -> :attempt
      "outcome" -> :outcome
      "outcome_recorded" -> :outcome
      "presentation" -> :presentation
      "presentation_recorded" -> :presentation
      "duty" -> :duty
      "duty_opened" -> :duty
      "scope" -> :scope
      "scope_opened" -> :scope
      "evidence" -> :evidence
      "evidence_recorded" -> :evidence
      "mandate" -> :mandate
      "mandate_issued" -> :mandate
      "erasure" -> :erasure
      "erasure_requested" -> :erasure
      "gap" -> :gap
      "duty_cause" -> :duty_cause
      "duty_required" -> :duty_required
      _other -> :unknown
    end
  end

  defp normalize_kind(_kind, record), do: struct_kind(record)

  defp struct_kind(%{__struct__: module}) do
    module
    |> Module.split()
    |> List.last()
    |> String.downcase()
    |> normalize_kind(%{})
  end

  defp struct_kind(_record), do: :unknown

  defp index_by_ref(records, kind) do
    Enum.reduce(records, %{}, fn record, index ->
      case ref(record, kind) do
        nil -> index
        ref -> Map.put(index, ref, record)
      end
    end)
  end

  defp ref(record, :act), do: get(record, [:act_ref, :ref])
  defp ref(record, :attempt), do: get(record, [:attempt_ref, :ref])
  defp ref(record, :outcome), do: get(record, [:outcome_ref, :ref])
  defp ref(record, :presentation), do: get(record, [:presentation_ref, :ref])
  defp ref(record, :duty), do: get(record, [:duty_ref, :ref])
  defp ref(record, :scope), do: get(record, [:scope_ref, :ref])
  defp ref(record, :evidence), do: get(record, [:evidence_ref, :ref])
  defp ref(record, :mandate), do: get(record, [:mandate_ref, :ref])
  defp ref(record, :erasure), do: get(record, [:erasure_ref, :ref])

  defp canonical_pairs(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, value} end)
    |> Enum.sort_by(fn {key, _value} -> stable_sort_key(key) end)
  end

  defp canonical_pairs(value), do: value

  defp authority_refs(nil), do: []
  defp authority_refs(value) when is_binary(value), do: [value]
  defp authority_refs(value) when is_list(value), do: Enum.filter(value, &is_binary/1)

  defp authority_refs(value) when is_map(value) do
    value
    |> get([:principal_refs, :controller_refs, :refs], [])
    |> authority_refs()
  end

  defp authority_refs(_value), do: []

  defp empty_map?(value), do: is_map(value) and map_size(value) == 0

  defp at_or_after?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left >= right
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

  defp required_at(cause, fallback) do
    case cause |> get([:required_at]) |> timestamp() do
      {:ok, value} -> value
      :error -> fallback
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
end
