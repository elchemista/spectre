defmodule Spectre.Definition.Component do
  @moduledoc """
  One typed component in a canonical Definition envelope.

  `criticality` tells older runtimes whether unknown semantics must fail
  closed. Security- and execution-relevant components use
  `:must_understand`; descriptive metadata never grants authority.
  """

  alias Spectre.Canonical.Value

  @criticalities [:must_understand, :advisory, :descriptive]

  @enforce_keys [:component_type, :schema_ref, :criticality, :payload]
  defstruct [:component_type, :schema_ref, :criticality, :payload]

  @type criticality :: :must_understand | :advisory | :descriptive

  @type t :: %__MODULE__{
          component_type: atom() | String.t(),
          schema_ref: String.t(),
          criticality: criticality(),
          payload: term()
        }

  @doc "Builds and validates a canonical Definition component."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    component = struct(__MODULE__, Map.take(attrs, fields()))

    with :ok <- validate_type(component.component_type),
         :ok <- validate_schema_ref(component.schema_ref),
         :ok <- validate_criticality(component.criticality),
         :ok <- validate_payload(component.payload) do
      {:ok, component}
    end
  end

  def new(value), do: {:error, {:invalid_definition_component, shape(value)}}

  @doc "Builds a component or raises with its stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, component} -> component
      {:error, reason} -> raise ArgumentError, "invalid Definition component: #{inspect(reason)}"
    end
  end

  @doc "Returns the portable envelope representation of a component."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = component) do
    %{
      "component_type" => component.component_type,
      "schema_ref" => component.schema_ref,
      "criticality" => component.criticality,
      "payload" => component.payload
    }
  end

  @doc "Restores a component from its portable envelope representation."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "component_type" => component_type,
        "schema_ref" => schema_ref,
        "criticality" => criticality,
        "payload" => payload
      }) do
    new(
      component_type: component_type,
      schema_ref: schema_ref,
      criticality: criticality,
      payload: payload
    )
  end

  def from_data(value), do: {:error, {:invalid_definition_component_data, shape(value)}}

  @spec validate_type(term()) :: :ok | {:error, term()}
  defp validate_type(type) when is_atom(type) and not is_nil(type), do: :ok
  defp validate_type(type) when is_binary(type) and type != "", do: :ok
  defp validate_type(type), do: {:error, {:invalid_component_type, type}}

  @spec validate_schema_ref(term()) :: :ok | {:error, term()}
  defp validate_schema_ref(ref) when is_binary(ref) and ref != "", do: :ok
  defp validate_schema_ref(ref), do: {:error, {:invalid_component_schema_ref, ref}}

  @spec validate_criticality(term()) :: :ok | {:error, term()}
  defp validate_criticality(criticality) when criticality in @criticalities, do: :ok

  defp validate_criticality(criticality),
    do: {:error, {:invalid_component_criticality, criticality}}

  @spec validate_payload(term()) :: :ok | {:error, term()}
  defp validate_payload(payload) do
    case Value.validate(payload) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_component_payload, reason}}
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
