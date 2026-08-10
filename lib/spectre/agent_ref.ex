defmodule Spectre.AgentRef do
  @moduledoc """
  Stable logical identity of a Spectre Agent.

  An Agent reference is process-, node-, Definition-, and Stack-independent.
  The compiled module, declared Definition version, and Stack digest are kept
  only as resolver hints for the 0.2 boundary; they never participate in the
  stable key. `legacy_key/1` exposes the former key explicitly so a
  Checkpoint Store can perform a controlled migration instead of silently
  creating or merging Instances.
  """

  alias Spectre.Definition
  alias Spectre.Run.Value
  alias Spectre.Stack.Definition, as: StackDefinition

  @schema_version 2

  @enforce_keys [:schema_version, :id]
  defstruct schema_version: @schema_version,
            id: nil,
            definition: nil,
            version: nil,
            stack_digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          definition: module() | nil,
          version: pos_integer() | nil,
          stack_digest: String.t() | nil
        }

  @doc "Returns the current stable AgentRef schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds a stable logical reference from an Agent module or returns an
  existing reference.

  The optional `:id` distinguishes intentionally separate logical Agents
  that use the same compiled source. Definition and Stack fields are resolver
  hints only and can change without changing `key/1`.
  """
  @spec new(module() | t(), keyword()) :: t()
  def new(agent_or_ref, opts \\ [])

  def new(%__MODULE__{} = ref, _opts), do: validate!(ref)

  def new(agent, opts) when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    definition = Definition.fetch!(agent)

    unless definition.kind == :agent do
      raise ArgumentError, "AgentRef requires an Agent definition, got: #{inspect(agent)}"
    end

    id = normalize_id(Keyword.get(opts, :id, definition.id || agent))

    %__MODULE__{
      schema_version: @schema_version,
      id: id,
      definition: agent,
      version: definition.version,
      stack_digest: stack_digest(definition.stack)
    }
    |> validate!()
  end

  @doc """
  Builds a stable reference from a portable logical id.

  This is the durable boundary form. `:definition`, `:version`, and
  `:stack_digest` may be supplied as trusted resolver hints but are not
  required to route the identity.
  """
  @spec from_id(term(), keyword()) :: t()
  def from_id(id, opts \\ []) when is_list(opts) do
    %__MODULE__{
      schema_version: @schema_version,
      id: normalize_id(id),
      definition: Keyword.get(opts, :definition),
      version: Keyword.get(opts, :version),
      stack_digest: Keyword.get(opts, :stack_digest)
    }
    |> validate!()
  end

  @doc "Returns the stable opaque key used by Instance routing and storage."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = ref) do
    ref = validate!(ref)
    Value.token("agent-ref-v2", {@schema_version, ref.id})
  end

  @doc """
  Returns the pre-0.2.3 key when the resolver hints needed to reproduce it are
  present.

  The legacy key is never selected automatically as the current identity.
  It exists only for explicit Checkpoint Store migration.
  """
  @spec legacy_key(t()) :: {:ok, String.t()} | {:error, term()}
  def legacy_key(%__MODULE__{} = ref) do
    with :ok <- validate!(ref) |> legacy_source_available() do
      {:ok, Value.token("agent-ref", {ref.id, ref.definition, ref.version, ref.stack_digest})}
    end
  end

  @doc "Returns the portable stable identity without making source hints authoritative."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = ref) do
    ref = validate!(ref)

    %{
      "schema_version" => ref.schema_version,
      "id" => ref.id,
      "source" => source_to_data(ref)
    }
  end

  @doc "Restores a stable AgentRef without creating atoms from persisted data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{"schema_version" => @schema_version, "id" => id, "source" => source}) do
    with {:ok, hints} <- source_from_data(source) do
      ref = struct(__MODULE__, Map.merge(%{schema_version: @schema_version, id: id}, hints))

      case validate(ref) do
        :ok -> {:ok, ref}
        {:error, _reason} = error -> error
      end
    end
  end

  def from_data(%{"schema_version" => version}),
    do: {:error, {:unsupported_agent_ref_schema, version}}

  def from_data(value), do: {:error, {:invalid_agent_ref_data, shape(value)}}

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = ref) do
    with :ok <- validate_schema(ref.schema_version),
         :ok <- validate_id(ref.id),
         :ok <- validate_definition(ref.definition),
         :ok <- validate_version(ref.version),
         :ok <- validate_stack_digest(ref.stack_digest),
         :ok <- validate_source_pair(ref) do
      Value.validate(ref, [:agent_ref])
    end
  end

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = ref) do
    case validate(ref) do
      :ok -> ref
      {:error, reason} -> raise ArgumentError, "invalid AgentRef: #{inspect(reason)}"
    end
  end

  @spec normalize_id(term()) :: String.t()
  defp normalize_id(id) do
    case Value.logical_id(id, "agent") do
      nil -> raise ArgumentError, "AgentRef id must be a portable logical value"
      value -> value
    end
  end

  defp stack_digest(nil), do: nil

  defp stack_digest(stack) when is_atom(stack) do
    case StackDefinition.fetch(stack) do
      {:ok, definition} -> definition.digest
      {:error, _reason} -> nil
    end
  end

  defp source_to_data(%__MODULE__{definition: nil}), do: nil

  defp source_to_data(%__MODULE__{} = ref) do
    %{
      "module" => Atom.to_string(ref.definition),
      "declared_version" => ref.version,
      "stack_digest" => ref.stack_digest
    }
  end

  defp source_from_data(nil),
    do: {:ok, %{definition: nil, version: nil, stack_digest: nil}}

  defp source_from_data(%{
         "module" => module_name,
         "declared_version" => version,
         "stack_digest" => stack_digest
       })
       when is_binary(module_name) do
    with {:ok, module} <- existing_module(module_name) do
      {:ok, %{definition: module, version: version, stack_digest: stack_digest}}
    end
  end

  defp source_from_data(value), do: {:error, {:invalid_agent_ref_source, shape(value)}}

  defp existing_module(module_name) do
    module = String.to_existing_atom(module_name)

    if Code.ensure_loaded?(module),
      do: {:ok, module},
      else: {:error, {:unknown_agent_ref_source, module_name}}
  rescue
    ArgumentError -> {:error, {:unknown_agent_ref_source, module_name}}
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_agent_ref_schema, version}}

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(id), do: {:error, {:invalid_agent_ref_id, id}}

  defp validate_definition(nil), do: :ok

  defp validate_definition(definition) when is_atom(definition) and not is_nil(definition),
    do: :ok

  defp validate_definition(definition),
    do: {:error, {:invalid_agent_ref_definition, definition}}

  defp validate_version(nil), do: :ok
  defp validate_version(version) when is_integer(version) and version > 0, do: :ok
  defp validate_version(version), do: {:error, {:invalid_agent_ref_version, version}}

  defp validate_stack_digest(nil), do: :ok
  defp validate_stack_digest(digest) when is_binary(digest) and digest != "", do: :ok

  defp validate_stack_digest(digest),
    do: {:error, {:invalid_agent_ref_stack_digest, digest}}

  defp validate_source_pair(%__MODULE__{definition: nil, version: nil, stack_digest: nil}),
    do: :ok

  defp validate_source_pair(%__MODULE__{definition: nil}),
    do: {:error, :agent_ref_source_module_missing}

  defp validate_source_pair(%__MODULE__{version: nil}),
    do: {:error, :agent_ref_source_version_missing}

  defp validate_source_pair(%__MODULE__{}), do: :ok

  defp legacy_source_available(%__MODULE__{definition: definition, version: version})
       when is_atom(definition) and not is_nil(definition) and is_integer(version) and version > 0,
       do: :ok

  defp legacy_source_available(%__MODULE__{}),
    do: {:error, :legacy_agent_ref_source_unavailable}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
