defmodule Spectre.Event.SchemaRegistry do
  @moduledoc "Host-owned compatibility gate for global Event payload schemas."

  alias Spectre.Definition.Ref
  alias Spectre.Event.Envelope

  @type config :: module() | {module(), keyword()} | nil

  @callback compatible?(Ref.t(), Envelope.t(), keyword()) :: :ok | {:error, term()}

  @spec verify(config(), Ref.t(), Envelope.t()) :: :ok | {:error, term()}
  def verify(nil, %Ref{}, %Envelope{}), do: {:error, :global_event_schema_registry_required}

  def verify(config, %Ref{} = definition_ref, %Envelope{} = envelope) do
    with {:ok, module, opts} <- normalize(config),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :compatible?, 3) do
      invoke(module, definition_ref, envelope, opts)
    else
      false -> {:error, :event_schema_registry_not_loaded}
      {:error, _reason} = error -> error
    end
  end

  defp invoke(module, definition_ref, envelope, opts) do
    case module.compatible?(definition_ref, envelope, opts) do
      :ok -> :ok
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_event_schema_registry_reply, module, value}}
    end
  rescue
    exception -> {:error, {:event_schema_registry_exception, module, exception.__struct__}}
  catch
    kind, reason -> {:error, {:event_schema_registry_failure, module, kind, reason}}
  end

  defp normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, module, []}

  defp normalize({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, module, opts},
      else: {:error, :invalid_event_schema_registry}
  end

  defp normalize(_value), do: {:error, :invalid_event_schema_registry}
end
