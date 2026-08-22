defmodule Spectre.Instance.Erasure.Status do
  @moduledoc """
  Portable projection of a store-private Instance erasure marker.

  The marker contains no checkpoint payload or Subject value. Its persisted
  representation is owned by the adapter; this struct is only the normalized
  read-back contract returned to core.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Ref

  @schema_version 1

  @enforce_keys [
    :schema_version,
    :erasure_id,
    :instance_key,
    :erased_revision,
    :checkpoint_digest,
    :owner_fencing_token,
    :erased_at
  ]
  defstruct schema_version: @schema_version,
            erasure_id: nil,
            instance_key: nil,
            erased_revision: nil,
            checkpoint_digest: nil,
            owner_fencing_token: nil,
            erased_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          erasure_id: String.t(),
          instance_key: String.t(),
          erased_revision: non_neg_integer() | nil,
          checkpoint_digest: String.t() | nil,
          owner_fencing_token: pos_integer(),
          erased_at: non_neg_integer()
        }

  @doc "Builds the public status corresponding to an accepted request."
  @spec from_request(Request.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def from_request(%Request{} = request, erased_at) do
    status = %__MODULE__{
      schema_version: @schema_version,
      erasure_id: request.erasure_id,
      instance_key: request.instance_key,
      erased_revision: request.expected_revision,
      checkpoint_digest: request.checkpoint_digest,
      owner_fencing_token: request.owner_fencing_token,
      erased_at: erased_at
    }

    case validate(status) do
      :ok -> {:ok, status}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate(t(), Ref.t() | nil) :: :ok | {:error, term()}
  def validate(status, ref \\ nil)

  def validate(%__MODULE__{} = status, ref) do
    with :ok <- schema(status.schema_version),
         :ok <- nonempty(status.erasure_id, :erasure_id),
         :ok <- nonempty(status.instance_key, :instance_key),
         :ok <- checkpoint_identity(status.erased_revision, status.checkpoint_digest),
         :ok <- positive(status.owner_fencing_token, :owner_fencing_token),
         :ok <- non_negative(status.erased_at, :erased_at),
         :ok <- ref_binding(status, ref) do
      Value.validate(Map.from_struct(status))
    end
  end

  def validate(value, _ref), do: {:error, {:invalid_instance_erasure_status, shape(value)}}

  @doc "Returns the canonical digest of the privacy-safe marker projection."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = status), do: status |> Map.from_struct() |> Value.digest!()

  defp ref_binding(_status, nil), do: :ok

  defp ref_binding(%__MODULE__{instance_key: key}, %Ref{key: key}), do: :ok
  defp ref_binding(%__MODULE__{}, %Ref{}), do: {:error, :instance_erasure_status_ref_mismatch}

  defp schema(@schema_version), do: :ok
  defp schema(value), do: {:error, {:unsupported_instance_erasure_status_schema, value}}

  defp checkpoint_identity(nil, nil), do: :ok

  defp checkpoint_identity(revision, <<digest::binary-size(64)>>)
       when is_integer(revision) and revision >= 0 do
    if String.match?(digest, ~r/\A[0-9a-f]{64}\z/),
      do: :ok,
      else: {:error, {:invalid_instance_erasure_status_field, :checkpoint_digest}}
  end

  defp checkpoint_identity(_revision, _digest),
    do: {:error, :invalid_instance_erasure_status_checkpoint_identity}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok

  defp nonempty(_value, field),
    do: {:error, {:invalid_instance_erasure_status_field, field}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok

  defp positive(_value, field),
    do: {:error, {:invalid_instance_erasure_status_field, field}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative(_value, field),
    do: {:error, {:invalid_instance_erasure_status_field, field}}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
