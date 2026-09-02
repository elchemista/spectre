defmodule Spectre.Kernel.Grant do
  @moduledoc false

  alias Spectre.Canonical.Value

  @enforce_keys [
    :act_ref,
    :domain_ref,
    :executor_ref,
    :issued_at,
    :expires_at,
    :generation,
    :material_digest,
    :nonce,
    :mac
  ]
  defstruct @enforce_keys

  @typedoc false
  @type t :: %__MODULE__{
          act_ref: String.t(),
          domain_ref: String.t(),
          executor_ref: String.t(),
          issued_at: integer(),
          expires_at: integer(),
          generation: non_neg_integer(),
          material_digest: String.t(),
          nonce: String.t(),
          mac: String.t()
        }

  @type verification_error ::
          :invalid_grant
          | :grant_not_yet_valid
          | :grant_expired
          | :grant_generation_mismatch
          | :grant_executor_mismatch
          | :grant_material_mismatch
          | :grant_authentication_failed

  @doc false
  @spec mint(map(), binary()) :: {:ok, t()} | {:error, term()}
  def mint(claims, secret)
      when is_map(claims) and is_binary(secret) and byte_size(secret) >= 32 do
    with {:ok, normalized} <- normalize_claims(claims),
         {:ok, encoded} <- Value.encode(normalized) do
      mac = encoded |> sign(secret) |> Base.url_encode64(padding: false)
      {:ok, struct!(__MODULE__, Map.put(normalized, :mac, mac))}
    end
  end

  def mint(_claims, _secret), do: {:error, :invalid_grant_material}

  @doc false
  @spec verify(t(), binary(), map()) :: :ok | {:error, verification_error()}
  def verify(%__MODULE__{} = grant, secret, expected)
      when is_binary(secret) and is_map(expected) do
    with :ok <- valid_shape(grant),
         :ok <- matches(grant, expected),
         :ok <- not_expired(grant, expected),
         :ok <- authentic(grant, secret) do
      :ok
    end
  end

  def verify(_grant, _secret, _expected), do: {:error, :invalid_grant}

  @doc false
  @spec claims(t()) :: map()
  def claims(%__MODULE__{} = grant) do
    grant
    |> Map.from_struct()
    |> Map.delete(:mac)
  end

  defp normalize_claims(claims) do
    required = [
      :act_ref,
      :domain_ref,
      :executor_ref,
      :issued_at,
      :expires_at,
      :generation,
      :material_digest,
      :nonce
    ]

    normalized = Map.take(claims, required)

    cond do
      Map.keys(normalized) |> Enum.sort() != Enum.sort(required) ->
        {:error, :incomplete_grant_material}

      not Enum.all?([:act_ref, :domain_ref, :executor_ref, :material_digest, :nonce], fn key ->
        is_binary(Map.fetch!(normalized, key)) and Map.fetch!(normalized, key) != ""
      end) ->
        {:error, :invalid_grant_material}

      not is_integer(normalized.issued_at) or not is_integer(normalized.expires_at) or
        normalized.issued_at < 0 or normalized.expires_at <= normalized.issued_at ->
        {:error, :invalid_grant_time_window}

      not (is_integer(normalized.generation) and normalized.generation >= 0) ->
        {:error, :invalid_grant_generation}

      true ->
        {:ok, normalized}
    end
  end

  defp valid_shape(grant) do
    case normalize_claims(claims(grant)) do
      {:ok, _claims} when is_binary(grant.mac) and grant.mac != "" -> :ok
      _other -> {:error, :invalid_grant}
    end
  end

  defp matches(grant, expected) do
    checks = [
      {:generation, :grant_generation_mismatch},
      {:executor_ref, :grant_executor_mismatch},
      {:material_digest, :grant_material_mismatch},
      {:act_ref, :invalid_grant},
      {:domain_ref, :invalid_grant}
    ]

    Enum.reduce_while(checks, :ok, fn {field, reason}, :ok ->
      case Map.fetch(expected, field) do
        {:ok, value} ->
          if value == Map.fetch!(grant, field),
            do: {:cont, :ok},
            else: {:halt, {:error, reason}}

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp not_expired(grant, expected) do
    case Map.fetch(expected, :now) do
      {:ok, now} when is_integer(now) and now < grant.issued_at ->
        {:error, :grant_not_yet_valid}

      {:ok, now} when is_integer(now) and now < grant.expires_at ->
        :ok

      {:ok, now} when is_integer(now) ->
        {:error, :grant_expired}

      _missing_or_invalid ->
        {:error, :invalid_grant}
    end
  end

  defp authentic(grant, secret) do
    with {:ok, supplied} <- Base.url_decode64(grant.mac, padding: false),
         {:ok, encoded} <- Value.encode(claims(grant)) do
      expected = sign(encoded, secret)

      if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
        do: :ok,
        else: {:error, :grant_authentication_failed}
    else
      _error -> {:error, :grant_authentication_failed}
    end
  end

  defp sign(encoded, secret), do: :crypto.mac(:hmac, :sha256, secret, encoded)
end
