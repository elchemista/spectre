defmodule Spectre.Monitor do
  @moduledoc """
  Failure boundary for host delivery around a Spectre agent.
  """

  require Logger

  alias Spectre.{Input, Prompt, State}

  @type context :: map()
  @type callback_result :: {:ok, map()} | {:error, term()}

  @spec dispatch(module(), context(), keyword()) :: callback_result()
  def dispatch(agent, context, opts) when is_atom(agent) and is_map(context) and is_list(opts) do
    with {:ok, run} <- fetch_callback(opts, :run) do
      case safe_run(run) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.error(
            "spectre_monitor detected_failure #{context_log(context)} reason=#{inspect(reason)}"
          )

          recover(agent, context, reason, opts)
      end
    end
  end

  @spec fallback_text(module(), context(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fallback_text(agent, context, reason, opts \\ []) do
    case Keyword.get(agent.__spectre_config__(), :fail) do
      {prompt, fail_opts} ->
        render_fallback(agent, prompt, context, reason, Keyword.merge(fail_opts, opts))

      nil ->
        {:error, {:missing_fail_prompt, agent}}
    end
  end

  defp safe_run(run) when is_function(run, 0) do
    case run.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      result -> {:ok, result}
    end
  rescue
    exception ->
      {:error, {:spectre_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason ->
      {:error, {:spectre_exit, reason}}

    kind, reason ->
      {:error, {:spectre_failure, kind, reason}}
  end

  defp recover(agent, context, reason, opts) do
    case existing_fallback(context, reason, opts) do
      {:ok, result} ->
        Logger.warning("spectre_monitor fallback_exists #{context_log(context)}")
        {:ok, Map.put_new(result, :status, :agent_fallback)}

      :not_found ->
        create_fallback(agent, context, reason, opts)
    end
  end

  defp existing_fallback(context, reason, opts) do
    case Keyword.get(opts, :fallback_exists?) do
      nil ->
        :not_found

      fun when is_function(fun, 1) ->
        normalize_existing_result(fun.(context))

      fun when is_function(fun, 2) ->
        normalize_existing_result(fun.(context, reason))
    end
  rescue
    exception ->
      Logger.error(
        "spectre_monitor fallback_exists_exception #{context_log(context)} reason=#{Exception.message(exception)}"
      )

      :not_found
  catch
    kind, caught_reason ->
      Logger.error(
        "spectre_monitor fallback_exists_failure #{context_log(context)} reason=#{inspect({kind, caught_reason})}"
      )

      :not_found
  end

  defp normalize_existing_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_existing_result(%{} = result), do: {:ok, result}
  defp normalize_existing_result(nil), do: :not_found
  defp normalize_existing_result(false), do: :not_found
  defp normalize_existing_result(:not_found), do: :not_found
  defp normalize_existing_result(_other), do: :not_found

  defp create_fallback(agent, context, reason, opts) do
    with {:ok, create} <- fetch_callback(opts, :create_fallback),
         {:ok, text} <- fallback_text(agent, context, reason, opts),
         {:ok, result} <- safe_create_fallback(create, context, text, reason) do
      Logger.warning(
        "spectre_monitor fallback_created #{context_log(context)} result=#{inspect(compact_result(result))}"
      )

      {:ok, Map.put_new(result, :status, :agent_fallback)}
    end
  end

  defp safe_create_fallback(create, context, text, reason) when is_function(create, 3) do
    create.(context, text, reason)
  rescue
    exception ->
      {:error, {:fallback_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, caught_reason ->
      {:error, {:fallback_failure, kind, caught_reason}}
  end

  defp render_fallback(agent, prompt, context, reason, opts) do
    input = input_from_context(context)
    assigns = opts |> Keyword.get(:assigns, %{}) |> Map.new()

    ctx = %{
      agent: agent,
      input: input,
      state: Keyword.get(opts, :state, %State{}),
      assigns:
        Map.merge(
          %{
            context: context,
            reason: reason
          },
          assigns
        )
    }

    case Prompt.render(agent, prompt, ctx, opts) do
      {:ok, text} ->
        {:ok, text}

      {:error, {:missing_prompt, _path}} when prompt == :agent_failure_reply ->
        {:ok, default_failure_text()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_failure_text do
    "I'm sorry, I couldn't complete that request right now. Please try again in a moment."
  end

  defp input_from_context(%{message: %{text: text}} = context) do
    Input.new(%{text: text, meta: input_meta(context)})
  end

  defp input_from_context(context), do: Input.new(%{text: "", meta: input_meta(context)})

  defp input_meta(context) do
    context
    |> Map.take([:conversation_id, :message_id, :user_id, :channel, :external_chat_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fetch_callback(opts, key) do
    case Keyword.get(opts, key) do
      fun when is_function(fun) -> {:ok, fun}
      nil -> {:error, {:missing_spectre_monitor_callback, key}}
      other -> {:error, {:invalid_spectre_monitor_callback, key, other}}
    end
  end

  defp context_log(context) do
    [
      conversation_id: Map.get(context, :conversation_id),
      message_id: Map.get(context, :message_id),
      user_id: Map.get(context, :user_id),
      channel: Map.get(context, :channel),
      chat_id: Map.get(context, :external_chat_id)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp compact_result(result) when is_map(result) do
    Map.take(result, [:status, :delivery, :outbound_id, :conversation_id, :message_id])
  end

  defp compact_result(result), do: result
end
