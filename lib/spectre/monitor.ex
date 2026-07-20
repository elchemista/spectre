defmodule Spectre.Monitor do
  @moduledoc """
  Failure boundary for host delivery around a Spectre agent.

  `Spectre.Monitor` wraps host delivery code and creates a fallback through
  injected callbacks when that code fails. This keeps databases, queues, and
  transport APIs outside the runtime while still giving applications one place
  to produce a user-safe failure response.
  """

  require Logger

  alias Spectre.Input
  alias Spectre.Prompt
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.State

  @type context :: map()
  @type callback_result :: {:ok, map()} | {:error, term()}

  @doc """
  Runs a monitored host operation and creates a fallback when it fails.

      Spectre.Monitor.dispatch(MyAgent, context,
        run: fn -> deliver_turn.() end,
        fallback_exists?: &MyApp.Fallbacks.exists?/1,
        create_fallback: &MyApp.Fallbacks.create/3
      )
  """
  @spec dispatch(module(), context(), keyword()) :: callback_result()
  def dispatch(agent, context, opts) when is_atom(agent) and is_map(context) and is_list(opts) do
    with {:ok, run} <- fetch_callback(opts, :run) do
      case safe_run(run, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.error(
            "spectre_monitor detected_failure #{context_log(context)} " <>
              "reason=#{reason_code(reason)}"
          )

          recover(agent, context, reason, opts)
      end
    end
  end

  @doc """
  Renders the configured failure fallback prompt.

      {:ok, text} = Spectre.Monitor.fallback_text(MyAgent, context, :timeout)
  """
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

  @spec safe_run(function(), keyword()) :: callback_result()
  defp safe_run(run, opts) when is_function(run, 0) do
    Call.run(
      :monitor,
      fn -> run.() |> normalize_callback_result() end,
      opts |> Call.adapter_opts() |> Keyword.put(:purpose, :monitor_run)
    )
  end

  defp safe_run(_run, _opts), do: {:error, {:invalid_spectre_monitor_callback_arity, :run}}

  @spec recover(module(), context(), term(), keyword()) :: callback_result()
  defp recover(agent, context, reason, opts) do
    case existing_fallback(context, reason, opts) do
      {:ok, result} ->
        Logger.warning("spectre_monitor fallback_exists #{context_log(context)}")
        {:ok, Map.put_new(result, :status, :agent_fallback)}

      :not_found ->
        create_fallback(agent, context, reason, opts)
    end
  end

  @spec existing_fallback(context(), term(), keyword()) :: {:ok, map()} | :not_found
  defp existing_fallback(context, reason, opts) do
    case Keyword.get(opts, :fallback_exists?) do
      nil ->
        :not_found

      fun when is_function(fun, 1) ->
        protected_existing_fallback(fn -> fun.(context) end, context, opts)

      fun when is_function(fun, 2) ->
        protected_existing_fallback(fn -> fun.(context, reason) end, context, opts)

      _other ->
        log_recovery_failure(context, :invalid_fallback_exists_callback)
        :not_found
    end
  end

  @spec protected_existing_fallback((-> term()), context(), keyword()) ::
          {:ok, map()} | :not_found
  defp protected_existing_fallback(callback, context, opts) do
    result =
      Call.run(
        :monitor,
        fn -> callback.() |> normalize_existing_result() end,
        opts |> Call.adapter_opts() |> Keyword.put(:purpose, :monitor_fallback_exists)
      )

    case result do
      {:ok, {:found, result}} ->
        {:ok, result}

      {:ok, :not_found} ->
        :not_found

      {:error, reason} ->
        log_recovery_failure(context, reason)
        :not_found
    end
  end

  @spec normalize_existing_result(term()) ::
          {:ok, {:found, map()} | :not_found} | {:error, term()}
  defp normalize_existing_result({:ok, result}) when is_map(result),
    do: {:ok, {:found, result}}

  defp normalize_existing_result(%{} = result), do: {:ok, {:found, result}}

  defp normalize_existing_result(value) when value in [nil, false, :not_found],
    do: {:ok, :not_found}

  defp normalize_existing_result({:error, reason}), do: {:error, reason}

  defp normalize_existing_result(other),
    do: {:error, Failure.invalid_reply(:monitor, other)}

  @spec create_fallback(module(), context(), term(), keyword()) :: callback_result()
  defp create_fallback(agent, context, reason, opts) do
    with {:ok, create} <- fetch_callback(opts, :create_fallback),
         {:ok, text} <- fallback_text(agent, context, reason, opts),
         {:ok, result} <- safe_create_fallback(create, context, text, reason, opts) do
      Logger.warning(
        "spectre_monitor fallback_created #{context_log(context)} result=#{inspect(compact_result(result))}"
      )

      {:ok, Map.put_new(result, :status, :agent_fallback)}
    end
  end

  @spec safe_create_fallback(function(), context(), String.t(), term(), keyword()) ::
          callback_result()
  defp safe_create_fallback(create, context, text, reason, opts) when is_function(create, 3) do
    Call.run(
      :monitor,
      fn -> create.(context, text, reason) |> normalize_callback_result() end,
      opts |> Call.adapter_opts() |> Keyword.put(:purpose, :monitor_create_fallback)
    )
  end

  defp safe_create_fallback(_create, _context, _text, _reason, _opts),
    do: {:error, {:invalid_spectre_monitor_callback_arity, :create_fallback}}

  @spec normalize_callback_result(term()) :: callback_result()
  defp normalize_callback_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_callback_result(%{} = result), do: {:ok, result}
  defp normalize_callback_result({:error, reason}), do: {:error, reason}

  defp normalize_callback_result(other),
    do: {:error, Failure.invalid_reply(:monitor, other)}

  @spec render_fallback(module(), atom() | String.t(), context(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
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

    case Prompt.render_asset(agent, prompt, ctx, opts) do
      {:ok, text} ->
        {:ok, text}

      {:error, {:missing_prompt, _path}} when prompt == :agent_failure_reply ->
        {:ok, default_failure_text()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec default_failure_text() :: String.t()
  defp default_failure_text do
    "I'm sorry, I couldn't complete that request right now. Please try again in a moment."
  end

  @spec input_from_context(context()) :: Input.t()
  defp input_from_context(%{message: %{text: text}} = context) do
    Input.new(%{text: text, meta: input_meta(context)})
  end

  defp input_from_context(context), do: Input.new(%{text: "", meta: input_meta(context)})

  @spec input_meta(context()) :: map()
  defp input_meta(context) do
    context
    |> Map.take([:conversation_id, :message_id, :user_id, :channel, :external_chat_id])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec fetch_callback(keyword(), atom()) :: {:ok, function()} | {:error, term()}
  defp fetch_callback(opts, key) do
    case Keyword.get(opts, key) do
      fun when is_function(fun) -> {:ok, fun}
      nil -> {:error, {:missing_spectre_monitor_callback, key}}
      other -> {:error, {:invalid_spectre_monitor_callback, key, other}}
    end
  end

  @spec context_log(context()) :: String.t()
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

  @spec compact_result(map()) :: map()
  defp compact_result(result) when is_map(result) do
    Map.take(result, [:status, :delivery, :outbound_id, :conversation_id, :message_id])
  end

  @spec log_recovery_failure(context(), term()) :: :ok
  defp log_recovery_failure(context, reason) do
    Logger.error(
      "spectre_monitor fallback_exists_failure #{context_log(context)} " <>
        "reason=#{reason_code(reason)}"
    )
  end

  @spec reason_code(term()) :: atom()
  defp reason_code(%Failure{kind: kind}), do: kind
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> code
      _other -> :monitor_callback_failed
    end
  end

  defp reason_code(_reason), do: :monitor_callback_failed
end
