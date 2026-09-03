defmodule Spectre.Domain.Command.Execution do
  @moduledoc """
  Orchestrates Grant issuance and the durable start of executor-mediated Acts.

  Host routes are resolved without becoming authority. A consumed Grant is
  recorded as an Attempt before any capability receipt is returned, and the
  recovered projection is rechecked before checkout. The module executes no
  external capability itself; Zone X remains in `Spectre.Attempt.Runner`.
  """

  alias Spectre.{Act, Attempt, Governance}
  alias Spectre.Domain.{Event, Projection, Transaction}
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Execution.Router
  alias Spectre.Kernel.{Authority, Grant}
  alias Spectre.Mandate.Ancestry
  alias Spectre.Payload.Store, as: PayloadStore
  alias Spectre.Secret.CheckoutReceipt

  @doc "Mints an executor Grant when an admitted Act still has a dispatch path."
  @spec mint_grant(State.t(), Act.t() | nil) :: {:ok, Grant.t() | nil} | {:error, term()}

  def mint_grant(_state, nil), do: {:ok, nil}

  def mint_grant(state, %Act{} = act) do
    case Governance.execution_mode(act) do
      {:ok, :ledger_internal} ->
        {:ok, nil}

      {:ok, :executor_mediated} ->
        mint_executor_grant(state, act)

      {:error, _reason} = error ->
        error
    end
  end

  defp mint_executor_grant(state, act) do
    cond do
      Map.has_key?(state.projection.attempts_by_act, act.ref) ->
        {:ok, nil}

      Map.has_key?(state.projection.dispatch_cancellations, act.ref) ->
        {:ok, nil}

      not MapSet.member?(state.projection.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      true ->
        with {:ok, now} <- Transaction.trusted_recorded_at(state.clock, state.projection),
             :ok <- Transaction.duties_materialized(state.projection, state.constitution, now),
             :ok <- mandate_still_active(state.projection, act, now),
             :ok <- verify_act_payloads(state, act),
             {:ok, route} <-
               Router.fetch(
                 state,
                 act.executor_ref,
                 act.executor_contract_ref
               ),
             :ok <-
               Router.profile_supports_act(
                 state.projection,
                 act,
                 route.broker_descriptor
               ),
             {:ok, nonce} <- Transaction.operational_id(state, "grant") do
          Grant.mint(
            %{
              act_ref: act.ref,
              domain_ref: state.domain_ref,
              executor_ref: act.executor_ref,
              issued_at: now,
              expires_at: now + state.grant_ttl_ms,
              generation: state.generation,
              material_digest: act.material_digest,
              nonce: nonce
            },
            state.grant_secret
          )
        end
    end
  end

  @doc "Consumes a Grant into one durable Attempt and returns its checkout receipt."
  @spec consume(State.t(), Grant.t(), keyword(), non_neg_integer()) ::
          {:ok, State.t(), Act.t(), Attempt.t(), CheckoutReceipt.t()}
          | {:error, State.t(), term()}
  def consume(state, grant, ledger_opts, conflicts_left) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state.clock, state.projection),
         :ok <- Transaction.duties_materialized(state.projection, state.constitution, now),
         {:ok, act} <- fetch_granted_act(state, grant, now),
         {:ok, broker} <- Router.broker(state),
         :ok <- Router.broker_supports_act(state.projection, act, broker),
         :ok <- verify_act_payloads(state, act),
         :ok <- attempt_available(state.projection, act, grant),
         {:ok, attempt_ref} <- Transaction.operational_id(state, "attempt"),
         {:ok, attempt} <- build_attempt(state, act, grant, attempt_ref, now),
         {:ok, payload} <- Event.record(:attempt, attempt),
         {:ok, _provisional} <- Transaction.apply_payloads(state.projection, [payload]),
         {:ok, batch_id} <- Transaction.operational_id(state, "attempt-batch") do
      expected_revision = state.projection.revision

      append_result =
        Transaction.append_exact(
          state,
          batch_id,
          [payload],
          expected_revision,
          ledger_opts,
          state.ambiguous_retries,
          now
        )

      Commit.resolve(
        state,
        append_result,
        conflicts_left,
        &recovered_attempt(state, &1, act.ref, attempt.ref),
        &retry_consumption_after_conflict(state, grant, ledger_opts, &1)
      )
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp verify_act_payloads(state, act) do
    refs = PayloadStore.act_payload_refs(state.projection, act)
    PayloadStore.verify_usable(state.payload_store, state.projection, refs)
  end

  defp verify_post_attempt_payloads(state, act) do
    refs = PayloadStore.post_attempt_payload_refs(state.projection, act)
    PayloadStore.verify_usable(state.payload_store, state.projection, refs)
  end

  defp fetch_granted_act(state, grant, now) do
    with {:ok, %Act{} = act} <- Map.fetch(state.projection.acts, grant.act_ref),
         :ok <-
           Grant.verify(grant, state.grant_secret, %{
             now: now,
             generation: state.generation,
             executor_ref: act.executor_ref,
             material_digest: act.material_digest,
             act_ref: act.ref,
             domain_ref: state.domain_ref
           }),
         :ok <- mandate_still_active(state.projection, act, now) do
      {:ok, act}
    else
      :error -> {:error, {:act_not_found, grant.act_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_granted_act}
    end
  end

  defp attempt_available(projection, act, grant) do
    nonce_digest = nonce_digest(grant.nonce)

    cond do
      not Governance.executor_mediated?(act) ->
        {:error, {:act_not_executor_mediated, act.ref}}

      not MapSet.member?(projection.dispatch_ready, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      Map.has_key?(projection.attempts_by_act, act.ref) ->
        {:error, {:act_already_attempted, act.ref}}

      MapSet.member?(projection.consumed_nonces, nonce_digest) ->
        {:error, {:grant_nonce_already_consumed, nonce_digest}}

      true ->
        :ok
    end
  end

  defp build_attempt(state, act, grant, attempt_ref, now) do
    Attempt.new(%{
      ref: attempt_ref,
      act_ref: act.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest,
      generation: state.generation,
      grant_nonce_digest: nonce_digest(grant.nonce),
      started_at: now
    })
  end

  defp recovered_attempt(state, projection, act_ref, attempt_ref) do
    recovered_state = %{state | projection: projection}

    with {:ok, %Act{} = act} <- Map.fetch(projection.acts, act_ref),
         {:ok, %Attempt{} = attempt} <- Map.fetch(projection.attempts, attempt_ref),
         true <- Map.get(projection.attempts_by_act, act_ref) == attempt_ref,
         {:ok, now} <- Transaction.trusted_recorded_at(state.clock, projection),
         {:ok, broker} <- Router.broker(recovered_state),
         :ok <- mandate_still_active(projection, act, now),
         :ok <- Router.broker_supports_act(projection, act, broker),
         :ok <- verify_post_attempt_payloads(recovered_state, act),
         {:ok, receipt} <- mint_checkout_receipt(recovered_state, act, attempt, broker, now) do
      {:ok, recovered_state, act, attempt, receipt}
    else
      :error ->
        halted = Control.halt(state, :attempt_not_recovered)
        {:error, halted, :attempt_not_recovered}

      false ->
        halted = Control.halt(state, :attempt_projection_mismatch)
        {:error, halted, :attempt_projection_mismatch}

      _invalid ->
        halted = Control.halt(state, :invalid_recovered_attempt)
        {:error, halted, :invalid_recovered_attempt}
    end
  end

  defp retry_consumption_after_conflict(state, grant, ledger_opts, conflicts_left) do
    case Transaction.recover_with_repair(state, ledger_opts) do
      {:ok, projection} ->
        consume(
          %{state | projection: projection},
          grant,
          ledger_opts,
          conflicts_left
        )

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, {:durable_recovery_failed, reason}}
    end
  end

  defp mint_checkout_receipt(state, act, attempt, broker, now) do
    CheckoutReceipt.mint(
      %{
        domain_ref: state.domain_ref,
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        executor_ref: act.executor_ref,
        material_digest: act.material_digest,
        generation: attempt.generation,
        grant_nonce_digest: attempt.grant_nonce_digest,
        broker_ref: broker.descriptor.ref,
        ledger_revision: state.projection.revision,
        issued_at: now,
        expires_at: now + state.grant_ttl_ms
      },
      state.checkout_receipt_secret
    )
  end

  defp mandate_still_active(projection, act, now) do
    authority_view = Projection.authority_view(projection)

    with :ok <- Authority.containment_status(act, authority_view),
         {:ok, mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
         true <- mandate.revision == act.mandate_revision,
         true <- now >= mandate.not_before and now < mandate.expires_at,
         :ok <- Authority.restriction_status(mandate, authority_view),
         :ok <- Authority.meter_debt_status(mandate, authority_view),
         :ok <- mandate_not_revoked(projection, mandate, now) do
      :ok
    else
      :error -> {:error, {:mandate_not_found, act.mandate_ref}}
      false -> {:error, {:mandate_not_dispatchable, act.mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp mandate_not_revoked(projection, mandate, now) do
    case Ancestry.status(projection.mandates, projection.revocations, mandate, now) do
      {:ok, :current} -> :ok
      {:ok, {:revoked, :direct, ref}} -> {:error, {:mandate_revoked, ref}}
      {:ok, {:revoked, :ancestor, ref}} -> {:error, {:mandate_ancestor_revoked, ref}}
      {:error, _reason} = error -> error
    end
  end

  defp nonce_digest(nonce) do
    :crypto.hash(:sha256, nonce)
    |> Base.encode16(case: :lower)
  end
end
