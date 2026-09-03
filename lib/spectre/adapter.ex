defmodule Spectre.Adapter do
  @moduledoc """
  Small, authority-free utilities shared by Spectre adapter boundaries.

  Adapters connect the governed runtime to application code: clocks, ingress,
  minds, stores, executors, brokers and observers. Discovering a module or
  calling one of its callbacks never grants authority; it only validates host
  wiring or crosses an already-declared boundary.

  This module intentionally knows nothing about a particular behaviour. Each
  boundary remains responsible for validating callback results and translating
  failures into its own domain vocabulary.
  """

  @type callback_spec :: {atom(), non_neg_integer()}
  @type validation_error ::
          {:invalid_adapter_module, term()}
          | {:adapter_module_not_loaded, module()}
          | {:adapter_callback_missing, module(), atom(), non_neg_integer()}
  @type invocation_error ::
          {:adapter_callback_exception, module(), atom(), module()}
          | {:adapter_callback_failure, module(), atom(), :exit | :throw}

  @doc "Validates that a loaded module implements every required callback."
  @spec validate(term(), [callback_spec()]) :: :ok | {:error, validation_error()}
  def validate(module, callbacks)
      when is_atom(module) and module not in [nil, true, false] and is_list(callbacks) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:adapter_module_not_loaded, module}}

      missing =
          Enum.find(callbacks, fn {name, arity} ->
            not (is_atom(name) and is_integer(arity) and arity >= 0 and
                     function_exported?(module, name, arity))
          end) ->
        {name, arity} = missing
        {:error, {:adapter_callback_missing, module, name, arity}}

      true ->
        :ok
    end
  end

  def validate(module, _callbacks), do: {:error, {:invalid_adapter_module, module}}

  @doc "Invokes a previously validated callback without leaking exception details."
  @spec invoke(module(), atom(), [term()]) :: {:ok, term()} | {:error, invocation_error()}
  def invoke(module, callback, arguments)
      when is_atom(module) and module not in [nil, true, false] and is_atom(callback) and
             is_list(arguments) do
    {:ok, apply(module, callback, arguments)}
  rescue
    exception -> {:error, {:adapter_callback_exception, module, callback, exception.__struct__}}
  catch
    kind, _reason when kind in [:exit, :throw] ->
      {:error, {:adapter_callback_failure, module, callback, kind}}
  end
end
