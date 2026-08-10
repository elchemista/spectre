defmodule Spectre.Authority.Envelope do
  @moduledoc """
  Effective, portable authority granted to one canonical Definition.

  Requests and grants are deliberately separate. `compose/2` intersects every
  requested capability with a host-owned ceiling; a request can therefore
  never create authority by itself. The resulting envelope contains grants
  only and is safe to seal into a `Spectre.Definition.Manifest`.
  """

  alias Spectre.Canonical.Value

  @schema_version 1
  @grant_fields [
    :operations,
    :actions,
    :effects,
    :state_reads,
    :state_writes,
    :event_classes,
    :prompt_phases,
    :prompt_budget_classes,
    :model_purposes,
    :model_profiles,
    :external_data_refs,
    :secret_refs,
    :open_capabilities,
    :consents
  ]
  @limit_fields [:max_cost, :max_duration_ms, :max_risk, :max_tokens]

  @enforce_keys [:schema_version] ++ @grant_fields ++ [:limits]
  defstruct [schema_version: @schema_version] ++
              Enum.map(@grant_fields, &{&1, []}) ++ [limits: %{}]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          operations: [term()],
          actions: [term()],
          effects: [term()],
          state_reads: [term()],
          state_writes: [term()],
          event_classes: [term()],
          prompt_phases: [term()],
          prompt_budget_classes: [term()],
          model_purposes: [term()],
          model_profiles: [term()],
          external_data_refs: [term()],
          secret_refs: [term()],
          open_capabilities: [term()],
          consents: [term()],
          limits: %{optional(atom()) => term()}
        }

  @doc "Returns the Authority Envelope schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates an effective authority envelope."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = envelope), do: envelope |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, grants} <- normalize_grants(attrs),
         {:ok, limits} <- normalize_limits(Map.get(attrs, :limits, %{})) do
      {:ok,
       struct!(
         __MODULE__,
         grants
         |> Map.put(:schema_version, @schema_version)
         |> Map.put(:limits, limits)
       )}
    end
  end

  def new(value), do: {:error, {:invalid_authority_envelope, shape(value)}}

  @doc "Builds an envelope or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, envelope} -> envelope
      {:error, reason} -> raise ArgumentError, "invalid authority envelope: #{inspect(reason)}"
    end
  end

  @doc "Returns an envelope with no grants and no limits."
  @spec empty() :: t()
  def empty, do: new!(%{})

  @doc """
  Intersects requested authority with the host-owned authority ceiling.

  Capability lists use canonical value identity. Numeric limits are reduced to
  the stricter value; non-numeric limits, such as risk classes, are taken from
  the ceiling and only appear when both sides declared the limit.
  """
  @spec compose(t() | map() | keyword(), t() | map() | keyword()) ::
          {:ok, t()} | {:error, term()}
  def compose(requested, ceiling) do
    with {:ok, requested} <- new(requested),
         {:ok, ceiling} <- new(ceiling) do
      grants =
        Map.new(@grant_fields, fn field ->
          {field, intersect(Map.fetch!(requested, field), Map.fetch!(ceiling, field))}
        end)

      new(Map.put(grants, :limits, intersect_limits(requested.limits, ceiling.limits)))
    end
  end

  @doc "Intersects authority or raises with its stable validation reason."
  @spec compose!(t() | map() | keyword(), t() | map() | keyword()) :: t()
  def compose!(requested, ceiling) do
    case compose(requested, ceiling) do
      {:ok, envelope} -> envelope
      {:error, reason} -> raise ArgumentError, "cannot compose authority: #{inspect(reason)}"
    end
  end

  @doc "Returns whether `value` is effectively granted in `field`."
  @spec allows?(t(), atom(), term()) :: boolean()
  def allows?(%__MODULE__{} = envelope, field, value) when field in @grant_fields do
    encoded = Value.encode!(value)
    Enum.any?(Map.fetch!(envelope, field), &(Value.encode!(&1) == encoded))
  rescue
    ArgumentError -> false
  end

  def allows?(%__MODULE__{}, _field, _value), do: false

  @doc "Returns the portable data sealed into a Definition Manifest."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = envelope) do
    @grant_fields
    |> Map.new(fn field -> {Atom.to_string(field), Map.fetch!(envelope, field)} end)
    |> Map.put("schema_version", envelope.schema_version)
    |> Map.put("limits", encode_limits(envelope.limits))
  end

  @doc "Restores an envelope from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{"schema_version" => schema_version, "limits" => limits} = data) do
    with {:ok, limits} <- decode_limits(limits) do
      attrs =
        Enum.reduce(@grant_fields, %{schema_version: schema_version, limits: limits}, fn field,
                                                                                         acc ->
          Map.put(acc, field, Map.get(data, Atom.to_string(field), []))
        end)

      new(attrs)
    end
  end

  def from_data(value), do: {:error, {:invalid_authority_envelope_data, shape(value)}}

  @doc "Returns the canonical SHA-256 digest of the effective grants."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = envelope), do: envelope |> to_data() |> Value.digest!()

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = [:schema_version, :limits | @grant_fields]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_authority_fields, Enum.sort(unknown)}}
    end
  end

  @spec validate_schema(term()) :: :ok | {:error, term()}
  defp validate_schema(@schema_version), do: :ok

  defp validate_schema(version),
    do: {:error, {:unsupported_authority_envelope_schema, version}}

  @spec normalize_grants(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_grants(attrs) do
    Enum.reduce_while(@grant_fields, {:ok, %{}}, fn field, {:ok, grants} ->
      case normalize_values(Map.get(attrs, field, []), field) do
        {:ok, values} -> {:cont, {:ok, Map.put(grants, field, values)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec normalize_values(term(), atom()) :: {:ok, [term()]} | {:error, term()}
  defp normalize_values(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn value, {:ok, unique} ->
      case Value.encode(value) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(unique, encoded, value)}}
        {:error, reason} -> {:halt, {:error, {:invalid_authority_grant, field, reason}}}
      end
    end)
    |> case do
      {:ok, unique} -> {:ok, unique |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_values(value, field),
    do: {:error, {:invalid_authority_grants, field, shape(value)}}

  @spec normalize_limits(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_limits(limits) when is_map(limits) do
    with [] <- Map.keys(limits) -- @limit_fields,
         :ok <- validate_limit_values(limits),
         :ok <- validate_portable_limits(limits) do
      {:ok, limits}
    else
      [_field | _rest] = unknown -> {:error, {:unknown_authority_limits, Enum.sort(unknown)}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_limits(value), do: {:error, {:invalid_authority_limits, shape(value)}}

  @spec validate_limit_values(map()) :: :ok | {:error, term()}
  defp validate_limit_values(limits) do
    Enum.reduce_while(limits, :ok, fn
      {field, value}, :ok when field in [:max_cost, :max_duration_ms, :max_tokens] ->
        if is_number(value) and value >= 0,
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_authority_limit, field, value}}}

      {:max_risk, value}, :ok ->
        if is_atom(value) and not is_nil(value),
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_authority_limit, :max_risk, value}}}
    end)
  end

  @spec validate_portable_limits(map()) :: :ok | {:error, term()}
  defp validate_portable_limits(limits) do
    case Value.validate(limits) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_authority_limits, reason}}
    end
  end

  @spec intersect([term()], [term()]) :: [term()]
  defp intersect(requested, ceiling) do
    ceiling = MapSet.new(Enum.map(ceiling, &Value.encode!/1))
    Enum.filter(requested, &MapSet.member?(ceiling, Value.encode!(&1)))
  end

  @spec intersect_limits(map(), map()) :: map()
  defp intersect_limits(requested, ceiling) do
    requested
    |> Map.take(Map.keys(ceiling))
    |> Map.new(fn {field, requested_value} ->
      ceiling_value = Map.fetch!(ceiling, field)

      value =
        if is_number(requested_value) and is_number(ceiling_value),
          do: min(requested_value, ceiling_value),
          else: ceiling_value

      {field, value}
    end)
  end

  @spec encode_limits(map()) :: map()
  defp encode_limits(limits),
    do: Map.new(limits, fn {field, value} -> {Atom.to_string(field), value} end)

  @spec decode_limits(term()) :: {:ok, map()} | {:error, term()}
  defp decode_limits(limits) when is_map(limits) do
    Enum.reduce_while(limits, {:ok, %{}}, fn {field, value}, {:ok, decoded} ->
      case limit_field(field) do
        {:ok, field} -> {:cont, {:ok, Map.put(decoded, field, value)}}
        :error -> {:halt, {:error, {:unknown_authority_limits, [field]}}}
      end
    end)
  end

  defp decode_limits(value), do: {:error, {:invalid_authority_limits, shape(value)}}

  @spec limit_field(term()) :: {:ok, atom()} | :error
  defp limit_field("max_cost"), do: {:ok, :max_cost}
  defp limit_field("max_duration_ms"), do: {:ok, :max_duration_ms}
  defp limit_field("max_risk"), do: {:ok, :max_risk}
  defp limit_field("max_tokens"), do: {:ok, :max_tokens}
  defp limit_field(field) when field in @limit_fields, do: {:ok, field}
  defp limit_field(_field), do: :error

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
