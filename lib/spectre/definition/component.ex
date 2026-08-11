defmodule Spectre.Definition.Component do
  @moduledoc """
  One typed component in a canonical Definition envelope.

  `criticality` tells older runtimes whether unknown semantics must fail
  closed. Security- and execution-relevant components use
  `:must_understand`; descriptive metadata never grants authority.
  """

  alias Spectre.Canonical.Value
  alias Spectre.SensitiveData

  @criticalities [:must_understand, :advisory, :descriptive]
  @fields [:component_type, :schema_ref, :criticality, :payload]
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
  def new(%__MODULE__{} = component), do: component |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_definition_component, :list}}
  end

  def new(attrs) when is_map(attrs) do
    component = struct(__MODULE__, Map.take(attrs, @fields))

    with :ok <- validate_keys(attrs),
         :ok <- validate_type(component.component_type),
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
  def from_data(data) when is_map(data) and not is_struct(data) do
    expected = Enum.map(@fields, &Atom.to_string/1)

    with [] <- Map.keys(data) -- expected,
         [] <- expected -- Map.keys(data) do
      new(
        component_type: Map.get(data, "component_type"),
        schema_ref: Map.get(data, "schema_ref"),
        criticality: Map.get(data, "criticality"),
        payload: Map.get(data, "payload")
      )
    else
      fields when is_list(fields) ->
        {:error, {:invalid_definition_component_fields, Enum.sort(fields)}}
    end
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
    with :ok <- portable_payload(payload) do
      cond do
        path = SensitiveData.sensitive_path(payload) ->
          {:error, {:secret_component_payload, path}}

        path = ast_path(payload) ->
          {:error, {:executable_component_ast, path}}

        true ->
          :ok
      end
    end
  end

  defp portable_payload(payload) do
    case Value.validate(payload) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_component_payload, reason}}
    end
  end

  @spec ast_path(term(), [term()]) :: [term()] | nil
  defp ast_path(value, path \\ [])

  defp ast_path({form, metadata, arguments} = value, path)
       when is_list(metadata) and (is_list(arguments) or is_atom(arguments)) do
    if ast_form?(form) and Keyword.keyword?(metadata) do
      Enum.reverse(path)
    else
      value |> Tuple.to_list() |> find_list_path(path, &ast_path/2)
    end
  end

  defp ast_path(value, path) when is_tuple(value),
    do: value |> Tuple.to_list() |> find_list_path(path, &ast_path/2)

  defp ast_path(value, path) when is_list(value),
    do: find_list_path(value, path, &ast_path/2)

  defp ast_path(value, path) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      ast_path(key, [{:key, key_label(key)} | path]) || ast_path(item, [key_label(key) | path])
    end)
  end

  defp ast_path(_value, _path), do: nil

  @spec find_list_path(term(), [term()], (term(), [term()] -> [term()] | nil)) ::
          [term()] | nil
  defp find_list_path(values, path, finder), do: find_list_path(values, path, finder, 0)

  @spec find_list_path(term(), [term()], (term(), [term()] -> [term()] | nil), non_neg_integer()) ::
          [term()] | nil
  defp find_list_path([], _path, _finder, _index), do: nil

  defp find_list_path([value | rest], path, finder, index) do
    finder.(value, [index | path]) || find_list_path(rest, path, finder, index + 1)
  end

  defp find_list_path(_improper, path, _finder, index),
    do: Enum.reverse([{:tail, index} | path])

  @spec ast_form?(term()) :: boolean()
  defp ast_form?(form) when is_atom(form), do: true

  defp ast_form?({:., metadata, [_target, function]})
       when is_list(metadata) and is_atom(function),
       do: Keyword.keyword?(metadata)

  defp ast_form?(_form), do: false

  @spec key_label(term()) :: term()
  defp key_label(key) when is_atom(key) or is_binary(key) or is_integer(key), do: key
  defp key_label(_key), do: :key

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_definition_component_fields, Enum.sort(unknown)}}
    end
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
