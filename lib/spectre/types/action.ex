defmodule Spectre.Action do
  @moduledoc """
  Provider-neutral description of one action.

  An action says *what* should happen and *which provider* owns the operation.
  It does not execute work and it does not carry lifecycle state. Spectre turns
  it into an `Spectre.Effect` before policy evaluation, persistence, and
  execution.

  `:via` is deliberately data rather than a module name. Libraries such as
  Kinetic, Lens, or an MCP adapter can therefore select a registered provider
  without teaching the core how that provider works.
  """

  alias Spectre.Effect

  defstruct [
    :name,
    :via,
    :mode,
    :planned_by,
    :schema_hash,
    args: %{},
    metadata: %{}
  ]

  @type provider_ref :: atom() | String.t() | tuple()
  @type name :: atom() | String.t()
  @type ref :: name() | {provider_ref(), name()} | tuple()

  @type t :: %__MODULE__{
          name: name(),
          via: provider_ref(),
          args: map(),
          mode: :read | :write | :destructive | nil,
          planned_by: module() | atom() | nil,
          schema_hash: String.t() | nil,
          metadata: map()
        }

  @doc """
  Builds an action from a name/reference and options.

      Spectre.Action.new(:list_projects)
      Spectre.Action.new(:navigate, via: :lens, args: %{url: "https://example.com"})
      Spectre.Action.new({:mcp, :github, :create_issue}, args: %{title: "Bug"})
  """
  @spec new(ref() | map()) :: t()
  def new(%__MODULE__{} = action), do: action
  def new(attrs) when is_map(attrs), do: build(attrs)
  def new(action), do: new(action, [])

  @spec new(ref() | t(), keyword()) :: t()
  def new(%__MODULE__{} = action, opts) when is_list(opts) do
    attrs =
      action
      |> Map.from_struct()
      |> Map.merge(Map.new(opts))

    new(attrs)
  end

  def new(action, opts) when is_list(opts) do
    {ref_via, name} = split_ref!(action)
    via = Keyword.get(opts, :via, ref_via)

    build(%{
      name: name,
      via: via,
      args: Keyword.get(opts, :args, %{}),
      mode: Keyword.get(opts, :mode),
      planned_by: Keyword.get(opts, :planned_by),
      schema_hash: Keyword.get(opts, :schema_hash),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  @spec build(map()) :: t()
  defp build(attrs) when is_map(attrs) do
    name = attr(attrs, :name)
    via = attr(attrs, :via) || :local
    args = attr(attrs, :args) || %{}
    metadata = attr(attrs, :metadata) || %{}

    mode = attr(attrs, :mode)
    planned_by = attr(attrs, :planned_by)
    schema_hash = attr(attrs, :schema_hash)

    validate_name!(name)
    validate_provider_ref!(via)
    validate_map!(args, "action args")
    validate_map!(metadata, "action metadata")
    validate_mode!(mode)
    validate_planned_by!(planned_by)
    validate_schema_hash!(schema_hash)

    %__MODULE__{
      name: name,
      via: via,
      args: args,
      mode: mode,
      planned_by: planned_by,
      schema_hash: schema_hash,
      metadata: metadata
    }
  end

  @spec validate_name!(term()) :: :ok
  defp validate_name!(name) do
    unless valid_name?(name),
      do: raise(ArgumentError, "invalid action name: #{inspect(name)}")

    :ok
  end

  @spec validate_provider_ref!(term()) :: :ok
  defp validate_provider_ref!(via) do
    unless valid_provider_ref?(via),
      do: raise(ArgumentError, "invalid action provider: #{inspect(via)}")

    :ok
  end

  @spec validate_map!(term(), String.t()) :: :ok
  defp validate_map!(value, _label) when is_map(value), do: :ok
  defp validate_map!(_value, label), do: raise(ArgumentError, "#{label} must be a map")

  @spec validate_mode!(term()) :: :ok
  defp validate_mode!(mode) when mode in [nil, :read, :write, :destructive], do: :ok
  defp validate_mode!(mode), do: raise(ArgumentError, "invalid action mode: #{inspect(mode)}")

  @spec validate_planned_by!(term()) :: :ok
  defp validate_planned_by!(planned_by) when is_atom(planned_by), do: :ok

  defp validate_planned_by!(planned_by),
    do: raise(ArgumentError, "invalid action planner: #{inspect(planned_by)}")

  @spec validate_schema_hash!(term()) :: :ok
  defp validate_schema_hash!(nil), do: :ok

  defp validate_schema_hash!(schema_hash) when is_binary(schema_hash) and schema_hash != "",
    do: :ok

  defp validate_schema_hash!(schema_hash),
    do: raise(ArgumentError, "invalid action schema hash: #{inspect(schema_hash)}")

  @doc """
  Restores the provider-neutral action carried by an effect.
  """
  @spec from_effect(Effect.t()) :: t()
  def from_effect(%Effect{} = effect) do
    payload = effect.payload

    %__MODULE__{
      name: effect.name,
      via: Map.get(payload, :via) || Map.get(payload, "via") || :local,
      args: effect.args,
      mode: effect.mode,
      planned_by: Map.get(payload, :planned_by) || Map.get(payload, "planned_by"),
      schema_hash: Map.get(payload, :schema_hash) || Map.get(payload, "schema_hash"),
      metadata:
        Map.get(payload, :action_metadata) ||
          Map.get(payload, "action_metadata") ||
          %{}
    }
  end

  @doc """
  Converts an action into attributes accepted by `Spectre.Effect.stage_action/3`.
  """
  @spec to_effect_attrs(t()) :: map()
  def to_effect_attrs(%__MODULE__{} = action) do
    %{
      name: action.name,
      args: action.args,
      mode: action.mode,
      payload:
        %{
          via: action.via,
          planned_by: action.planned_by,
          schema_hash: action.schema_hash,
          action_metadata: action.metadata,
          source: Map.get(action.metadata, :source, default_source(action)),
          selected_tool: Map.get(action.metadata, :selected_tool),
          al: Map.get(action.metadata, :al),
          hooks: Map.get(action.metadata, :hooks, [])
        }
        |> compact_payload()
    }
  end

  @doc """
  Returns the canonical `{provider, operation}` reference.
  """
  @spec ref(t() | Effect.t() | ref()) :: {provider_ref(), name()}
  def ref(%__MODULE__{via: via, name: name}), do: {via, name}
  def ref(%Effect{} = effect), do: effect |> from_effect() |> ref()
  def ref(action), do: split_ref!(action)

  @doc """
  Returns true when a DSL protection/hook reference selects the action.

  A bare action name remains provider-agnostic for backwards compatibility.
  A tuple is namespaced and must match both provider and operation.
  """
  @spec matches_ref?(term(), t() | Effect.t()) :: boolean()
  def matches_ref?(expected, %Effect{} = effect), do: matches_ref?(expected, from_effect(effect))

  def matches_ref?(expected, %__MODULE__{} = action)
      when is_atom(expected) or is_binary(expected),
      do: comparable_name(expected) == comparable_name(action.name)

  def matches_ref?({:al, _al}, %__MODULE__{}), do: false

  def matches_ref?(expected, %__MODULE__{} = action) when is_tuple(expected) do
    case split_ref(expected) do
      {:ok, {via, name}} ->
        via == action.via and comparable_name(name) == comparable_name(action.name)

      :error ->
        false
    end
  end

  def matches_ref?(_expected, %__MODULE__{}), do: false

  @doc """
  Splits compact references such as `{:lens, :navigate}` and
  `{:mcp, :github, :create_issue}`.
  """
  @spec split_ref(ref()) :: {:ok, {provider_ref(), name()}} | :error
  def split_ref(name) when is_atom(name) or is_binary(name), do: {:ok, {:local, name}}

  def split_ref(reference) when is_tuple(reference) and tuple_size(reference) >= 2 do
    parts = Tuple.to_list(reference)
    name = List.last(parts)
    via_parts = Enum.drop(parts, -1)

    via =
      case via_parts do
        [one] -> one
        many -> List.to_tuple(many)
      end

    if valid_name?(name) and valid_provider_ref?(via),
      do: {:ok, {via, name}},
      else: :error
  end

  def split_ref(_reference), do: :error

  @doc """
  Returns whether a value is a supported compact action reference.
  """
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(reference), do: match?({:ok, _ref}, split_ref(reference))

  @spec split_ref!(ref()) :: {provider_ref(), name()}
  defp split_ref!(reference) do
    case split_ref(reference) do
      {:ok, ref} -> ref
      :error -> raise ArgumentError, "invalid action reference: #{inspect(reference)}"
    end
  end

  @spec valid_name?(term()) :: boolean()
  defp valid_name?(name),
    do: (is_atom(name) and not is_nil(name)) or (is_binary(name) and name != "")

  @spec valid_provider_ref?(term()) :: boolean()
  defp valid_provider_ref?(ref) when is_atom(ref), do: not is_nil(ref)
  defp valid_provider_ref?(ref) when is_binary(ref), do: ref != ""

  defp valid_provider_ref?(ref) when is_tuple(ref) do
    tuple_size(ref) > 0 and
      ref
      |> Tuple.to_list()
      |> Enum.all?(&valid_provider_segment?/1)
  end

  defp valid_provider_ref?(_ref), do: false

  @spec valid_provider_segment?(term()) :: boolean()
  defp valid_provider_segment?(segment) when is_atom(segment), do: not is_nil(segment)
  defp valid_provider_segment?(segment) when is_binary(segment), do: segment != ""
  defp valid_provider_segment?(_segment), do: false

  @spec comparable_name(term()) :: term()
  defp comparable_name(name) when is_atom(name), do: Atom.to_string(name)
  defp comparable_name(name) when is_binary(name), do: name
  defp comparable_name(name), do: name

  @spec default_source(t()) :: :planner | :dsl
  defp default_source(%__MODULE__{planned_by: planned_by}) when not is_nil(planned_by),
    do: :planner

  defp default_source(%__MODULE__{}), do: :dsl

  @spec compact_payload(map()) :: map()
  defp compact_payload(payload) do
    Map.reject(payload, fn
      {_key, nil} -> true
      {_key, []} -> true
      {_key, %{}} -> true
      _entry -> false
    end)
  end

  @spec attr(map(), atom()) :: term()
  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
