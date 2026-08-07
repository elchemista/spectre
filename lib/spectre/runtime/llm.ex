defmodule Spectre.LLM do
  @moduledoc """
  Small LLM boundary used by `Spectre.Runner`.

  The runner sends a typed `Spectre.Prompt.Plan` here. A module that exports
  `complete_plan/2` receives that plan with separate instruction, context, and
  task fragments. Existing modules, tuples, and functions continue to receive
  the plan's legacy string byte-for-byte. Tuple/function adapters may opt into
  the typed contract with `prompt_format: :plan`; `prompt_format: :string`
  explicitly selects compatibility serialization.

  A fallback model independently negotiates the same capability, so a legacy
  primary and structured fallback (or the reverse) can share one prompt plan.
  """

  alias Spectre.Inference.Response
  alias Spectre.Prompt.Plan
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @callback complete(String.t(), keyword()) ::
              {:ok, String.t() | Response.t() | map()} | {:error, term()}
  @callback complete_plan(Plan.t(), keyword()) ::
              {:ok, String.t() | Response.t() | map()} | {:error, term()}

  @optional_callbacks complete_plan: 2

  @type prompt :: String.t() | Plan.t()
  @type completion :: String.t() | Response.t() | map()
  @type completion_result :: {:ok, completion()} | {:error, term()}

  # Keys the Spectre runtime attaches to the adapter keyword list for its own
  # bookkeeping and prompt context. Providers never accept them, so adapters
  # strip them with provider_opts/2 before building an HTTP/SDK call.
  @runtime_opt_keys [
    :adapter,
    :model,
    :fallback,
    :primary_error,
    :purpose,
    :prompt_format,
    :explicit_model_override?,
    :sanitize_reply,
    :plan_actions?,
    :policy_prompt?,
    :agent,
    :agent_ref,
    :input,
    :state,
    :state_persistence,
    :route,
    :policy,
    :memory,
    :assigns,
    :history,
    :recent_chat,
    :conversation_id,
    :origin_conversation_id,
    :conversation_ref,
    :origin_conversation_ref,
    :turn_id,
    :trace_id,
    :run_id,
    :run_revision,
    :run_metadata,
    :operation_id,
    :subject,
    :subject_id,
    :instance_pid,
    :instance_run_lifecycle?,
    :correlation_id,
    :causation_id,
    :provenance,
    :journal_sequence,
    :message,
    :actions_module,
    :actions,
    :action_planner,
    :classifier_assigns,
    :classifier,
    :classifier_evidence,
    :classifier_history,
    :embedding,
    :journal,
    :chat_summary,
    :history_summary,
    :chat_history_limit,
    :turn_handlers,
    :input_pipeline,
    :router,
    :arbitrator,
    :local_result,
    :local_opts,
    :semantic_cache,
    :semantic_cache_query_embedding,
    :inference_profile,
    :provider_retry,
    :provider_fallback,
    :usage,
    :telemetry_metadata,
    :runtime_inject,
    :handler_inject,
    :prompt_scope,
    :inference_purpose,
    :modalities
  ]

  @doc """
  Returns the option keys the Spectre runtime injects into adapter calls.
  """
  @spec runtime_opt_keys() :: [atom()]
  def runtime_opt_keys, do: @runtime_opt_keys

  @doc """
  Strips Spectre runtime context from an adapter keyword list.

  Everything the runtime attaches for its own purposes — routing context,
  state, prompt assigns, model bookkeeping — is removed, along with any
  `spectre_*`-prefixed key, leaving only options intended for the provider.
  Adapters call this instead of maintaining their own allowlists:

      def complete(prompt, opts) do
        provider_opts = Spectre.LLM.provider_opts(opts, [:test_pid])
        MyHTTP.post(url, body, provider_opts)
      end

  `extra_keys` removes host-specific keys on top of the runtime set.
  """
  @spec provider_opts(keyword(), [atom()]) :: keyword()
  def provider_opts(opts, extra_keys \\ []) when is_list(opts) and is_list(extra_keys) do
    Enum.reject(opts, fn
      {key, _value} when is_atom(key) ->
        key in @runtime_opt_keys or key in extra_keys or runtime_family_key?(key) or
          spectre_prefixed?(key)

      _other ->
        false
    end)
  end

  @spec spectre_prefixed?(atom()) :: boolean()
  defp spectre_prefixed?(key), do: String.starts_with?(Atom.to_string(key), "spectre_")

  @spec runtime_family_key?(atom()) :: boolean()
  defp runtime_family_key?(key) do
    name = Atom.to_string(key)
    String.ends_with?(name, "_timeout") or String.ends_with?(name, "_max_bytes")
  end

  @doc """
  Completes a rendered string or typed prompt plan through the configured model
  adapter or function.

      Spectre.LLM.complete("Say hello", model: {MyApp.LLM, :complete, model: "small"})
  """
  @spec complete(prompt(), keyword()) :: completion_result()
  def complete(prompt, opts \\ [])

  def complete(prompt, opts)
      when (is_binary(prompt) or is_struct(prompt, Plan)) and is_list(opts) do
    prompt
    |> do_complete(opts)
    |> maybe_fallback(prompt, opts)
  end

  @doc """
  Executes exactly one configured model without applying the legacy fallback.

  `Spectre.Inference` uses this primitive so one boundary owns retry and
  profile fallback decisions.
  """
  @spec complete_once(prompt(), keyword()) ::
          completion_result()
  def complete_once(prompt, opts \\ [])

  def complete_once(prompt, opts)
      when (is_binary(prompt) or is_struct(prompt, Plan)) and is_list(opts) do
    do_complete(prompt, opts)
  end

  @spec do_complete(prompt(), keyword()) :: completion_result()
  defp do_complete(prompt, opts) do
    cond do
      model = Keyword.get(opts, :model) ->
        call_model(model, prompt, opts)

      adapter = Keyword.get(opts, :adapter) ->
        call_model(adapter, prompt, opts)

      adapter = Application.get_env(:spectre, :llm_adapter) ->
        call_model(adapter, prompt, opts)

      true ->
        {:error, :missing_llm_adapter}
    end
  end

  @spec maybe_fallback(completion_result(), prompt(), keyword()) :: completion_result()
  defp maybe_fallback({:ok, _text} = ok, _prompt, _opts), do: ok

  defp maybe_fallback({:error, reason} = error, prompt, opts) do
    case fallback_model(opts) do
      nil ->
        error

      fallback ->
        fallback_opts =
          opts
          |> Keyword.delete(:model)
          |> Keyword.delete(:adapter)
          |> Keyword.delete(:fallback)
          |> Keyword.put(:primary_error, reason)

        case call_model(fallback, prompt, fallback_opts) do
          {:ok, _text} = ok -> ok
          {:error, fallback_reason} -> {:error, {:llm_fallback_failed, reason, fallback_reason}}
        end
    end
  end

  @spec fallback_model(keyword()) :: term() | nil
  defp fallback_model(opts) do
    Keyword.get(opts, :fallback) || fallback_from_model(Keyword.get(opts, :model))
  end

  @spec fallback_from_model(term()) :: term() | nil
  defp fallback_from_model({_module, _function, model_opts}) when is_list(model_opts) do
    Keyword.get(model_opts, :fallback)
  end

  defp fallback_from_model(_model), do: nil

  @spec call_model(
          function() | module() | {module(), atom()} | {module(), atom(), keyword()} | term(),
          prompt(),
          keyword()
        ) :: completion_result()
  defp call_model({_module, _function, adapter_opts} = model, prompt, opts)
       when is_list(adapter_opts) do
    protected_call(model, prompt, model_opts(adapter_opts, opts))
  end

  defp call_model(model, prompt, opts) do
    protected_call(model, prompt, Keyword.delete(opts, :model))
  end

  @spec protected_call(term(), prompt(), keyword()) :: completion_result()
  defp protected_call(model, prompt, opts) do
    adapter_opts = Call.adapter_opts(opts)

    case Call.run(
           :llm,
           fn -> model |> dispatch_model(prompt, adapter_opts) |> normalize_model_reply() end,
           opts
         ) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, %Response{}} = response -> response
      {:ok, %{text: text}} = response when is_binary(text) -> response
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_model_reply(term()) :: completion_result() | term()
  defp normalize_model_reply({:ok, text} = reply) when is_binary(text), do: reply
  defp normalize_model_reply({:ok, %Response{}} = reply), do: reply
  defp normalize_model_reply({:ok, %{text: text}} = reply) when is_binary(text), do: reply

  defp normalize_model_reply({:ok, other}),
    do: {:error, Failure.invalid_reply(:llm, other)}

  defp normalize_model_reply({:error, _reason} = error), do: error
  defp normalize_model_reply(other), do: other

  @spec dispatch_model(term(), prompt(), keyword()) :: term()
  defp dispatch_model({module, function, _adapter_opts}, prompt, opts)
       when is_atom(module) and is_atom(function) do
    with {:ok, prompt} <- tuple_prompt(function, prompt, opts) do
      apply(module, function, [prompt, opts])
    end
  end

  defp dispatch_model({module, function}, prompt, opts)
       when is_atom(module) and is_atom(function) do
    with {:ok, prompt} <- tuple_prompt(function, prompt, opts) do
      apply(module, function, [prompt, opts])
    end
  end

  defp dispatch_model(module, %Plan{} = plan, opts) when is_atom(module) do
    with {:ok, format} <- prompt_format(opts) do
      dispatch_module(format, module, plan, opts)
    end
  end

  defp dispatch_model(module, prompt, opts) when is_atom(module),
    do: module.complete(prompt, opts)

  defp dispatch_model(fun, prompt, opts), do: call_model_fun(fun, prompt, opts)

  @spec dispatch_module(:auto | :plan | :string, module(), Plan.t(), keyword()) :: term()
  defp dispatch_module(:string, module, plan, opts),
    do: module.complete(Plan.legacy(plan), opts)

  defp dispatch_module(:plan, module, plan, opts),
    do: dispatch_module_plan(module, plan, opts)

  defp dispatch_module(:auto, module, plan, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :complete_plan, 2),
      do: module.complete_plan(plan, opts),
      else: module.complete(Plan.legacy(plan), opts)
  end

  @spec dispatch_module_plan(module(), Plan.t(), keyword()) :: term()
  defp dispatch_module_plan(module, plan, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :complete_plan, 2),
      do: module.complete_plan(plan, opts),
      else: {:error, {:unsupported_prompt_format, module, :plan}}
  end

  @spec tuple_prompt(atom(), prompt(), keyword()) :: {:ok, prompt()} | {:error, term()}
  defp tuple_prompt(_function, prompt, _opts) when is_binary(prompt), do: {:ok, prompt}

  defp tuple_prompt(function, %Plan{} = plan, opts) do
    with {:ok, format} <- prompt_format(opts) do
      format_tuple_prompt(function, format, plan)
    end
  end

  @spec format_tuple_prompt(atom(), :auto | :plan | :string, Plan.t()) :: {:ok, prompt()}
  defp format_tuple_prompt(_function, :plan, plan), do: {:ok, plan}
  defp format_tuple_prompt(:complete_plan, :auto, plan), do: {:ok, plan}
  defp format_tuple_prompt(_function, _format, plan), do: {:ok, Plan.legacy(plan)}

  @spec call_model_fun(function() | term(), prompt(), keyword()) :: completion_result()
  defp call_model_fun(fun, %Plan{} = plan, opts) do
    with {:ok, format} <- prompt_format(opts) do
      call_model_fun(fun, plan, opts, format)
    end
  end

  defp call_model_fun(fun, prompt, opts) when is_binary(prompt),
    do: call_model_fun(fun, prompt, opts, :string)

  @spec call_model_fun(function() | term(), prompt(), keyword(), :auto | :plan | :string) ::
          term()
  defp call_model_fun(fun, %Plan{} = plan, opts, :plan) when is_function(fun, 2),
    do: fun.(plan, opts)

  defp call_model_fun(fun, %Plan{} = plan, opts, _format),
    do: call_model_fun(fun, Plan.legacy(plan), opts, :string)

  defp call_model_fun(fun, prompt, opts, _format) when is_function(fun, 2),
    do: fun.(prompt, opts)

  defp call_model_fun(fun, prompt, _opts, _format) when is_function(fun, 1), do: fun.(prompt)
  defp call_model_fun(other, _prompt, _opts, _format), do: {:error, {:invalid_model, other}}

  @spec prompt_format(keyword()) :: {:ok, :auto | :plan | :string} | {:error, term()}
  defp prompt_format(opts) do
    opts
    |> Keyword.get(:prompt_format, :auto)
    |> normalize_prompt_format()
  end

  @spec normalize_prompt_format(term()) ::
          {:ok, :auto | :plan | :string} | {:error, :invalid_prompt_format}
  defp normalize_prompt_format(format) when format in [:auto, :plan, :string],
    do: {:ok, format}

  defp normalize_prompt_format(_format), do: {:error, :invalid_prompt_format}

  @spec model_opts(keyword(), keyword()) :: keyword()
  defp model_opts(adapter_opts, opts) do
    Keyword.merge(adapter_opts, Keyword.delete(opts, :model))
  end
end
