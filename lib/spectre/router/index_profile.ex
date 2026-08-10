defmodule Spectre.Router.IndexProfile do
  @moduledoc """
  Versioned identity for a rebuildable routing cache or index.

  Profiles describe how a Routing projection may be indexed. They contain no
  embeddings or provider clients; derived rows remain disposable cache data.
  """

  alias Spectre.Canonical.Value

  @schema_version 1
  @strategies [:exact, :lexical, :embedding]
  @metrics [:none, :cosine, :dot, :euclidean]
  @fields [
    :schema_version,
    :id,
    :version,
    :strategy,
    :model_profile_ref,
    :dimensions,
    :metric,
    :max_entries,
    :metadata
  ]

  @enforce_keys [:schema_version, :id, :version, :strategy, :metric, :max_entries]
  defstruct schema_version: @schema_version,
            id: "spectre.routing.exact",
            version: 1,
            strategy: :exact,
            model_profile_ref: nil,
            dimensions: nil,
            metric: :none,
            max_entries: 10_000,
            metadata: %{}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          version: pos_integer(),
          strategy: :exact | :lexical | :embedding,
          model_profile_ref: String.t() | nil,
          dimensions: pos_integer() | nil,
          metric: :none | :cosine | :dot | :euclidean,
          max_entries: pos_integer(),
          metadata: map()
        }

  @doc "Returns the current index-profile schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the deterministic built-in exact-routing profile."
  @spec default() :: t()
  def default, do: new!(%{})

  @doc "Builds and validates an index profile."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_routing_index_profile, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = atomize_known_keys(attrs)

    with :ok <- exact_keys(attrs),
         profile = struct(__MODULE__, Map.take(attrs, @fields)),
         :ok <- validate(profile),
         :ok <- validate_portable(profile) do
      {:ok, profile}
    end
  end

  def new(value), do: {:error, {:invalid_routing_index_profile, shape(value)}}

  @doc "Builds an index profile or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid routing index profile: #{inspect(reason)}"
    end
  end

  @doc "Restores an index profile from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Returns the portable profile representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = profile) do
    profile
    |> Map.from_struct()
    |> Map.take(@fields)
  end

  @doc "Returns the canonical profile digest used in cache keys."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = profile), do: profile |> to_data() |> Value.digest!()

  @spec validate(t()) :: :ok | {:error, term()}
  defp validate(%__MODULE__{} = profile) do
    with :ok <- validate_schema(profile.schema_version),
         :ok <- validate_id(profile.id),
         :ok <- validate_version(profile.version),
         :ok <- validate_strategy(profile.strategy),
         :ok <- validate_metric(profile.metric),
         :ok <- validate_capacity(profile.max_entries),
         :ok <- validate_metadata(profile.metadata) do
      validate_model_fields(profile)
    end
  end

  defp validate_schema(@schema_version), do: :ok

  defp validate_schema(version),
    do: {:error, {:unsupported_routing_index_profile_schema, version}}

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(id), do: {:error, {:invalid_routing_index_profile_id, id}}

  defp validate_version(version) when is_integer(version) and version > 0, do: :ok

  defp validate_version(version),
    do: {:error, {:invalid_routing_index_profile_version, version}}

  defp validate_strategy(strategy) when strategy in @strategies, do: :ok
  defp validate_strategy(strategy), do: {:error, {:invalid_routing_index_strategy, strategy}}

  defp validate_metric(metric) when metric in @metrics, do: :ok
  defp validate_metric(metric), do: {:error, {:invalid_routing_index_metric, metric}}

  defp validate_capacity(capacity) when is_integer(capacity) and capacity > 0, do: :ok
  defp validate_capacity(capacity), do: {:error, {:invalid_routing_index_capacity, capacity}}

  defp validate_metadata(metadata) when is_map(metadata), do: :ok
  defp validate_metadata(_metadata), do: {:error, :invalid_routing_index_metadata}

  defp validate_model_fields(%__MODULE__{strategy: :embedding} = profile),
    do: validate_embedding(profile)

  defp validate_model_fields(%__MODULE__{
         model_profile_ref: nil,
         dimensions: nil,
         metric: :none
       }),
       do: :ok

  defp validate_model_fields(%__MODULE__{}),
    do: {:error, :non_embedding_routing_index_has_model_fields}

  @spec validate_embedding(t()) :: :ok | {:error, term()}
  defp validate_embedding(profile) do
    if is_binary(profile.model_profile_ref) and profile.model_profile_ref != "" and
         is_integer(profile.dimensions) and profile.dimensions > 0 and
         profile.metric in [:cosine, :dot, :euclidean] do
      :ok
    else
      {:error, :incomplete_embedding_routing_index_profile}
    end
  end

  @spec validate_portable(t()) :: :ok | {:error, term()}
  defp validate_portable(profile) do
    case profile |> to_data() |> Value.validate() do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_routing_index_profile, reason}}
    end
  end

  @spec exact_keys(map()) :: :ok | {:error, term()}
  defp exact_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] ->
        :ok

      unknown ->
        {:error, {:unknown_routing_index_profile_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(attrs) do
    Enum.reduce(@fields, attrs, fn key, normalized ->
      string = Atom.to_string(key)

      case Map.fetch(normalized, string) do
        {:ok, value} -> normalized |> Map.delete(string) |> Map.put_new(key, value)
        :error -> normalized
      end
    end)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
