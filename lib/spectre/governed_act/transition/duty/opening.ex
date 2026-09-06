defmodule Spectre.GovernedAct.Transition.Duty.Opening do
  @moduledoc """
  Validates the causal proof carried by a `duty_opened` event.

  The general derivation pass proves that the exact Duty is required by the
  prefix and its Constitution. Built-in classes receive an additional closed
  check for the safety invariant Spectre itself owns, such as blocked retry or
  an overdue Scope promise. Application-defined classes remain governed by
  their configured cause-source and disposition rules.

  This module only validates an already restored `Spectre.Duty`; insertion in
  disposable state remains the responsibility of `Transition.Duty`.
  """

  alias Spectre.{Act, Candidate, Condition, Duty, Outcome}
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{Index, State}
  alias Spectre.Kernel.Recognition
  alias Spectre.Scope.Opening, as: ScopeOpening

  @doc false
  @spec validate(State.t(), Duty.t()) :: :ok | {:error, term()}
  def validate(%State{} = state, %Duty{} = duty) do
    with :ok <- new_duty_open(duty),
         :ok <- unique_cause(state, duty),
         :ok <- optional_act_exists(state, duty.act_ref),
         :ok <- optional_attempt_matches(state, duty.attempt_ref, duty.act_ref),
         :ok <-
           Index.ensure_present(state.evidence, duty.evidence_refs, :outcome_evidence_not_found),
         :ok <- match_duty_act(state, duty),
         :ok <- required_at_prefix(state, duty) do
      validate_builtin_cause(state, duty)
    end
  end

  defp new_duty_open(%Duty{status: :open, disposition_act_ref: nil}), do: :ok

  defp new_duty_open(%Duty{ref: ref}),
    do: {:error, {:duty_opened_in_terminal_state, ref}}

  defp unique_cause(state, duty) do
    if Map.has_key?(state.duties, duty.cause_key),
      do: {:error, {:duplicate_duty_cause, duty.cause_key}},
      else: :ok
  end

  defp required_at_prefix(state, duty) do
    cause =
      state
      |> Derive.required_duties(duty.opened_at)
      |> Enum.find(&(&1.cause_key === duty.cause_key))

    case cause do
      nil ->
        {:error, {:duty_cause_not_required_at_prefix, duty.ref}}

      cause ->
        with {:ok, expected} <-
               cause
               |> Derive.materialization_attrs(duty.opened_at)
               |> Duty.new(),
             true <- expected === duty do
          :ok
        else
          false -> {:error, {:duty_cause_materialization_mismatch, duty.ref}}
          {:error, reason} -> {:error, {:invalid_required_duty, duty.cause_key, reason}}
        end
    end
  end

  defp match_duty_act(_state, %Duty{act_ref: nil}), do: :ok

  defp match_duty_act(state, duty) do
    with {:ok, act} <- Index.fetch_act(state, duty.act_ref) do
      cond do
        duty.mandate_ref != act.mandate_ref ->
          {:error, {:duty_mandate_mismatch, duty.ref, act.ref}}

        duty.subjects != act.subject_refs ->
          {:error, {:duty_subjects_mismatch, duty.ref, act.ref}}

        duty.accountable != act.accountable_ref ->
          {:error, {:duty_accountable_mismatch, duty.ref, act.ref}}

        not conflicts_include_cause_roles?(duty, act) ->
          {:error, {:duty_conflict_refs_mismatch, duty.ref, act.ref}}

        true ->
          :ok
      end
    end
  end

  defp validate_builtin_cause(
         state,
         %Duty{
           class: :ambiguous_outcome,
           cause_key: {:ambiguous_outcome, act_ref, attempt_ref}
         } = duty
       ) do
    case {Map.fetch(state.attempts, attempt_ref), Map.fetch(state.acts, act_ref)} do
      {{:ok, attempt}, {:ok, act}} ->
        deadline_reached? =
          duty.opened_at >= attempt.started_at + act.observation_window_ms

        cause_observed? =
          ambiguous_outcome_observed?(state, act_ref, attempt_ref, duty.opened_at)

        if duty.act_ref == act_ref and duty.attempt_ref == attempt_ref and
             (deadline_reached? or cause_observed?) and valid_containment?(duty, act),
           do: :ok,
           else: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

      _missing_or_invalid ->
        {:error, {:invalid_ambiguous_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_cause(
         state,
         %Duty{
           class: :contradicted_outcome,
           cause_key: {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, outcome} <- Map.fetch(state.outcomes, outcome_ref),
         {:ok, act} <- Map.fetch(state.acts, act_ref),
         true <- outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref,
         true <- Outcome.correction?(outcome) and outcome.observed_at <= duty.opened_at,
         {:ok, corrected} <- Map.fetch(state.outcomes, outcome.contradicts_outcome_ref),
         true <- corrected.status == :definitive_no_effect,
         true <- duty.act_ref == act_ref and duty.attempt_ref == attempt_ref,
         true <- valid_containment?(duty, act) do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_contradicted_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_cause(_state, %Duty{class: :ambiguous_outcome} = duty),
    do: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

  defp validate_builtin_cause(_state, %Duty{class: :contradicted_outcome} = duty),
    do: {:error, {:invalid_contradicted_duty_cause, duty.ref}}

  defp validate_builtin_cause(state, %Duty{class: :disputed_evidence} = duty) do
    cause =
      state
      |> Derive.required_duties(%{}, duty.opened_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    expected = if cause, do: Derive.materialization_attrs(cause, duty.opened_at)
    act = if expected, do: Map.get(state.acts, expected.act_ref)

    valid? =
      is_map(expected) and not is_nil(act) and disputed_binding?(duty, expected) and
        valid_containment?(duty, act)

    if valid?,
      do: :ok,
      else: {:error, {:invalid_disputed_evidence_duty_cause, duty.ref}}
  end

  defp validate_builtin_cause(
         state,
         %Duty{
           class: :scope_promise_overdue,
           cause_key: {:scope_promise_overdue, scope_ref}
         } = duty
       ) do
    case Map.fetch(state.catalog.scopes, scope_ref) do
      {:ok, %ScopeOpening{} = opening} ->
        condition = opening.promise_condition
        source_act = Map.get(state.acts, opening.source_act_ref)
        timely_evidence = Derive.available_evidence_at(state, opening.due_at)

        valid? =
          opening.kind in [:work, :vigil] and duty.act_ref == opening.source_act_ref and
            scope_source_binding?(duty, source_act) and
            scope_promise_binding?(duty, opening, source_act) and
            duty.opened_at >= opening.due_at and
            Recognition.check([condition], timely_evidence, opening.due_at) != :satisfied

        if valid?,
          do: :ok,
          else: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

      :error ->
        {:error, {:scope_promise_duty_scope_not_found, duty.ref, scope_ref}}
    end
  end

  defp validate_builtin_cause(
         state,
         %Duty{
           class: :erasure_reduces_verifiability,
           cause_key:
             {:erasure_reduces_verifiability, erasure_ref, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, erasure} <- Map.fetch(state.erasures, erasure_ref),
         {:ok, act} <- Map.fetch(state.acts, act_ref),
         {:ok, attempt} <- Map.fetch(state.attempts, attempt_ref),
         {:ok, outcome} <- Map.fetch(state.outcomes, outcome_ref),
         true <- erasure.reduces_verifiability,
         true <- erasure.source_act_ref == act.ref,
         true <- attempt.act_ref == act.ref,
         true <- outcome.act_ref == act.ref and outcome.attempt_ref == attempt.ref,
         true <- outcome.status == :succeeded,
         true <- duty.act_ref == act.ref and duty.attempt_ref == attempt.ref,
         true <- duty.mandate_ref == act.mandate_ref,
         true <- duty.subjects == act.subject_refs,
         true <- duty.accountable == act.accountable_ref,
         true <- duty.evidence_refs == outcome.evidence_refs,
         true <- duty.opened_at >= outcome.observed_at do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_cause(_state, %Duty{class: :scope_promise_overdue} = duty),
    do: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

  defp validate_builtin_cause(
         _state,
         %Duty{class: :erasure_reduces_verifiability} = duty
       ),
       do: {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}

  defp validate_builtin_cause(_state, %Duty{class: class}) when is_binary(class), do: :ok

  defp ambiguous_outcome_observed?(state, act_ref, attempt_ref, time) do
    Enum.any?(state.outcomes, fn {_ref, outcome} ->
      outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref and
        outcome.status == :ambiguous and outcome.observed_at <= time
    end)
  end

  defp disputed_binding?(duty, expected) do
    fields = [
      :act_ref,
      :attempt_ref,
      :mandate_ref,
      :subjects,
      :accountable,
      :evidence_refs,
      :missing,
      :opened_at
    ]

    Map.take(duty, fields) === Map.take(expected, fields)
  end

  defp scope_source_binding?(_duty, nil), do: false

  defp scope_source_binding?(duty, source_act) do
    is_nil(duty.attempt_ref) and duty.mandate_ref == source_act.mandate_ref and
      duty.subjects == source_act.subject_refs
  end

  defp scope_promise_binding?(duty, opening, source_act) do
    duty.accountable == opening.accountable_ref and
      duty.disposition_authority_refs == opening.disposition_authority_refs and
      conflicts_include_cause_roles?(duty, source_act) and
      duty.closing_conditions === [Condition.canonical(opening.promise_condition)]
  end

  defp conflicts_include_cause_roles?(%Duty{} = duty, %Act{} = act) do
    duty.accountable
    |> Derive.conflict_refs([], act)
    |> Enum.all?(&(&1 in duty.conflict_refs))
  end

  defp valid_containment?(%Duty{} = duty, %Act{} = act) do
    case duty.containment do
      %{
        "consequence_digest" => consequence_digest,
        "meter_reservations" => reservations,
        "dispatch" => :blocked,
        "retry" => :forbidden
      } ->
        reservations === act.reservations and
          Candidate.effect_digest(act) == {:ok, consequence_digest}

      _invalid ->
        false
    end
  end

  defp optional_act_exists(_state, nil), do: :ok

  defp optional_act_exists(state, act_ref) do
    with {:ok, _act} <- Index.fetch_act(state, act_ref), do: :ok
  end

  defp optional_attempt_matches(_state, nil, _act_ref), do: :ok

  defp optional_attempt_matches(state, attempt_ref, act_ref) do
    with {:ok, attempt} <- Index.fetch_attempt(state, attempt_ref) do
      if attempt.act_ref == act_ref,
        do: :ok,
        else: {:error, {:duty_attempt_act_mismatch, attempt_ref, act_ref}}
    end
  end
end
