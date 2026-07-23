defmodule Spectre.Turn.Handlers do
  @moduledoc false

  alias Spectre.Context
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request

  @type handler :: module() | {module(), keyword()}
  @type config :: false | nil | [handler()]
  @type dispatch_result :: :cont | {:reply, Result.t()} | {:error, term()}

  @doc false
  @spec dispatch(Context.t()) :: dispatch_result()
  def dispatch(%Context{} = context) do
    case Keyword.get(context.opts, :turn_handlers, []) do
      value when value in [nil, false, []] -> :cont
      handlers when is_list(handlers) -> run(handlers, Request.new(context), context)
      invalid -> {:error, {:invalid_turn_handlers, shape(invalid)}}
    end
  end

  @spec run([term()], Request.t(), Context.t()) :: dispatch_result()
  defp run(handlers, %Request{} = request, %Context{} = context) do
    Enum.reduce_while(handlers, :cont, fn handler, :cont ->
      case call(handler, request, context) do
        :cont -> {:cont, :cont}
        {:reply, %Result{} = result} -> {:halt, {:reply, result}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec call(term(), Request.t(), Context.t()) :: dispatch_result()
  defp call({handler, handler_opts}, %Request{} = request, %Context{} = context)
       when is_atom(handler) and not is_nil(handler) and is_list(handler_opts) do
    if Keyword.keyword?(handler_opts) do
      invoke_bounded(handler, handler_opts, request, context)
    else
      {:error, {:invalid_turn_handler, shape({handler, handler_opts})}}
    end
  end

  defp call(handler, %Request{} = request, %Context{} = context)
       when is_atom(handler) and not is_nil(handler),
       do: invoke_bounded(handler, [], request, context)

  defp call(handler, %Request{}, %Context{}),
    do: {:error, {:invalid_turn_handler, shape(handler)}}

  @spec invoke_bounded(module(), keyword(), Request.t(), Context.t()) :: dispatch_result()
  defp invoke_bounded(handler, handler_opts, %Request{} = request, %Context{} = context) do
    callback_opts = callback_opts(handler_opts, context.opts)

    result =
      Call.run(
        :turn_handler,
        fn -> invoke(handler, request, callback_opts) end,
        Keyword.put(callback_opts, :purpose, :turn_handler)
      )

    case result do
      {:ok, :cont} -> :cont
      {:ok, {:reply, %Reply{} = reply}} -> {:reply, to_result(handler, reply, context)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec invoke(module(), Request.t(), keyword()) ::
          {:ok, :cont | {:reply, Reply.t()}} | {:error, term()}
  defp invoke(handler, %Request{} = request, opts) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :handle_turn, 2) do
      handler.handle_turn(request, opts)
      |> normalize_reply()
    else
      {:error, {:undefined_turn_handler, handler}}
    end
  end

  @spec normalize_reply(term()) :: {:ok, :cont | {:reply, Reply.t()}} | {:error, term()}
  defp normalize_reply(:cont), do: {:ok, :cont}

  defp normalize_reply({:reply, %Reply{} = reply}) do
    with :ok <- Reply.validate(reply), do: {:ok, {:reply, reply}}
  end

  defp normalize_reply({:error, _reason} = error), do: error
  defp normalize_reply(other), do: {:error, Failure.invalid_reply(:turn_handler, other)}

  @spec callback_opts(keyword(), keyword()) :: keyword()
  defp callback_opts(handler_opts, runtime_opts) do
    runtime_opts = runtime_opts |> Keyword.delete(:turn_handlers) |> Call.adapter_opts()
    Keyword.merge(handler_opts, runtime_opts)
  end

  @spec to_result(module(), Reply.t(), Context.t()) :: Result.t()
  defp to_result(handler, %Reply{} = reply, %Context{} = context) do
    %Result{
      input: context.input,
      state: context.state,
      reply_text: reply.reply_text,
      events: [%{type: :turn_handled, handler: handler} | reply.events],
      metadata: Map.put(reply.metadata, :turn_handler, handler)
    }
  end

  @spec shape(term()) :: atom() | {:struct, module()}
  defp shape(value) when is_list(value), do: :list
  defp shape(%{__struct__: module}), do: {:struct, module}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
