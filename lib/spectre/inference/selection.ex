defmodule Spectre.Inference.Selection do
  @moduledoc """
  Frozen model selection for one inference attempt.
  """

  defstruct [
    :request_id,
    :level,
    :model,
    :reason,
    :selector,
    :profile_hash,
    attempt: 1,
    fallback_chain: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          request_id: String.t(),
          level: term(),
          model: term(),
          reason: term(),
          selector: module(),
          profile_hash: String.t(),
          fallback_chain: [term()],
          attempt: pos_integer(),
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = selection), do: selection
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    selection =
      attrs
      |> Map.update(:fallback_chain, [], &List.wrap/1)
      |> then(&struct(__MODULE__, Map.take(&1, fields())))

    unless is_binary(selection.request_id) and selection.request_id != "",
      do: raise(ArgumentError, "selection request id is required")

    if is_nil(selection.model), do: raise(ArgumentError, "selection model is required")
    selection
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
