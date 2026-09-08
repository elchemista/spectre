defmodule Spectre.Extension do
  @moduledoc """
  Explicit compile-time package contributions, without an installer runtime.

  The shared authoring DSL passes an install block as a keyword of declaration
  names and argument lists to configure/1. A package validates its vocabulary
  and returns portable configuration plus named adapter ports:

      {:ok, %{
        data: %{catalog: catalog},
        ports: %{{:request, :inference} => {MyPackage.Request, [catalog: catalog]}}
      }}

  Configuration never starts resources, fetches credentials, downloads models
  or grants authority. Mix installs the optional package; the host supervises
  and wires its resources. A package may expose ordinary functions in addition
  to this callback. There is no private Agent attribute or second compiler hook.
  """

  alias Spectre.{Adapter, Portable}

  @type ports :: %{{atom(), atom()} => {module(), keyword()}}
  @type contribution :: %{data: term(), ports: ports()}
  @callback configure(keyword()) :: {:ok, contribution()} | {:error, term()}

  @doc "Validates a package's inert contribution without invoking a runtime adapter."
  @spec configure(module(), keyword()) :: {:ok, contribution()} | {:error, term()}
  def configure(module, opts) do
    with true <- Portable.keyword?(opts),
         :ok <- Portable.validate(opts),
         :ok <- Adapter.validate(module, configure: 1),
         {:ok, {:ok, contribution}} <- Adapter.invoke(module, :configure, [opts]),
         {:ok, attrs} <- Portable.normalize_attrs(contribution, [:data, :ports], :extension),
         :ok <- Portable.validate(attrs),
         ports = Map.get(attrs, :ports, %{}),
         true <- is_map(ports),
         :ok <- Spectre.Validation.all(ports, &port/1) do
      {:ok, %{data: Map.get(attrs, :data, %{}), ports: ports}}
    else
      false -> {:error, :invalid_extension_configuration}
      {:ok, {:error, _} = error} -> error
      {:ok, _invalid} -> {:error, :invalid_extension_reply}
      {:error, _} = error -> error
    end
  end

  defp port({{kind, name}, {module, opts}})
       when is_atom(kind) and kind not in [nil, true, false] and
              is_atom(name) and name not in [nil, true, false] do
    if Portable.keyword?(opts),
      do: Adapter.validate(module, []),
      else: {:error, :invalid_extension_port_options}
  end

  defp port(_entry), do: {:error, :invalid_extension_port}
end
