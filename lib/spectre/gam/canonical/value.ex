defmodule Spectre.GAM.Canonical.Value do
  @moduledoc """
  Portable deterministic SPCV v1 values for GAM, using the shared Spectre codec.

  Maps use canonical key order and decoding never creates atoms. Structs require
  `:allowed_structs`; processes, references, functions and improper lists are
  rejected. The GAM encoder checks its byte budget incrementally, before
  allocating the final binary. `validate/2` checks the same budget without
  constructing that binary.
  """
  alias Spectre.Canonical.Value

  @type reason :: Value.reason()

  @doc "Returns the canonicalization format version."
  @spec version() :: pos_integer()
  defdelegate version(), to: Value

  @doc "Returns the digest algorithm used by `digest/2`."
  @spec digest_algorithm() :: :sha256
  defdelegate digest_algorithm(), to: Value

  @doc """
  Encodes a value into the versioned canonical binary format.

  Options: `:allowed_structs`, `:max_bytes` (including the header), `:max_depth`
  and `:max_collection_size`. See `Spectre.Canonical.Value.encode/2`.
  """
  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, reason()}
  def encode(value, opts \\ []), do: Value.encode_budgeted(value, opts)

  @doc "Encodes a value or raises `ArgumentError` with the stable failure reason."
  @spec encode!(term(), keyword()) :: binary()
  def encode!(value, opts \\ []), do: unwrap!(encode(value, opts))

  @doc "Decodes canonical bytes, rejecting trailing data, aliases and disallowed structs."
  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, reason()}
  def decode(encoded, opts \\ []), do: Value.decode_checked(encoded, opts)

  @doc "Returns the lowercase SHA-256 digest of a canonical value."
  @spec digest(term(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def digest(value, opts \\ []) do
    with {:ok, encoded} <- encode(value, opts) do
      {:ok, encoded |> then(&:crypto.hash(digest_algorithm(), &1)) |> Base.encode16(case: :lower)}
    end
  end

  @doc "Returns the digest or raises `ArgumentError` for a non-canonical value."
  @spec digest!(term(), keyword()) :: String.t()
  def digest!(value, opts \\ []), do: unwrap!(digest(value, opts))

  @doc "Checks whether a value can be represented within this codec's limits."
  @spec validate(term(), keyword()) :: :ok | {:error, reason()}
  def validate(value, opts \\ []), do: Value.validate_budgeted(value, opts)

  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, reason}),
    do: raise(ArgumentError, "non-canonical Spectre.GAM value: #{inspect(reason)}")
end
