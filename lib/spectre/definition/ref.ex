defmodule Spectre.Definition.Ref do
  @moduledoc """
  Content-addressed identity of one canonical Spectre Definition.

  A Ref proves integrity of canonical bytes. It does not prove publisher
  identity, trust, approval, or current authority.
  """

  import Kernel, except: [to_string: 1]

  alias Spectre.Definition.Canonical

  @algorithm :sha256
  @digest_bytes 32
  @hex_bytes @digest_bytes * 2

  @enforce_keys [:algorithm, :digest, :canonicalization_version, :contract_version]
  defstruct [:algorithm, :digest, :canonicalization_version, :contract_version]

  @type t :: %__MODULE__{
          algorithm: :sha256,
          digest: String.t(),
          canonicalization_version: pos_integer(),
          contract_version: pos_integer()
        }

  @doc "Builds the Ref for a canonical Definition."
  @spec new(Canonical.t()) :: t()
  def new(%Canonical{} = canonical) do
    %__MODULE__{
      algorithm: @algorithm,
      digest: Canonical.digest(canonical),
      canonicalization_version: canonical.canonicalization_version,
      contract_version: canonical.contract_version
    }
  end

  @doc "Parses the stable `sha256:<hex>` representation."
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(value, opts \\ [])

  def parse("sha256:" <> digest, opts) when is_list(opts) do
    ref = %__MODULE__{
      algorithm: @algorithm,
      digest: digest,
      canonicalization_version: Keyword.get(opts, :canonicalization_version, 1),
      contract_version: Keyword.get(opts, :contract_version, 1)
    }

    if valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_definition_ref, value(ref)}}
  end

  def parse(value, _opts), do: {:error, {:invalid_definition_ref, value(value)}}

  @doc "Returns the stable textual representation of a Ref."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{algorithm: algorithm, digest: digest}), do: "#{algorithm}:#{digest}"

  @doc "Checks the shape and supported algorithm of a Definition Ref."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = ref) do
    ref.algorithm == @algorithm and valid_digest?(ref.digest) and
      is_integer(ref.canonicalization_version) and ref.canonicalization_version > 0 and
      is_integer(ref.contract_version) and ref.contract_version > 0
  end

  def valid?(_value), do: false

  @doc "Verifies that a Ref addresses the supplied canonical Definition."
  @spec verify(t(), Canonical.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = expected, %Canonical{} = canonical) do
    actual = new(canonical)

    if expected == actual,
      do: :ok,
      else: {:error, {:definition_ref_mismatch, to_string(expected), to_string(actual)}}
  end

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == @hex_bytes do
    case Base.decode16(digest, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == @digest_bytes
      :error -> false
    end
  end

  defp valid_digest?(_digest), do: false

  @spec value(term()) :: term()
  defp value(%__MODULE__{} = ref), do: Map.from_struct(ref)
  defp value(value), do: value
end

defimpl String.Chars, for: Spectre.Definition.Ref do
  def to_string(ref), do: Spectre.Definition.Ref.to_string(ref)
end
