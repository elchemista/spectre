defmodule Spectre.Experience.Evidence.Ref do
  @moduledoc "Content-addressed identity of redacted Experience evidence."

  import Kernel, except: [to_string: 1]

  @algorithm :sha256

  @enforce_keys [:algorithm, :digest]
  defstruct algorithm: @algorithm, digest: nil

  @type t :: %__MODULE__{algorithm: :sha256, digest: String.t()}

  @doc "Builds a Ref for validated Experience evidence."
  @spec new(Spectre.Experience.Evidence.t()) :: t()
  def new(%Spectre.Experience.Evidence{} = evidence) do
    %__MODULE__{algorithm: @algorithm, digest: Spectre.Experience.Evidence.digest(evidence)}
  end

  @doc "Parses the canonical `experience:sha256:<lowercase hex>` representation."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse("experience:sha256:" <> digest) do
    ref = %__MODULE__{algorithm: @algorithm, digest: digest}
    if valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_experience_evidence_ref, digest}}
  end

  def parse(value), do: {:error, {:invalid_experience_evidence_ref, value}}

  @doc "Returns the canonical textual representation."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{algorithm: algorithm, digest: digest}) do
    "experience:#{algorithm}:#{digest}"
  end

  @doc "Checks the Ref algorithm and lowercase digest shape."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{algorithm: @algorithm, digest: digest})
      when is_binary(digest) and byte_size(digest) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(digest, case: :lower))
  end

  def valid?(_value), do: false

  @doc "Verifies that a Ref addresses the supplied evidence."
  @spec verify(t(), Spectre.Experience.Evidence.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = expected, %Spectre.Experience.Evidence{} = evidence) do
    actual = new(evidence)

    if expected == actual,
      do: :ok,
      else: {:error, {:experience_evidence_ref_mismatch, to_string(expected), to_string(actual)}}
  end
end

defimpl String.Chars, for: Spectre.Experience.Evidence.Ref do
  def to_string(ref), do: Spectre.Experience.Evidence.Ref.to_string(ref)
end
