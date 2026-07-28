defmodule Spectre.Stack.Ref do
  @moduledoc """
  Logical reference to one capability or runtime resource in a resolved Stack.

  A Ref carries version and definition fences, but never the process, client,
  connection, or secret used to implement the capability.
  """

  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Value

  @kinds [:package, :contract, :service, :operation, :action, :resource]

  @enforce_keys [
    :stack,
    :stack_digest,
    :installation,
    :installation_digest,
    :package,
    :kind,
    :id,
    :version
  ]
  defstruct [
    :stack,
    :stack_digest,
    :installation,
    :installation_digest,
    :package,
    :kind,
    :id,
    :version
  ]

  @type kind :: :package | :contract | :service | :operation | :action | :resource

  @type t :: %__MODULE__{
          stack: module(),
          stack_digest: String.t(),
          installation: term(),
          installation_digest: String.t(),
          package: term(),
          kind: kind(),
          id: term(),
          version: String.t()
        }

  @doc false
  @spec new(Definition.t(), Installation.t(), kind(), term()) :: t()
  def new(
        %Definition{owner: stack, digest: stack_digest},
        %Installation{
          id: installation_id,
          digest: installation_digest,
          package: %Package{id: package_id, version: version}
        },
        kind,
        id
      )
      when kind in @kinds and is_binary(stack_digest) and
             is_binary(installation_digest) do
    %__MODULE__{
      stack: stack,
      stack_digest: stack_digest,
      installation: installation_id,
      installation_digest: installation_digest,
      package: package_id,
      kind: kind,
      id: id,
      version: version
    }
  end

  def new(_definition, _installation, _kind, _id) do
    raise ArgumentError, "cannot create a Stack Ref from an unfinalized definition"
  end

  @doc """
  Returns the stable key used to fence a runtime child binding.
  """
  @spec key(t()) :: tuple()
  def key(%__MODULE__{} = ref) do
    {
      ref.stack,
      ref.stack_digest,
      ref.installation,
      ref.installation_digest,
      ref.package,
      ref.kind,
      ref.id,
      ref.version
    }
  end

  @doc """
  Validates that a Ref contains only immutable logical data.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{kind: kind} = ref) when kind in @kinds do
    Value.portable?(ref) and Value.valid_id?(ref.stack) and
      Value.valid_id?(ref.installation) and Value.valid_id?(ref.package) and
      Value.valid_id?(ref.id) and valid_digest?(ref.stack_digest) and
      valid_digest?(ref.installation_digest) and valid_version?(ref.version)
  end

  def valid?(_ref), do: false

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest), do: is_binary(digest) and byte_size(digest) == 64

  @spec valid_version?(term()) :: boolean()
  defp valid_version?(version),
    do: is_binary(version) and match?({:ok, _parsed}, Version.parse(version))
end
