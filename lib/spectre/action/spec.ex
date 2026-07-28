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
    :visibility,
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
          visibility: :deterministic | :planner | :both,
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
    visibility = attr(attrs, :visibility) || :both

    action = Spectre.Action.new(%{name: name, via: via})
    schema_hash = hash(action.via, action.name, schema, mode)

    validate_id!(id)
    validate_description!(description)
    validate_mode!(mode)
    validate_visibility!(visibility)
    validate_metadata!(metadata)
    validate_schema_hash!(attr(attrs, :schema_hash), schema_hash)

    %__MODULE__{
      id: id,
      name: action.name,
      via: action.via,
      description: description,
      mode: mode,
      visibility: visibility,
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

  @spec validate_id!(term()) :: :ok
  defp validate_id!(nil), do: :ok
  defp validate_id!(id) when is_binary(id) and id != "", do: :ok
  defp validate_id!(id), do: raise(ArgumentError, "invalid action spec id: #{inspect(id)}")

  @spec validate_description!(term()) :: :ok
  defp validate_description!(nil), do: :ok
  defp validate_description!(description) when is_binary(description), do: :ok

  defp validate_description!(description),
    do: raise(ArgumentError, "invalid action description: #{inspect(description)}")

  @spec validate_mode!(term()) :: :ok
  defp validate_mode!(mode) when mode in [nil, :read, :write, :destructive], do: :ok
  defp validate_mode!(mode), do: raise(ArgumentError, "invalid action mode: #{inspect(mode)}")

  @doc """
  Returns whether a spec may be exposed to a model-facing planner.
  """
  @spec planner_visible?(t()) :: boolean()
  def planner_visible?(%__MODULE__{visibility: visibility}), do: visibility in [:planner, :both]

  @spec validate_visibility!(term()) :: :ok
  defp validate_visibility!(visibility) when visibility in [:deterministic, :planner, :both],
    do: :ok

  defp validate_visibility!(visibility),
    do: raise(ArgumentError, "invalid action visibility: #{inspect(visibility)}")

  @spec validate_metadata!(term()) :: :ok
  defp validate_metadata!(metadata) when is_map(metadata), do: :ok

  defp validate_metadata!(_metadata),
    do: raise(ArgumentError, "action spec metadata must be a map")

  @spec validate_schema_hash!(term(), String.t()) :: :ok
  defp validate_schema_hash!(nil, _expected), do: :ok
  defp validate_schema_hash!(expected, expected), do: :ok

  defp validate_schema_hash!(other, _expected),
    do: raise(ArgumentError, "action schema hash does not match schema: #{inspect(other)}")

  @spec attr(map(), atom()) :: term()
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
