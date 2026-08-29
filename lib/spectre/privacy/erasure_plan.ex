defmodule Spectre.Privacy.ErasurePlan do
  @moduledoc """
  Read-only capability map for one configured Instance erasure.

  The plan contains no Subject value and performs no adapter I/O. It reports
  whether core can acquire maintenance ownership and execute the configured
  journal, receipt-payload, and checkpoint steps in their required order.
  """

  @schema_version 1
  @statuses [:ready, :not_configured, :required, :unsupported, :unavailable]

  @enforce_keys [:schema_version, :instance_key, :ready, :order, :components]
  defstruct schema_version: @schema_version,
            instance_key: nil,
            ready: false,
            order: [:journal, :receipt_payloads, :package_data, :checkpoint],
            components: %{}

  @type component :: %{
          required(:configured) => boolean(),
          required(:status) => :ready | :not_configured | :required | :unsupported | :unavailable,
          optional(:adapter) => String.t()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          instance_key: String.t(),
          ready: boolean(),
          order: [:journal | :receipt_payloads | :package_data | :checkpoint],
          components: %{
            required(:owner) => component(),
            required(:journal) => component(),
            required(:receipt_payloads) => component(),
            required(:package_data) => component(),
            required(:checkpoint) => component()
          }
        }

  @doc false
  @spec new(String.t(), map()) :: t()
  def new(instance_key, components)
      when is_binary(instance_key) and instance_key != "" and is_map(components) do
    ready = Enum.all?(components, fn {_name, component} -> ready?(component.status) end)

    %__MODULE__{
      schema_version: @schema_version,
      instance_key: instance_key,
      ready: ready,
      order: [:journal, :receipt_payloads, :package_data, :checkpoint],
      components: components
    }
  end

  @doc false
  @spec component(boolean(), atom(), module() | nil) :: component()
  def component(configured, status, module \\ nil)
      when is_boolean(configured) and status in @statuses do
    %{configured: configured, status: status}
    |> maybe_adapter(module)
  end

  defp ready?(status), do: status in [:ready, :not_configured]

  defp maybe_adapter(component, nil), do: component
  defp maybe_adapter(component, module), do: Map.put(component, :adapter, inspect(module))
end
