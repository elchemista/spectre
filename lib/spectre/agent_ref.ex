defmodule Spectre.AgentRef do
  @moduledoc """
  Logical address of a compiled Spectre Agent definition.

  An Agent reference is process- and node-independent. It can therefore be
  combined with a `Spectre.Subject` to locate the single live
  `Spectre.Instance` that owns that subject's ordered state.
  """

  alias Spectre.Definition
  alias Spectre.Run.Value
  alias Spectre.Stack.Definition, as: StackDefinition

  @enforce_keys [:id, :definition, :version]
  defstruct [:id, :definition, :version, :stack_digest]

  @type t :: %__MODULE__{
          id: String.t(),
          definition: module(),
          version: pos_integer(),
          stack_digest: String.t() | nil
        }

  @doc """
  Builds a logical reference from an Agent module or returns an existing one.

  The optional `:id` distinguishes intentionally separate logical Agents that
  use the same compiled definition. It never contains a PID or node name.
  """
  @spec new(module() | t(), keyword()) :: t()
  def new(agent_or_ref, opts \\ [])

  def new(%__MODULE__{} = ref, _opts), do: validate!(ref)

  def new(agent, opts) when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    definition = Definition.fetch!(agent)

    unless definition.kind == :agent do
      raise ArgumentError, "AgentRef requires an Agent definition, got: #{inspect(agent)}"
    end

    id =
      opts
      |> Keyword.get(:id, definition.id || agent)
      |> Value.logical_id("agent")

    if is_nil(id) do
      raise ArgumentError, "AgentRef id must be a portable logical value"
    end

    %__MODULE__{
      id: id,
      definition: agent,
      version: definition.version,
      stack_digest: stack_digest(definition.stack)
    }
    |> validate!()
  end

  @doc """
  Returns a stable opaque key suitable for registries and transport routing.
  """
  @spec key(t()) :: String.t()
  def key(%__MODULE__{} = ref) do
    ref = validate!(ref)
    Value.token("agent-ref", {ref.id, ref.definition, ref.version, ref.stack_digest})
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = ref) do
    with :ok <- validate_id(ref.id),
         :ok <- validate_definition(ref.definition),
         :ok <- validate_version(ref.version),
         :ok <- validate_stack_digest(ref.stack_digest) do
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

  defp stack_digest(nil), do: nil

  defp stack_digest(stack) when is_atom(stack) do
    case StackDefinition.fetch(stack) do
      {:ok, definition} -> definition.digest
      {:error, _reason} -> nil
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok
  defp validate_id(id), do: {:error, {:invalid_agent_ref_id, id}}

  defp validate_definition(definition) when is_atom(definition) and not is_nil(definition),
    do: :ok

  defp validate_definition(definition),
    do: {:error, {:invalid_agent_ref_definition, definition}}

  defp validate_version(version) when is_integer(version) and version > 0, do: :ok
  defp validate_version(version), do: {:error, {:invalid_agent_ref_version, version}}

  defp validate_stack_digest(nil), do: :ok
  defp validate_stack_digest(digest) when is_binary(digest) and digest != "", do: :ok

  defp validate_stack_digest(digest),
    do: {:error, {:invalid_agent_ref_stack_digest, digest}}
end
