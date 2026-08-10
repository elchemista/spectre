defmodule Spectre.Stack.Contract.V1 do
  @moduledoc """
  Executable version-one conformance contract for Stack packages.

  Satellite libraries can call these functions from their own ExUnit suites
  without depending on ExUnit from production code.
  """

  alias Spectre.Stack.Contract.V2
  alias Spectre.Stack.Installable
  alias Spectre.Stack.Package

  @version 1

  @doc """
  Returns the contract version implemented by this module.
  """
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Verifies an installable module and returns its normalized manifest.
  """
  @spec verify_installable(module()) :: {:ok, Package.t()} | {:error, term()}
  def verify_installable(module), do: Installable.verify(module, @version)

  @doc """
  Verifies a raw manifest for `module`.
  """
  @spec verify_manifest(module(), Package.t() | map() | keyword()) ::
          {:ok, Package.t()} | {:error, term()}
  def verify_manifest(module, manifest) do
    package = Package.new!(module, manifest)

    if package.contract == @version,
      do: {:ok, package},
      else: {:error, {:unsupported_stack_contract, package.contract, [@version]}}
  rescue
    exception in ArgumentError -> {:error, {:invalid_manifest, Exception.message(exception)}}
  end

  @doc """
  Verifies an installable module or raises.
  """
  @spec assert_installable!(module()) :: Package.t()
  def assert_installable!(module), do: Installable.verify!(module, @version)

  @doc """
  Reads a compiled V1 Stack and conservatively lowers it into Contract V2.

  V1 declarations remain requests. Only capabilities present in the trusted
  `:authority_ceiling` become effective grants in the returned contract.
  """
  @spec to_v2(Spectre.Stack.Definition.t() | module() | nil, keyword()) ::
          {:ok, V2.t()} | {:error, term()}
  def to_v2(stack, opts \\ []), do: V2.from_v1(stack, opts)
end
