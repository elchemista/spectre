defmodule Spectre.Input.Source do
  @moduledoc """
  Provider-neutral origin attached to a normalized Spectre input.

  Optional channel and protocol packages use `kind` as their namespace and
  `mount` as the concrete configured endpoint. Identifiers remain opaque to
  the core.
  """

  defstruct [
    :kind,
    :mount,
    :conversation_id,
    :actor_id,
    :reply_to,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom() | String.t(),
          mount: term(),
          conversation_id: term(),
          actor_id: term(),
          reply_to: term(),
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = source), do: source
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    source = struct(__MODULE__, Map.take(attrs, fields()))

    unless (is_atom(source.kind) and not is_nil(source.kind)) or
             (is_binary(source.kind) and source.kind != "") do
      raise ArgumentError, "input source kind must be a non-empty atom or string"
    end

    unless is_map(source.metadata),
      do: raise(ArgumentError, "input source metadata must be a map")

    source
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
