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
  alias Spectre.Duty.Authority, as: DutyAuthority
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.{Index, MeterState, State}
  alias Spectre.Kernel.Meter.Amounts
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
    do: resolve_duty_meter(projection, data)

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
         {:ok, _supporting} <- validate_duty_disposition(projection, act, duty, disposition),
         :ok <- validate_duty_meter_disposed(projection, duty, disposition, act.ref),
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

  defp match_duty_act(_projection, %{act_ref: nil}), do: :ok

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
         %{
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
         %{
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

  defp validate_builtin_duty_cause(_projection, %{class: :ambiguous_outcome} = duty),
    do: {:error, {:invalid_ambiguous_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %{class: :contradicted_outcome} = duty),
    do: {:error, {:invalid_contradicted_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         projection,
         %{class: :disputed_evidence} = duty
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
         %{
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
         %{
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

  defp validate_builtin_duty_cause(_projection, %{class: :scope_promise_overdue} = duty),
    do: {:error, {:invalid_scope_promise_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(
         _projection,
         %{class: :erasure_reduces_verifiability} = duty
       ),
       do: {:error, {:invalid_erasure_verifiability_duty_cause, duty.ref}}

  defp validate_builtin_duty_cause(_projection, %{class: class})
       when is_binary(class),
       do: :ok

  defp duty_conflicts_include_cause_roles?(duty, act) when is_map(act) do
    duty.accountable
    |> Derive.conflict_refs([], act)
    |> Enum.all?(&(&1 in duty.conflict_refs))
  end

  defp valid_builtin_duty_containment?(duty, act) do
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

  defp validate_duty_disposition(projection, act, duty, disposition) do
    with :ok <- validate_disposition_act(act, duty),
         :ok <- validate_disposition_binding(duty, disposition),
         {:ok, supporting} <- disposition_support(projection, disposition, act),
         :ok <- validate_disposition_authority(projection, act, duty, disposition),
         :ok <- validate_disposition_basis(projection, act, duty, disposition, supporting) do
      {:ok, supporting}
    end
  end

  defp validate_disposition_authority(_projection, _act, _duty, %{kind: :condition_met}),
    do: :ok

  defp validate_disposition_authority(projection, act, duty, disposition) do
    if Disposition.discretionary?(disposition) do
      DutyAuthority.validate(
        duty,
        act,
        duty_cause_act(projection, duty),
        projection.principals,
        projection.mandates
      )
    else
      :ok
    end
  end

  defp duty_cause_act(projection, %{act_ref: act_ref}) when is_binary(act_ref),
    do: Map.get(projection.acts, act_ref)

  defp duty_cause_act(
         projection,
         %{class: :scope_promise_overdue, cause_key: {:scope_promise_overdue, scope_ref}}
       ) do
    case Map.get(projection.scopes, scope_ref) do
      %Opening{source_act_ref: act_ref} -> Map.get(projection.acts, act_ref)
      _missing -> nil
    end
  end

  defp duty_cause_act(_projection, _duty), do: nil

  defp validate_disposition_act(act, duty) do
    cond do
      act.class != "duty.dispose" ->
        {:error, {:duty_disposition_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:duty_disposition_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:duty_disposition_act_has_reservations, act.ref}}

      not Act.targets?(act, [duty.ref]) ->
        {:error, {:duty_disposition_target_missing, act.ref, duty.ref}}

      act.ref == duty.act_ref ->
        {:error, {:duty_cause_act_cannot_dispose, duty.ref, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_disposition_binding(duty, disposition) do
    cond do
      disposition.duty_ref != duty.ref ->
        {:error, {:duty_disposition_ref_mismatch, duty.ref, disposition.duty_ref}}

      disposition.cause_key != duty.cause_key ->
        {:error, {:duty_disposition_cause_mismatch, duty.ref}}

      disposition.opening_digest != Spectre.Duty.digest(duty) ->
        {:error, {:duty_disposition_opening_mismatch, duty.ref}}

      true ->
        :ok
    end
  end

  defp disposition_support(projection, disposition, act) do
    Enum.reduce_while(disposition.supporting_refs, {:ok, []}, fn ref, {:ok, records} ->
      case supporting_record(projection, ref) do
        {:ok, record} ->
          with :ok <- support_frozen_and_available(projection, act, ref, record),
               true <- support_available_at?(record, act.committed_at) do
            {:cont, {:ok, [record | records]}}
          else
            false -> {:halt, {:error, {:duty_disposition_support_from_future, ref}}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, _reason} = error -> error
    end
  end

  defp support_frozen_and_available(projection, act, ref, {:evidence, _evidence}) do
    if ref in act.evidence_refs,
      do: ErasureAnalysis.validate_evidence_available(projection, [ref]),
      else: {:error, {:duty_disposition_evidence_not_frozen, act.ref, ref}}
  end

  defp support_frozen_and_available(_projection, _act, _ref, {_kind, _record}), do: :ok

  defp supporting_record(projection, ref) do
    matches =
      [
        {:evidence, Map.get(projection.evidence, ref)},
        {:outcome, Map.get(projection.outcomes, ref)},
        {:act, Map.get(projection.acts, ref)}
      ]
      |> Enum.reject(fn {_kind, record} -> is_nil(record) end)

    case matches do
      [record] -> {:ok, record}
      [] -> {:error, {:duty_disposition_support_not_found, ref}}
      _collision -> {:error, {:duty_disposition_support_ambiguous, ref}}
    end
  end

  defp support_available_at?({:evidence, evidence}, committed_at),
    do: evidence.observed_at <= committed_at

  defp support_available_at?({:outcome, outcome}, committed_at),
    do: outcome.observed_at <= committed_at

  defp support_available_at?({:act, act}, committed_at),
    do: act.committed_at <= committed_at

  defp validate_disposition_basis(
         projection,
         act,
         duty,
         %{kind: :condition_met},
         supporting
       ) do
    if Enum.any?(
         duty.closing_conditions,
         &closing_condition_met?(projection, &1, supporting, act.committed_at)
       ) do
      :ok
    else
      {:error, {:duty_closing_condition_not_met, duty.ref}}
    end
  end

  defp validate_disposition_basis(_projection, act, duty, disposition, _supporting) do
    if Disposition.discretionary?(disposition),
      do: :ok,
      else: {:error, {:invalid_duty_disposition_kind, disposition.kind, act.ref, duty.ref}}
  end

  defp closing_condition_met?(
         projection,
         %{"kind" => :definitive_outcome, "attempt_ref" => attempt_ref} = condition,
         supporting,
         committed_at
       )
       when map_size(condition) == 2 do
    Enum.any?(supporting, fn
      {:outcome, outcome} ->
        outcome.attempt_ref == attempt_ref and
          outcome.status in [:succeeded, :failed, :definitive_no_effect] and
          outcome.observed_at <= committed_at and
          outcome_not_corrected_at?(projection, outcome, committed_at)

      _other ->
        false
    end)
  end

  defp closing_condition_met?(projection, condition, supporting, committed_at) do
    available_evidence = projection |> ErasureAnalysis.available_evidence() |> Map.values()
    supporting_refs = for {:evidence, item} <- supporting, do: item.ref

    with {:ok, condition} <- Condition.new(condition),
         {:satisfied, basis_refs} <-
           Recognition.check_with_basis([condition], available_evidence, committed_at) do
      basis_refs -- supporting_refs == []
    else
      _not_satisfied_or_invalid -> false
    end
  end

  defp resolve_duty_meter(projection, data) do
    disposition_act_ref = data["disposition_act_ref"]
    duty_ref = data["duty_ref"]
    cause_act_ref = data["act_ref"]
    mandate_ref = data["mandate_ref"]
    operation = data["operation"]

    with true <- operation in [:settle, :release],
         {:ok, amounts} <- Amounts.normalize(data["amounts"]),
         :ok <- duty_meter_resolution_absent(projection, disposition_act_ref),
         {:ok, duty} <- Index.fetch_duty_by_ref(projection, duty_ref),
         :ok <- duty_open(duty),
         true <- duty.act_ref == cause_act_ref,
         {:ok, disposition_act} <- Index.fetch_act(projection, disposition_act_ref),
         {:ok, disposition} <- Disposition.from_consequence(disposition_act.consequence),
         {:ok, supporting} <-
           validate_duty_disposition(projection, disposition_act, duty, disposition),
         true <- disposition.meter_resolution == operation,
         {:ok, cause_act} <- Index.fetch_act(projection, cause_act_ref),
         true <- cause_act.mandate_ref == mandate_ref,
         true <- Act.reservations?(cause_act),
         {:ok, :suspended, binding} <- MeterState.reservation(projection, cause_act.ref),
         :ok <- match_duty_meter_binding(binding, cause_act, mandate_ref),
         {:ok, expected_amounts, recontainment} <-
           expected_duty_meter_amounts(projection, cause_act, duty),
         true <- amounts == expected_amounts,
         :ok <-
           validate_duty_meter_resolution(
             projection,
             operation,
             supporting,
             cause_act,
             duty,
             disposition_act.committed_at
           ),
         {:ok, accounts} <- MeterState.accounts(projection, mandate_ref),
         {:ok, accounts} <-
           MeterState.transition_accounts(accounts, amounts, operation, :suspended),
         {:ok, projection} <- MeterState.put_accounts(projection, mandate_ref, accounts) do
      resolution = %{
        act_ref: cause_act.ref,
        disposition_act_ref: disposition_act.ref,
        duty_ref: duty.ref,
        mandate_ref: mandate_ref,
        operation: operation,
        amounts: amounts
      }

      projection =
        projection
        |> put_duty_meter_resolution(resolution)
        |> put_resolved_recontainment(recontainment, disposition_act.ref)

      {:ok,
       %{
         projection
         | reservation_states:
             Map.put(
               projection.reservation_states,
               cause_act.ref,
               resolved_reservation_status(operation)
             )
       }}
    else
      false ->
        {:error, {:invalid_duty_meter_resolution_event, disposition_act_ref}}

      {:ok, status, _binding} ->
        {:error, {:duty_meter_resolution_requires_suspension, cause_act_ref, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp duty_meter_resolution_absent(projection, disposition_act_ref) do
    if Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref),
      do: {:error, {:duplicate_duty_meter_resolution, disposition_act_ref}},
      else: :ok
  end

  defp match_duty_meter_binding(binding, cause_act, mandate_ref) do
    with true <- binding.act_ref == cause_act.ref,
         true <- binding.mandate_ref == mandate_ref,
         {:ok, declared} <- Amounts.normalize(cause_act.reservations),
         true <- binding.amounts == declared do
      :ok
    else
      false -> {:error, {:duty_meter_reservation_binding_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  defp expected_duty_meter_amounts(projection, cause_act, duty) do
    case Map.get(projection.meter_recontainments, cause_act.ref) do
      nil ->
        with {:ok, binding} <- Map.fetch(projection.reservation_bindings, cause_act.ref) do
          {:ok, binding.amounts, nil}
        else
          :error -> {:error, {:reservation_binding_not_found, cause_act.ref}}
        end

      %{status: :open, cause_key: cause_key, mandate_ref: mandate_ref} = record ->
        cond do
          cause_key != duty.cause_key ->
            {:error, {:meter_recontainment_requires_causal_duty, cause_act.ref, cause_key}}

          mandate_ref != cause_act.mandate_ref ->
            {:error, {:meter_recontainment_mandate_mismatch, cause_act.ref}}

          true ->
            {:ok, record.recontained, record}
        end

      %{status: status} ->
        {:error, {:invalid_meter_recontainment_state, cause_act.ref, status}}

      _invalid ->
        {:error, {:invalid_meter_recontainment, cause_act.ref}}
    end
  end

  defp put_duty_meter_resolution(projection, resolution) do
    %{
      projection
      | duty_meter_resolutions:
          Map.put(
            projection.duty_meter_resolutions,
            resolution.disposition_act_ref,
            resolution
          )
    }
  end

  defp put_resolved_recontainment(projection, nil, _disposition_act_ref), do: projection

  defp put_resolved_recontainment(projection, record, disposition_act_ref) do
    updated = %{record | status: :disposed, disposition_act_ref: disposition_act_ref}

    %{
      projection
      | meter_recontainments: Map.put(projection.meter_recontainments, record.act_ref, updated)
    }
  end

  defp validate_duty_meter_disposed(projection, %{act_ref: nil} = duty, disposition, act_ref) do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(projection.duty_meter_resolutions, act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed(projection, duty, disposition, disposition_act_ref) do
    with {:ok, cause_act} <- Index.fetch_act(projection, duty.act_ref) do
      validate_duty_meter_disposed_for_act(
        projection,
        duty,
        cause_act,
        disposition,
        disposition_act_ref
      )
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         %{reservations: reservations} = cause_act,
         disposition,
         disposition_act_ref
       )
       when map_size(reservations) == 0 do
    cond do
      disposition.meter_resolution != :none ->
        {:error, {:duty_has_no_meter_reservation, duty.ref}}

      Map.has_key?(projection.reservation_states, cause_act.ref) ->
        {:error, {:unexpected_duty_reservation_state, cause_act.ref}}

      Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         cause_act,
         %{meter_resolution: :none},
         disposition_act_ref
       ) do
    recontainment = Map.get(projection.meter_recontainments, cause_act.ref)

    cond do
      Map.has_key?(projection.duty_meter_resolutions, disposition_act_ref) ->
        {:error, {:unexpected_duty_meter_resolution, disposition_act_ref}}

      Map.get(projection.reservation_states, cause_act.ref) == :suspended and
        match?(%{status: :open}, recontainment) and
          recontainment.cause_key != duty.cause_key ->
        :ok

      Map.get(projection.reservation_states, cause_act.ref) not in [:settled, :released] ->
        {:error, {:duty_meter_not_resolved, cause_act.ref}}

      true ->
        :ok
    end
  end

  defp validate_duty_meter_disposed_for_act(
         projection,
         duty,
         cause_act,
         disposition,
         disposition_act_ref
       ) do
    expected_status = resolved_reservation_status(disposition.meter_resolution)

    with {:ok, resolution} <-
           Map.fetch(projection.duty_meter_resolutions, disposition_act_ref),
         true <- resolution.act_ref == cause_act.ref,
         true <- resolution.duty_ref == duty.ref,
         true <- resolution.mandate_ref == cause_act.mandate_ref,
         true <- resolution.operation == disposition.meter_resolution,
         true <- Map.get(projection.reservation_states, cause_act.ref) == expected_status,
         :ok <-
           validate_resolved_recontainment(
             projection,
             cause_act.ref,
             duty.cause_key,
             disposition_act_ref
           ) do
      :ok
    else
      :error -> {:error, {:duty_meter_resolution_missing, disposition_act_ref}}
      false -> {:error, {:duty_meter_resolution_binding_mismatch, disposition_act_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_resolved_recontainment(projection, cause_act_ref, cause_key, disposition_act_ref) do
    case Map.get(projection.meter_recontainments, cause_act_ref) do
      nil ->
        :ok

      %{status: :disposed, cause_key: ^cause_key, disposition_act_ref: ^disposition_act_ref} ->
        :ok

      _invalid ->
        {:error, {:meter_recontainment_not_resolved, cause_act_ref}}
    end
  end

  defp resolved_reservation_status(:settle), do: :settled
  defp resolved_reservation_status(:release), do: :released

  defp validate_duty_meter_resolution(
         _projection,
         :settle,
         _supporting,
         _cause_act,
         _duty,
         _committed_at
       ),
       do: :ok

  defp validate_duty_meter_resolution(
         projection,
         :release,
         supporting,
         cause_act,
         duty,
         committed_at
       ) do
    if Enum.any?(supporting, fn
         {:outcome, %{status: :definitive_no_effect} = outcome} ->
           outcome.act_ref == cause_act.ref and
             (is_nil(duty.attempt_ref) or outcome.attempt_ref == duty.attempt_ref) and
             outcome_not_corrected_at?(projection, outcome, committed_at)

         _other ->
           false
       end) do
      :ok
    else
      {:error, :duty_meter_release_not_proven}
    end
  end

  defp outcome_not_corrected_at?(projection, outcome, committed_at) do
    not Enum.any?(projection.outcomes, fn {_ref, candidate} ->
      candidate.contradicts_outcome_ref == outcome.ref and
        candidate.observed_at <= committed_at
    end)
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
