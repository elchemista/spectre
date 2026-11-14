defmodule Spectre.GAM.Domain.Transaction do
  @moduledoc """
  Durable transaction boundary shared by Domain command workflows.

  It performs one exact append, classifies an ambiguous result and advances the
  disposable projection only from a confirmed durable batch. Conflicts resume
  from the verified prefix; full replay remains the cold-start recovery path.
  Conflict policy remains with the calling workflow; this module never replies
  to callers, schedules work or grants a capability.

  Missing derived Duties are repaired through the same append/recovery path so
  every workflow observes an equivalent governed prefix.

  A physical batch is not a new authority boundary. This workflow changes only
  the supplied logical Domain; sharing a Store or supervisor never merges the
  identities, Mandates or obligations of independently governed participants.
  """

  require Spectre.GAM.Portable

  alias Spectre.GAM.{Adapter, Clock, Id, Portable}
  alias Spectre.GAM.Attempt.Reconciler
  alias Spectre.GAM.Clock.Guard, as: ClockGuard
  alias Spectre.GAM.Domain.{Bootstrap, Recovery}
  alias Spectre.GAM.Domain.Sequencer.State
  alias Spectre.GAM.GovernedAct.Commit
  alias Spectre.GAM.GovernedAct.State, as: GovernedState
  alias Spectre.GAM.Ledger.Writer
  alias Spectre.GAM.Payload.Store, as: PayloadStore

  # A repair should converge in one batch at a fixed trusted time. Keep a
  # bounded allowance for causal follow-ups; a derivation bug must not produce
  # an unbounded stream of durable "repair" events.
  @max_duty_repair_rounds 8

  @doc """
  Appends one exact batch and returns the confirmed, Duty-complete projection.

  Preparation is pure; only the store acknowledgement/recovery establishes
  durability. `:conflict` returns control to the command's CAS policy. Failure
  after a write does not prove that the write was absent, so it remains an
  error rather than a fabricated previous state or permission to dispatch.
  This function never mints a Grant or calls an executor.
  """
  @spec append_exact(
          State.t(),
          String.t(),
          [map()],
          non_neg_integer()
        ) ::
          {:ok, GovernedState.t()} | :conflict | {:error, term()}
  def append_exact(
        state,
        batch_id,
        payloads,
        recorded_at
      ) do
    with {:ok, projection} <- append_verified(state, batch_id, payloads, recorded_at) do
      case repair_missing_duties(%{state | projection: projection}) do
        {:ok, projection} ->
          Spectre.GAM.Domain.Notifications.committed(projection.domain_ref, projection.revision)
          {:ok, projection}

        {:error, reason} ->
          {:error, {:durable_recovery_failed, reason}}
      end
    end
  end

  defp append_verified(
         state,
         batch_id,
         payloads,
         recorded_at
       )
       when Portable.is_non_negative_integer(recorded_at) do
    latest_recorded_at = latest_recorded_at(state.projection)

    if recorded_at >= latest_recorded_at do
      with {:ok, prepared} <-
             Commit.prepare(state.projection, batch_id, payloads, recorded_at) do
        append_exact_at(state, prepared, state.ambiguous_retries)
      end
    else
      {:error, {:ledger_time_regression, recorded_at, latest_recorded_at}}
    end
  end

  defp append_verified(
         _state,
         _batch_id,
         _payloads,
         recorded_at
       ),
       do: {:error, {:invalid_recorded_at, recorded_at}}

  defp append_exact_at(
         state,
         %Commit{payloads: payloads, recorded_at: recorded_at, receipt: receipt} =
           prepared,
         retries_left
       ) do
    with :ok <-
           verify_new_payload_references(state.payload_store, state.projection, payloads) do
      Writer.append(
        state.store,
        state.projection.domain_ref,
        receipt.batch_id,
        payloads,
        receipt.expected_revision,
        Keyword.put(state.ledger_opts, :recorded_at, recorded_at)
      )
    end
    |> case do
      {:ok, revision} ->
        if revision === receipt.last_revision,
          do: recover_after_append(state, prepared),
          else: {:error, {:durable_recovery_failed, {:unexpected_append_revision, revision}}}

      {:error, :conflict} ->
        :conflict

      {:error, :ambiguous} ->
        classify_append_ambiguity(state, prepared, retries_left)

      {:error, _reason} = error ->
        error
    end
  end

  defp classify_append_ambiguity(
         state,
         %Commit{payloads: payloads, receipt: receipt} = prepared,
         retries_left
       ) do
    case Recovery.classify_ambiguous(
           state.store,
           state.projection.domain_ref,
           receipt.batch_id,
           payloads,
           receipt.expected_revision,
           state.ledger_opts
         ) do
      {:ok, {:committed, _info}} ->
        recover_after_append(state, prepared)

      {:ok, :not_committed} when retries_left > 0 ->
        append_exact_at(state, prepared, retries_left - 1)

      {:ok, :not_committed} ->
        {:error, :ambiguous_commit_unresolved}

      {:error, _reason} ->
        {:error, :ambiguous_commit_unresolved}
    end
  end

  @doc "Materializes every Duty required by the current prefix, retrying CAS conflicts."
  @spec repair_missing_duties(State.t()) :: {:ok, GovernedState.t()} | {:error, term()}
  def repair_missing_duties(%State{} = state) do
    with {:ok, now} <- trusted_recorded_at(state) do
      repair_missing_duties(state, now, state.conflict_retries, @max_duty_repair_rounds)
    end
  end

  defp repair_missing_duties(state, now, conflicts_left, rounds_left) do
    projection = state.projection

    with {:ok, plan} <- Reconciler.repair_plan(projection, now) do
      cond do
        plan.payloads == [] ->
          {:ok, projection}

        rounds_left == 0 ->
          {:error, :duty_repair_rounds_exhausted}

        true ->
          commit_duty_repair(
            %{state | projection: projection},
            plan,
            conflicts_left,
            now,
            rounds_left
          )
      end
    end
  end

  @doc "Checks that no derived Duty is waiting to be durably materialized."
  @spec duties_materialized(GovernedState.t(), non_neg_integer()) :: :ok | {:error, term()}
  def duties_materialized(projection, now) do
    with {:ok, plan} <- Reconciler.repair_plan(projection, now) do
      if plan.payloads == [], do: :ok, else: {:error, :required_duties_pending}
    end
  end

  defp commit_duty_repair(
         state,
         plan,
         conflicts_left,
         recorded_at,
         rounds_left
       ) do
    case append_verified(
           state,
           plan.batch_id,
           plan.payloads,
           recorded_at
         ) do
      {:ok, recovered} ->
        repair_missing_duties(
          %{state | projection: recovered},
          max(recorded_at, recovered.recorded_at),
          conflicts_left,
          rounds_left - 1
        )

      :conflict when conflicts_left > 0 ->
        retry_duty_repair_after_conflict(
          state,
          conflicts_left - 1,
          recorded_at,
          rounds_left
        )

      :conflict ->
        {:error, :duty_repair_conflict_retries_exhausted}

      {:error, {:durable_recovery_failed, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:duty_repair_failed, reason}}
    end
  end

  defp retry_duty_repair_after_conflict(state, conflicts_left, now, rounds_left) do
    with {:ok, projection} <- recover_verified(state) do
      repair_missing_duties(
        %{state | projection: projection},
        max(now, projection.recorded_at),
        conflicts_left,
        rounds_left
      )
    end
  end

  defp recover_after_append(state, prepared) do
    result =
      with {:ok, projection} <-
             Recovery.confirm_prepared(
               state.store,
               state.projection,
               prepared,
               state.ledger_opts,
               &verify_recovered_payloads(state.payload_store, &1, &2)
             ),
           :ok <- verify_projection(state, projection) do
        {:ok, projection}
      end

    case result do
      {:ok, projection} -> {:ok, projection}
      {:error, reason} -> {:error, {:durable_recovery_failed, reason}}
    end
  end

  @doc "Recovers verified state and completes any missing derived-Duty batch."
  @spec recover_with_repair(State.t()) ::
          {:ok, GovernedState.t()} | {:error, term()}
  def recover_with_repair(state) do
    with {:ok, projection} <- recover_verified(state) do
      repair_missing_duties(%{state | projection: projection})
    end
  end

  @doc "Recovers and verifies the durable projection without adding repair events."
  @spec recover_verified(State.t()) ::
          {:ok, GovernedState.t()} | {:error, term()}
  def recover_verified(state) do
    case Recovery.resume(
           state.store,
           state.projection,
           state.ledger_opts,
           &verify_recovered_payloads(state.payload_store, &1, &2)
         ) do
      {:ok, projection} ->
        with :ok <- verify_projection(state, projection) do
          {:ok, projection}
        end

      :not_found ->
        {:error, :domain_ledger_disappeared}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_projection(state, projection) do
    Bootstrap.verify_extension(state.projection, projection, State.verification_opts(state))
  end

  defp verify_recovered_payloads(store, projection, refs) do
    PayloadStore.verify_references(store, projection, refs)
  end

  @doc "Checks content references carried by a list of canonical event envelopes."
  @spec verify_payload_references(term(), [map()]) :: :ok | {:error, term()}
  def verify_payload_references(payload_store, payloads) do
    payloads
    |> PayloadStore.introduced_refs()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case PayloadStore.verify(payload_store, ref) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_new_payload_references(payload_store, projection, payloads) do
    refs = PayloadStore.introduced_refs(payloads)
    PayloadStore.verify_new_references(payload_store, projection, refs)
  end

  @doc "Reads trusted host time while containing adapter failures."
  @spec trusted_now(module()) :: {:ok, non_neg_integer()} | {:error, term()}
  def trusted_now(clock) do
    case Clock.read(clock) do
      {:ok, now} ->
        {:ok, now}

      {:error, :invalid_clock_value} ->
        {:error, :invalid_trusted_time}

      {:error, reason} ->
        {:error, {:trusted_clock_failed, reason}}
    end
  end

  @doc "Returns monotonic ledger time relative to the recovered prefix."
  @spec trusted_recorded_at(State.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def trusted_recorded_at(%State{} = state) do
    with {:ok, now} <- trusted_now(state.clock),
         :ok <- ClockGuard.validate(state.clock_guard, now),
         :ok <- clock_matches_prefix(state.clock_guard, now, latest_recorded_at(state.projection)) do
      {:ok, max(now, latest_recorded_at(state.projection))}
    end
  end

  defp clock_matches_prefix(nil, _now, _recorded_at), do: :ok

  defp clock_matches_prefix(guard, now, recorded_at) do
    if recorded_at - now <= guard.tolerance_ms,
      do: :ok,
      else: {:error, {:ledger_clock_ahead, recorded_at, now}}
  end

  defp latest_recorded_at(%GovernedState{} = projection) do
    projection.recorded_at
  end

  @doc "Obtains an opaque operational identifier from the configured source."
  @spec operational_id(State.t()) :: {:ok, String.t()} | {:error, term()}
  def operational_id(%State{} = state) do
    case Adapter.invoke(state.id_source, :generate, []) do
      {:ok, id} ->
        if Id.valid?(id),
          do: {:ok, id},
          else: {:error, {:invalid_operational_identifier, Portable.shape(id)}}

      {:error, reason} ->
        {:error, {:identifier_generation_failed, reason}}
    end
  end
end
