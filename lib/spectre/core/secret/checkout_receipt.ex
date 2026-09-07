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

  require Spectre.Portable

  alias Spectre.{Act, Attempt, Portable, Seal, Validation}

  @domain "spectre:checkout-receipt:v1\0"
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
  def mint(claims, secret) when is_map(claims) do
    if Seal.valid_secret?(secret) do
      with {:ok, claims} <- normalize_claims(claims),
           {:ok, mac} <- Seal.sign(claims, secret, @domain) do
        {:ok, struct!(__MODULE__, Map.put(claims, :mac, mac))}
      end
    else
      {:error, :invalid_checkout_receipt_material}
    end
  end

  def mint(_claims, _secret), do: {:error, :invalid_checkout_receipt_material}

  @doc "Verifies authenticity, exact binding and the half-open validity window."
  @spec verify(t(), binary(), map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = receipt, secret, expected)
      when is_map(expected) do
    if Seal.valid_secret?(secret) do
      with {:ok, _claims} <- normalize_claims(claims(receipt)),
           :ok <- match_expected(receipt, expected),
           :ok <- current(receipt, Map.get(expected, :now)) do
        authentic(receipt, secret)
      end
    else
      {:error, :invalid_checkout_receipt}
    end
  end

  def verify(_receipt, _secret, _expected), do: {:error, :invalid_checkout_receipt}

  @doc false
  @spec claims(t()) :: map()
  def claims(%__MODULE__{} = receipt),
    do: receipt |> Map.from_struct() |> Map.delete(:mac)

  @doc false
  @spec binding(Act.t(), Attempt.t(), String.t()) :: map()
  def binding(%Act{} = act, %Attempt{} = attempt, broker_ref) do
    %{
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest,
      generation: attempt.generation,
      grant_nonce_digest: attempt.grant_nonce_digest,
      broker_ref: broker_ref
    }
  end

  @doc false
  @spec validate_binding(t(), Act.t(), Attempt.t(), String.t()) :: :ok | {:error, term()}
  def validate_binding(%__MODULE__{} = receipt, %Act{} = act, %Attempt{} = attempt, broker_ref) do
    match_expected(receipt, binding(act, attempt, broker_ref))
  end

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

      not Portable.is_non_negative_integer(normalized.generation) ->
        {:error, :invalid_checkout_receipt_generation}

      not Portable.is_positive_integer(normalized.ledger_revision) ->
        {:error, :invalid_checkout_receipt_revision}

      not (Portable.is_non_negative_integer(normalized.issued_at) and
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
    |> Validation.all(fn field ->
      actual = Map.fetch!(receipt, field)

      case Map.fetch(expected, field) do
        {:ok, ^actual} -> :ok
        {:ok, _different} -> {:error, {:checkout_receipt_mismatch, field}}
        :error -> :ok
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
    case Seal.verify(claims(receipt), receipt.mac, secret, @domain) do
      :ok -> :ok
      :error -> {:error, :checkout_receipt_authentication_failed}
    end
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
end
