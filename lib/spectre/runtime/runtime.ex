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

  alias Spectre.ActionExecutor
  alias Spectre.Context
  alias Spectre.Definition
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Policy
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.Router
  alias Spectre.State
  alias Spectre.State.Codec

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
    opts = agent |> runtime_opts(opts) |> put_turn_identity()

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
  Resolves a currently open policy from a trusted host decision and persists
  the state transition before returning it.

  Unlike a user turn, this does not route synthetic text, append chat history,
  or invoke the memory adapter.

      {:ok, approved} =
        Spectre.Runtime.resolve_policy(
          MyApp.Agent,
          awaiting_result,
          {:accept, :terms_accepted},
          assigns: %{user: user}
        )
  """
  @spec resolve_policy(module(), Result.t(), Policy.resolution(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def resolve_policy(agent, %Result{} = result, resolution, opts \\ [])
      when is_atom(agent) and is_list(opts) do
    opts = runtime_opts(agent, opts)
    input = policy_resolution_input(result, opts)
    state = State.new(result.state)

    ctx = %Context{
      agent: agent,
      input: input,
      state: state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{}),
      route: result.route
    }

    with {:ok, %Result{} = resolved} <- Policy.resolve(resolution, input, ctx),
         {:ok, %Result{} = persisted} <- persist_state(resolved, ctx) do
      {:ok, persisted}
    end
  end

  @doc """
  Executes a staged effect using the durable two-commit workflow.

  The executable state is persisted before the capability is invoked, and the
  completed/failed state is persisted before the terminal result is returned.
  Adapters receive the effect idempotency key through the action context.
  """
  @spec execute(module(), Result.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def execute(agent, %Result{} = result, opts \\ []) when is_atom(agent) and is_list(opts) do
    opts = agent |> runtime_opts(opts) |> put_turn_identity()
    input = policy_resolution_input(result, opts)
    state = State.new(result.state)

    ctx = %Context{
      agent: agent,
      input: input,
      state: state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{}),
      route: result.route
    }

    result = %{result | state: state}

    if terminal_execution_result?(result) do
      {:ok, result}
    else
      execute_pending_result(result, ctx, opts)
    end
  end

  @spec execute_pending_result(Result.t(), Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  defp execute_pending_result(%Result{} = result, %Context{} = ctx, opts) do
    with {:ok, prepared} <- ensure_execution_state_persisted(result, ctx),
         execution_ctx = %{ctx | state: prepared.state},
         {:ok, executed} <- ActionExecutor.execute_pending(prepared.state, execution_ctx, opts),
         executed <- inherit_execution_context(executed, prepared) do
      persist_state(executed, execution_ctx)
    end
  end

  @spec terminal_execution_result?(Result.t()) :: boolean()
  defp terminal_execution_result?(%Result{state: %State{} = state, effects: effects}) do
    is_nil(State.pending_effect(state)) and
      Enum.any?(effects, fn
        %Effect{id: id} = effect ->
          Effect.terminal?(effect) and
            Enum.any?(state.planned_effects, &(&1.id == id and &1.status == effect.status))

        _effect ->
          false
      end)
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
      # "yes" should approve/reject the open policy awaitable, not be interpreted as a
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
    config = definition_config(agent)
    state_module = Keyword.get(config, :state)
    conversation_id = Keyword.get(opts, :conversation_id)

    cond do
      Keyword.has_key?(opts, :state) ->
        # Explicit state is a test and host-app escape hatch; it wins over the
        # adapter so callers can replay a turn deterministically.
        {:ok, opts |> Keyword.get(:state) |> State.new() |> put_conversation_id(conversation_id)}

      is_atom(state_module) && function_exported?(state_module, :load, 3) ->
        load_state_adapter(state_module, :load, [input, agent, opts], conversation_id, opts)

      is_atom(state_module) && function_exported?(state_module, :load, 2) ->
        load_state_adapter(state_module, :load, [input, opts], conversation_id, opts)

      true ->
        {:ok, put_conversation_id(%State{}, conversation_id)}
    end
  end

  @spec load_memory(module(), Input.t(), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp load_memory(agent, input, state, opts) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    result =
      cond do
        Keyword.has_key?(opts, :memory) ->
          # Memory can be injected for tests or for host applications that have
          # already performed retrieval before calling Spectre.
          {:ok, Keyword.get(opts, :memory)}

        is_atom(memory_module) && function_exported?(memory_module, :recall, 2) ->
          Call.run(
            :memory,
            fn ->
              normalize_provider_reply(
                memory_module.recall(input.text, state: state, input: input)
              )
            end,
            Keyword.put(opts, :purpose, :memory_recall)
          )

        true ->
          {:ok, nil}
      end

    with {:ok, memory} <- result,
         :ok <- validate_term_size(memory, :memory_recall, opts, :memory_max_bytes, 1_000_000) do
      {:ok, memory}
    end
  end

  @spec persist(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist(%Result{} = result, %Context{} = ctx) do
    with {:ok, %Result{} = result} <- persist_state(result, ctx) do
      case persist_memory(result, ctx) do
        :ok -> {:ok, result}
        {:error, reason} -> memory_persist_failure(result, ctx, reason)
      end
    end
  end

  @spec memory_persist_failure(Result.t(), Context.t(), term()) ::
          {:ok, Result.t()} | {:error, term()}
  defp memory_persist_failure(%Result{} = result, %Context{} = ctx, reason) do
    case Keyword.get(ctx.opts, :memory_persist_failure, :warn) do
      :warn ->
        warning = %{type: :memory_persist_failed, error: reason}

        metadata = result.metadata

        warnings =
          metadata
          |> Map.get(:persistence_warnings, [])
          |> List.wrap()
          |> Kernel.++([warning])

        result =
          %{
            result
            | events: result.events ++ [warning],
              metadata: Map.put(metadata, :persistence_warnings, warnings)
          }

        {:ok, result}

      :error ->
        # The state write is already committed. Carry the committed result so a
        # session can advance its in-memory state even while reporting strict
        # memory failure to the host.
        {:error, {:memory_persist_failed, reason, result}}

      other ->
        {:error, {:invalid_memory_persist_failure, other}}
    end
  end

  @spec persist_state(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp persist_state(
         %Result{} = result,
         %Context{agent: agent, input: input, opts: opts, state: current_state}
       ) do
    state_module = agent |> definition_config() |> Keyword.get(:state)
    expected_revision = current_state.revision

    with :ok <- validate_result_revision(result, expected_revision) do
      next = %{result | state: State.bump_revision(result.state)}

      case persistence_callback(state_module, next.state, expected_revision, input, agent, opts) do
        nil ->
          {:ok, mark_state_persisted(next, expected_revision, :in_memory)}

        {module, function, args, mode} ->
          persist_with_adapter(module, function, args, mode, next, expected_revision, opts)
      end
    end
  end

  @spec persist_memory(Result.t(), Context.t()) :: :ok | {:error, term()}
  defp persist_memory(%Result{} = result, %Context{agent: agent, input: input, opts: opts}) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    case memory_callback(memory_module) do
      {:ok, callback} ->
        persist_memory_callback(callback, input, result, agent, opts)

      :ok ->
        :ok
    end
  end

  @spec persist_memory_callback(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: :ok | {:error, term()}
  defp persist_memory_callback(callback, input, result, agent, opts) do
    with :ok <-
           validate_term_size(
             memory_payload(input, result, agent),
             :memory_persist,
             opts,
             :memory_persist_max_bytes,
             2_000_000
           ) do
      call_memory_persist(callback, input, result, agent, opts)
    end
  end

  @spec call_memory_persist(
          {:remember | :persist, 2 | 4, module()},
          Input.t(),
          Result.t(),
          module(),
          keyword()
        ) :: :ok | {:error, term()}
  defp call_memory_persist(callback, input, result, agent, opts) do
    result =
      Call.run(
        :memory,
        fn ->
          callback
          |> call_memory_callback(input, result, agent, opts)
          |> normalize_memory_provider_reply()
        end,
        Keyword.put(opts, :purpose, :memory_persist)
      )

    case result do
      {:ok, :persisted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_memory_persist_reply(term()) :: :ok | {:error, term()}
  defp normalize_memory_persist_reply(:ok), do: :ok
  defp normalize_memory_persist_reply({:ok, _reply}), do: :ok
  defp normalize_memory_persist_reply({:error, reason}), do: {:error, reason}

  defp normalize_memory_persist_reply(other),
    do: {:error, Failure.invalid_reply(:memory, other)}

  @spec normalize_memory_provider_reply(term()) :: {:ok, :persisted} | {:error, term()}
  defp normalize_memory_provider_reply(reply) do
    case normalize_memory_persist_reply(reply) do
      :ok -> {:ok, :persisted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load_state_adapter(module(), atom(), list(), term(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  defp load_state_adapter(module, function, args, conversation_id, opts) do
    case Call.run(
           :state,
           fn -> module |> apply(function, args) |> normalize_provider_reply() end,
           Keyword.put(opts, :purpose, :state_load)
         ) do
      {:ok, payload} -> normalize_loaded_state(payload, conversation_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_provider_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_provider_reply({:ok, value}), do: {:ok, value}
  defp normalize_provider_reply({:error, reason}), do: {:error, reason}
  defp normalize_provider_reply(value), do: {:ok, value}

  @spec normalize_loaded_state(term(), term()) :: {:ok, State.t()} | {:error, term()}
  defp normalize_loaded_state(%State{} = state, conversation_id),
    do: {:ok, put_conversation_id(state, conversation_id)}

  defp normalize_loaded_state(payload, conversation_id)
       when is_map(payload) or is_binary(payload) do
    case Codec.decode(payload) do
      {:ok, state} -> {:ok, put_conversation_id(state, conversation_id)}
      {:error, reason} -> {:error, {:invalid_persisted_state, reason}}
    end
  end

  defp normalize_loaded_state(other, _conversation_id),
    do: {:error, {:invalid_state_reply, reply_shape(other)}}

  @spec persistence_callback(
          module() | term(),
          State.t(),
          non_neg_integer(),
          Input.t(),
          module(),
          keyword()
        ) ::
          {module(), atom(), list(), :cas | :legacy} | nil
  defp persistence_callback(module, state, expected, input, agent, opts) when is_atom(module) do
    adapter_opts = Call.adapter_opts(opts)

    cond do
      function_exported?(module, :compare_and_swap, 5) ->
        {module, :compare_and_swap, [state, expected, input, agent, adapter_opts], :cas}

      function_exported?(module, :persist, 5) ->
        {module, :persist, [state, expected, input, agent, adapter_opts], :cas}

      function_exported?(module, :persist, 4) ->
        {module, :persist, [state, input, agent, adapter_opts], :legacy}

      function_exported?(module, :persist, 2) ->
        {module, :persist, [state, input], :legacy}

      true ->
        nil
    end
  end

  defp persistence_callback(_module, _state, _expected, _input, _agent, _opts), do: nil

  @spec persist_with_adapter(
          module(),
          atom(),
          list(),
          :cas | :legacy,
          Result.t(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp persist_with_adapter(module, function, args, mode, result, expected, opts) do
    reply =
      Call.run(
        :state,
        fn -> module |> apply(function, args) |> normalize_persist_provider_reply() end,
        Keyword.put(opts, :purpose, :state_persist)
      )

    case reply do
      {:ok, :persisted} ->
        {:ok, mark_state_persisted(result, expected, mode)}

      {:ok, {:state, payload}} ->
        with {:ok, state} <- normalize_loaded_state(payload, result.state.conversation_id),
             :ok <- validate_persisted_revision(state, result.state.revision) do
          result = %{result | state: state}
          {:ok, mark_state_persisted(result, expected, mode)}
        end

      {:error, :stale_state} ->
        {:error, {:stale_state, expected}}

      {:error, {:stale_state, actual}} ->
        {:error, {:stale_state, expected, actual}}

      {:error, {:ambiguous, reason}} ->
        ambiguous = mark_state_persisted(result, expected, :ambiguous)
        {:error, {:persistence_ambiguous, reason, ambiguous}}

      {:error, {:persistence_ambiguous, reason}} ->
        ambiguous = mark_state_persisted(result, expected, :ambiguous)
        {:error, {:persistence_ambiguous, reason, ambiguous}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec normalize_persist_provider_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_persist_provider_reply(:ok), do: {:ok, :persisted}
  defp normalize_persist_provider_reply({:ok, %State{} = state}), do: {:ok, {:state, state}}

  defp normalize_persist_provider_reply({:ok, state}) when is_map(state) or is_binary(state),
    do: {:ok, {:state, state}}

  defp normalize_persist_provider_reply({:error, reason}), do: {:error, reason}

  defp normalize_persist_provider_reply(other),
    do: {:error, {:invalid_persist_reply, reply_shape(other)}}

  @spec validate_result_revision(Result.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_result_revision(%Result{state: %State{revision: revision}}, expected)
       when revision == expected,
       do: :ok

  defp validate_result_revision(%Result{state: %State{revision: revision}}, expected),
    do: {:error, {:invalid_state_revision_transition, expected, revision}}

  @spec validate_persisted_revision(State.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_persisted_revision(%State{revision: revision}, expected)
       when revision == expected,
       do: :ok

  defp validate_persisted_revision(%State{revision: revision}, expected),
    do: {:error, {:invalid_persisted_revision, expected, revision}}

  @spec mark_state_persisted(Result.t(), non_neg_integer(), atom()) :: Result.t()
  defp mark_state_persisted(%Result{} = result, expected, mode) do
    persistence = %{
      status: if(mode == :ambiguous, do: :ambiguous, else: :committed),
      mode: mode,
      expected_revision: expected,
      revision: result.state.revision
    }

    %{result | metadata: Map.put(result.metadata, :state_persistence, persistence)}
  end

  @spec ensure_execution_state_persisted(Result.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp ensure_execution_state_persisted(%Result{} = result, %Context{} = ctx) do
    case get_in(result.metadata, [:state_persistence, :revision]) do
      revision when revision == result.state.revision ->
        {:ok, result}

      nil ->
        persist_state(result, ctx)

      revision ->
        {:error, {:stale_execution_result, revision, result.state.revision}}
    end
  end

  @spec inherit_execution_context(Result.t(), Result.t()) :: Result.t()
  defp inherit_execution_context(%Result{} = executed, %Result{} = prepared) do
    %{
      executed
      | route: prepared.route,
        metadata: Map.merge(prepared.metadata, executed.metadata)
    }
  end

  @spec definition_config(module()) :: keyword()
  defp definition_config(agent), do: Definition.fetch!(agent).config

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_nil(value), do: nil
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(%{__struct__: module}), do: {:struct, module}
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other

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

  @spec runtime_opts(module(), keyword()) :: keyword()
  defp runtime_opts(agent, opts) do
    agent
    |> agent_runtime_opts()
    |> Keyword.merge(opts)
  end

  @spec agent_runtime_opts(module()) :: keyword()
  defp agent_runtime_opts(agent) do
    config = definition_config(agent)

    []
    |> maybe_put_config(config, :model)
    |> maybe_put_config(config, :classifier)
    |> maybe_put_config(config, :adapter)
    |> maybe_put_config(config, :embedding)
    |> maybe_put_config(config, :input_pipeline)
    |> maybe_put_config(config, :journal)
    |> maybe_put_config(config, :history)
    |> maybe_put_config(config, :chat_history_limit)
    |> maybe_put_config(config, :state_timeout)
    |> maybe_put_config(config, :memory_timeout)
    |> maybe_put_config(config, :run_timeout)
    |> maybe_put_config(config, :renderer_timeout)
    |> maybe_put_config(config, :hook_timeout)
    |> maybe_put_config(config, :prompt_timeout)
    |> maybe_put_config(config, :input_timeout)
    |> maybe_put_config(config, :router_timeout)
    |> maybe_put_config(config, :monitor_timeout)
    |> maybe_put_config(config, :callback_timeout)
    |> maybe_put_config(config, :input_max_bytes)
    |> maybe_put_config(config, :memory_max_bytes)
    |> maybe_put_config(config, :memory_persist_max_bytes)
  end

  @spec normalize_input(module(), Input.t(), keyword()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(agent, %Input{} = input, opts) do
    normalized =
      case Keyword.get(opts, :input_pipeline, []) do
        [] ->
          {:ok, input}

        specs when is_list(specs) ->
          Pipeline.run(input, %{agent: agent, opts: opts}, specs)

        other ->
          {:error, {:invalid_input_pipeline, other}}
      end

    with {:ok, input} <- normalized,
         :ok <- validate_binary_size(input.text, :input, opts, :input_max_bytes, 64_000) do
      {:ok, input}
    end
  end

  @spec maybe_put_config(keyword(), keyword(), atom()) :: keyword()
  defp maybe_put_config(opts, config, key) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  @spec put_turn_identity(keyword()) :: keyword()
  defp put_turn_identity(opts) do
    turn_id = Keyword.get(opts, :turn_id) || Spectre.Identity.uuid7()
    trace_id = Keyword.get(opts, :trace_id) || turn_id

    opts
    |> Keyword.put(:turn_id, turn_id)
    |> Keyword.put(:trace_id, trace_id)
  end

  @spec record_history(Result.t(), Context.t()) :: Result.t()
  defp record_history(%Result{} = result, %Context{agent: agent, opts: opts}) do
    limit =
      Keyword.get(
        opts,
        :chat_history_limit,
        Keyword.get(definition_config(agent), :history, 20)
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
      effects: result.effects,
      awaitables: result.awaitables,
      events: result.events
    }
  end

  @spec policy_resolution_input(Result.t(), keyword()) :: Input.t()
  defp policy_resolution_input(%Result{} = result, opts) do
    case Keyword.get(opts, :input, result.input) do
      %Input{} = input -> input
      nil -> Input.new("")
      input -> Input.new(input)
    end
  end

  @spec put_conversation_id(State.t(), term()) :: State.t()
  defp put_conversation_id(%State{} = state, nil), do: state

  defp put_conversation_id(%State{conversation_id: nil} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}

  defp put_conversation_id(%State{} = state, _conversation_id), do: state

  @spec validate_binary_size(binary(), atom(), keyword(), atom(), pos_integer()) ::
          :ok | {:error, term()}
  defp validate_binary_size(value, boundary, opts, key, default) when is_binary(value) do
    max_bytes = Keyword.get(opts, key, default)

    if is_integer(max_bytes) and max_bytes > 0 and byte_size(value) <= max_bytes do
      :ok
    else
      {:error, {:payload_too_large, boundary, byte_size(value), max_bytes}}
    end
  end

  @spec validate_term_size(term(), atom(), keyword(), atom(), pos_integer()) ::
          :ok | {:error, term()}
  defp validate_term_size(value, boundary, opts, key, default) do
    max_bytes = Keyword.get(opts, key, default)
    bytes = :erlang.external_size(value)

    if is_integer(max_bytes) and max_bytes > 0 and bytes <= max_bytes do
      :ok
    else
      {:error, {:payload_too_large, boundary, bytes, max_bytes}}
    end
  rescue
    exception -> {:error, {:payload_size_failed, boundary, exception.__struct__}}
  end
end
