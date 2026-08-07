defmodule Spectre.Operation.Delivery do
  @moduledoc "Authorizes proactive delivery without performing transport I/O."

  alias Spectre.Operation.Delivery.Consent
  alias Spectre.Operation.Delivery.Policy
  alias Spectre.Operation.Delivery.Receipt
  alias Spectre.Operation.Event
  alias Spectre.Operation.Loop
  alias Spectre.Run.Value

  @doc """
  Decides whether `event` may be proactively delivered to `destination` under `policy`.

  Returns `{:ok, receipt}` when delivery is authorized, deferred (quiet hours) or
  routed to a digest, `{:duplicate, receipt}` when a prior receipt in `history`
  matches the dedupe key within its TTL, and `{:error, receipt}` when delivery is
  denied; the receipt records the decision and its reason. No transport I/O occurs.
  """
  @spec authorize(
          Event.t(),
          Loop.t(),
          term(),
          Policy.t() | map() | keyword(),
          [Receipt.t()],
          keyword()
        ) ::
          {:ok, Receipt.t()} | {:duplicate, Receipt.t()} | {:error, Receipt.t()}
  def authorize(%Event{} = event, %Loop{} = loop, destination, policy, history, opts \\ []) do
    policy = Policy.new(policy)
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    channel = Keyword.get(opts, :channel, destination_field(destination, :channel))
    consent = normalize_consent(Keyword.get(opts, :consent))
    dedupe_key = Keyword.get(opts, :dedupe_key, Value.token("delivery", {event.id, destination}))

    base = %Receipt{
      id: Keyword.get(opts, :receipt_id, Spectre.Identity.uuid7()),
      event_id: event.id,
      loop_id: loop.id,
      subject_id: loop.subject_id,
      destination: destination,
      channel: channel,
      consent_id: consent && consent.id,
      dedupe_key: dedupe_key,
      status: :denied,
      decided_at: now,
      metadata: Map.merge(policy.metadata, normalize_metadata(Keyword.get(opts, :metadata, %{})))
    }

    cond do
      event.loop_id != loop.id ->
        denied(base, :event_loop_mismatch)

      destination not in loop.destinations ->
        denied(base, :destination_not_authorized)

      policy.event_types != [] and event.type not in policy.event_types ->
        denied(base, :event_not_deliverable)

      policy.channels != [] and channel not in policy.channels ->
        denied(base, :channel_not_authorized)

      policy.consent_required and not valid_consent?(consent, loop, destination, channel, now) ->
        denied(base, :consent_missing_expired_or_revoked)

      duplicate = duplicate_receipt(history, dedupe_key, policy.dedupe_ttl_ms, now) ->
        {:duplicate, duplicate}

      rate_limited?(history, policy, destination, now) ->
        denied(base, :delivery_rate_limited)

      not_before = quiet_hours_end(policy, now) ->
        accepted(%{base | status: :deferred, reason: :quiet_hours, not_before: not_before})

      policy.mode == :digest ->
        accepted(%{base | status: :digest, reason: :digest_policy})

      true ->
        accepted(%{base | status: :authorized})
    end
  end

  @doc "Promotes a due deferred or digest receipt back to `:authorized`."
  @spec authorized(Receipt.t(), non_neg_integer()) :: {:ok, Receipt.t()} | {:error, term()}
  def authorized(%Receipt{} = receipt, at \\ System.system_time(:millisecond)) do
    Receipt.transition(receipt, :authorized, nil, at)
  end

  @doc """
  Marks an authorized receipt as delivered, recording the external receipt and time.

  Returns `{:ok, receipt}` with the updated receipt, or `{:error, reason}` when the
  transition is not allowed from the receipt's current status.
  """
  @spec delivered(Receipt.t(), term(), non_neg_integer()) ::
          {:ok, Receipt.t()} | {:error, term()}
  def delivered(%Receipt{} = receipt, external_receipt, at \\ System.system_time(:millisecond)) do
    Receipt.transition(receipt, :delivered, external_receipt, at)
  end

  @doc """
  Marks an authorized receipt as failed with the given reason.

  Returns `{:ok, receipt}` with the updated receipt, or `{:error, reason}` when the
  transition is not allowed from the receipt's current status.
  """
  @spec failed(Receipt.t(), term()) :: {:ok, Receipt.t()} | {:error, term()}
  def failed(%Receipt{} = receipt, reason), do: Receipt.transition(receipt, :failed, reason)

  @spec denied(Receipt.t(), term()) :: {:error, Receipt.t()}
  defp denied(receipt, reason) do
    receipt = %{receipt | status: :denied, reason: reason}

    case Receipt.validate(receipt) do
      :ok -> {:error, receipt}
      {:error, invalid} -> {:error, %{receipt | reason: {:invalid_delivery_receipt, invalid}}}
    end
  end

  @spec accepted(Receipt.t()) :: {:ok, Receipt.t()} | {:error, Receipt.t()}
  defp accepted(receipt) do
    case Receipt.validate(receipt) do
      :ok -> {:ok, receipt}
      {:error, reason} -> denied(receipt, {:invalid_delivery_receipt, reason})
    end
  end

  @spec valid_consent?(Consent.t() | nil, Loop.t(), term(), term(), non_neg_integer()) ::
          boolean()
  defp valid_consent?(%Consent{} = consent, loop, destination, channel, now) do
    Consent.active?(consent, now) and consent.subject_id == loop.subject_id and
      consent.destination == destination and
      (is_nil(consent.origin) or consent.origin == loop.origin or
         consent.origin in loop.authorized_origins) and
      (consent.channels == [] or channel in consent.channels)
  end

  defp valid_consent?(_consent, _loop, _destination, _channel, _now), do: false

  @spec normalize_consent(term()) :: Consent.t() | nil
  defp normalize_consent(%Consent{} = consent), do: consent

  defp normalize_consent(value) when is_map(value) or is_list(value) do
    Consent.new(value)
  rescue
    _exception -> nil
  end

  defp normalize_consent(_value), do: nil

  @spec duplicate_receipt([Receipt.t()], term(), non_neg_integer(), non_neg_integer()) ::
          Receipt.t() | nil
  defp duplicate_receipt(history, key, ttl, now) do
    Enum.find(history, fn receipt ->
      valid_receipt?(receipt) and receipt.dedupe_key == key and
        receipt.status in [:authorized, :deferred, :digest, :delivered] and
        now - receipt.decided_at <= ttl
    end)
  end

  @spec rate_limited?([Receipt.t()], Policy.t(), term(), non_neg_integer()) :: boolean()
  defp rate_limited?(history, policy, destination, now) do
    Enum.count(history, fn receipt ->
      valid_receipt?(receipt) and receipt.destination == destination and
        receipt.status in [:authorized, :deferred, :digest, :delivered] and
        now - receipt.decided_at <= policy.window_ms
    end) >= policy.max_deliveries
  end

  @spec valid_receipt?(term()) :: boolean()
  defp valid_receipt?(%Receipt{} = receipt), do: Receipt.validate(receipt) == :ok
  defp valid_receipt?(_receipt), do: false

  @spec quiet_hours_end(Policy.t(), non_neg_integer()) :: non_neg_integer() | nil
  defp quiet_hours_end(%Policy{quiet_hours: nil}, _now), do: nil

  defp quiet_hours_end(policy, now) do
    {start_minute, end_minute} = quiet_hours(policy.quiet_hours)
    local_ms = now + policy.utc_offset_minutes * 60_000
    minute = rem(div(local_ms, 60_000), 1440)

    inside? =
      if start_minute < end_minute,
        do: minute >= start_minute and minute < end_minute,
        else: minute >= start_minute or minute < end_minute

    if inside? do
      minutes = if minute < end_minute, do: end_minute - minute, else: 1440 - minute + end_minute
      now + minutes * 60_000
    end
  end

  @spec quiet_hours(
          {non_neg_integer(), non_neg_integer()}
          | %{start: non_neg_integer(), end: non_neg_integer()}
        ) :: {non_neg_integer(), non_neg_integer()}
  defp quiet_hours({start_minute, end_minute}), do: {start_minute, end_minute}
  defp quiet_hours(%{start: start_minute, end: end_minute}), do: {start_minute, end_minute}

  @spec destination_field(term(), atom()) :: term() | nil
  defp destination_field(destination, :channel) when is_map(destination),
    do: Map.get(destination, :channel, Map.get(destination, "channel"))

  defp destination_field(_destination, _key), do: nil

  @spec normalize_metadata(term()) :: map()
  defp normalize_metadata(value) when is_map(value), do: value

  defp normalize_metadata(value) when is_list(value),
    do: if(Keyword.keyword?(value), do: Map.new(value), else: %{})

  defp normalize_metadata(_value), do: %{}
end
