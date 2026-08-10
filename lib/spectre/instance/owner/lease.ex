defmodule Spectre.Instance.Owner.Lease do
  @moduledoc """
  Portable lease issued by an Instance ownership adapter.

  The fencing token is monotonic in the adapter's ownership domain. A local
  Registry lease is suitable only for a single-owner deployment; distributed
  hosts must provide a lease backed by their own linearizable authority.
  """

  alias Spectre.Canonical.Value

  @schema_version 1

  @enforce_keys [
    :schema_version,
    :owner_id,
    :fencing_token,
    :issued_at,
    :expires_at,
    :metadata
  ]
  defstruct schema_version: @schema_version,
            owner_id: nil,
            fencing_token: nil,
            issued_at: nil,
            expires_at: nil,
            metadata: %{}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          owner_id: String.t(),
          fencing_token: pos_integer(),
          issued_at: non_neg_integer(),
          expires_at: non_neg_integer() | nil,
          metadata: map()
        }

  @doc "Builds and validates a lease."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :schema_version, @schema_version)

    with :ok <- validate_schema(Map.get(attrs, :schema_version)),
         :ok <- nonempty(Map.get(attrs, :owner_id), :owner_id),
         :ok <- positive(Map.get(attrs, :fencing_token), :fencing_token),
         :ok <- non_negative(Map.get(attrs, :issued_at), :issued_at),
         :ok <- optional_expiry(Map.get(attrs, :expires_at), Map.get(attrs, :issued_at)),
         :ok <- portable_metadata(Map.get(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         owner_id: Map.fetch!(attrs, :owner_id),
         fencing_token: Map.fetch!(attrs, :fencing_token),
         issued_at: Map.fetch!(attrs, :issued_at),
         expires_at: Map.get(attrs, :expires_at),
         metadata: Map.get(attrs, :metadata, %{})
       }}
    end
  end

  def new(value), do: {:error, {:invalid_instance_owner_lease, shape(value)}}

  @doc "Builds a lease or raises with its stable reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, lease} -> lease
      {:error, reason} -> raise ArgumentError, "invalid Instance owner lease: #{inspect(reason)}"
    end
  end

  @doc "Returns whether the lease has not expired at `now`."
  @spec current?(t(), non_neg_integer()) :: boolean()
  def current?(%__MODULE__{expires_at: nil}, _now), do: true

  def current?(%__MODULE__{expires_at: expires_at}, now)
      when is_integer(now) and now >= 0,
      do: now < expires_at

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(value), do: {:error, {:unsupported_owner_lease_schema, value}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:invalid_owner_lease_field, field, value}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(value, field), do: {:error, {:invalid_owner_lease_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp non_negative(value, field), do: {:error, {:invalid_owner_lease_field, field, value}}

  defp optional_expiry(nil, _issued_at), do: :ok

  defp optional_expiry(expires_at, issued_at)
       when is_integer(expires_at) and is_integer(issued_at) and expires_at > issued_at,
       do: :ok

  defp optional_expiry(value, _issued_at),
    do: {:error, {:invalid_owner_lease_field, :expires_at, value}}

  defp portable_metadata(value) when is_map(value) and not is_struct(value) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_owner_lease_metadata, reason}}
    end
  end

  defp portable_metadata(value),
    do: {:error, {:invalid_owner_lease_field, :metadata, shape(value)}}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
