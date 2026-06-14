defmodule Spectre.Runtime do
  @moduledoc """
  Turn-level orchestration for Spectre agents.

  Runtime owns the per-turn workflow, but it deliberately does not own the
  domain decisions inside an agent. It coordinates boundaries in this order:

    1. Merge agent/runtime options.
    2. Normalize input through the configured input pipeline.
    3. Load state and memory adapters.
    4. Resume an active policy, or route the input normally.
    5. Run the selected handler.
    6. Record chat history and persist state/memory.

  Keeping this flow centralized makes individual adapters simpler and keeps
  policy gates from being accidentally skipped.
  """

  alias Spectre.Context
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Policy
  alias Spectre.Result
  alias Spectre.Router
  alias Spectre.State

  @doc """
  Handles one normalized input turn for an agent module.

      {:ok, result} =
        Spectre.Runtime.handle(
          MyApp.Agent,
          Spectre.Input.new("delete my account"),
          conversation_id: "conv-123"
        )
  """
  @spec handle(module(), Input.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def handle(agent, %Input{} = input, opts) do
    opts = runtime_opts(agent, opts)

    with {:ok, input} <- normalize_input(agent, input, opts),
         {:ok, ctx} <- load_context(agent, input, opts),
         {:ok, result} <- run_turn(ctx) do
      result
      |> record_history(ctx)
      |> persist(ctx)
    end
  end

  @doc """
  Restores initial session state from the configured state adapter.

      {:ok, state} = Spectre.Runtime.restore_state(MyApp.Agent, conversation_id: "conv-123")
  """
  @spec restore_state(module(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def restore_state(agent, opts) do
    opts = runtime_opts(agent, opts)
    input = Input.new(%{text: "", meta: Map.take(Map.new(opts), [:conversation_id])})
    load_state(agent, input, opts)
  end

  @doc """
  Builds the per-turn context by loading state and memory adapters.

      {:ok, ctx} = Spectre.Runtime.load_context(MyApp.Agent, input, [])
  """
  @spec load_context(module(), Input.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def load_context(agent, %Input{} = input, opts) do
    with {:ok, state} <- load_state(agent, input, opts),
         {:ok, memory} <- load_memory(agent, input, state, opts) do
      {:ok,
       %Context{
         agent: agent,
         input: input,
         state: state,
         opts: opts,
         memory: memory,
         assigns: Keyword.get(opts, :assigns, %{})
       }}
    end
  end

  @spec run_turn(Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp run_turn(%Context{state: state} = ctx) do
    if Policy.awaiting?(state) do
      # Policy replies intentionally bypass normal routing. A short answer like
      # "yes" should approve/reject the pending action, not be interpreted as a
      # general conversation intent.
      Policy.resume(ctx.input, ctx)
    else
      with {:ok, router_context} <- Router.route_context(ctx.input, ctx),
           {:ok, route} <- Router.route_from_context(router_context) do
        # Router plugs may enrich the input before a handler runs, so the runner
        # receives the router context input rather than the original input.
        Spectre.Runner.run(route, %{ctx | input: router_context.input, route: route})
      end
    end
  end

  @spec load_state(module(), Input.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  defp load_state(agent, input, opts) do
    config = agent.__spectre_config__()
    state_module = Keyword.get(config, :state)
    conversation_id = Keyword.get(opts, :conversation_id)

    cond do
      Keyword.has_key?(opts, :state) ->
        # Explicit state is a test and host-app escape hatch; it wins over the
        # adapter so callers can replay a turn deterministically.
        {:ok, opts |> Keyword.get(:state) |> State.new() |> put_conversation_id(conversation_id)}

      is_atom(state_module) && function_exported?(state_module, :load, 3) ->
        state_module.load(input, agent, opts) |> normalize_state_reply(conversation_id)

      is_atom(state_module) && function_exported?(state_module, :load, 2) ->
        state_module.load(input, opts) |> normalize_state_reply(conversation_id)

      true ->
        {:ok, put_conversation_id(%State{}, conversation_id)}
    end
  end

  @spec load_memory(module(), Input.t(), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp load_memory(agent, input, state, opts) do
    memory_module = agent.__spectre_config__() |> Keyword.get(:memory)

    cond do
      Keyword.has_key?(opts, :memory) ->
        # Memory can be injected for tests or for host applications that have
        # already performed retrieval before calling Spectre.
        {:ok, Keyword.get(opts, :memory)}

      is_atom(memory_module) && function_exported?(memory_module, :recall, 2) ->
        memory_module.recall(input.text, state: state, input: input)

      true ->
        {:ok, nil}
    end
  end

  @spec persist(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist(%Result{} = result, %Context{} = ctx) do
    with {:ok, %Result{} = result} <- persist_state(result, ctx),
         :ok <- persist_memory(result, ctx) do
      {:ok, result}
    end
  end

  @spec persist_state(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist_state(%Result{} = result, %Context{agent: agent, input: input, opts: opts}) do
    state_module = agent.__spectre_config__() |> Keyword.get(:state)

    cond do
      is_atom(state_module) && function_exported?(state_module, :persist, 4) ->
        result.state
        |> state_module.persist(input, agent, opts)
        |> normalize_persist_reply(result)

      is_atom(state_module) && function_exported?(state_module, :persist, 2) ->
        result.state
        |> state_module.persist(input)
        |> normalize_persist_reply(result)

      true ->
        {:ok, result}
    end
  end

  @spec persist_memory(Result.t(), Context.t()) :: :ok | {:error, term()}
  defp persist_memory(%Result{} = result, %Context{agent: agent, input: input, opts: opts}) do
    memory_module = agent.__spectre_config__() |> Keyword.get(:memory)

    with {:ok, callback} <- memory_callback(memory_module) do
      callback
      |> call_memory_callback(input, result, agent, opts)
      |> normalize_memory_persist_reply()
    end
  end

  @spec normalize_persist_reply(term(), Result.t()) :: {:ok, Result.t()} | {:error, term()}
  defp normalize_persist_reply({:ok, state}, %Result{} = result),
    do: {:ok, %{result | state: State.new(state)}}

  defp normalize_persist_reply(:ok, %Result{} = result), do: {:ok, result}
  defp normalize_persist_reply({:error, reason}, _result), do: {:error, reason}
  defp normalize_persist_reply(other, _result), do: {:error, {:invalid_persist_reply, other}}

  @spec normalize_memory_persist_reply(term()) :: :ok | {:error, term()}
  defp normalize_memory_persist_reply(:ok), do: :ok
  defp normalize_memory_persist_reply({:ok, _reply}), do: :ok
  defp normalize_memory_persist_reply({:error, reason}), do: {:error, reason}
  defp normalize_memory_persist_reply(other), do: {:error, {:invalid_memory_persist_reply, other}}

  @spec memory_callback(module() | term()) ::
          {:ok, {:remember | :persist, 2 | 4, module()}} | :ok
  defp memory_callback(module) when is_atom(module) do
    cond do
      function_exported?(module, :remember, 4) -> {:ok, {:remember, 4, module}}
      function_exported?(module, :persist, 4) -> {:ok, {:persist, 4, module}}
      function_exported?(module, :remember, 2) -> {:ok, {:remember, 2, module}}
      function_exported?(module, :persist, 2) -> {:ok, {:persist, 2, module}}
      true -> :ok
    end
  end

  defp memory_callback(_module), do: :ok

  @spec call_memory_callback(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: term()
  defp call_memory_callback({function, 4, module}, input, result, agent, opts) do
    apply(module, function, [input, result, agent, opts])
  end

  defp call_memory_callback({function, 2, module}, input, result, agent, opts) do
    payload = memory_payload(input, result, agent)

    memory_opts =
      Keyword.merge(opts, input: input, state: result.state, result: result, agent: agent)

    apply(module, function, [payload, memory_opts])
  end

  @spec normalize_state_reply(term(), term()) :: {:ok, State.t()} | {:error, term()}
  defp normalize_state_reply({:ok, state}, conversation_id),
    do: {:ok, state |> State.new() |> put_conversation_id(conversation_id)}

  defp normalize_state_reply(%State{} = state, conversation_id),
    do: {:ok, put_conversation_id(state, conversation_id)}

  defp normalize_state_reply(state, conversation_id) when is_map(state),
    do: {:ok, state |> State.new() |> put_conversation_id(conversation_id)}

  defp normalize_state_reply(other, _conversation_id), do: {:error, {:invalid_state_reply, other}}

  @spec runtime_opts(module(), keyword()) :: keyword()
  defp runtime_opts(agent, opts) do
    agent
    |> agent_runtime_opts()
    |> Keyword.merge(opts)
  end

  @spec agent_runtime_opts(module()) :: keyword()
  defp agent_runtime_opts(agent) do
    config = agent.__spectre_config__()

    []
    |> maybe_put_config(config, :model)
    |> maybe_put_config(config, :classifier)
    |> maybe_put_config(config, :adapter)
    |> maybe_put_config(config, :embedding)
    |> maybe_put_config(config, :input_pipeline)
    |> maybe_put_config(config, :history)
    |> maybe_put_config(config, :chat_history_limit)
  end

  @spec normalize_input(module(), Input.t(), keyword()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(agent, %Input{} = input, opts) do
    case Keyword.get(opts, :input_pipeline, []) do
      [] ->
        {:ok, input}

      specs when is_list(specs) ->
        Pipeline.run(input, %{agent: agent, opts: opts}, specs)

      other ->
        {:error, {:invalid_input_pipeline, other}}
    end
  end

  @spec maybe_put_config(keyword(), keyword(), atom()) :: keyword()
  defp maybe_put_config(opts, config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  @spec record_history(Result.t(), Context.t()) :: Result.t()
  defp record_history(%Result{} = result, %Context{agent: agent, opts: opts}) do
    limit =
      Keyword.get(
        opts,
        :chat_history_limit,
        Keyword.get(agent.__spectre_config__(), :history, 20)
      )

    %{result | state: State.record_turn(result.state, result.input, result, limit)}
  end

  @spec memory_payload(Input.t(), Result.t(), module()) :: map()
  defp memory_payload(%Input{} = input, %Result{} = result, agent) do
    %{
      agent: agent,
      input: input,
      reply_text: result.reply_text,
      route: result.route,
      state: result.state,
      actions: result.actions,
      events: result.events
    }
  end

  @spec put_conversation_id(State.t(), term()) :: State.t()
  defp put_conversation_id(%State{} = state, nil), do: state

  defp put_conversation_id(%State{conversation_id: nil} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}

  defp put_conversation_id(%State{} = state, _conversation_id), do: state
end
