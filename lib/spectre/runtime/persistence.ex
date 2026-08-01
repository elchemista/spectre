defmodule Spectre.Runtime.Persistence do
  @moduledoc """
  State and memory persistence boundaries for `Spectre.Runtime`.

  Loads state through the configured adapter (supporting compare-and-swap and
  legacy arities), persists advanced state with revision fencing, classifies
  ambiguous adapter outcomes so they are never blindly retried, and invokes
  the memory adapter for recall and persistence with bounded payload sizes.
  """

  alias Spectre.Context
  alias Spectre.Definition
  alias Spectre.Input
  alias Spectre.Journal.Recorder
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.State
  alias Spectre.State.Codec

  @doc "Loads initial state from an explicit option or the configured adapter."
  @spec load_state(module(), Input.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def load_state(agent, input, opts) do
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

  @doc "Recalls memory through an explicit option or the configured adapter."
  @spec load_memory(module(), Input.t(), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def load_memory(agent, input, state, opts) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    result =
      cond do
        Keyword.has_key?(opts, :memory) ->
          # Memory can be injected for tests or for host applications that have
          # already performed retrieval before calling Spectre.
          {:ok, Keyword.get(opts, :memory)}

        is_nil(memory_module) ->
          {:ok, nil}

        not is_atom(memory_module) ->
          {:error, {:invalid_memory_adapter, memory_module}}

        not Code.ensure_loaded?(memory_module) ->
          {:error, {:memory_adapter_unavailable, memory_module}}

        function_exported?(memory_module, :recall, 2) ->
          memory_opts =
            opts
            |> Keyword.put(:state, state)
            |> Keyword.put(:input, input)
            |> Keyword.put(:agent, agent)

          Call.run(
            :memory,
            fn ->
              normalize_provider_reply(memory_module.recall(input.text, memory_opts))
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

  @doc "Persists state, then memory, honoring the memory failure policy."
  @spec persist(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def persist(%Result{} = result, %Context{} = ctx) do
    with {:ok, %Result{} = result} <- persist_state(result, ctx) do
      case persist_memory(result, ctx) do
        :ok -> {:ok, result}
        {:error, reason} -> memory_persist_failure(result, ctx, reason)
      end
    end
  end

  @doc "Persists the advanced state revision through the configured adapter."
  @spec persist_state(Result.t(), Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def persist_state(
        %Result{} = result,
        %Context{agent: agent, input: input, opts: opts, state: current_state} = ctx
      ) do
    state_module = agent |> definition_config() |> Keyword.get(:state)
    expected_revision = current_state.revision

    with :ok <- validate_result_revision(result, expected_revision) do
      next = %{result | state: State.bump_revision(result.state)}

      persisted =
        case persistence_callback(state_module, next.state, expected_revision, input, agent, opts) do
          nil ->
            {:ok, mark_state_persisted(next, expected_revision, :in_memory)}

          {module, function, args, mode} ->
            persist_with_adapter(module, function, args, mode, next, expected_revision, opts)
        end

      case persisted do
        {:ok, %Result{} = committed} ->
          emit_persistence(:committed, committed, ctx)
          record_committed_persistence(committed, ctx)

        {:error, {:persistence_ambiguous, reason, %Result{} = ambiguous}} ->
          emit_persistence(:ambiguous, ambiguous, ctx)
          _ = Recorder.record_persistence(ambiguous, ctx)
          {:error, {:persistence_ambiguous, reason, ambiguous}}

        {:error, reason} = error
        when is_tuple(reason) and tuple_size(reason) > 0 and elem(reason, 0) == :stale_state ->
          emit_persistence_conflict(ctx, expected_revision)
          error

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Persists the executable state exactly once before an effect runs."
  @spec ensure_execution_state_persisted(Result.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def ensure_execution_state_persisted(%Result{} = result, %Context{} = ctx) do
    case get_in(result.metadata, [:state_persistence, :revision]) do
      revision when revision == result.state.revision ->
        {:ok, result}

      nil ->
        persist_state(result, ctx)

      revision ->
        {:error, {:stale_execution_result, revision, result.state.revision}}
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

  @spec record_committed_persistence(Result.t(), Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp record_committed_persistence(%Result{} = committed, %Context{} = ctx) do
    case Recorder.record_persistence(committed, ctx) do
      {:ok, %Result{} = recorded} ->
        {:ok, recorded}

      {:error, reason} ->
        # State has already crossed its commit boundary. Preserve that fact for
        # sessions and hosts even when a strict persistence-journal append
        # fails afterward.
        {:error, {:persistence_journal_failed, reason, committed}}
    end
  end

  defp emit_persistence(outcome, result, ctx) do
    Spectre.Telemetry.emit(
      [:persistence, :stop],
      %{count: 1},
      %{
        agent: ctx.agent,
        outcome: outcome,
        revision: result.state.revision,
        mode: get_in(result.metadata, [:state_persistence, :mode])
      },
      ctx.opts
    )
  end

  defp emit_persistence_conflict(ctx, expected_revision) do
    Spectre.Telemetry.emit(
      [:persistence, :conflict],
      %{count: 1},
      %{agent: ctx.agent, reason: :stale_state, expected_revision: expected_revision},
      ctx.opts
    )
  end

  @spec persist_memory(Result.t(), Context.t()) :: :ok | {:error, term()}
  defp persist_memory(%Result{} = result, %Context{agent: agent, input: input, opts: opts}) do
    memory_module = agent |> definition_config() |> Keyword.get(:memory)

    case memory_callback(memory_module) do
      {:ok, callback} ->
        persist_memory_callback(callback, input, result, agent, opts)

      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason}
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
    run_state_persist(
      module,
      function,
      args,
      Keyword.put(opts, :purpose, :state_persist)
    )
    |> handle_persist_reply(mode, result, expected)
  end

  @spec handle_persist_reply(term(), :cas | :legacy, Result.t(), non_neg_integer()) ::
          {:ok, Result.t()} | {:error, term()}
  defp handle_persist_reply({:ok, :persisted}, mode, result, expected) do
    {:ok, mark_state_persisted(result, expected, mode)}
  end

  defp handle_persist_reply({:ok, {:state, payload}}, mode, result, expected) do
    case normalize_persisted_state(payload, result) do
      {:ok, %Result{} = persisted_result} ->
        {:ok, mark_state_persisted(persisted_result, expected, mode)}

      {:error, reason} ->
        ambiguous_persistence(result, expected, reason)
    end
  end

  defp handle_persist_reply({:error, :stale_state}, _mode, _result, expected) do
    {:error, {:stale_state, expected}}
  end

  defp handle_persist_reply({:error, {:stale_state, actual}}, _mode, _result, expected) do
    {:error, {:stale_state, expected, actual}}
  end

  defp handle_persist_reply({:error, {:ambiguous, reason}}, _mode, result, expected) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply(
         {:error, {:persistence_ambiguous, reason}},
         _mode,
         result,
         expected
       ) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply(
         {:error, %Failure{provider: :state, kind: kind} = failure},
         _mode,
         result,
         expected
       )
       when kind != :configuration do
    # The adapter worker was invoked. An exception, exit, crash, timeout, or
    # invalid provider reply can happen after the durable write, so treating it
    # as a definite failure would make a blind retry unsafe.
    ambiguous_persistence(result, expected, failure)
  end

  defp handle_persist_reply(
         {:error, {:invalid_persist_reply, _shape} = reason},
         _mode,
         result,
         expected
       ) do
    ambiguous_persistence(result, expected, reason)
  end

  defp handle_persist_reply({:error, reason}, _mode, _result, _expected), do: {:error, reason}

  defp run_state_persist(module, function, args, opts) do
    Call.run(
      :state,
      fn -> module |> apply(function, args) |> normalize_persist_provider_reply() end,
      opts
    )
  end

  @spec normalize_persisted_state(term(), Result.t()) :: {:ok, Result.t()} | {:error, term()}
  defp normalize_persisted_state(payload, %Result{} = result) do
    with {:ok, state} <- normalize_loaded_state(payload, result.state.conversation_id),
         :ok <- validate_persisted_revision(state, result.state.revision) do
      {:ok, %{result | state: state}}
    end
  end

  @spec ambiguous_persistence(Result.t(), non_neg_integer(), term()) ::
          {:error, {:persistence_ambiguous, term(), Result.t()}}
  defp ambiguous_persistence(%Result{} = result, expected, reason) do
    ambiguous = mark_state_persisted(result, expected, :ambiguous)
    {:error, {:persistence_ambiguous, reason, ambiguous}}
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

  @spec memory_callback(module() | term()) ::
          {:ok, {:remember | :persist, 2 | 4, module()}}
          | :ok
          | {:error, term()}
  defp memory_callback(nil), do: :ok

  defp memory_callback(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      loaded_memory_callback(module)
    else
      {:error, {:memory_adapter_unavailable, module}}
    end
  end

  defp memory_callback(module), do: {:error, {:invalid_memory_adapter, module}}

  defp loaded_memory_callback(module) do
    cond do
      function_exported?(module, :remember, 4) -> {:ok, {:remember, 4, module}}
      function_exported?(module, :persist, 4) -> {:ok, {:persist, 4, module}}
      function_exported?(module, :remember, 2) -> {:ok, {:remember, 2, module}}
      function_exported?(module, :persist, 2) -> {:ok, {:persist, 2, module}}
      true -> :ok
    end
  end

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

  @spec put_conversation_id(State.t(), term()) :: State.t()
  defp put_conversation_id(%State{} = state, nil), do: state

  defp put_conversation_id(%State{conversation_id: nil} = state, conversation_id),
    do: %{state | conversation_id: conversation_id}

  defp put_conversation_id(%State{} = state, _conversation_id), do: state

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

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_nil(value), do: nil
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(%{__struct__: module}), do: {:struct, module}
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other

  @spec definition_config(module()) :: keyword()
  defp definition_config(agent), do: Definition.fetch!(agent).config
end
