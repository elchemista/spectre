defmodule Spectre.Morph.StableName do
  @moduledoc """
  Normalizes existing stable identifiers without creating runtime atoms.

  Compiled definitions may contain atom or integer authoring values while
  transported definitions contain strings. Morph compares those identities in
  their string representation and never converts data-authored strings back to
  atoms.
  """

  @type t :: String.t()

  @doc false
  @spec normalize(term()) :: {:ok, t()} | {:error, :invalid_stable_name}
  def normalize(value) when is_binary(value) and value != "", do: {:ok, value}

  def normalize(value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}

  def normalize(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  def normalize(_value), do: {:error, :invalid_stable_name}

  @doc false
  @spec equal?(term(), term()) :: boolean()
  def equal?(left, right) do
    with {:ok, normalized_left} <- normalize(left),
         {:ok, normalized_right} <- normalize(right) do
      normalized_left == normalized_right
    else
      {:error, :invalid_stable_name} -> false
    end
  end
end
