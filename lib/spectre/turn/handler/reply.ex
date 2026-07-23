defmodule Spectre.Turn.Handler.Reply do
  @moduledoc """
  Safe, typed reply returned by a `Spectre.Turn.Handler`.

  The value intentionally contains no Spectre state, route, capability effect,
  or awaitable. Spectre remains authoritative for those fields when it builds
  the final `Spectre.Result` and, at the host boundary, `Spectre.Turn`.
  """

  @type t :: %__MODULE__{
          reply_text: String.t(),
          events: [term()],
          metadata: map()
        }

  defstruct reply_text: "", events: [], metadata: %{}

  @doc "Builds a typed turn-handler reply."
  @spec new(String.t(), keyword()) :: t()
  def new(reply_text, opts \\ [])

  def new(reply_text, opts) when is_binary(reply_text) and is_list(opts) do
    reply = %__MODULE__{
      reply_text: reply_text,
      events: Keyword.get(opts, :events, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    case validate(reply) do
      :ok ->
        reply

      {:error, reason} ->
        raise ArgumentError, "invalid turn handler reply: #{inspect(reason)}"
    end
  end

  def new(reply_text, opts) do
    raise ArgumentError,
          "turn handler reply expects binary text and keyword options, got: " <>
            inspect({shape(reply_text), shape(opts)})
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = reply) do
    cond do
      not is_binary(reply.reply_text) ->
        {:error, {:invalid_turn_handler_reply_text, shape(reply.reply_text)}}

      not is_list(reply.events) ->
        {:error, {:invalid_turn_handler_events, shape(reply.events)}}

      not is_map(reply.metadata) ->
        {:error, {:invalid_turn_handler_metadata, shape(reply.metadata)}}

      true ->
        :ok
    end
  end

  @spec shape(term()) :: atom() | {:struct, module()}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(%{__struct__: module}), do: {:struct, module}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
