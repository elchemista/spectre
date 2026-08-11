defmodule Spectre.Gate.Receipt.Ref do
  @moduledoc "Content-addressed identity of a governance gate receipt."

  import Kernel, except: [to_string: 1]

  @algorithm :sha256
  @enforce_keys [:algorithm, :digest]
  defstruct algorithm: @algorithm, digest: nil

  @type t :: %__MODULE__{algorithm: :sha256, digest: String.t()}

  @spec new(Spectre.Gate.Receipt.t()) :: t()
  def new(%Spectre.Gate.Receipt{} = receipt),
    do: %__MODULE__{algorithm: @algorithm, digest: Spectre.Gate.Receipt.digest(receipt)}

  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse("gate:sha256:" <> digest) do
    ref = %__MODULE__{algorithm: @algorithm, digest: digest}
    if valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_gate_receipt_ref, digest}}
  end

  def parse(value), do: {:error, {:invalid_gate_receipt_ref, value}}

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{algorithm: algorithm, digest: digest}),
    do: "gate:#{algorithm}:#{digest}"

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{algorithm: @algorithm, digest: digest})
      when is_binary(digest) and byte_size(digest) == 64,
      do: match?({:ok, <<_::256>>}, Base.decode16(digest, case: :lower))

  def valid?(_value), do: false

  @spec verify(t(), Spectre.Gate.Receipt.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = expected, %Spectre.Gate.Receipt{} = receipt) do
    actual = new(receipt)

    if expected == actual,
      do: :ok,
      else: {:error, {:gate_receipt_ref_mismatch, to_string(expected), to_string(actual)}}
  end
end

defimpl String.Chars, for: Spectre.Gate.Receipt.Ref do
  def to_string(ref), do: Spectre.Gate.Receipt.Ref.to_string(ref)
end
