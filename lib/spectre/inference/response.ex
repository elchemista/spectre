defmodule Spectre.Inference.Response do
  @moduledoc """
  Normalized inference response with optional usage and provider metadata.
  """

  defstruct [
    :text,
    :selection,
    :latency_ms,
    :provider_request_id,
    usage: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          selection: Spectre.Inference.Selection.t() | nil,
          usage: map(),
          latency_ms: non_neg_integer() | nil,
          provider_request_id: term(),
          metadata: map()
        }

  @spec new(t() | String.t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = response), do: response
  def new(text) when is_binary(text), do: %__MODULE__{text: text}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    response = struct(__MODULE__, Map.take(attrs, fields()))

    unless is_binary(response.text),
      do: raise(ArgumentError, "inference response text must be a string")

    unless is_map(response.usage) and is_map(response.metadata),
      do: raise(ArgumentError, "inference response metadata must be maps")

    response
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
