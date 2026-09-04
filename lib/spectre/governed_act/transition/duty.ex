defmodule Spectre.GovernedAct.Transition.Duty do
  @moduledoc """
  Replays the obligation lifecycle derived by the Governed Act Model.

  A Duty is materialized only when its causal prefix requires it. Disposition
  must itself be an admitted governed Act, and any suspended Meter reservation
  is resolved in the same causal lifecycle. Keeping these rules together makes
  the obligation boundary explicit without coupling it to ledger I/O.
  """

  alias Spectre.{Act, Condition, Duty, Outcome}
  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.Duty.{Derive, Disposition}
  alias Spectre.GovernedAct.{Index, State}
  alias Spectre.GovernedAct.Transition.Duty.Disposal
  alias Spectre.GovernedAct.Transition.Duty.Meter, as: DutyMeter
  alias Spectre.Kernel.Recognition
  alias Spectre.Scope.Opening

  @event_types ~w(duty_opened duty_disposed meter_duty_resolved)

  @doc false
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @spec apply(State.t(), Event.t(), non_neg_integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def apply(
        %State{} = state,
        %Event{type: type, identity: identity, data: data},
        revision
      )
      when type in @event_types,
      do: reduce(type, identity, data, revision, state)

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_duty_event, type}}

  defp reduce("meter_duty_resolved", _identity, data, _revision, projection),
    do: DutyMeter.resolve(projection, data)

  defp reduce("duty_opened", identity, data, _revision, projection) do
    with {:ok, duty} <- Record.decode(Spectre.Duty, data),
         :ok <- Record.match_identity(identity, Record.ref(duty)),
         :ok <- new_duty_open(duty),
         :ok <- unique_duty(projection, duty),
         :ok <- match_duty_references(projection, duty) do
      {:ok,
       %{
         projection
         | duties: Map.put(projection.duties, duty.cause_key, duty),
           duty_refs: Map.put(projection.duty_refs, duty.ref, duty.cause_key)
       }}
    end
  end

  defp reduce("duty_disposed", identity, data, _revision, projection) do
    cause_key = data["cause_key"]
    disposition_act_ref = data["disposition_act_ref"]

    with {:ok, duty} <- Index.fetch_duty_by_cause(projection, cause_key),
         :ok <- duty_open(duty),
         :ok <- Record.match_identity(identity, disposition_act_ref),
         {:ok, act} <- Index.fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(act.consequence),
         {:ok, _supporting} <- Disposal.validate(projection, act, duty, disposition),
         :ok <- DutyMeter.validate_disposed(projection, duty, disposition, act.ref),
         {:ok, updated} <-
           Spectre.Duty.new(%{
             duty
             | status: :disposed,
               disposition_act_ref: disposition_act_ref
           }) do
      {:ok, %{projection | duties: Map.put(projection.duties, cause_key, updated)}}
    end
  end

  defp unique_duty(projection, duty) do
    cond do
      Map.has_key?(projection.duties, duty.cause_key) ->
        {:error, {:duplicate_duty_cause, duty.cause_key}}

      Map.has_key?(projection.duty_refs, duty.ref) ->
        {:error, {:duplicate_domain_record, :duty, duty.ref}}

      true ->
        :ok
    end
  end

  defp new_duty_open(%Spectre.Duty{status: :open, disposition_act_ref: nil}), do: :ok

  defp new_duty_open(%Spectre.Duty{ref: ref}),
    do: {:error, {:duty_opened_in_terminal_state, ref}}

  defp match_duty_references(projection, duty) do
    with :ok <- optional_act_exists(projection, duty.act_ref),
         :ok <- optional_attempt_matches(projection, duty.attempt_ref, duty.act_ref),
         :ok <-
           Index.ensure_present(
             projection.evidence,
             duty.evidence_refs,
             :outcome_evidence_not_found
           ),
         :ok <- match_duty_act(projection, duty),
         :ok <- duty_required_at_prefix(projection, duty) do
      validate_builtin_duty_cause(projection, duty)
    end
  end

  defp duty_required_at_prefix(projection, duty) do
    cause =
      projection
      |> Derive.required_duties(projection.constitution, duty.opened_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    case cause do
      nil ->
        {:error, {:duty_cause_not_required_at_prefix, duty.ref}}

      cause ->
        with {:ok, expected} <-
               cause
               |> Derive.materialization_attrs(duty.opened_at)
               |> Duty.new(),
             true <- expected == duty do
          :ok
        else
          false -> {:error, {:duty_cause_materialization_mismatch, duty.ref}}
          {:error, reason} -> {:error, {:invalid_required_duty, duty.cause_key, reason}}
        end
    end
  end

  defp match_duty_act(_projection, %Duty{act_ref: nil}), do: :ok

  defp match_duty_act(projection, duty) do
    with {:ok, act} <- Index.fetch_act(projection, duty.act_ref) do
      cond do
        duty.mandate_ref != act.mandate_ref ->
          {:error, {:duty_mandate_mismatch, duty.ref, act.ref}}

        duty.subjects != act.subject_refs ->
          {:error, {:duty_subjects_mismatch, duty.ref, act.ref}}

        duty.accountable != act.accountable_ref ->
          {:error, {:duty_accountable_mismatch, duty.ref, act.ref}}

        not duty_conflicts_include_cause_roles?(duty, act) ->
          {:error, {:duty_conflict_refs_mismatch, duty.ref, act.ref}}

        true ->
          :ok
      end
    end
  end

  defp validate_builtin_duty_cause(
         projection,
         %Duty{
           class: :ambiguous_outcome,
           cause_key: {:ambiguous_outcome, act_ref, attempt_ref}
         } = duty
       ) do
    deadline_reached? =
      case {Map.fetch(projection.attempts, attempt_ref), Map.fetch(projection.acts, act_ref)} do
        {{:ok, attempt}, {:ok, act}} ->
          duty.opened_at >= attempt.started_at + act.observation_window_ms

        _missing ->
          false
      end

    ambiguous_outcome? =
      Enum.any?(projection.outcomes, fn {_ref, outcome} ->
        outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref and
          outcome.status == :ambiguous and outcome.observed_at <= duty.opened_at
      end)

    safe_containment? =
      case Map.fetch(projection.acts, act_ref) do
        {:ok, act} -> valid_builtin_duty_containment?(duty, act)
        :error -> false
      end

    if duty.act_ref == act_ref and duty.attempt_ref == attempt_ref and
         (deadline_reached? or ambiguous_outcome?) and safe_containment?,
       do: :ok,
       else: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}
  end

  defp validate_builtin_duty_cause(
         projection,
         %Duty{
           class: :contradicted_outcome,
           cause_key: {:contradicted_outcome, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, outcome} <- Map.fetch(projection.outcomes, outcome_ref),
         {:ok, act} <- Map.fetch(projection.acts, act_ref),
         true <- outcome.act_ref == act_ref and outcome.attempt_ref == attempt_ref,
         true <- Outcome.correction?(outcome) and outcome.observed_at <= duty.opened_at,
         {:ok, corrected} <- Map.fetch(projection.outcomes, outcome.contradicts_outcome_ref),
         true <- corrected.status == :definitive_no_effect,
         true <- duty.act_ref == act_ref and duty.attempt_ref == attempt_ref,
         true <- valid_builtin_duty_containment?(duty, act) do
      :ok
    else
      _missing_or_mismatch -> {:error, {:invalid_contradicted_duty_cause, duty.ref}}
    end
  end

  defp validate_builtin_duty_cause(_projection, %Duty{class: :ambiguous_outcome} = duty),
    do: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %Duty{class: :contradicted_outcome} = duty),
    do: {:error, {:invalid_contradicted_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         projection,
         %Duty{class: :disputed_evidence} = duty
       ) do
    cause =
      projection
      |> Derive.required_duties(%{}, duty.opened_at)
      |> Enum.find(&(&1.cause_key == duty.cause_key))

    expected = if cause, do: Derive.materialization_attrs(cause, duty.opened_at)
    act = if expected, do: Map.get(projection.acts, expected.act_ref)

    valid? =
      is_map(expected) and not is_nil(act) and duty.act_ref == expected.act_ref and
        duty.attempt_ref == expected.attempt_ref and duty.mandate_ref == expected.mandate_ref and
        duty.subjects == expected.subjects and duty.accountable == expected.accountable and
        duty.evidence_refs == expected.evidence_refs and duty.missing == expected.missing and
        duty.opened_at == expected.opened_at and valid_builtin_duty_containment?(duty, act)

    if valid?,
      do: :ok,
      else: {:error, {:invalid_disputed_evidence_duty_cause, duty.ref}}
  end

  defp validate_builtin_duty_cause(
         projection,
         %Duty{
           class: :scope_promise_overdue,
           cause_key: {:scope_promise_overdue, scope_ref}
         } = duty
       ) do
    case Map.fetch(projection.scopes, scope_ref) do
      {:ok, %Opening{} = opening} ->
        condition = opening.promise_condition
        source_act = Map.get(projection.acts, opening.source_act_ref)
        timely_evidence = Derive.available_evidence_at(projection, opening.due_at)

        valid? =
          opening.kind in [:work, :vigil] and duty.act_ref == opening.source_act_ref and
            duty.attempt_ref == nil and not is_nil(source_act) and
            duty.mandate_ref == source_act.mandate_ref and
            duty.subjects == source_act.subject_refs and
            duty.accountable == opening.accountable_ref and
            duty.disposition_authority_refs == opening.disposition_authority_refs and
            duty_conflicts_include_cause_roles?(duty, source_act) and
            duty.closing_conditions == [Condition.canonical(condition)] and
            duty.opened_at >= opening.due_at and
            Recognition.check([condition], timely_evidence, opening.due_at) != :satisfied

        if valid?,
          do: :ok,
          else: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

      :error ->
        {:error, {:scope_promise_duty_scope_not_found, duty.ref, scope_ref}}
    end
  end

  defp validate_builtin_duty_cause(
         projection,
         %Duty{
           class: :erasure_reduces_verifiability,
           cause_key:
             {:erasure_reduces_verifiability, erasure_ref, act_ref, attempt_ref, outcome_ref}
         } = duty
       ) do
    with {:ok, erasure} <- Map.fetch(projection.erasures, erasure_ref),
         {:ok, act} <- Map.fetch(projection.acts, act_ref),
         {:ok, attempt} <- Map.fetch(projection.attempts, attempt_ref),
         {:ok, outcome} <- Map.fetch(projection.outcomes, outcome_ref),
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

  defp validate_builtin_duty_cause(_projection, %Duty{class: :scope_promise_overdue} = duty),
    do: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         _projection,
         %Duty{class: :erasure_reduces_verifiability} = duty
       ),
       do: {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %Duty{class: class})
       when is_binary(class),
       do: :ok

  defp duty_conflicts_include_cause_roles?(%Duty{} = duty, %Act{} = act) do
    duty.accountable
    |> Derive.conflict_refs([], act)
    |> Enum.all?(&(&1 in duty.conflict_refs))
  end

  defp valid_builtin_duty_containment?(%Duty{} = duty, %Act{} = act) do
    case duty.containment do
      %{
        "consequence_digest" => consequence_digest,
        "meter_reservations" => reservations,
        "dispatch" => :blocked,
        "retry" => :forbidden
      } ->
        reservations == act.reservations and
          Spectre.Candidate.effect_digest(act) == {:ok, consequence_digest}

      _invalid ->
        false
    end
  end

  defp optional_act_exists(_projection, nil), do: :ok

  defp optional_act_exists(projection, act_ref) do
    with {:ok, _act} <- Index.fetch_act(projection, act_ref), do: :ok
  end

  defp optional_attempt_matches(_projection, nil, _act_ref), do: :ok

  defp optional_attempt_matches(projection, attempt_ref, act_ref) do
    with {:ok, attempt} <- Index.fetch_attempt(projection, attempt_ref) do
      if attempt.act_ref == act_ref,
        do: :ok,
        else: {:error, {:duty_attempt_act_mismatch, attempt_ref, act_ref}}
    end
  end

  defp duty_open(%Spectre.Duty{status: :open}), do: :ok
  defp duty_open(%Spectre.Duty{cause_key: cause_key}), do: {:error, {:duty_disposed, cause_key}}
end
