defmodule Spectre.Kernel.Grant do
  @moduledoc false

  alias Spectre.{Act, Seal}

  @seal_domain "spectre:grant:v1\0"

  @claim_fields [
    :act_ref,
    :domain_ref,
    :executor_ref,
    :issued_at,
    :expires_at,
    :generation,
    :material_digest,
    :nonce
  ]
  @enforce_keys @claim_fields ++ [:mac]
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
  def mint(claims, secret) when is_map(claims) do
    if Seal.valid_secret?(secret) do
      with {:ok, normalized} <- normalize_claims(claims),
           {:ok, mac} <- Seal.sign(normalized, secret, @seal_domain) do
        {:ok, struct!(__MODULE__, Map.put(normalized, :mac, mac))}
      end
    else
      {:error, :invalid_grant_material}
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

  @doc false
  @spec act_binding(Act.t()) :: map()
  def act_binding(%Act{} = act) do
    %{
      act_ref: act.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest
    }
  end

  @doc false
  @spec validate_act_binding(t(), Act.t()) :: :ok | {:error, :grant_act_binding_mismatch}
  def validate_act_binding(%__MODULE__{} = grant, %Act{} = act) do
    if Enum.all?(act_binding(act), fn {field, expected} ->
         Map.fetch!(grant, field) == expected
       end),
       do: :ok,
       else: {:error, :grant_act_binding_mismatch}
  end

  defp normalize_claims(claims) do
    normalized = Map.take(claims, @claim_fields)

    cond do
      map_size(normalized) != length(@claim_fields) ->
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
    case Seal.verify(claims(grant), grant.mac, secret, @seal_domain) do
      :ok -> :ok
      :error -> {:error, :grant_authentication_failed}
    end
  end
end
