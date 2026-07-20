defmodule Spectre.Telemetry do
  @moduledoc """
  Privacy-safe operational telemetry boundary.

  Spectre emits through the standard `:telemetry` module when the host has it
  installed. Tests and lightweight hosts may instead provide a
  `:telemetry_handler` callback in runtime options. Telemetry is observational:
  callback failures never alter a turn.
  """

  @spec emit([atom()], map(), map(), keyword()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}, opts \\ [])

  def emit(event, measurements, metadata, opts)
      when is_list(event) and is_map(measurements) and is_map(metadata) and is_list(opts) do
    full_event = [:spectre | event]
    notify_handler(Keyword.get(opts, :telemetry_handler), full_event, measurements, metadata)

    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      :erlang.apply(:telemetry, :execute, [full_event, measurements, metadata])
    end

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  def emit(_event, _measurements, _metadata, _opts), do: :ok

  defp notify_handler(nil, _event, _measurements, _metadata), do: :ok

  defp notify_handler(handler, event, measurements, metadata) when is_function(handler, 3) do
    handler.(event, measurements, metadata)
    :ok
  end

  defp notify_handler({module, function}, event, measurements, metadata)
       when is_atom(module) and is_atom(function) do
    apply(module, function, [event, measurements, metadata])
    :ok
  end

  defp notify_handler(_handler, _event, _measurements, _metadata), do: :ok
end
