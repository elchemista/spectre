defmodule Spectre.Domain.Transaction do
  @moduledoc """
  Durable transaction boundary shared by Domain command workflows.

  It validates provisional payloads, performs one exact append, classifies an
  ambiguous result and rebuilds the disposable projection from the ledger.
  Conflict policy remains with the calling workflow; this module never replies
  to callers, schedules work or grants a capability.

  Missing derived Duties are repaired through the same append/recovery path so
  every workflow observes an equivalent governed prefix.
  """

  alias Spectre.Attempt.Reconciler
  alias Spectre.Domain.{Bootstrap, Projection, Recovery}
  alias Spectre.Domain.Sequencer.State
  alias Spectre.GovernedAct.State, as: GovernedState
  alias Spectre.Id
  alias Spectre.Ledger.Writer
  alias Spectre.Payload.Store, as: PayloadStore

  @doc "Applies a prospective batch to disposable state without advancing the ledger head."
  @spec apply_payloads(GovernedState.t(), [map()]) ::
          {:ok, GovernedState.t()} | {:error, term()}
  def apply_payloads(projection, payloads) do
    Enum.reduce_while(payloads, {:ok, projection}, fn payload, {:ok, current} ->
      provisional_revision = current.revision + 1

      case Projection.apply_payload(current, payload, provisional_revision) do
        {:ok, next} -> {:cont, {:ok, %{next | revision: provisional_revision}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Appends one exact batch and returns the projection rebuilt from durable history."
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
      )
      when is_integer(recorded_at) and recorded_at >= 0 do
    latest_recorded_at = latest_recorded_at(state.projection)
    expected_revision = state.projection.revision

    if recorded_at >= latest_recorded_at do
      append_exact_at(
        state,
        batch_id,
        payloads,
        expected_revision,
        recorded_at,
        state.ambiguous_retries
      )
    else
      {:error, {:ledger_time_regression, recorded_at, latest_recorded_at}}
    end
  end

  def append_exact(
        _state,
        _batch_id,
        _payloads,
        recorded_at
      ),
      do: {:error, {:invalid_recorded_at, recorded_at}}

  defp append_exact_at(
         state,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         retries_left
       ) do
    with :ok <-
           verify_new_payload_references(state.payload_store, state.projection, payloads) do
      Writer.append(
        state.store,
        state.projection.domain_ref,
        batch_id,
        payloads,
        expected_revision,
        Keyword.put(state.ledger_opts, :recorded_at, recorded_at)
      )
    end
    |> case do
      {:ok, _revision} ->
        recover_after_append(state)

      {:error, :conflict} ->
        :conflict

      {:error, :ambiguous} ->
        classify_append_ambiguity(
          state,
          batch_id,
          payloads,
          expected_revision,
          recorded_at,
          retries_left
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp classify_append_ambiguity(
         state,
         batch_id,
         payloads,
         expected_revision,
         recorded_at,
         retries_left
       ) do
    case Recovery.classify_ambiguous(
           state.store,
           state.projection.domain_ref,
           batch_id,
           payloads,
           expected_revision,
           state.ledger_opts
         ) do
      {:ok, {:committed, _info}} ->
        recover_after_append(state)

      {:ok, :not_committed} when retries_left > 0 ->
        append_exact_at(
          state,
          batch_id,
          payloads,
          expected_revision,
          recorded_at,
          retries_left - 1
        )

      {:ok, :not_committed} ->
        {:error, :ambiguous_commit_unresolved}

      {:error, _reason} ->
        {:error, :ambiguous_commit_unresolved}
    end
  end

  @doc "Materializes every Duty required by the current prefix, retrying CAS conflicts."
  @spec repair_missing_duties(State.t()) :: {:ok, GovernedState.t()} | {:error, term()}
  def repair_missing_duties(%State{} = state) do
    repair_missing_duties(state, state.conflict_retries)
  end

  defp repair_missing_duties(state, conflicts_left) do
    projection = state.projection

    with {:ok, now} <- trusted_recorded_at(state),
         {:ok, plan} <- Reconciler.repair_plan(projection, now) do
      if plan.payloads == [] do
        {:ok, projection}
      else
        commit_duty_repair(state, projection, plan, conflicts_left, now)
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
         projection,
         plan,
         conflicts_left,
         recorded_at
       ) do
    with {:ok, _provisional} <- apply_payloads(projection, plan.payloads) do
      repair_state = %{state | projection: projection}

      case append_exact(
             repair_state,
             plan.batch_id,
             plan.payloads,
             recorded_at
           ) do
        {:ok, recovered} ->
          {:ok, recovered}

        :conflict when conflicts_left > 0 ->
          retry_duty_repair_after_conflict(
            repair_state,
            conflicts_left - 1
          )

        :conflict ->
          {:error, :duty_repair_conflict_retries_exhausted}

        {:error, {:durable_recovery_failed, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, {:duty_repair_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:duty_repair_failed, reason}}
    end
  end

  defp retry_duty_repair_after_conflict(state, conflicts_left) do
    with {:ok, projection} <- recover_verified(state) do
      repair_missing_duties(
        %{state | projection: projection},
        conflicts_left
      )
    end
  end

  defp recover_after_append(state) do
    case recover_with_repair(state) do
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
    case Recovery.recover(
           state.store,
           state.projection.domain_ref,
           state.projection.constitution,
           state.ledger_opts
         ) do
      {:ok, projection} ->
        with :ok <- Bootstrap.verify_projection(projection, State.verification_opts(state)),
             :ok <- PayloadStore.verify_live_references(state.payload_store, projection) do
          {:ok, projection}
        end

      :not_found ->
        {:error, :domain_ledger_disappeared}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Checks content references carried by a list of canonical event envelopes."
  @spec verify_payload_references(term(), [map()]) :: :ok | {:error, term()}
  def verify_payload_references(payload_store, payloads) do
    payloads
    |> Enum.flat_map(&content_payload_refs/1)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      case PayloadStore.verify(payload_store, ref) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_new_payload_references(payload_store, projection, payloads) do
    refs = payloads |> Enum.flat_map(&content_payload_refs/1) |> Enum.uniq()
    PayloadStore.verify_new_references(payload_store, projection, refs)
  end

  defp content_payload_refs(payload) do
    case {Map.get(payload, "type"), Map.get(payload, "data")} do
      {"evidence_recorded", data} when is_map(data) ->
        optional_payload_ref(Map.get(data, "payload_ref"))

      {"presentation_recorded", data} when is_map(data) ->
        optional_payload_ref(Map.get(data, "rendered_payload_ref"))

      _other ->
        []
    end
  end

  defp optional_payload_ref(nil), do: []
  defp optional_payload_ref(ref), do: [ref]

  @doc "Reads trusted host time while containing adapter failures."
  @spec trusted_now(module()) :: {:ok, integer()} | {:error, term()}
  def trusted_now(clock) do
    case clock.now() do
      value when is_integer(value) -> {:ok, value}
      _invalid -> {:error, :invalid_trusted_time}
    end
  rescue
    exception -> {:error, {:trusted_clock_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:trusted_clock_failed, kind}}
  end

  @doc "Returns monotonic ledger time relative to the recovered prefix."
  @spec trusted_recorded_at(State.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def trusted_recorded_at(%State{} = state) do
    with {:ok, now} <- trusted_now(state.clock) do
      {:ok, max(now, latest_recorded_at(state.projection))}
    end
  end

  defp latest_recorded_at(%GovernedState{} = projection) do
    projection.recorded_at
  end

  @doc "Obtains an opaque operational identifier from the configured source."
  @spec operational_id(State.t()) :: {:ok, String.t()} | {:error, term()}
  def operational_id(state) do
    {:ok, Id.generate(state.id_source)}
  rescue
    exception -> {:error, {:identifier_generation_failed, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:identifier_generation_failed, kind}}
  end
end
