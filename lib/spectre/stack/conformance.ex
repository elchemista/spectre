defmodule Spectre.Stack.Conformance do
  @moduledoc """
  Executable whole-Stack conformance gate for package ecosystems.

  A package can conform in isolation while still colliding with another
  package, missing a requirement, declaring a conflict, or rejecting the
  current core release. `run/2` normalizes every Contract V1 input and feeds
  the resulting installations through the same immutable Stack compiler used
  by Agents. Satellite libraries can therefore publish a tested compatibility
  matrix without pulling ExUnit into production code.
  """

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Contract.V2
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Value

  @contract_version 1

  @type entry :: module() | {module(), Package.t() | map() | keyword()}

  @doc "Returns the whole-Stack conformance contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc """
  Validates a non-empty package matrix against the running Spectre release.

  Entries may be installable modules or `{module, manifest}` pairs. The latter
  form is useful for fixtures and generated package manifests. Optional
  `:configs` is a map keyed by package id and must contain portable data.
  """
  @spec run([entry()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(entries, opts \\ [])

  def run(entries, opts) when is_list(entries) and is_list(opts) do
    with :ok <- validate_options(opts),
         :ok <- require_entries(entries),
         {:ok, packages} <- normalize_entries(entries) do
      compile_matrix(packages, opts)
    end
  end

  def run(entries, opts),
    do: {:error, {:invalid_stack_conformance_matrix, shape(entries), shape(opts)}}

  @spec compile_matrix([Package.t()], keyword()) :: {:ok, map()} | {:error, term()}
  defp compile_matrix(packages, opts) do
    configs = Keyword.get(opts, :configs, %{})

    installations =
      Enum.map(packages, fn package ->
        config = Map.get(configs, package.id, %{})
        Installation.build!(package.id, package, config, %{}, false)
      end)

    definition =
      Definition.new!(
        id: Keyword.get(opts, :id, {:conformance, @contract_version}),
        owner: __MODULE__,
        installations: installations
      )

    packages =
      Enum.map(definition.installations, fn installation ->
        package = installation.package

        %{
          id: package.id,
          module: package.module,
          version: package.version,
          digest: package.digest,
          provides: package.provides,
          requires: package.requires,
          conflicts: package.conflicts
        }
      end)

    {:ok,
     %{
       contract_version: @contract_version,
       core_version: Spectre.version(),
       module_input_contract: V1.version(),
       sealed_runtime_contract: V2.version(),
       stack_digest: definition.digest,
       package_count: length(packages),
       packages: packages,
       digest: Value.digest(%{stack_digest: definition.digest, packages: packages})
     }}
  rescue
    exception in ArgumentError ->
      {:error, {:stack_conformance_failed, Exception.message(exception)}}
  end

  @spec validate_options(keyword()) :: :ok | {:error, term()}
  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      configs = Keyword.get(opts, :configs, %{})
      allowed = [:configs, :id]
      unknown = Keyword.keys(opts) -- allowed

      cond do
        unknown != [] ->
          {:error, {:unknown_stack_conformance_options, Enum.uniq(unknown)}}

        not is_map(configs) or is_struct(configs) ->
          {:error, {:invalid_stack_conformance_configs, shape(configs)}}

        true ->
          :ok
      end
    else
      {:error, :invalid_stack_conformance_options}
    end
  end

  @spec require_entries([entry()]) :: :ok | {:error, term()}
  defp require_entries([]), do: {:error, :empty_stack_conformance_matrix}
  defp require_entries(_entries), do: :ok

  @spec normalize_entries([entry()]) :: {:ok, [Package.t()]} | {:error, term()}
  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, packages} ->
      case normalize_entry(entry) do
        {:ok, package} -> {:cont, {:ok, [package | packages]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, packages} -> {:ok, Enum.reverse(packages)}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_entry(entry()) :: {:ok, Package.t()} | {:error, term()}
  defp normalize_entry(module) when is_atom(module) and not is_nil(module),
    do: V1.verify_installable(module)

  defp normalize_entry({module, manifest}) when is_atom(module) and not is_nil(module),
    do: V1.verify_manifest(module, manifest)

  defp normalize_entry(value),
    do: {:error, {:invalid_stack_conformance_entry, shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
