defmodule Spectre.Kernel.Grant do
  @moduledoc """
  Internal, ephemeral permission to consume one committed Act into an Attempt.

  This type is documented so runtime orchestration signatures are inspectable;
  it is not part of the application-facing proposal API. Grants are minted only
  after commit, bound to a Domain generation and exact Act material, and checked
  again at consumption. They are not ledger records, externally verifiable
  signatures or reusable provider credentials. Applications should submit via
  `Spectre.propose/3`, which does not return this internal value.
  """

  require Spectre.Portable

  alias Spectre.{Act, Portable, Seal, Validation}

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

  @typedoc "Internal sealed claims; never persist or expose this value to a Mind."
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
         :ok <- not_expired(grant, expected) do
      authentic(grant, secret)
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
        Portable.is_non_empty_binary(Map.fetch!(normalized, key))
      end) ->
        {:error, :invalid_grant_material}

      not Portable.is_non_negative_integer(normalized.issued_at) or
        not is_integer(normalized.expires_at) or normalized.expires_at <= normalized.issued_at ->
        {:error, :invalid_grant_time_window}

      not Portable.is_non_negative_integer(normalized.generation) ->
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

    Validation.all(checks, fn {field, reason} ->
      actual = Map.fetch!(grant, field)

      case Map.fetch(expected, field) do
        {:ok, ^actual} -> :ok
        {:ok, _different} -> {:error, reason}
        :error -> {:error, :invalid_grant}
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
