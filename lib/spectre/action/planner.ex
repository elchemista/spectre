defmodule Spectre.Action.Planner do
  @moduledoc """
  Port implemented by optional action-planning libraries.

  A planner may inspect an LLM reply and return provider-neutral
  `Spectre.Action` values. It cannot execute providers or mutate Agent state.
  """

  alias Spectre.Action

  @type response :: %{
          required(:reply_text) => String.t(),
          required(:actions) => [Action.t() | map()]
        }

  @callback plan_response(String.t(), Spectre.Context.t() | map(), keyword()) ::
              {:ok, response()} | {:error, term()}

  @callback plan(String.t(), Spectre.Context.t() | map(), keyword()) ::
              {:ok, Action.t() | map()} | {:error, term()}

  @callback clean_reply(String.t(), Spectre.Context.t() | map(), keyword()) :: String.t()

  @callback incremental_cleaner?() :: boolean()

  @optional_callbacks plan: 3, clean_reply: 3, incremental_cleaner?: 0
end
