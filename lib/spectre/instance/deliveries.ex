defmodule Spectre.Instance.Deliveries do
  @moduledoc """
  Proactive-delivery ledger for `Spectre.Instance`.

  Normalizes and validates delivery consents, policies and receipts, and
  commits their transitions into the canonical `:correlations` section with
  the corresponding delivery events. Committed events are returned unrouted;
  the Instance owns feeding them back into the Run scheduler.
  """

  alias Spectre.AgentRef
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Loops
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Delivery
  alias Spectre.Operation.Delivery.Consent, as: DeliveryConsent
  alias Spectre.Operation.Delivery.Policy, as: DeliveryPolicy
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop

  @delivery_receipt_limit 512

  @doc "Normalizes and validates a supplied delivery consent value."
  @spec normalize_consent(term()) :: {:ok, DeliveryConsent.t()} | {:error, term()}
  def normalize_consent(%DeliveryConsent{} = consent) do
    with :ok <- DeliveryConsent.validate(consent), do: {:ok, consent}
  end

  def normalize_consent(value) when is_map(value) or is_list(value) do
    {:ok, DeliveryConsent.new(value)}
  rescue
    exception -> {:error, {:invalid_delivery_consent, Exception.message(exception)}}
  end

  def normalize_consent(value), do: {:error, {:invalid_delivery_consent, value}}

  @doc "Normalizes and validates a supplied delivery policy value."
  @spec normalize_policy(term()) :: {:ok, DeliveryPolicy.t()} | {:error, term()}
  def normalize_policy(%DeliveryPolicy{} = policy) do
    with :ok <- DeliveryPolicy.validate(policy), do: {:ok, policy}
  end

  def normalize_policy(value) when is_map(value) or is_list(value) or is_nil(value) do
    {:ok, DeliveryPolicy.new(value)}
  rescue
    exception -> {:error, {:invalid_delivery_policy, Exception.message(exception)}}
  end

  def normalize_policy(value), do: {:error, {:invalid_delivery_policy, value}}

  @doc "Requires the consent subject to match the owning Instance Subject."
  @spec validate_consent_subject(DeliveryConsent.t(), InstanceState.t()) ::
          :ok | {:error, :delivery_consent_subject_mismatch}
  def validate_consent_subject(consent, %InstanceState{} = data) do
    if consent.subject_id == data.subject.id,
      do: :ok,
      else: {:error, :delivery_consent_subject_mismatch}
  end

  @doc "Commits a consent grant or revocation as one canonical transition."
  @spec commit_consent(InstanceState.t(), DeliveryConsent.t(), keyword(), atom()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def commit_consent(%InstanceState{} = data, consent, opts, transition) do
    key = delivery_consent_key(consent.id)
    correlations = Loops.canonical_value!(data, :correlations)
    existing = Map.get(correlations, key)

    with :ok <- DeliveryConsent.validate(consent),
         :ok <-
           validate_delivery_consent_transition(existing, consent, transition) do
      maybe_commit_consent(data, correlations, key, existing, consent, opts, transition)
    end
  end

  @doc "Fetches one committed consent by id."
  @spec fetch_consent(InstanceState.t(), term()) ::
          {:ok, DeliveryConsent.t()} | {:error, term()}
  def fetch_consent(_data, consent_id)
      when not is_binary(consent_id) or consent_id == "",
      do: {:error, :invalid_delivery_consent_id}

  def fetch_consent(%InstanceState{} = data, consent_id) do
    case Map.get(Loops.canonical_value!(data, :correlations), delivery_consent_key(consent_id)) do
      %DeliveryConsent{} = consent -> {:ok, consent}
      _missing -> {:error, :delivery_consent_not_found}
    end
  end

  @doc "Finds the newest active consent for a loop Subject and destination."
  @spec find_consent(InstanceState.t(), OperationLoop.t(), term(), integer()) ::
          DeliveryConsent.t() | nil
  def find_consent(%InstanceState{} = data, loop, destination, now) do
    data
    |> Loops.canonical_value!(:correlations)
    |> Map.values()
    |> Enum.filter(&match?(%DeliveryConsent{}, &1))
    |> Enum.sort_by(& &1.granted_at, :desc)
    |> Enum.find(fn consent ->
      consent.subject_id == loop.subject_id and consent.destination == destination and
        DeliveryConsent.active?(consent, now)
    end)
  end

  @doc "Fetches one committed operation event by id."
  @spec committed_operation_event(InstanceState.t(), term()) ::
          {:ok, OperationEvent.t()} | {:error, :operation_event_not_found}
  def committed_operation_event(%InstanceState{} = data, event_id) do
    event =
      data
      |> Loops.canonical_value!(:events)
      |> Map.get(:records, [])
      |> Enum.find(&(&1.id == event_id))

    if match?(%OperationEvent{}, event),
      do: {:ok, event},
      else: {:error, :operation_event_not_found}
  end

  @doc "Lists the committed, structurally valid delivery receipts."
  @spec committed_receipts(InstanceState.t()) :: [DeliveryReceipt.t()]
  def committed_receipts(%InstanceState{} = data) do
    data
    |> Loops.canonical_value!(:correlations)
    |> Map.values()
    |> Enum.filter(fn
      %DeliveryReceipt{} = receipt -> match?(:ok, DeliveryReceipt.validate(receipt))
      _other -> false
    end)
  end

  @doc "Returns true when the caller may read one delivery receipt."
  @spec receipt_visible?(InstanceState.t(), DeliveryReceipt.t(), keyword()) :: boolean()
  def receipt_visible?(%InstanceState{} = data, %DeliveryReceipt{} = receipt, opts) do
    case Loops.operation_loop(data, receipt.loop_id) do
      {:ok, loop, _control} ->
        receipt.subject_id == loop.subject_id and match?(:ok, Loops.authorize_loop(loop, opts))

      {:error, _reason} ->
        false
    end
  end

  @doc "Fetches one committed delivery receipt by id."
  @spec fetch_receipt(InstanceState.t(), term()) ::
          {:ok, DeliveryReceipt.t()} | {:error, term()}
  def fetch_receipt(_data, receipt_id)
      when not is_binary(receipt_id) or receipt_id == "",
      do: {:error, :invalid_delivery_receipt_id}

  def fetch_receipt(%InstanceState{} = data, receipt_id) do
    case Map.get(Loops.canonical_value!(data, :correlations), delivery_receipt_key(receipt_id)) do
      %DeliveryReceipt{} = receipt -> {:ok, receipt}
      _missing -> {:error, :delivery_receipt_not_found}
    end
  end

  @doc "Applies a transport outcome to an authorized receipt."
  @spec update_receipt(DeliveryReceipt.t(), atom(), term()) ::
          {:ok, DeliveryReceipt.t()} | {:error, term()}
  def update_receipt(receipt, :delivered, external_receipt),
    do: Delivery.delivered(receipt, external_receipt)

  def update_receipt(receipt, :failed, reason),
    do: Delivery.failed(receipt, reason)

  def update_receipt(_receipt, outcome, _detail),
    do: {:error, {:invalid_delivery_outcome, outcome}}

  @doc """
  Commits a delivery receipt with its decision event.

  Re-committing an identical receipt is a no-op. The committed events are
  returned unrouted.
  """
  @spec commit_receipt(InstanceState.t(), OperationLoop.t(), DeliveryReceipt.t(), keyword()) ::
          {:ok, InstanceState.t(), [OperationEvent.t()]} | {:error, term()}
  def commit_receipt(%InstanceState{} = data, loop, receipt, opts) do
    correlations = Loops.canonical_value!(data, :correlations)
    key = delivery_receipt_key(receipt.id)
    existing = Map.get(correlations, key)

    with :ok <- DeliveryReceipt.validate(receipt),
         :ok <- validate_delivery_receipt_owner(receipt, loop),
         :ok <- validate_delivery_receipt_transition(existing, receipt) do
      maybe_commit_receipt(data, loop, receipt, opts, correlations, key, existing)
    end
  end

  defp maybe_commit_consent(
         data,
         _correlations,
         _key,
         existing,
         consent,
         _opts,
         _transition
       )
       when existing == consent,
       do: {:ok, data}

  defp maybe_commit_consent(data, correlations, key, _existing, consent, opts, transition) do
    correlations = Map.put(correlations, key, consent)

    with {:ok, next} <-
           Commit.canonical_sections(data, %{correlations: correlations},
             correlation_id: Keyword.get(opts, :correlation_id, consent.id),
             causation_id: Keyword.get(opts, :causation_id),
             provenance: Keyword.get(opts, :provenance, %{source: :delivery_policy}),
             metadata: %{transition: transition, consent_id: consent.id}
           ) do
      _ =
        Spectre.Journal.record(
          data.agent,
          transition,
          %{consent_id: consent.id, canonical_revision: next.canonical.revision},
          data.base_opts
        )

      {:ok, next}
    end
  end

  defp maybe_commit_receipt(data, _loop, receipt, _opts, _correlations, _key, existing)
       when existing == receipt,
       do: {:ok, data, []}

  defp maybe_commit_receipt(data, loop, receipt, opts, correlations, key, _existing) do
    correlations =
      correlations
      |> Map.put(key, receipt)
      |> trim_delivery_receipts()

    revision = data.canonical.revision + 1
    event_type = delivery_event_type(receipt.status)

    event =
      OperationEvent.new(loop, event_type,
        agent_id: AgentRef.key(data.agent_ref),
        revision: revision,
        correlation_id: Keyword.get(opts, :correlation_id, loop.correlation_id),
        causation_id: receipt.event_id,
        provenance: Keyword.get(opts, :provenance, %{source: :delivery_policy}),
        payload: %{receipt_id: receipt.id, status: receipt.status, reason: receipt.reason},
        metadata: %{transition: :delivery_decision}
      )

    writes = %{
      correlations: correlations,
      events: Commit.append_events(data, [event])
    }

    with :ok <- Commit.validate_operation_events(data, [event]),
         {:ok, next} <-
           Commit.canonical_sections(data, writes,
             correlation_id: event.correlation_id,
             causation_id: event.causation_id,
             provenance: event.provenance,
             metadata: %{transition: :delivery_decision, receipt_id: receipt.id}
           ) do
      _ =
        Spectre.Journal.record(
          data.agent,
          :delivery_decision,
          %{
            receipt_id: receipt.id,
            loop_id: loop.id,
            status: receipt.status,
            canonical_revision: next.canonical.revision
          },
          data.base_opts
        )

      {:ok, next, [event]}
    end
  end

  defp validate_delivery_consent_transition(
         nil,
         %DeliveryConsent{revoked_at: nil},
         :delivery_consent_granted
       ),
       do: :ok

  defp validate_delivery_consent_transition(nil, _consent, :delivery_consent_granted),
    do: {:error, :cannot_grant_revoked_delivery_consent}

  defp validate_delivery_consent_transition(
         %DeliveryConsent{} = current,
         next,
         :delivery_consent_revoked
       ) do
    immutable = [
      :id,
      :subject_id,
      :origin,
      :destination,
      :granted_at,
      :expires_at,
      :channels,
      :metadata
    ]

    if Map.take(current, immutable) == Map.take(next, immutable) and
         (current.revoked_at == next.revoked_at or
            (is_nil(current.revoked_at) and is_integer(next.revoked_at))) do
      :ok
    else
      {:error, :invalid_delivery_consent_revocation_transition}
    end
  end

  defp validate_delivery_consent_transition(%DeliveryConsent{} = current, next, _transition) do
    if current == next,
      do: :ok,
      else: {:error, {:delivery_consent_id_conflict, next.id}}
  end

  defp validate_delivery_consent_transition(_invalid, _next, _transition),
    do: {:error, :invalid_existing_delivery_consent}

  defp validate_delivery_receipt_owner(receipt, loop) do
    if receipt.loop_id == loop.id and receipt.subject_id == loop.subject_id,
      do: :ok,
      else: {:error, :delivery_receipt_owner_mismatch}
  end

  defp validate_delivery_receipt_transition(nil, _receipt), do: :ok
  defp validate_delivery_receipt_transition(receipt, receipt), do: :ok

  defp validate_delivery_receipt_transition(
         %DeliveryReceipt{status: :authorized} = current,
         %DeliveryReceipt{status: status} = next
       )
       when status in [:delivered, :failed] do
    immutable = [
      :id,
      :event_id,
      :loop_id,
      :subject_id,
      :destination,
      :channel,
      :consent_id,
      :dedupe_key,
      :decided_at,
      :not_before,
      :metadata
    ]

    if Map.take(current, immutable) == Map.take(next, immutable),
      do: :ok,
      else: {:error, :delivery_receipt_identity_changed}
  end

  defp validate_delivery_receipt_transition(
         %DeliveryReceipt{} = current,
         %DeliveryReceipt{} = next
       ),
       do: {:error, {:invalid_delivery_receipt_transition, current.status, next.status}}

  defp validate_delivery_receipt_transition(_invalid, _next),
    do: {:error, :invalid_existing_delivery_receipt}

  defp trim_delivery_receipts(correlations) do
    receipts =
      correlations
      |> Enum.filter(fn {_key, value} -> match?(%DeliveryReceipt{}, value) end)
      |> Enum.sort_by(fn {_key, receipt} -> receipt.decided_at end, :desc)

    receipts
    |> Enum.drop(@delivery_receipt_limit)
    |> Enum.reduce(correlations, fn {key, _receipt}, acc -> Map.delete(acc, key) end)
  end

  defp delivery_event_type(:authorized), do: :delivery_authorized
  defp delivery_event_type(:deferred), do: :delivery_deferred
  defp delivery_event_type(:digest), do: :delivery_digest_queued
  defp delivery_event_type(:denied), do: :delivery_denied
  defp delivery_event_type(:delivered), do: :delivery_recorded
  defp delivery_event_type(:failed), do: :delivery_failed

  defp delivery_consent_key(id) when is_binary(id), do: "delivery:consent:" <> id
  defp delivery_receipt_key(id) when is_binary(id), do: "delivery:receipt:" <> id
end
