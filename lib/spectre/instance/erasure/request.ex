defmodule Spectre.Instance.Erasure.Request do
  @moduledoc """
  Fenced request passed to a Checkpoint Store erasure callback.

  A present checkpoint is bound by revision and canonical digest. Both fields
  are `nil` only when core observed the key as absent and asks the adapter to
  install an anti-resurrection marker for that absence.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Instance.Ref

  @schema_version 1

  @enforce_keys [
    :schema_version,
    :erasure_id,
    :instance_key,
    :expected_revision,
    :checkpoint_digest,
    :owner_fencing_token,
    :requested_at
  ]
  defstruct schema_version: @schema_version,
            erasure_id: nil,
            instance_key: nil,
            expected_revision: nil,
            checkpoint_digest: nil,
            owner_fencing_token: nil,
            requested_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          erasure_id: String.t(),
          instance_key: String.t(),
          expected_revision: non_neg_integer() | nil,
          checkpoint_digest: String.t() | nil,
          owner_fencing_token: pos_integer(),
          requested_at: non_neg_integer()
        }

  @doc "Builds a validated request bound to one exact Instance Ref."
  @spec new(Ref.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Ref{} = ref, attrs) when is_list(attrs), do: new(ref, Map.new(attrs))

  def new(%Ref{} = ref, attrs) when is_map(attrs) and not is_struct(attrs) do
    request = %__MODULE__{
      schema_version: Map.get(attrs, :schema_version, @schema_version),
      erasure_id: Map.get(attrs, :erasure_id),
      instance_key: Map.get(attrs, :instance_key, ref.key),
      expected_revision: Map.get(attrs, :expected_revision),
      checkpoint_digest: Map.get(attrs, :checkpoint_digest),
      owner_fencing_token: Map.get(attrs, :owner_fencing_token),
      requested_at: Map.get(attrs, :requested_at)
    }

    with :ok <- validate(request),
         true <- request.instance_key == ref.key do
      {:ok, request}
    else
      false -> {:error, :instance_erasure_request_ref_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def new(%Ref{}, value), do: {:error, {:invalid_instance_erasure_request, shape(value)}}

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = request) do
    with :ok <- schema(request.schema_version),
         :ok <- nonempty(request.erasure_id, :erasure_id),
         :ok <- nonempty(request.instance_key, :instance_key),
         :ok <- checkpoint_identity(request.expected_revision, request.checkpoint_digest),
         :ok <- positive(request.owner_fencing_token, :owner_fencing_token),
         :ok <- non_negative(request.requested_at, :requested_at) do
      Value.validate(Map.from_struct(request))
    end
  end

  def validate(value), do: {:error, {:invalid_instance_erasure_request, shape(value)}}

  defp schema(@schema_version), do: :ok
  defp schema(value), do: {:error, {:unsupported_instance_erasure_request_schema, value}}

  defp checkpoint_identity(nil, nil), do: :ok

  defp checkpoint_identity(revision, digest)
       when is_integer(revision) and revision >= 0 and is_binary(digest) do
    if digest?(digest),
      do: :ok,
      else: {:error, {:invalid_instance_erasure_request_field, :checkpoint_digest}}
  end

  defp checkpoint_identity(_revision, _digest),
    do: {:error, :invalid_instance_erasure_checkpoint_identity}

  defp digest?(<<digest::binary-size(64)>>),
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp digest?(_value), do: false

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok

  defp nonempty(_value, field),
    do: {:error, {:invalid_instance_erasure_request_field, field}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok

  defp positive(_value, field),
    do: {:error, {:invalid_instance_erasure_request_field, field}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative(_value, field),
    do: {:error, {:invalid_instance_erasure_request_field, field}}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
