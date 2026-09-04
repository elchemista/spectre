defmodule Spectre.Secret.CheckoutReceipt do
  @moduledoc """
  Ephemeral proof that one Grant was consumed into a durable Attempt.

  The receipt is minted only after ledger recovery confirms the Attempt. It is
  exact-bound to one broker and must be claimed once by that broker before any
  capability is released. Receipts are never ledger records or public results.

  HMAC verification makes the broker part of the trusted host boundary: a
  physically isolated deployment must provision the dedicated receipt key only
  to the sequencer and its broker.
  """

  alias Spectre.Canonical.Value

  @domain "spectre:checkout-receipt:v1\0"
  @minimum_secret_bytes 32
  @claim_fields [
    :domain_ref,
    :act_ref,
    :attempt_ref,
    :executor_ref,
    :material_digest,
    :generation,
    :grant_nonce_digest,
    :broker_ref,
    :ledger_revision,
    :issued_at,
    :expires_at
  ]

  @enforce_keys @claim_fields ++ [:mac]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          act_ref: String.t(),
          attempt_ref: String.t(),
          executor_ref: String.t(),
          material_digest: String.t(),
          generation: non_neg_integer(),
          grant_nonce_digest: String.t(),
          broker_ref: String.t(),
          ledger_revision: pos_integer(),
          issued_at: non_neg_integer(),
          expires_at: pos_integer(),
          mac: String.t()
        }

  @doc false
  @spec mint(map(), binary()) :: {:ok, t()} | {:error, term()}
  def mint(claims, secret)
      when is_map(claims) and is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes do
    with {:ok, claims} <- normalize_claims(claims),
         {:ok, encoded} <- Value.encode(claims) do
      mac = encoded |> sign(secret) |> Base.url_encode64(padding: false)
      {:ok, struct!(__MODULE__, Map.put(claims, :mac, mac))}
    end
  end

  def mint(_claims, _secret), do: {:error, :invalid_checkout_receipt_material}

  @doc "Verifies authenticity, exact binding and the half-open validity window."
  @spec verify(t(), binary(), map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = receipt, secret, expected)
      when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes and
             is_map(expected) do
    with {:ok, _claims} <- normalize_claims(claims(receipt)),
         :ok <- match_expected(receipt, expected),
         :ok <- current(receipt, Map.get(expected, :now)),
         :ok <- authentic(receipt, secret) do
      :ok
    end
  end

  def verify(_receipt, _secret, _expected), do: {:error, :invalid_checkout_receipt}

  @doc false
  @spec claims(t()) :: map()
  def claims(%__MODULE__{} = receipt),
    do: receipt |> Map.from_struct() |> Map.delete(:mac)

  defp normalize_claims(claims) do
    normalized = Map.take(claims, @claim_fields)

    cond do
      map_size(normalized) != length(@claim_fields) ->
        {:error, :incomplete_checkout_receipt}

      not Enum.all?(
        [
          :domain_ref,
          :act_ref,
          :attempt_ref,
          :executor_ref,
          :material_digest,
          :grant_nonce_digest,
          :broker_ref
        ],
        &non_empty_binary?(Map.fetch!(normalized, &1))
      ) ->
        {:error, :invalid_checkout_receipt_material}

      not (is_integer(normalized.generation) and normalized.generation >= 0) ->
        {:error, :invalid_checkout_receipt_generation}

      not (is_integer(normalized.ledger_revision) and normalized.ledger_revision > 0) ->
        {:error, :invalid_checkout_receipt_revision}

      not (is_integer(normalized.issued_at) and normalized.issued_at >= 0 and
             is_integer(normalized.expires_at) and
               normalized.expires_at > normalized.issued_at) ->
        {:error, :invalid_checkout_receipt_time_window}

      true ->
        {:ok, normalized}
    end
  end

  defp match_expected(receipt, expected) do
    @claim_fields
    |> Enum.reject(&(&1 in [:issued_at, :expires_at]))
    |> Enum.reduce_while(:ok, fn field, :ok ->
      case Map.fetch(expected, field) do
        {:ok, value} ->
          if value == Map.fetch!(receipt, field),
            do: {:cont, :ok},
            else: {:halt, {:error, {:checkout_receipt_mismatch, field}}}

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp current(_receipt, now) when not is_integer(now),
    do: {:error, :invalid_checkout_receipt_time}

  defp current(receipt, now) do
    cond do
      now < receipt.issued_at -> {:error, :checkout_receipt_not_yet_valid}
      now >= receipt.expires_at -> {:error, :checkout_receipt_expired}
      true -> :ok
    end
  end

  defp authentic(receipt, secret) do
    with {:ok, supplied} <- Base.url_decode64(receipt.mac, padding: false),
         {:ok, encoded} <- Value.encode(claims(receipt)) do
      expected = sign(encoded, secret)

      if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
        do: :ok,
        else: {:error, :checkout_receipt_authentication_failed}
    else
      _invalid -> {:error, :checkout_receipt_authentication_failed}
    end
  end

  defp sign(encoded, secret), do: :crypto.mac(:hmac, :sha256, secret, @domain <> encoded)
  defp non_empty_binary?(value), do: is_binary(value) and value != ""
end
