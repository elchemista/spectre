defmodule Spectre.Definition.ContractRegistry do
  @moduledoc """
  Trusted registry of component contracts understood by this runtime.

  Canonical Definitions carry schema Refs, never validator modules. The host
  constructs this registry from reviewed code and the resolver rejects every
  unknown `:must_understand` component. Unknown advisory or descriptive
  components remain opaque and are preserved in the Manifest snapshot.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component

  @criticalities [:must_understand, :advisory, :descriptive]
  @builtin_entries [
    %{
      component_type: :identity,
      schema_ref: "spectre.definition.identity/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :metadata,
      schema_ref: "spectre.definition.metadata/1",
      criticalities: [:descriptive],
      version: 1
    },
    %{
      component_type: :applicability,
      schema_ref: "spectre.definition.applicability/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :routing,
      schema_ref: "spectre.definition.routing/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :policies,
      schema_ref: "spectre.definition.policies/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :prompt_fragments,
      schema_ref: "spectre.prompt.fragments/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :requirements,
      schema_ref: "spectre.definition.requirements/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :skills,
      schema_ref: "spectre.definition.skills/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :compiled_runtime,
      schema_ref: "spectre.definition.compiled-runtime/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :change_surface,
      schema_ref: "spectre.definition.change-surface/1",
      criticalities: [:must_understand],
      version: 1,
      validator: {Spectre.Morph.Surface, :validate_component}
    },
    %{
      component_type: :execution,
      schema_ref: "spectre.definition.execution/1",
      criticalities: [:must_understand],
      version: 1
    },
    %{
      component_type: :projection,
      schema_ref: "spectre.definition.projection/1",
      criticalities: [:advisory],
      version: 1
    }
  ]

  @enforce_keys [:entries]
  defstruct entries: %{}

  @type validator :: {module(), atom()} | nil
  @type entry :: %{
          required(:component_type) => atom() | String.t(),
          required(:schema_ref) => String.t(),
          required(:criticalities) => [Component.criticality()],
          required(:version) => pos_integer(),
          required(:validator) => validator()
        }
  @type t :: %__MODULE__{entries: %{optional(String.t()) => entry()}}

  @doc "Returns the registry understood by the current Spectre release."
  @spec default() :: t()
  def default, do: new!(@builtin_entries)

  @doc "Builds a registry from trusted component contract entries."
  @spec new([map() | keyword()]) :: {:ok, t()} | {:error, term()}
  def new(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %__MODULE__{entries: %{}}}, fn entry, {:ok, registry} ->
      case register(registry, entry) do
        {:ok, registry} -> {:cont, {:ok, registry}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def new(value), do: {:error, {:invalid_component_contract_registry, shape(value)}}

  @doc "Builds a registry or raises with its stable validation reason."
  @spec new!([map() | keyword()]) :: t()
  def new!(entries) do
    case new(entries) do
      {:ok, registry} -> registry
      {:error, reason} -> raise ArgumentError, "invalid component registry: #{inspect(reason)}"
    end
  end

  @doc "Registers one reviewed component contract."
  @spec register(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{} = registry, attrs) when is_list(attrs),
    do: register(registry, Map.new(attrs))

  def register(%__MODULE__{} = registry, attrs) when is_map(attrs) do
    with {:ok, entry} <- normalize_entry(attrs),
         false <- Map.has_key?(registry.entries, entry.schema_ref) do
      {:ok, %{registry | entries: Map.put(registry.entries, entry.schema_ref, entry)}}
    else
      true -> {:error, {:duplicate_component_contract, Map.get(attrs, :schema_ref)}}
      {:error, _reason} = error -> error
    end
  end

  def register(%__MODULE__{}, value),
    do: {:error, {:invalid_component_contract, shape(value)}}

  @doc "Fetches a registered contract by its exact schema Ref."
  @spec fetch(t(), String.t()) :: {:ok, entry()} | :error
  def fetch(%__MODULE__{entries: entries}, schema_ref), do: Map.fetch(entries, schema_ref)

  @doc "Validates all understood components and fail-closes unknown critical semantics."
  @spec validate(t(), Canonical.t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = registry, %Canonical{components: components}) do
    Enum.reduce_while(components, :ok, fn component, :ok ->
      case validate_component(registry, component) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Returns the exact contract interpretation sealed into a Manifest."
  @spec snapshot(t(), Canonical.t()) :: {:ok, [map()]} | {:error, term()}
  def snapshot(%__MODULE__{} = registry, %Canonical{} = canonical) do
    with :ok <- validate(registry, canonical) do
      contracts =
        Enum.map(canonical.components, &snapshot_component(registry, &1))

      {:ok, Enum.sort_by(contracts, &{&1.schema_ref, &1.component_type})}
    end
  end

  @doc "Verifies that the current registry interprets a Definition exactly as published."
  @spec verify_snapshot(t(), Canonical.t(), [map()]) :: :ok | {:error, term()}
  def verify_snapshot(%__MODULE__{} = registry, %Canonical{} = canonical, expected)
      when is_list(expected) do
    with {:ok, actual} <- snapshot(registry, canonical) do
      if actual == expected,
        do: :ok,
        else: {:error, {:component_contract_snapshot_mismatch, expected, actual}}
    end
  end

  def verify_snapshot(%__MODULE__{}, %Canonical{}, value),
    do: {:error, {:invalid_component_contract_snapshot, shape(value)}}

  @spec validate_component(t(), Component.t()) :: :ok | {:error, term()}
  defp validate_component(registry, %Component{} = component) do
    case fetch(registry, component.schema_ref) do
      {:ok, entry} ->
        validate_understood(component, entry)

      :error when component.criticality == :must_understand ->
        {:error, {:unknown_must_understand_component, component.schema_ref}}

      :error ->
        :ok
    end
  end

  @spec validate_understood(Component.t(), entry()) :: :ok | {:error, term()}
  defp validate_understood(component, entry) do
    cond do
      component.component_type != entry.component_type ->
        {:error,
         {:component_contract_type_mismatch, component.schema_ref, entry.component_type,
          component.component_type}}

      component.criticality not in entry.criticalities ->
        {:error,
         {:component_contract_criticality_mismatch, component.schema_ref, component.criticality}}

      true ->
        invoke_validator(entry.validator, component)
    end
  end

  @spec invoke_validator(validator(), Component.t()) :: :ok | {:error, term()}
  defp invoke_validator(nil, _component), do: :ok

  defp invoke_validator({module, function}, component) do
    case apply(module, function, [component]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:component_contract_rejected, component.schema_ref, reason}}
      value -> {:error, {:invalid_component_contract_reply, component.schema_ref, value}}
    end
  rescue
    exception ->
      {:error, {:component_contract_exception, component.schema_ref, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:component_contract_failure, component.schema_ref, kind, reason}}
  end

  @spec snapshot_component(t(), Component.t()) :: map()
  defp snapshot_component(registry, component) do
    case fetch(registry, component.schema_ref) do
      {:ok, entry} -> contract_snapshot(component, entry.version, :understood)
      :error -> contract_snapshot(component, nil, :opaque)
    end
  end

  @spec contract_snapshot(Component.t(), pos_integer() | nil, :understood | :opaque) :: map()
  defp contract_snapshot(component, version, status) do
    %{
      component_type: component.component_type,
      schema_ref: component.schema_ref,
      criticality: component.criticality,
      contract_version: version,
      status: status
    }
  end

  @spec normalize_entry(map()) :: {:ok, entry()} | {:error, term()}
  defp normalize_entry(attrs) do
    component_type = Map.get(attrs, :component_type)
    schema_ref = Map.get(attrs, :schema_ref)
    criticalities = Map.get(attrs, :criticalities, [])
    version = Map.get(attrs, :version)
    validator = Map.get(attrs, :validator)

    with :ok <- validate_component_type(component_type),
         :ok <- validate_schema_ref(schema_ref),
         :ok <- validate_criticalities(criticalities),
         :ok <- validate_version(version),
         :ok <- validate_validator(validator) do
      {:ok,
       %{
         component_type: component_type,
         schema_ref: schema_ref,
         criticalities: Enum.uniq(criticalities),
         version: version,
         validator: validator
       }}
    end
  end

  @spec validate_component_type(term()) :: :ok | {:error, term()}
  defp validate_component_type(value) do
    if valid_component_type?(value),
      do: :ok,
      else: {:error, {:invalid_component_contract_type, value}}
  end

  @spec validate_schema_ref(term()) :: :ok | {:error, term()}
  defp validate_schema_ref(value) when is_binary(value) and value != "", do: :ok
  defp validate_schema_ref(value), do: {:error, {:invalid_component_contract_ref, value}}

  @spec validate_criticalities(term()) :: :ok | {:error, term()}
  defp validate_criticalities(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(&1 in @criticalities)),
      do: :ok,
      else: {:error, {:invalid_component_contract_criticalities, values}}
  end

  defp validate_criticalities(value),
    do: {:error, {:invalid_component_contract_criticalities, value}}

  @spec validate_version(term()) :: :ok | {:error, term()}
  defp validate_version(value) when is_integer(value) and value > 0, do: :ok
  defp validate_version(value), do: {:error, {:invalid_component_contract_version, value}}

  @spec validate_validator(term()) :: :ok | {:error, term()}
  defp validate_validator(value) do
    if valid_validator?(value),
      do: :ok,
      else: {:error, {:invalid_component_contract_validator, value}}
  end

  @spec valid_component_type?(term()) :: boolean()
  defp valid_component_type?(value) when is_atom(value), do: not is_nil(value)
  defp valid_component_type?(value) when is_binary(value), do: value != ""
  defp valid_component_type?(_value), do: false

  @spec valid_validator?(term()) :: boolean()
  defp valid_validator?(nil), do: true

  defp valid_validator?({module, function}),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function)

  defp valid_validator?(_value), do: false

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
