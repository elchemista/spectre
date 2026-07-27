defmodule Spectre.ActionPlanner do
  @moduledoc """
  Provider-neutral facade over an optional action planner.

  Spectre does not parse an action language, load a tool registry, or know
  which planning library is installed. A configured implementation of
  `Spectre.Action.Planner` returns `Spectre.Action` values; this facade gives
  them trusted route ownership and turns them into staged effects.
  """

  alias Spectre.Action
  alias Spectre.Effect

  @doc """
  Plans actions found in a model response.

  When no planner is mounted the reply passes through unchanged.
  """
  @spec plan_response(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan_response(text, opts \\ []) when is_binary(text) and is_list(opts) do
    plan_response(text, Keyword.get(opts, :context, %{}), opts)
  end

  @spec plan_response(String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, %{reply_text: String.t(), effects: [Effect.t()]}} | {:error, term()}
  def plan_response(text, ctx, opts)
      when is_binary(text) and is_map(ctx) and is_list(opts) do
    case planner_module(opts) do
      nil ->
        {:ok, %{reply_text: String.trim(text), effects: []}}

      planner ->
        plan_response_with(planner, text, ctx, opts)
    end
  end

  @doc """
  Plans one explicit planner instruction without executing it.
  """
  @spec plan(String.t(), keyword()) :: {:ok, Effect.t()} | {:error, term()}
  def plan(instruction, opts \\ []) when is_binary(instruction) and is_list(opts) do
    plan(instruction, Keyword.get(opts, :context, %{}), opts)
  end

  @spec plan(String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Effect.t()} | {:error, term()}
  def plan(instruction, ctx, opts)
      when is_binary(instruction) and is_map(ctx) and is_list(opts) do
    case planner_module(opts) do
      nil ->
        {:error, :action_planner_not_configured}

      planner ->
        plan_with(planner, instruction, ctx, opts)
    end
  end

  @doc """
  Removes planner syntax from a visible model reply when the mounted planner
  supports that operation.
  """
  @spec clean_reply(String.t(), keyword()) :: String.t()
  def clean_reply(text, opts \\ []) when is_binary(text) and is_list(opts) do
    clean_reply(text, Keyword.get(opts, :context, %{}), opts)
  end

  @spec clean_reply(String.t(), Spectre.Context.t() | map(), keyword()) :: String.t()
  def clean_reply(text, ctx, opts)
      when is_binary(text) and is_map(ctx) and is_list(opts) do
    case planner_module(opts) do
      nil ->
        String.trim(text)

      planner ->
        clean_reply_with(planner, text, ctx, opts)
    end
  end

  @spec plan_response_with(module(), String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, %{reply_text: String.t(), effects: [Effect.t()]}} | {:error, term()}
  defp plan_response_with(planner, text, ctx, opts) do
    with {:ok, response} <-
           safely(planner, :plan_response, fn ->
             planner.plan_response(text, ctx, opts)
           end),
         {:ok, reply_text, actions} <- normalize_response(response),
         {:ok, effects} <- stage_actions(actions, opts) do
      {:ok, %{reply_text: reply_text, effects: effects}}
    end
  end

  @spec plan_with(module(), String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Effect.t()} | {:error, term()}
  defp plan_with(planner, instruction, ctx, opts) do
    cond do
      not Code.ensure_loaded?(planner) ->
        {:error, {:action_planner_not_loaded, planner}}

      not function_exported?(planner, :plan, 3) ->
        {:error, {:action_planner_callback_missing, planner, :plan, 3}}

      true ->
        invoke_plan(planner, instruction, ctx, opts)
    end
  end

  @spec invoke_plan(module(), String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Effect.t()} | {:error, term()}
  defp invoke_plan(planner, instruction, ctx, opts) do
    with {:ok, planned} <-
           safely(planner, :plan, fn ->
             planner.plan(instruction, ctx, opts)
           end),
         {:ok, action} <- unwrap_planned_action(planned) do
      stage_action(action, opts)
    end
  end

  @spec clean_reply_with(module(), String.t(), Spectre.Context.t() | map(), keyword()) ::
          String.t()
  defp clean_reply_with(planner, text, ctx, opts) do
    if Code.ensure_loaded?(planner) and function_exported?(planner, :clean_reply, 3) do
      invoke_clean_reply(planner, text, ctx, opts)
    else
      String.trim(text)
    end
  end

  @spec invoke_clean_reply(module(), String.t(), Spectre.Context.t() | map(), keyword()) ::
          String.t()
  defp invoke_clean_reply(planner, text, ctx, opts) do
    case safely(planner, :clean_reply, fn ->
           planner.clean_reply(text, ctx, opts)
         end) do
      {:ok, clean} when is_binary(clean) -> clean
      _error -> String.trim(text)
    end
  end

  @spec normalize_response(term()) ::
          {:ok, String.t(), [Action.t() | map() | Effect.t()]} | {:error, term()}
  defp normalize_response({:ok, response}), do: normalize_response(response)
  defp normalize_response({:error, reason}), do: {:error, reason}

  defp normalize_response(%{reply_text: text, actions: actions})
       when is_binary(text) and is_list(actions),
       do: {:ok, text, actions}

  defp normalize_response(%{"reply_text" => text, "actions" => actions})
       when is_binary(text) and is_list(actions),
       do: {:ok, text, actions}

  # Compatibility for early generic-planner implementations. Effects are
  # converted back to actions and restaged with trusted route origin below.
  defp normalize_response(%{reply_text: text, effects: effects})
       when is_binary(text) and is_list(effects),
       do: {:ok, text, effects}

  defp normalize_response(response), do: {:error, {:invalid_action_planner_response, response}}

  @spec stage_actions([Action.t() | map() | Effect.t()], keyword()) ::
          {:ok, [Effect.t()]} | {:error, term()}
  defp stage_actions(actions, opts) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, effects} ->
      case stage_action(action, opts) do
        {:ok, effect} -> {:cont, {:ok, [effect | effects]}}
        {:error, reason} -> {:halt, {:error, {:invalid_planned_action, index, reason}}}
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, Enum.reverse(effects)}
      {:error, _reason} = error -> error
    end
  end

  @spec stage_action(Action.t() | map() | Effect.t(), keyword()) ::
          {:ok, Effect.t()} | {:error, term()}
  defp stage_action(%Effect{kind: :action} = effect, opts),
    do: effect |> Action.from_effect() |> stage_action(opts)

  defp stage_action(%Effect{} = effect, _opts),
    do: {:error, {:unsupported_planned_effect_kind, effect.kind}}

  defp stage_action(action, opts) do
    with {:ok, action} <- normalize_action(action) do
      attrs = Action.to_effect_attrs(action)
      stage_with_origin(attrs, opts)
    end
  end

  @spec normalize_action(Action.t() | map()) :: {:ok, Action.t()} | {:error, term()}
  defp normalize_action(action) when is_map(action) do
    attrs = if is_struct(action), do: Map.from_struct(action), else: action
    {:ok, Action.new(attrs)}
  rescue
    exception -> {:error, {:invalid_action, Exception.message(exception)}}
  end

  defp normalize_action(action), do: {:error, {:invalid_action, action}}

  @spec unwrap_planned_action(term()) :: {:ok, Action.t() | map()} | {:error, term()}
  defp unwrap_planned_action({:ok, action}), do: {:ok, action}
  defp unwrap_planned_action(action) when is_map(action), do: {:ok, action}
  defp unwrap_planned_action(other), do: {:error, {:invalid_action_planner_reply, other}}

  @spec stage_with_origin(map(), keyword()) :: {:ok, Effect.t()} | {:error, term()}
  defp stage_with_origin(attrs, opts) do
    case {Keyword.get(opts, :effect_owner), Keyword.get(opts, :effect_scope)} do
      {owner, scope} when is_atom(owner) and not is_nil(owner) and not is_nil(scope) ->
        {:ok, Effect.stage_action(attrs, owner, scope)}

      {nil, nil} ->
        {:ok, Effect.stage(attrs)}

      origin ->
        {:error, {:incomplete_effect_origin, origin}}
    end
  end

  @spec planner_module(keyword()) :: module() | nil
  defp planner_module(opts) do
    Keyword.get(opts, :action_planner) || Keyword.get(opts, :planner)
  end

  @spec safely(module(), atom(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp safely(module, callback, function) do
    if Code.ensure_loaded?(module) do
      case function.() do
        {:error, reason} -> {:error, reason}
        reply -> {:ok, reply}
      end
    else
      {:error, {:action_planner_not_loaded, module}}
    end
  rescue
    exception ->
      {:error, {:action_planner_exception, module, callback, exception}}
  catch
    kind, reason ->
      {:error, {:action_planner_failure, module, callback, kind, reason}}
  end
end
