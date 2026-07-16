defmodule Spectre.Turn.Decision do
  @moduledoc """
  Reduces a `%Spectre.Result{}` into the host's next lifecycle decision.

  Decisions are intentionally closed over lifecycle, while effect and awaitable
  kinds remain open data.
  """

  alias Spectre.Result

  @doc """
  Decides what the host should do next for a result.

  Authoritative pending state is read through `Spectre.Result`, so a host does
  not lose an open policy or pending effect when a transition-local list is
  omitted while reconstructing a result.
  """
  @spec decide(Result.t()) :: Spectre.Turn.decision()
  def decide(%Result{} = result) do
    cond do
      awaitable = Result.open_awaitable(result) ->
        {:awaiting, awaitable, result}

      effect = Result.pending_effect(result) ->
        {:needs, effect, result}

      completion = Result.latest_completion(result) ->
        {:completed, completion, result}

      Result.visible_reply?(result) ->
        {:reply, result}

      true ->
        {:no_response, result}
    end
  end
end
