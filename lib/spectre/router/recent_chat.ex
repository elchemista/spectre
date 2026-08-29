defmodule Spectre.Router.RecentChat do
  @moduledoc false

  @default_limit 5

  @doc false
  @spec put(keyword(), Spectre.State.t() | nil) :: keyword()
  def put(opts, state) when is_list(opts) do
    Keyword.put_new_lazy(opts, :recent_chat, fn -> value(state, opts) end)
  end

  @doc false
  @spec value(Spectre.State.t() | nil, keyword()) :: term()
  def value(state, opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :recent_chat) ->
        Keyword.get(opts, :recent_chat)

      Keyword.get(opts, :classifier_history, true) == false ->
        "none"

      true ->
        format(state, history_limit(opts))
    end
  end

  @spec format(Spectre.State.t() | nil, pos_integer()) :: String.t()
  defp format(%Spectre.State{data: data}, limit) do
    data
    |> Map.get(:chat_history, [])
    |> Enum.take(-limit)
    |> Enum.map_join("\n", fn turn ->
      "User: #{turn_value(turn, :user)}\nAssistant: #{turn_value(turn, :assistant)}"
    end)
    |> case do
      "" -> "none"
      chat -> chat
    end
  end

  defp format(_state, _limit), do: "none"

  @spec history_limit(keyword()) :: pos_integer()
  defp history_limit(opts) do
    case Keyword.get(opts, :classifier_history_limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_limit
    end
  end

  @spec turn_value(map() | term(), atom()) :: term()
  defp turn_value(turn, key) when is_map(turn) do
    Map.get(turn, key, Map.get(turn, Atom.to_string(key), ""))
  end

  defp turn_value(_turn, _key), do: ""
end
