defmodule Spectre.Operation.Delivery.Consent do
  @moduledoc "Revocable, expiring consent for proactive delivery to one destination."

  alias Spectre.Run.Value

  @enforce_keys [:id, :subject_id, :destination, :granted_at]
  defstruct [
    :id,
    :subject_id,
    :origin,
    :destination,
    :granted_at,
    :expires_at,
    :revoked_at,
    channels: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(map() | keyword()) :: t()
  def new(%__MODULE__{} = consent), do: validate!(consent)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    consent = %__MODULE__{
      id: attr(attrs, :id, Spectre.Identity.uuid7()),
      subject_id: attr(attrs, :subject_id),
      origin: attr(attrs, :origin),
      destination: attr(attrs, :destination),
      granted_at: attr(attrs, :granted_at, System.system_time(:millisecond)),
      expires_at: attr(attrs, :expires_at),
      revoked_at: attr(attrs, :revoked_at),
      channels: List.wrap(attr(attrs, :channels, [])),
      metadata: attr(attrs, :metadata, %{})
    }

    validate!(consent)
  end

  @spec active?(t(), non_neg_integer()) :: boolean()
  def active?(%__MODULE__{} = consent, now) when is_integer(now) and now >= 0 do
    is_nil(consent.revoked_at) and
      (is_nil(consent.expires_at) or consent.expires_at > now)
  end

  def active?(%__MODULE__{}, _now), do: false

  @spec revoke(t(), non_neg_integer()) :: t()
  def revoke(consent, at \\ System.system_time(:millisecond))

  def revoke(%__MODULE__{revoked_at: revoked_at} = consent, _at) when is_integer(revoked_at),
    do: consent

  def revoke(%__MODULE__{} = consent, at)
      when is_integer(at) and at >= 0 do
    %{consent | revoked_at: at} |> validate!()
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = consent) do
    cond do
      not (is_binary(consent.id) and consent.id != "") ->
        {:error, :delivery_consent_id_required}

      not (is_binary(consent.subject_id) and consent.subject_id != "") ->
        {:error, :delivery_consent_subject_required}

      is_nil(consent.destination) ->
        {:error, :delivery_consent_destination_required}

      not is_integer(consent.granted_at) or consent.granted_at < 0 ->
        {:error, :invalid_delivery_consent_grant_time}

      not is_nil(consent.expires_at) and
          (not is_integer(consent.expires_at) or consent.expires_at <= consent.granted_at) ->
        {:error, :invalid_delivery_consent_expiry}

      not is_nil(consent.revoked_at) and
          (not is_integer(consent.revoked_at) or consent.revoked_at < consent.granted_at) ->
        {:error, :invalid_delivery_consent_revocation}

      not is_list(consent.channels) or Enum.uniq(consent.channels) != consent.channels or
          Enum.any?(consent.channels, &is_nil/1) ->
        {:error, :invalid_delivery_consent_channels}

      not is_map(consent.metadata) ->
        {:error, :invalid_delivery_consent_metadata}

      true ->
        case Value.validate(consent, [:delivery, :consent, consent.id]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:nonportable_delivery_consent, reason}}
        end
    end
  end

  defp validate!(consent) do
    case validate(consent) do
      :ok -> consent
      {:error, reason} -> raise ArgumentError, "invalid delivery consent: #{inspect(reason)}"
    end
  end

  defp attr(map, key, default \\ nil),
    do: Map.get(map, key, default)
end
