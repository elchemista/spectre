defmodule Spectre.Action.Spec do
  @moduledoc """
  Planner-facing description of an action exposed by a provider.

  Specs are discovery data only. Execution always resolves the provider again
  from the compiled Agent definition, so a planner cannot inject an arbitrary
  implementation module.
  """

  defstruct [
    :id,
    :name,
    :via,
    :description,
    :mode,
    :schema,
    :schema_hash,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: Spectre.Action.name(),
          via: Spectre.Action.provider_ref(),
          description: String.t() | nil,
          mode: atom() | nil,
          schema: term(),
          schema_hash: String.t(),
          metadata: map()
        }

  @doc """
  Builds a normalized spec and derives a stable schema hash when omitted.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    name = attr(attrs, :name)
    via = attr(attrs, :via) || :local
    schema = attr(attrs, :schema) || %{}
    metadata = attr(attrs, :metadata) || %{}
    id = attr(attrs, :id)
    description = attr(attrs, :description)
    mode = attr(attrs, :mode)

    action = Spectre.Action.new(%{name: name, via: via})
    schema_hash = hash(action.via, action.name, schema, mode)

    unless is_nil(id) or (is_binary(id) and id != ""),
      do: raise(ArgumentError, "invalid action spec id: #{inspect(id)}")

    unless is_nil(description) or is_binary(description),
      do: raise(ArgumentError, "invalid action description: #{inspect(description)}")

    unless mode in [nil, :read, :write, :destructive],
      do: raise(ArgumentError, "invalid action mode: #{inspect(mode)}")

    unless is_map(metadata), do: raise(ArgumentError, "action spec metadata must be a map")

    case attr(attrs, :schema_hash) do
      nil -> :ok
      ^schema_hash -> :ok
      other -> raise ArgumentError, "action schema hash does not match schema: #{inspect(other)}"
    end

    %__MODULE__{
      id: id,
      name: action.name,
      via: action.via,
      description: description,
      mode: mode,
      schema: schema,
      schema_hash: schema_hash,
      metadata: metadata
    }
  end

  @doc """
  Computes the stable hash used to detect provider-schema drift.
  """
  @spec hash(Spectre.Action.provider_ref(), Spectre.Action.name(), term()) :: String.t()
  def hash(via, name, schema), do: hash(via, name, schema, nil)

  @spec hash(Spectre.Action.provider_ref(), Spectre.Action.name(), term(), atom() | nil) ::
          String.t()
  def hash(via, name, schema, mode) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({via, name, mode, schema}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @spec attr(map(), atom()) :: term()
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
