defmodule Spectre.Extension do
  @moduledoc """
  On-demand package contributions without a second runtime or compiler hook.

  An extension supplies `definition/1`, returning an Agent/Skill declaration
  built from its configuration, and optionally `ports/1`, returning a map of
  named host adapter configurations (`module` or `{module, keyword}`). Mount it
  with `extend MyPackage, as: "package", options: [...]` in an Agent or Skill.

  Candidate templates, routes, assets and component references are expanded
  and pinned in the immutable parent Definition. Ports remain in the compiled
  host module's `ports/0`, under the same namespace; no executable module or
  capability is loaded from ledger data. The application explicitly wires each
  port to its boundary (router, ingress, store, executor, observer, etc.), whose
  own behaviour validates it. Merely installing a package creates no authority.

  This replaces the old action-provider/effect-executor ownership machinery.
  Package DSL macros can call these ordinary declarations; they need neither a
  private Agent attribute nor an additional `@before_compile` hook.
  """

  alias Spectre.{Adapter, Definition, Portable}
  alias Spectre.Agent.Declaration
  alias Spectre.Router.Rule

  @type ports :: %{String.t() => {module(), keyword()}}
  @callback definition(keyword()) :: {:ok, Definition.t()} | {:error, term()}
  @callback ports(keyword()) :: ports()
  @optional_callbacks ports: 1

  @doc "Compiles and validates inert declarations separately from host ports."
  @spec compile(module(), keyword()) :: {:ok, Definition.t(), ports()} | {:error, term()}
  def compile(module, opts) do
    with true <- Portable.keyword?(opts),
         :ok <- Adapter.validate(module, definition: 1),
         {:ok, {:ok, value}} <- Adapter.invoke(module, :definition, [opts]),
         {:ok, definition} <- Definition.new(value),
         {:ok, _} <- Declaration.read(definition),
         {:ok, ports} <- load_ports(module, opts) do
      {:ok, definition, ports}
    else
      false -> {:error, :invalid_extension_options}
      {:ok, {:error, _} = error} -> error
      {:ok, _} -> {:error, :invalid_extension_definition_reply}
      {:error, _} = error -> error
    end
  end

  @doc false
  def validate_ports(values) when is_map(values) and not is_struct(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      {module, opts} =
        case value do
          {module, opts} -> {module, opts}
          module -> {module, []}
        end

      with :ok <- Rule.path(name),
           true <- Portable.keyword?(opts),
           :ok <- Adapter.validate(module, []) do
        {:cont, {:ok, Map.put(acc, name, {module, opts})}}
      else
        false -> {:halt, {:error, :invalid_extension_port_options}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def validate_ports(_values), do: {:error, :invalid_extension_ports}

  defp load_ports(module, opts) do
    if function_exported?(module, :ports, 1) do
      with {:ok, ports} <- Adapter.invoke(module, :ports, [opts]), do: validate_ports(ports)
    else
      {:ok, %{}}
    end
  end
end
