defmodule Spectre.Consent do
  @moduledoc """
  Closed, portable material that a person must evaluate before approval.

  The value is stored as a plain string-keyed map inside Candidate, Decision
  and Act records. `data_digest` is the canonical SHA-256 digest of the data
  represented by a Presentation; the data itself need not be duplicated in an
  Act. Purpose is repeated here deliberately and must match the Candidate's
  authoritative purpose fields.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [
    :schema_version,
    :recipient_refs,
    :data_digest,
    :cost,
    :purpose_ref,
    :purpose_params,
    :risk,
    :reversibility,
    :alternatives
  ]

  @type t :: %{required(String.t()) => term()}

  @doc "Builds the canonical consent value and rejects unknown or missing fields."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(value) do
    with {:ok, attrs} <- Portable.normalize_attrs(value, @fields, :consent),
         :ok <- required_fields(attrs),
         {:ok, recipient_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :recipient_refs), :consent_recipient_refs),
         attrs = Map.put(attrs, :recipient_refs, recipient_refs),
         :ok <- validate(attrs),
         canonical = canonical_attrs(attrs),
         :ok <- Portable.validate(canonical) do
      {:ok, canonical}
    end
  end

  @doc "Returns the canonical SHA-256 digest used to bind presented data."
  @spec data_digest(term()) :: {:ok, String.t()} | {:error, term()}
  def data_digest(data), do: Portable.digest(data)

  @doc "Checks that the duplicated purpose is the Candidate's current purpose."
  @spec validate_purpose(t(), String.t(), map()) :: :ok | {:error, term()}
  def validate_purpose(consent, purpose_ref, purpose_params) when is_map(consent) do
    if consent["purpose_ref"] == purpose_ref and consent["purpose_params"] == purpose_params,
      do: :ok,
      else: {:error, :consent_purpose_mismatch}
  end

  def validate_purpose(_consent, _purpose_ref, _purpose_params),
    do: {:error, :invalid_consent_material}

  defp required_fields(attrs) do
    case @fields -- Map.keys(attrs) do
      [] -> :ok
      missing -> {:error, {:missing_consent_fields, missing}}
    end
  end

  defp validate(attrs) do
    cond do
      attrs.schema_version != @schema_version ->
        {:error, {:unsupported_consent_schema_version, attrs.schema_version}}

      attrs.recipient_refs == [] ->
        {:error, :missing_consent_recipients}

      not sha256_digest?(attrs.data_digest) ->
        {:error, {:invalid_consent_data_digest, attrs.data_digest}}

      is_nil(attrs.cost) ->
        {:error, :missing_consent_cost}

      not is_map(attrs.purpose_params) or is_struct(attrs.purpose_params) ->
        {:error, {:invalid_consent_purpose_params, Portable.shape(attrs.purpose_params)}}

      is_nil(attrs.risk) ->
        {:error, :missing_consent_risk}

      is_nil(attrs.reversibility) ->
        {:error, :missing_consent_reversibility}

      not is_list(attrs.alternatives) ->
        {:error, {:invalid_consent_alternatives, Portable.shape(attrs.alternatives)}}

      true ->
        with :ok <- Portable.validate_ref(attrs.purpose_ref, :consent_purpose_ref),
             :ok <- Portable.validate(attrs.cost),
             :ok <- Portable.validate(attrs.purpose_params),
             :ok <- Portable.validate(attrs.risk),
             :ok <- Portable.validate(attrs.reversibility),
             :ok <- Portable.validate(attrs.alternatives) do
          :ok
        end
    end
  end

  defp canonical_attrs(attrs) do
    Portable.canonical_fields(attrs, @fields)
  end

  defp sha256_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    case Base.decode16(digest, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp sha256_digest?(_digest), do: false
end
