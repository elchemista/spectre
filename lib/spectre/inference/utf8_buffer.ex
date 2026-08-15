defmodule Spectre.Inference.Utf8Buffer do
  @moduledoc false

  # A valid UTF-8 scalar can leave at most three bytes pending after a
  # transport boundary (its leading byte plus the available continuations).
  @max_residual_bytes 3

  defstruct residual: ""

  @type t :: %__MODULE__{residual: binary()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec push(t(), binary()) :: {:ok, binary(), t()} | {:error, atom()}
  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    combined = state.residual <> chunk

    case :unicode.characters_to_binary(combined, :utf8, :utf8) do
      valid when is_binary(valid) ->
        {:ok, valid, %{state | residual: ""}}

      {:incomplete, valid, residual}
      when is_binary(valid) and is_binary(residual) and
             byte_size(residual) <= @max_residual_bytes ->
        {:ok, valid, %{state | residual: residual}}

      {:incomplete, _valid, _residual} ->
        {:error, :invalid_provider_utf8}

      {:error, _valid, _invalid} ->
        {:error, :invalid_provider_utf8}
    end
  end

  @spec finish(t()) :: :ok | {:error, :incomplete_provider_utf8}
  def finish(%__MODULE__{residual: ""}), do: :ok
  def finish(%__MODULE__{}), do: {:error, :incomplete_provider_utf8}
end
