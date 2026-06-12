defmodule Spectre.Input do
  @moduledoc """
  Normalized inbound user turn.
  """

  defstruct text: "", meta: %{}, raw: nil

  @type t :: %__MODULE__{text: String.t(), meta: map(), raw: term()}

  @doc """
  Normalizes raw inbound input into a Spectre input struct.
  """
  @spec new(t() | String.t() | map() | term()) :: t()
  def new(%__MODULE__{} = input), do: input

  def new(text) when is_binary(text), do: %__MODULE__{text: text, raw: text}

  def new(%{text: text} = input) when is_binary(text) do
    %__MODULE__{
      text: text,
      meta: Map.get(input, :meta, Map.get(input, "meta", %{})),
      raw: input
    }
  end

  def new(%{"text" => text} = input) when is_binary(text) do
    %__MODULE__{
      text: text,
      meta: Map.get(input, "meta", %{}),
      raw: input
    }
  end

  def new(input), do: %__MODULE__{text: to_string(input), raw: input}
end
