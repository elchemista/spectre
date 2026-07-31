defmodule Spectre.Operation.Artifact do
  @moduledoc "Portable reference to output produced by an operational loop."

  alias Spectre.Run.Value

  @enforce_keys [:id, :kind, :created_at]
  defstruct [:id, :kind, :uri, :digest, :media_type, :created_at, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom() | String.t(),
          uri: String.t() | nil,
          digest: String.t() | nil,
          media_type: String.t() | nil,
          created_at: non_neg_integer(),
          metadata: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    kind = Map.get(attrs, :kind, Map.get(attrs, "kind"))

    unless (is_atom(kind) and not is_nil(kind)) or (is_binary(kind) and kind != ""),
      do: raise(ArgumentError, "artifact kind is required")

    artifact = %__MODULE__{
      id: Map.get(attrs, :id, Map.get(attrs, "id", Spectre.Identity.uuid7())),
      kind: kind,
      uri: Map.get(attrs, :uri, Map.get(attrs, "uri")),
      digest: Map.get(attrs, :digest, Map.get(attrs, "digest")),
      media_type: Map.get(attrs, :media_type, Map.get(attrs, "media_type")),
      created_at:
        Map.get(
          attrs,
          :created_at,
          Map.get(attrs, "created_at", System.system_time(:millisecond))
        ),
      metadata: Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
    }

    validate!(artifact)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = artifact) do
    cond do
      not (is_binary(artifact.id) and artifact.id != "") ->
        {:error, :invalid_operation_artifact_id}

      not valid_kind?(artifact.kind) ->
        {:error, :invalid_operation_artifact_kind}

      not optional_binary?(artifact.uri) ->
        {:error, :invalid_operation_artifact_uri}

      not optional_binary?(artifact.digest) ->
        {:error, :invalid_operation_artifact_digest}

      not optional_binary?(artifact.media_type) ->
        {:error, :invalid_operation_artifact_media_type}

      not is_integer(artifact.created_at) or artifact.created_at < 0 ->
        {:error, :invalid_operation_artifact_timestamp}

      not is_map(artifact.metadata) ->
        {:error, :invalid_operation_artifact_metadata}

      true ->
        portable(artifact)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = artifact) do
    case validate(artifact) do
      :ok -> artifact
      {:error, reason} -> raise ArgumentError, "invalid operation artifact: #{inspect(reason)}"
    end
  end

  defp portable(artifact) do
    case Value.validate(artifact, [:operation_artifact, artifact.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_artifact, reason}}
    end
  end

  defp valid_kind?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: is_binary(value) and value != ""
end
