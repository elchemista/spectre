defmodule Spectre.ExternalIdentity do
  @moduledoc """
  Authenticated external principal presented by a channel boundary.

  The raw provider principal is reduced to an opaque identifier at
  construction time. Similar names, numbers, address-book entries, or message
  text never imply that two values represent the same Subject.
  """

  alias Spectre.Input.Source
  alias Spectre.Run.Value

  @enforce_keys [:id, :provider, :channel, :authenticated_at]
  defstruct [
    :id,
    :provider,
    :channel,
    :endpoint,
    :authenticated_at,
    :proof_ref,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom() | String.t(),
          channel: atom() | String.t(),
          endpoint: term(),
          authenticated_at: integer(),
          proof_ref: String.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an authenticated external identity.

  Pass the provider's authenticated identifier as `:principal_id`,
  `:external_id`, or `:actor_id`. It is hashed and is not retained.
  """
  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = identity), do: validate!(identity)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    provider = value(attrs, :provider, value(attrs, :kind))
    channel = value(attrs, :channel, value(attrs, :kind))
    endpoint = value(attrs, :endpoint, value(attrs, :mount))
    authenticated_at = value(attrs, :authenticated_at, value(attrs, :verified_at))
    principal = principal(attrs)

    id =
      case value(attrs, :id) do
        id when is_binary(id) and id != "" ->
          id

        _missing when not is_nil(principal) ->
          opaque_identity_id!(provider, channel, endpoint, principal)

        _missing ->
          nil
      end

    proof_ref = proof_ref!(value(attrs, :proof_ref))

    %__MODULE__{
      id: id,
      provider: provider,
      channel: channel,
      endpoint: endpoint,
      authenticated_at: authenticated_at,
      proof_ref: proof_ref,
      metadata: value(attrs, :metadata, %{})
    }
    |> validate!()
  end

  @doc """
  Converts an authenticated normalized input source into an identity.

  Channel adapters must call this only after authenticating the endpoint and
  sender; the core does not infer authentication from source fields.
  """
  @spec from_source(Source.t(), keyword()) :: t()
  def from_source(%Source{} = source, opts \\ []) do
    new(%{
      provider: Keyword.get(opts, :provider, :beam),
      channel: source.kind,
      endpoint: source.mount,
      actor_id: source.actor_id,
      authenticated_at: Keyword.fetch!(opts, :authenticated_at),
      proof_ref: Keyword.get(opts, :proof_ref),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @doc """
  Returns the exact, opaque identity key used by the Subject Registry.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = identity) do
    identity = validate!(identity)

    Value.token(
      "external-key",
      {identity.provider, identity.channel, identity.endpoint, identity.id}
    )
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = identity) do
    with :ok <- validate_id(identity.id),
         :ok <- validate_namespace(:provider, identity.provider),
         :ok <- validate_namespace(:channel, identity.channel),
         :ok <- validate_authenticated_at(identity.authenticated_at),
         :ok <- validate_proof_ref(identity.proof_ref),
         :ok <- validate_metadata(identity.metadata) do
      Value.validate(identity, [:external_identity])
    end
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = identity) do
    case validate(identity) do
      :ok -> identity
      {:error, reason} -> raise ArgumentError, "invalid ExternalIdentity: #{inspect(reason)}"
    end
  end

  @spec principal(map()) :: term() | nil
  defp principal(attrs) do
    value(
      attrs,
      :principal_id,
      value(attrs, :external_id, value(attrs, :actor_id))
    )
  end

  @spec opaque_identity_id!(atom() | String.t(), atom() | String.t(), term(), term()) ::
          String.t()
  defp opaque_identity_id!(provider, channel, endpoint, principal) do
    value = {provider, channel, endpoint, principal}

    case Value.validate(value, [:external_identity, :principal]) do
      :ok ->
        Value.token("external-identity", value)

      {:error, reason} ->
        raise ArgumentError, "invalid ExternalIdentity: #{inspect(reason)}"
    end
  end

  @spec proof_ref!(term()) :: String.t() | nil
  defp proof_ref!(nil), do: nil

  defp proof_ref!(value) do
    case Value.validate(value, [:external_identity, :proof_ref]) do
      :ok ->
        Value.logical_id(value, "identity-proof")

      {:error, reason} ->
        raise ArgumentError, "invalid ExternalIdentity: #{inspect(reason)}"
    end
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec validate_id(term()) :: :ok | {:error, {:invalid_external_identity_id, term()}}
  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(id), do: {:error, {:invalid_external_identity_id, id}}

  @spec validate_namespace(:provider | :channel, term()) :: :ok | {:error, term()}
  defp validate_namespace(_kind, value) when is_atom(value) and not is_nil(value), do: :ok
  defp validate_namespace(_kind, value) when is_binary(value) and value != "", do: :ok

  defp validate_namespace(:provider, value) do
    {:error, {:invalid_external_identity_provider, value}}
  end

  defp validate_namespace(:channel, value) do
    {:error, {:invalid_external_identity_channel, value}}
  end

  @spec validate_authenticated_at(term()) ::
          :ok | {:error, {:invalid_external_identity_authentication, term()}}
  defp validate_authenticated_at(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_authenticated_at(value),
    do: {:error, {:invalid_external_identity_authentication, value}}

  @spec validate_proof_ref(term()) ::
          :ok | {:error, {:invalid_external_identity_proof_ref, term()}}
  defp validate_proof_ref(nil), do: :ok
  defp validate_proof_ref(value) when is_binary(value) and value != "", do: :ok

  defp validate_proof_ref(value),
    do: {:error, {:invalid_external_identity_proof_ref, value}}

  @spec validate_metadata(term()) ::
          :ok | {:error, {:invalid_external_identity_metadata, term()}}
  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata),
    do: {:error, {:invalid_external_identity_metadata, metadata}}
end
