defmodule Spectre.Definition.Candidate.Ref do
  @moduledoc """
  Content-addressed identity of a bootstrap Definition Candidate.

  A Candidate Ref is intentionally distinct from a `Definition.Ref`: it binds
  the exact publication receipt and provenance proposed for activation, while
  the Definition Ref continues to identify behavior bytes.
  """

  import Kernel, except: [to_string: 1]

  alias Spectre.Definition.Candidate

  @algorithm :sha256
  @digest_bytes 32
  @hex_bytes @digest_bytes * 2

  @enforce_keys [:algorithm, :digest]
  defstruct algorithm: @algorithm, digest: nil

  @type t :: %__MODULE__{algorithm: :sha256, digest: String.t()}

  @doc "Builds the Ref for a validated Candidate."
  @spec new(Candidate.t()) :: t()
  def new(%Candidate{} = candidate) do
    %__MODULE__{algorithm: @algorithm, digest: Candidate.digest(candidate)}
  end

  @doc "Parses the stable `candidate:sha256:<hex>` representation."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse("candidate:sha256:" <> digest) do
    ref = %__MODULE__{algorithm: @algorithm, digest: digest}

    if valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_candidate_ref, digest}}
  end

  def parse(value), do: {:error, {:invalid_candidate_ref, value}}

  @doc "Returns the stable textual representation."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{algorithm: algorithm, digest: digest}),
    do: "candidate:#{algorithm}:#{digest}"

  @doc "Checks the shape and supported digest algorithm."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{algorithm: @algorithm, digest: digest}), do: valid_digest?(digest)
  def valid?(_value), do: false

  @doc "Verifies that a Ref addresses the supplied Candidate."
  @spec verify(t(), Candidate.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = expected, %Candidate{} = candidate) do
    actual = new(candidate)

    if expected == actual,
      do: :ok,
      else: {:error, {:candidate_ref_mismatch, to_string(expected), to_string(actual)}}
  end

  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == @hex_bytes do
    case Base.decode16(digest, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == @digest_bytes
      :error -> false
    end
  end

  defp valid_digest?(_digest), do: false
end

defimpl String.Chars, for: Spectre.Definition.Candidate.Ref do
  def to_string(ref), do: Spectre.Definition.Candidate.Ref.to_string(ref)
end
