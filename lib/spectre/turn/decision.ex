defmodule Spectre.Turn.Decision do
  @moduledoc """
  Reduces a `%Spectre.Result{}` into the host's next lifecycle decision.

  Decisions are intentionally closed over lifecycle, while effect and awaitable
  kinds remain open data.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Result

  @doc """
  Decides what the host should do next for a result.
  """
  @spec decide(Result.t()) :: Spectre.Turn.decision()
  def decide(%Result{} = result) do
    cond do
      awaitable = open_awaitable(result) ->
        {:awaiting, awaitable, result}

      effect = pending_effect(result) ->
        {:needs, effect, result}

      completion = latest_completion(result) ->
        {:completed, completion, result}

      visible_reply?(result) ->
        {:reply, result}

      true ->
        {:no_response, result}
    end
  end

  @spec open_awaitable(Result.t()) :: Awaitable.t() | nil
  defp open_awaitable(%Result{awaitables: awaitables}) do
    Enum.find(awaitables, &(&1.status == :open))
  end

  @spec pending_effect(Result.t()) :: Effect.t() | nil
  defp pending_effect(%Result{effects: effects}) do
    Enum.find(effects, &(&1.status in [:pending, :waiting_policy, :approved]))
  end

  @spec latest_completion(Result.t()) :: Effect.t() | Awaitable.t() | nil
  defp latest_completion(%Result{effects: effects, awaitables: awaitables}) do
    Enum.find(Enum.reverse(effects), &(&1.status in [:completed, :failed, :cancelled])) ||
      Enum.find(
        Enum.reverse(awaitables),
        &(&1.status in [:accepted, :rejected, :cancelled, :expired])
      )
  end

  @spec visible_reply?(Result.t()) :: boolean()
  defp visible_reply?(%Result{reply_text: text}) when is_binary(text), do: String.trim(text) != ""
end
