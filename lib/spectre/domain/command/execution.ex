defmodule Spectre.Domain.Command.Execution do
  @moduledoc """
  Orchestrates Grant issuance and the durable start of executor-mediated Acts.

  Host routes are resolved without becoming authority. A consumed Grant is
  recorded as an Attempt before any capability receipt is returned, and the
  recovered projection is rechecked before checkout. The module executes no
  external capability itself; Zone X remains in `Spectre.Attempt.Runner`.
  """

  alias Spectre.{Act, Attempt, Mandate}
  alias Spectre.Domain.{Event, Projection, Transaction}
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Execution.Router
  alias Spectre.GovernedAct.DispatchState
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel.{Authority, Grant}
  alias Spectre.Payload.Store, as: PayloadStore
  alias Spectre.Secret.CheckoutReceipt

  @doc "Mints an executor Grant when an admitted Act still has a dispatch path."
  @spec mint_grant(State.t(), Act.t() | nil) :: {:ok, Grant.t() | nil} | {:error, term()}

  def mint_grant(_state, nil), do: {:ok, nil}

  def mint_grant(state, %Act{} = act) do
    case GovernedExecution.mode(act) do
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
      DispatchState.attempted?(state.projection, act.ref) ->
        {:ok, nil}

      DispatchState.cancelled?(state.projection, act.ref) ->
        {:ok, nil}

      not DispatchState.pending?(state.projection, act.ref) ->
        {:error, {:act_not_dispatch_ready, act.ref}}

      true ->
        with {:ok, now} <- Transaction.trusted_recorded_at(state),
             :ok <- Transaction.duties_materialized(state.projection, now),
             :ok <- mandate_still_active(state.projection, act, now),
             :ok <- verify_act_payloads(state, act),
             {:ok, route} <-
               Router.fetch(
                 state.execution_boundary,
                 act.executor_ref,
                 act.executor_contract_ref
               ),
             :ok <-
               Router.profile_supports_act(
                 state.projection,
                 act,
                 route.broker_descriptor
               ),
             {:ok, nonce} <- Transaction.operational_id(state) do
          claims =
            act
            |> Grant.act_binding()
            |> Map.merge(%{
              domain_ref: state.projection.domain_ref,
              issued_at: now,
              expires_at: now + state.grant_ttl_ms,
              generation: state.generation,
              nonce: nonce
            })

          Grant.mint(
            claims,
            state.grant_secret
          )
        end
    end
  end

  @doc "Consumes a Grant into one durable Attempt and returns its checkout receipt."
  @spec consume(State.t(), Grant.t()) ::
          {:ok, State.t(), Act.t(), Attempt.t(), CheckoutReceipt.t()}
          | {:error, State.t(), term()}
  def consume(state, grant) do
    consume_with_retries(state, grant, state.conflict_retries)
  end

  defp consume_with_retries(state, grant, conflicts_left) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state),
         :ok <- Transaction.duties_materialized(state.projection, now),
         {:ok, act} <- fetch_granted_act(state, grant, now),
         {:ok, broker} <- Router.broker(state.execution_boundary),
         :ok <- Router.broker_supports_act(state.projection, act, broker),
         :ok <- verify_act_payloads(state, act),
         {:ok, attempt_ref} <- Transaction.operational_id(state),
         {:ok, attempt} <- build_attempt(state, act, grant, attempt_ref, now),
         {:ok, payload} <- Event.record(:attempt, attempt) do
      Commit.append(
        state,
        [payload],
        now,
        conflicts_left,
        &recovered_attempt(state, &1, act.ref, attempt.ref),
        &consume_with_retries(&1, grant, &2)
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
         expected =
           act
           |> Grant.act_binding()
           |> Map.merge(%{
             now: now,
             generation: state.generation,
             domain_ref: state.projection.domain_ref
           }),
         :ok <- Grant.verify(grant, state.grant_secret, expected),
         :ok <- mandate_still_active(state.projection, act, now) do
      {:ok, act}
    else
      :error -> {:error, {:act_not_found, grant.act_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_granted_act}
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
         true <- DispatchState.attempt_ref(projection, act_ref) == attempt_ref,
         {:ok, now} <- Transaction.trusted_recorded_at(recovered_state),
         {:ok, broker} <- Router.broker(recovered_state.execution_boundary),
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

  defp mint_checkout_receipt(state, act, attempt, broker, now) do
    claims =
      act
      |> CheckoutReceipt.binding(attempt, broker.descriptor.ref)
      |> Map.merge(%{
        domain_ref: state.projection.domain_ref,
        ledger_revision: state.projection.revision,
        issued_at: now,
        expires_at: now + state.grant_ttl_ms
      })

    CheckoutReceipt.mint(
      claims,
      state.checkout_receipt_secret
    )
  end

  defp mandate_still_active(projection, act, now) do
    authority_view = Projection.authority_view(projection)

    with {:ok, %Mandate{} = mandate} <- Map.fetch(projection.mandates, act.mandate_ref),
         :ok <- Authority.dispatchable?(act, mandate, authority_view, now) do
      :ok
    else
      :error -> {:error, {:mandate_not_found, act.mandate_ref}}
      {:ok, _invalid} -> {:error, {:invalid_mandate_record, act.mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp nonce_digest(nonce) do
    :crypto.hash(:sha256, nonce)
    |> Base.encode16(case: :lower)
  end
end
