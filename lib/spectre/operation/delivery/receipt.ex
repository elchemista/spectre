defmodule Spectre.Operation.Delivery.Receipt do
  @moduledoc "Portable audit receipt for one governed delivery decision."

  alias Spectre.Run.Value

  @statuses [:authorized, :deferred, :digest, :denied, :delivered, :failed]

  @enforce_keys [
    :id,
    :event_id,
    :loop_id,
    :subject_id,
    :destination,
    :dedupe_key,
    :status,
    :decided_at
  ]
  defstruct [
    :id,
    :event_id,
    :loop_id,
    :subject_id,
    :destination,
    :channel,
    :consent_id,
    :dedupe_key,
    :status,
    :reason,
    :decided_at,
    :not_before,
    :delivered_at,
    :external_receipt,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Validates the receipt's identity, target, status, timestamps and portability.

  Returns `:ok`, or `{:error, reason}` naming the first invalid field or the
  status whose required fields are inconsistent.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = receipt) do
    cond do
      Enum.any?([receipt.id, receipt.event_id, receipt.loop_id, receipt.dedupe_key], fn value ->
        not (is_binary(value) and value != "")
      end) ->
        {:error, :invalid_delivery_receipt_identity}

      not (is_binary(receipt.subject_id) and receipt.subject_id != "") or
          is_nil(receipt.destination) ->
        {:error, :invalid_delivery_receipt_target}

      receipt.status not in @statuses ->
        {:error, {:invalid_delivery_receipt_status, receipt.status}}

      not is_integer(receipt.decided_at) or receipt.decided_at < 0 ->
        {:error, :invalid_delivery_receipt_decision_time}

      not optional_time?(receipt.not_before) or not optional_time?(receipt.delivered_at) ->
        {:error, :invalid_delivery_receipt_time}

      not is_nil(receipt.consent_id) and
          (not is_binary(receipt.consent_id) or receipt.consent_id == "") ->
        {:error, :invalid_delivery_receipt_consent}

      not is_map(receipt.metadata) ->
        {:error, :invalid_delivery_receipt_metadata}

      true ->
        with :ok <- validate_status_fields(receipt) do
          portable(receipt)
        end
    end
  end

  @doc """
  Same as `validate/1` but returns the receipt, raising `ArgumentError` when invalid.
  """
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = receipt) do
    case validate(receipt) do
      :ok -> receipt
      {:error, reason} -> raise ArgumentError, "invalid delivery receipt: #{inspect(reason)}"
    end
  end

  @doc """
  Re-authorizes a due `:deferred`/`:digest` receipt, or transitions an
  `:authorized` receipt to `:delivered` or `:failed`.

  For `:delivered`, `detail` is stored as the external receipt and `at` as the
  delivery time; for `:failed`, `detail` becomes the failure reason. Repeating a
  transition with the same detail is idempotent. Returns `{:ok, receipt}` or
  `{:error, reason}` when the transition is not allowed from the current status.
  """
  @spec transition(t(), :authorized | :delivered | :failed, term(), non_neg_integer()) ::
          {:ok, t()} | {:error, term()}
  def transition(receipt, outcome, detail, at \\ System.system_time(:millisecond))

  def transition(
        %__MODULE__{status: :delivered, external_receipt: detail} = receipt,
        :delivered,
        detail,
        _at
      ),
      do: with(:ok <- validate(receipt), do: {:ok, receipt})

  def transition(%__MODULE__{status: :failed, reason: detail} = receipt, :failed, detail, _at),
    do: with(:ok <- validate(receipt), do: {:ok, receipt})

  def transition(%__MODULE__{status: :authorized} = receipt, :authorized, _detail, _at),
    do: with(:ok <- validate(receipt), do: {:ok, receipt})

  def transition(
        %__MODULE__{status: :deferred, not_before: not_before} = receipt,
        :authorized,
        _detail,
        at
      )
      when is_integer(not_before) and is_integer(at) and at >= not_before do
    updated = %{receipt | status: :authorized, reason: nil, not_before: nil}
    with :ok <- validate(updated), do: {:ok, updated}
  end

  def transition(%__MODULE__{status: :digest} = receipt, :authorized, _detail, at)
      when is_integer(at) and at >= receipt.decided_at do
    updated = %{receipt | status: :authorized, reason: nil}
    with :ok <- validate(updated), do: {:ok, updated}
  end

  def transition(%__MODULE__{status: :authorized} = receipt, :delivered, detail, at)
      when is_integer(at) and at >= 0 do
    updated = %{receipt | status: :delivered, delivered_at: at, external_receipt: detail}
    with :ok <- validate(updated), do: {:ok, updated}
  end

  def transition(%__MODULE__{status: :authorized} = receipt, :failed, reason, _at)
      when not is_nil(reason) do
    updated = %{receipt | status: :failed, reason: reason}
    with :ok <- validate(updated), do: {:ok, updated}
  end

  def transition(%__MODULE__{} = receipt, outcome, _detail, _at)
      when outcome in [:authorized, :delivered, :failed],
      do: {:error, {:invalid_delivery_receipt_transition, receipt.status, outcome}}

  def transition(%__MODULE__{}, outcome, _detail, _at),
    do: {:error, {:invalid_delivery_outcome, outcome}}

  @spec validate_status_fields(t()) :: :ok | {:error, atom()}
  defp validate_status_fields(%__MODULE__{status: :authorized} = receipt) do
    if is_nil(receipt.reason) and is_nil(receipt.not_before) and is_nil(receipt.delivered_at) and
         is_nil(receipt.external_receipt),
       do: :ok,
       else: {:error, :invalid_authorized_delivery_receipt}
  end

  defp validate_status_fields(%__MODULE__{status: :deferred} = receipt) do
    if not is_nil(receipt.reason) and is_integer(receipt.not_before) and
         receipt.not_before > receipt.decided_at and is_nil(receipt.delivered_at) and
         is_nil(receipt.external_receipt),
       do: :ok,
       else: {:error, :invalid_deferred_delivery_receipt}
  end

  defp validate_status_fields(%__MODULE__{status: :digest} = receipt) do
    if not is_nil(receipt.reason) and is_nil(receipt.not_before) and
         is_nil(receipt.delivered_at) and is_nil(receipt.external_receipt),
       do: :ok,
       else: {:error, :invalid_digest_delivery_receipt}
  end

  defp validate_status_fields(%__MODULE__{status: :denied} = receipt) do
    if not is_nil(receipt.reason) and is_nil(receipt.not_before) and
         is_nil(receipt.delivered_at) and is_nil(receipt.external_receipt),
       do: :ok,
       else: {:error, :invalid_denied_delivery_receipt}
  end

  defp validate_status_fields(%__MODULE__{status: :delivered} = receipt) do
    if is_nil(receipt.reason) and is_nil(receipt.not_before) and
         is_integer(receipt.delivered_at) and receipt.delivered_at >= receipt.decided_at,
       do: :ok,
       else: {:error, :invalid_delivered_delivery_receipt}
  end

  defp validate_status_fields(%__MODULE__{status: :failed} = receipt) do
    if not is_nil(receipt.reason) and is_nil(receipt.not_before) and
         is_nil(receipt.delivered_at) and is_nil(receipt.external_receipt),
       do: :ok,
       else: {:error, :invalid_failed_delivery_receipt}
  end

  @spec optional_time?(term()) :: boolean()
  defp optional_time?(nil), do: true
  defp optional_time?(value), do: is_integer(value) and value >= 0

  @spec portable(t()) :: :ok | {:error, {:nonportable_delivery_receipt, term()}}
  defp portable(receipt) do
    case Value.validate(receipt, [:delivery, :receipt, receipt.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_delivery_receipt, reason}}
    end
  end
end
