defmodule Spectre.Turn.Dispatcher do
  @moduledoc """
  Drives a `%Spectre.Turn{}` decision to a delivered outcome.

  Every host that consumes `Spectre.turn/3` ends up writing the same loop:
  branch on the decision tuple, auto-resolve a policy the host can already
  satisfy, execute the pending effect, and pick a fallback reply when the
  model produced nothing deliverable. This module owns that protocol so the
  host only implements delivery.

  The only required callback is `deliver_reply/3`. Everything else has a
  protocol-level default:

    * `{:reply, result}` — `deliver_reply/3` with the reply text, or
      `fallback_reply/2` → `no_response/2` when the text is empty
    * `{:no_response, result}` — `no_response/2`
    * `{:awaiting, awaitable, result}` — `satisfied_resolution/2` first; a
      resolution re-enters `Spectre.Turn.resolve_policy/3` and the loop
      continues with the new decision. `:not_satisfied` delivers the policy
      request via `policy_request/3`.
    * `{:needs, effect, result}` — `execute?/3` (default `true`) then
      `Spectre.execute/3`; the executed result re-enters the loop. A `false`
      veto delivers through `suppressed/3`.
    * `{:completed, completion, result}` — `action_result/3`

  ## Example

      defmodule MyApp.ChatDelivery do
        @behaviour Spectre.Turn.Dispatcher

        @impl true
        def deliver_reply(text, _result, opts) do
          MyApp.Chat.send(Keyword.fetch!(opts, :conversation_id), text)
        end
      end

      {:ok, turn} = Spectre.turn(instance, message.text, opts)
      {:ok, _delivered} = Spectre.Turn.Dispatcher.dispatch(turn, MyApp.ChatDelivery)

  The loop is bounded: a turn crossing more than 4 policy-resolution or
  execution steps returns `{:error, {:dispatch_loop_exceeded, decision}}`
  instead of spinning.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.Turn

  @max_steps 4

  @doc "Delivers reply text to the user. The only required callback."
  @callback deliver_reply(String.t(), Result.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Handles a turn that intentionally produces no reply. Default: `{:ok, :no_response}`."
  @callback no_response(Result.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Delivers an open policy request. Default: `deliver_reply/3` with the result text."
  @callback policy_request(Awaitable.t(), Result.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Resolves an open policy from host state without asking the user.

  Return `{:ok, resolution}` when the host already knows the answer (for
  example, terms accepted in a previous session); the dispatcher feeds it to
  `Spectre.Turn.resolve_policy/3` and continues with the resulting decision.
  Default: `:not_satisfied`.
  """
  @callback satisfied_resolution(Awaitable.t(), keyword()) ::
              {:ok, Spectre.Policy.resolution()} | :not_satisfied

  @doc "Final host veto before executing a pending effect. Default: `true`."
  @callback execute?(Effect.t(), Result.t(), keyword()) :: boolean()

  @doc "Delivers the outcome of a vetoed effect. Default: `deliver_reply/3` with the result text."
  @callback suppressed(Effect.t(), Result.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Delivers an executed action result. Default: `deliver_reply/3` with the result text.

  The completion is the terminal `%Spectre.Effect{}`: `status: :completed` after a
  normal execution, `status: :cancelled` when a `before_action` guard suppressed
  the capability call (the result text then carries the guard's reply).
  """
  @callback action_result(term(), Result.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Reply used when the result text is empty. Default: `nil` (fall through to `no_response/2`)."
  @callback fallback_reply(Result.t(), keyword()) :: String.t() | nil

  @optional_callbacks no_response: 2,
                      policy_request: 3,
                      satisfied_resolution: 2,
                      execute?: 3,
                      suppressed: 3,
                      action_result: 3,
                      fallback_reply: 2

  @doc """
  Dispatches the turn's decision through the handler module.

      {:ok, delivered} = Spectre.Turn.Dispatcher.dispatch(turn, MyApp.ChatDelivery)

  `opts` are merged over `turn.opts` and passed to every callback.
  """
  @spec dispatch(Turn.t(), module(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%Turn{} = turn, handler, opts \\ []) when is_atom(handler) do
    dispatch_decision(turn, handler, Keyword.merge(turn.opts, opts), @max_steps)
  end

  @spec dispatch_decision(Turn.t(), module(), keyword(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  defp dispatch_decision(%Turn{decision: decision}, _handler, _opts, 0),
    do: {:error, {:dispatch_loop_exceeded, elem(decision, 0)}}

  defp dispatch_decision(%Turn{decision: {:reply, result}}, handler, opts, _steps),
    do: deliver_or_fallback(handler, result, opts)

  defp dispatch_decision(%Turn{decision: {:no_response, result}}, handler, opts, _steps),
    do: callback(handler, :no_response, [result, opts], fn -> {:ok, :no_response} end)

  defp dispatch_decision(
         %Turn{decision: {:awaiting, %Awaitable{} = awaitable, result}} = turn,
         handler,
         opts,
         steps
       ) do
    case callback(handler, :satisfied_resolution, [awaitable, opts], fn -> :not_satisfied end) do
      {:ok, resolution} ->
        with {:ok, %Turn{} = resolved} <- Turn.resolve_policy(turn, resolution, opts) do
          dispatch_decision(resolved, handler, opts, steps - 1)
        end

      :not_satisfied ->
        callback(handler, :policy_request, [awaitable, result, opts], fn ->
          deliver_or_fallback(handler, result, opts)
        end)
    end
  end

  defp dispatch_decision(
         %Turn{decision: {:needs, %Effect{} = effect, result}} = turn,
         handler,
         opts,
         steps
       ) do
    if callback(handler, :execute?, [effect, result, opts], fn -> true end) do
      with {:ok, %Result{} = executed} <- Spectre.execute(turn.agent, result, opts) do
        turn.agent
        |> Turn.from_result(turn.input, opts, executed)
        |> dispatch_decision(handler, opts, steps - 1)
      end
    else
      callback(handler, :suppressed, [effect, result, opts], fn ->
        deliver_or_fallback(handler, result, opts)
      end)
    end
  end

  defp dispatch_decision(
         %Turn{decision: {:completed, completion, result}},
         handler,
         opts,
         _steps
       ) do
    callback(handler, :action_result, [completion, result, opts], fn ->
      deliver_or_fallback(handler, result, opts)
    end)
  end

  @spec deliver_or_fallback(module(), Result.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp deliver_or_fallback(handler, %Result{} = result, opts) do
    case reply_text(result) do
      nil -> deliver_fallback(handler, result, opts)
      text -> handler.deliver_reply(text, result, opts)
    end
  end

  @spec deliver_fallback(module(), Result.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp deliver_fallback(handler, %Result{} = result, opts) do
    case callback(handler, :fallback_reply, [result, opts], fn -> nil end) do
      text when is_binary(text) and text != "" ->
        handler.deliver_reply(text, result, opts)

      _no_fallback ->
        callback(handler, :no_response, [result, opts], fn -> {:ok, :no_response} end)
    end
  end

  @spec reply_text(Result.t()) :: String.t() | nil
  defp reply_text(%Result{reply_text: text}) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _visible -> text
    end
  end

  defp reply_text(%Result{}), do: nil

  @spec callback(module(), atom(), [term()], (-> term())) :: term()
  defp callback(handler, name, args, default) do
    Code.ensure_loaded(handler)

    if function_exported?(handler, name, length(args)) do
      apply(handler, name, args)
    else
      default.()
    end
  end
end
