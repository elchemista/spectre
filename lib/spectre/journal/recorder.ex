defmodule Spectre.Journal.Recorder do
  @moduledoc """
  Builds, filters, and delivers observational journal records.

  Journaling is disabled unless an agent, runtime call, or application config
  supplies a store. Asynchronous warning mode is the monitoring default;
  synchronous error mode is available when the host requires a journal append
  to succeed before the turn continues.
  """

  require Logger

  alias Spectre.Journal.Buffer
  alias Spectre.Journal.Record
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context

  @recorder_keys [
    :events,
    :include_input,
    :include_reply,
    :mode,
    :on_error,
    :buffer_size,
    :overflow,
    :sample_rate,
    :sample_rates,
    :redact,
    :retention,
    :telemetry_handler,
    :store_opts
  ]

  @doc """
  Records the final routing/arbitration decision in a router context.

  The returned context is unchanged. Only an explicit synchronous
  `on_error: :error` configuration can turn an append failure into a routing
  error.
  """
  @spec record_routing(Context.t()) :: {:ok, Context.t()} | {:error, term()}
  def record_routing(%Context{} = context) do
    case configuration(context.opts) do
      :disabled ->
        {:ok, context}

      {:ok, store, config} ->
        if routing_event_enabled?(config) do
          context
          |> routing_record(config)
          |> maybe_deliver(store, config, context)
        else
          {:ok, context}
        end

      {:error, reason} ->
        {:error, {:invalid_journal_configuration, reason}}
    end
  end

  @doc """
  Records policy, lifecycle, and execution events carried by a runtime result.

  Records exclude effect arguments, action results, provider errors, input,
  and replies unless explicitly enabled. The result is returned unchanged.
  """
  @spec record_result(Result.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def record_result(%Result{} = result, %{opts: opts} = context) when is_list(opts) do
    case configuration(opts) do
      :disabled ->
        {:ok, result}

      {:ok, store, config} ->
        deliver_runtime_records(result, context, store, config)

      {:error, reason} ->
        {:error, {:invalid_journal_configuration, reason}}
    end
  end

  defp deliver_runtime_records(result, context, store, config) do
    result.events
    |> Enum.with_index(10)
    |> Enum.filter(fn {event, _sequence} -> runtime_event_enabled?(config, event) end)
    |> Enum.reduce_while({:ok, result}, fn event, accumulated ->
      deliver_runtime_record(event, accumulated, context, store, config)
    end)
  end

  defp deliver_runtime_record({event, sequence}, {:ok, value}, context, store, config) do
    record = runtime_record(value, context, event, sequence, config)

    case deliver_value(record, store, config, value) do
      {:ok, value} -> {:cont, {:ok, value}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc """
  Records a committed or ambiguous persistence boundary.
  """
  @spec record_persistence(Result.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def record_persistence(%Result{} = result, %{opts: opts} = context) when is_list(opts) do
    case configuration(opts) do
      :disabled ->
        {:ok, result}

      {:ok, store, config} ->
        if event_enabled?(config, :persistence) do
          record = persistence_record(result, context, config)
          deliver_value(record, store, config, result)
        else
          {:ok, result}
        end

      {:error, reason} ->
        {:error, {:invalid_journal_configuration, reason}}
    end
  end

  @spec configuration(keyword()) :: :disabled | {:ok, module(), keyword()} | {:error, term()}
  defp configuration(opts) do
    with {:ok, store, config} <-
           opts
           |> Keyword.get_lazy(:journal, fn -> Application.get_env(:spectre, :journal, false) end)
           |> normalize_configuration(),
         config <-
           Keyword.put_new(config, :telemetry_handler, Keyword.get(opts, :telemetry_handler)),
         :ok <- validate_configuration(config) do
      {:ok, store, config}
    else
      :disabled -> :disabled
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_configuration(term()) ::
          :disabled | {:ok, module(), keyword()} | {:error, term()}
  defp normalize_configuration(value) when value in [nil, false], do: :disabled
  defp normalize_configuration(true), do: {:error, true}
  defp normalize_configuration(store) when is_atom(store), do: {:ok, store, []}

  defp normalize_configuration({store, config}) when is_atom(store) and is_list(config),
    do: {:ok, store, config}

  defp normalize_configuration(config) when is_list(config) do
    case Keyword.fetch(config, :store) do
      {:ok, store} when is_atom(store) -> {:ok, store, Keyword.delete(config, :store)}
      _other -> {:error, config}
    end
  end

  defp normalize_configuration(other), do: {:error, other}

  @spec validate_configuration(keyword()) :: :ok | {:error, term()}
  defp validate_configuration(config) do
    mode = Keyword.get(config, :mode, :async)
    on_error = Keyword.get(config, :on_error, :warn)
    sample_rate = Keyword.get(config, :sample_rate, 1.0)
    sample_rates = Keyword.get(config, :sample_rates, %{})
    buffer_size = Keyword.get(config, :buffer_size, 1_000)
    overflow = Keyword.get(config, :overflow, :drop_newest)

    [
      validate_mode(mode),
      validate_error_policy(mode, on_error),
      validate_sample_rate(sample_rate),
      validate_sample_rates(sample_rates),
      validate_buffer_size(buffer_size),
      validate_overflow(overflow)
    ]
    |> Enum.find(:ok, &match?({:error, _reason}, &1))
  end

  defp validate_mode(mode) when mode in [:sync, :async], do: :ok
  defp validate_mode(mode), do: {:error, {:invalid_journal_mode, mode}}

  defp validate_error_policy(:async, :error), do: {:error, :async_journal_cannot_fail_turn}
  defp validate_error_policy(_mode, policy) when policy in [:warn, :ignore, :error], do: :ok
  defp validate_error_policy(_mode, policy), do: {:error, {:invalid_journal_error_policy, policy}}

  defp validate_sample_rate(rate) when is_number(rate) and rate >= 0 and rate <= 1, do: :ok
  defp validate_sample_rate(rate), do: {:error, {:invalid_journal_sample_rate, rate}}

  defp validate_sample_rates(rates) when is_list(rates),
    do: rates |> Map.new() |> validate_sample_rates()

  defp validate_sample_rates(rates) when is_map(rates) do
    Enum.reduce_while(rates, :ok, fn
      {phase, rate}, :ok when is_atom(phase) ->
        case validate_sample_rate(rate) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {phase, _rate}, :ok ->
        {:halt, {:error, {:invalid_journal_sample_phase, phase}}}
    end)
  end

  defp validate_sample_rates(rates), do: {:error, {:invalid_journal_sample_rates, rates}}

  defp validate_buffer_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_buffer_size(size), do: {:error, {:invalid_journal_buffer_size, size}}

  defp validate_overflow(overflow) when overflow in [:drop_newest, :drop_oldest], do: :ok
  defp validate_overflow(overflow), do: {:error, {:invalid_journal_overflow_policy, overflow}}

  @spec routing_event_enabled?(keyword()) :: boolean()
  defp routing_event_enabled?(config) do
    events = List.wrap(Keyword.get(config, :events, [:routing, :arbitration]))
    :all in events or :routing in events or :arbitration in events
  end

  @spec event_enabled?(keyword(), atom()) :: boolean()
  defp event_enabled?(config, phase) do
    events = List.wrap(Keyword.get(config, :events, [:routing, :arbitration]))
    :all in events or phase in events
  end

  @spec runtime_event_enabled?(keyword(), term()) :: boolean()
  defp runtime_event_enabled?(config, event) when is_map(event) do
    event_enabled?(config, event_phase(Map.get(event, :type)))
  end

  defp runtime_event_enabled?(_config, _event), do: false

  defp event_phase(type)
       when type in [
              :awaitable_opened,
              :awaitable_pending,
              :awaitable_accepted,
              :awaitable_rejected,
              :awaitable_cancelled,
              :awaitable_expired,
              :policy_resolved
            ],
       do: :policy

  defp event_phase(type)
       when type in [:effect_completed, :effect_failed, :effect_already_resolved],
       do: :execution

  defp event_phase(_type), do: :lifecycle

  @spec routing_record(Context.t(), keyword()) :: Record.t()
  defp routing_record(%Context{} = context, config) do
    route = context.route
    state = host_state(context)
    opts = context.opts

    Record.new(%{
      agent: Keyword.get(opts, :spectre_agent),
      agent_version: Keyword.get(opts, :agent_version),
      conversation_id: conversation_id(state, context),
      turn_id: Keyword.get(opts, :turn_id),
      trace_id: Keyword.get(opts, :trace_id),
      sequence: Keyword.get(opts, :journal_sequence, 1),
      state_revision: state_revision(state),
      phase: :arbitration,
      decision: route_decision(route),
      reason: routing_reason(context),
      evidence:
        Enum.map(
          Enum.reverse(context.candidates),
          &candidate_evidence(&1, context.arbitration)
        ),
      input: recorded_input(context, config),
      metadata: %{
        thresholds: get_in(context.arbitration || %{}, [:thresholds]) || routing_thresholds(opts),
        state_version: state_value(state, :state_version),
        current_flow: state_value(state, :current_flow),
        current_scope: state_value(state, :current_scope),
        router_errors: context.errors |> Enum.reverse() |> Enum.map(&reason_code/1)
      }
    })
  end

  @spec runtime_record(Result.t(), map(), map(), non_neg_integer(), keyword()) :: Record.t()
  defp runtime_record(%Result{} = result, context, event, sequence, config) do
    phase = event_phase(Map.get(event, :type))
    state = result.state

    Record.new(%{
      agent: Map.get(context, :agent),
      agent_version: Keyword.get(context.opts, :agent_version),
      conversation_id: state && state.conversation_id,
      turn_id: Keyword.get(context.opts, :turn_id),
      trace_id: Keyword.get(context.opts, :trace_id),
      sequence: sequence,
      state_revision: state && state.revision,
      phase: phase,
      decision: %{kind: Map.get(event, :type, :runtime_event)},
      reason: event_reason(event),
      transition: transition_summary(event),
      policy: policy_summary(event),
      effect: effect_summary(event),
      input: recorded_runtime_input(result, config),
      reply: recorded_runtime_reply(result, config),
      metadata: record_metadata(config, %{state_version: state && state.state_version})
    })
  end

  @spec persistence_record(Result.t(), map(), keyword()) :: Record.t()
  defp persistence_record(%Result{} = result, context, config) do
    persistence = Map.get(result.metadata, :state_persistence, %{})

    Record.new(%{
      agent: Map.get(context, :agent),
      agent_version: Keyword.get(context.opts, :agent_version),
      conversation_id: result.state && result.state.conversation_id,
      turn_id: Keyword.get(context.opts, :turn_id),
      trace_id: Keyword.get(context.opts, :trace_id),
      sequence: 90,
      state_revision: result.state && result.state.revision,
      phase: :persistence,
      decision: %{
        kind: :state_persisted,
        status: Map.get(persistence, :status),
        mode: Map.get(persistence, :mode)
      },
      reason: %{code: Map.get(persistence, :status, :committed)},
      transition: %{
        from_revision: Map.get(persistence, :expected_revision),
        to_revision: Map.get(persistence, :revision)
      },
      metadata:
        record_metadata(config, %{state_version: result.state && result.state.state_version})
    })
  end

  defp event_reason(event) do
    reason = Map.get(event, :reason) || Map.get(event, :error)
    %{code: if(reason, do: reason_code(reason), else: Map.get(event, :type, :runtime_event))}
  end

  defp transition_summary(event) do
    %{
      event: Map.get(event, :type),
      entity_id: Map.get(event, :effect_id) || Map.get(event, :subject_id),
      status: event |> Map.get(:effect) |> entity_status()
    }
  end

  defp entity_status(%{status: status}) when is_atom(status), do: status
  defp entity_status(_entity), do: nil

  defp policy_summary(event) do
    if event_phase(Map.get(event, :type)) == :policy do
      %{
        name: Map.get(event, :name),
        kind: Map.get(event, :kind),
        label: Map.get(event, :label),
        source: Map.get(event, :source)
      }
    end
  end

  defp effect_summary(event) do
    if Map.has_key?(event, :effect_id) or event_phase(Map.get(event, :type)) == :execution do
      effect = Map.get(event, :effect)

      %{
        id: Map.get(event, :effect_id),
        kind: Map.get(event, :kind),
        name: Map.get(event, :name),
        owner: Map.get(event, :owner),
        scope: Map.get(event, :scope),
        status: entity_status(effect),
        idempotency_key: Map.get(event, :idempotency_key)
      }
    end
  end

  defp recorded_runtime_input(result, config) do
    if Keyword.get(config, :include_input, false) and result.input do
      %{text: result.input.text, meta: result.input.meta}
    end
  end

  defp recorded_runtime_reply(result, config) do
    if Keyword.get(config, :include_reply, false), do: result.reply_text
  end

  defp record_metadata(config, metadata) do
    case Keyword.get(config, :retention) do
      nil -> metadata
      retention when is_map(retention) -> Map.put(metadata, :retention, retention)
      retention when is_list(retention) -> Map.put(metadata, :retention, Map.new(retention))
      retention -> Map.put(metadata, :retention, %{policy: retention})
    end
  end

  @spec host_state(Context.t()) :: Spectre.State.t() | nil
  defp host_state(%Context{host_context: host_context}) when is_map(host_context) do
    Map.get(host_context, :state)
  end

  defp host_state(_context), do: nil

  @spec state_value(Spectre.State.t() | nil, atom()) :: term()
  defp state_value(%Spectre.State{} = state, key), do: Map.get(state, key)
  defp state_value(_state, _key), do: nil

  @spec route_decision(Spectre.Route.t() | nil) :: map()
  defp route_decision(nil), do: %{kind: :no_route}

  defp route_decision(route) do
    %{
      kind: :route_selected,
      label: route.label,
      scope: route.scope,
      owner: route.owner,
      strategy: route.strategy,
      accepted?: route.accepted?,
      confidence: route.confidence,
      margin: route.margin,
      terminal?: route.terminal?
    }
  end

  @spec routing_reason(Context.t()) :: map()
  defp routing_reason(%Context{route: %Spectre.Route{accepted?: true}, traces: traces}),
    do: trace_reason(traces)

  defp routing_reason(%Context{traces: traces}) do
    ambiguity_reason(traces) || trace_reason(traces)
  end

  @spec trace_reason([term()]) :: map()
  defp trace_reason(traces) do
    Enum.find_value(traces, %{code: :pipeline_completed}, fn
      {:llm_arbitrated, route} ->
        %{code: :llm_selected, label: route.label}

      {:llm_arbitration_failed, reason} ->
        %{code: :llm_failed, error: reason_code(reason)}

      {:llm_arbitration_skipped, reason} ->
        %{code: :llm_skipped, reason: reason}

      {:arbitrated, route} ->
        %{code: :candidate_selected, provider: route.strategy, label: route.label}

      {:clarify, _text} ->
        %{code: :clarification_required}

      _trace ->
        nil
    end)
  end

  @spec ambiguity_reason([term()]) :: map() | nil
  defp ambiguity_reason(traces) do
    Enum.find_value(traces, fn
      {:ambiguous_scoped_labels, strategy, labels} ->
        %{code: :ambiguous_scoped_labels, strategy: strategy, labels: labels}

      _trace ->
        nil
    end)
  end

  @spec candidate_evidence(Candidate.t(), map() | nil) :: map()
  defp candidate_evidence(%Candidate{} = candidate, arbitration) do
    base =
      Map.take(candidate, [
        :label,
        :scope,
        :provider,
        :score,
        :margin,
        :strength,
        :accepted?,
        :terminal?
      ])

    explanation =
      arbitration
      |> case do
        %{candidates: candidates} -> candidates
        _other -> []
      end
      |> Enum.find(fn item ->
        item.provider == candidate.provider and item.label == candidate.label and
          item.scope == candidate.scope
      end)

    Map.merge(
      base,
      Map.take(explanation || %{}, [
        :eligible?,
        :winner?,
        :rejection_reason,
        :required
      ])
    )
  end

  @spec reason_code(term()) :: atom()
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> code
      _other -> :router_error
    end
  end

  defp reason_code(_reason), do: :router_error

  @spec recorded_input(Context.t(), keyword()) :: map() | nil
  defp recorded_input(%Context{} = context, config) do
    if Keyword.get(config, :include_input, false) do
      %{text: context.input.text, meta: context.input.meta}
    end
  end

  @spec conversation_id(Spectre.State.t() | nil, Context.t()) :: term()
  defp conversation_id(%Spectre.State{conversation_id: id}, _context) when not is_nil(id), do: id

  defp conversation_id(_state, %Context{} = context) do
    first_present([
      Keyword.get(context.opts, :conversation_id),
      Map.get(context.input.meta, :conversation_id),
      Map.get(context.input.meta, "conversation_id")
    ])
  end

  @spec first_present([term()]) :: term()
  defp first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  @spec state_revision(Spectre.State.t() | nil) :: non_neg_integer() | nil
  defp state_revision(%Spectre.State{revision: revision}), do: revision
  defp state_revision(_state), do: nil

  @spec routing_thresholds(keyword()) :: map()
  defp routing_thresholds(opts) do
    arbitrator_opts =
      case Keyword.get(opts, :arbitrator) do
        {_module, configured} when is_list(configured) -> configured
        _other -> []
      end

    arbitrator_opts
    |> Keyword.merge(opts)
    |> Keyword.take([
      :classifier_accept,
      :classifier_margin,
      :embedding_accept,
      :embedding_margin,
      :bag_accept,
      :jaro_accept,
      :conflict,
      :no_decision
    ])
    |> Map.new()
  end

  @spec maybe_deliver(Record.t(), module(), keyword(), Context.t()) ::
          {:ok, Context.t()} | {:error, term()}
  defp maybe_deliver(%Record{} = record, store, config, context) do
    case redact_record(record, config) do
      {:ok, record} ->
        maybe_deliver_sampled(record, store, config, context)

      {:error, reason} ->
        handle_sync_error({:journal_redaction_failed, reason}, config, context)
    end
  end

  defp maybe_deliver_sampled(record, store, config, context) do
    if sampled?(record, sample_rate(config, record.phase)) do
      emit_record(record, config)
      deliver(record, store, config, context)
    else
      {:ok, context}
    end
  end

  @spec deliver_value(Record.t(), module(), keyword(), term()) ::
          {:ok, term()} | {:error, term()}
  defp deliver_value(%Record{} = record, store, config, value) do
    case redact_record(record, config) do
      {:ok, record} ->
        deliver_redacted_value(record, store, config, value)

      {:error, reason} ->
        handle_value_error({:journal_redaction_failed, reason}, config, value)
    end
  end

  defp deliver_redacted_value(record, store, config, value) do
    if sampled?(record, sample_rate(config, record.phase)) do
      emit_record(record, config)
      deliver_value_by_mode(record, store, config, value)
    else
      {:ok, value}
    end
  end

  defp deliver_value_by_mode(record, store, config, value) do
    case Keyword.get(config, :mode, :async) do
      :sync ->
        deliver_sync_value(record, store, config, value)

      :async ->
        start_async_append(store, record, config)
        {:ok, value}

      mode ->
        {:error, {:invalid_journal_mode, mode}}
    end
  end

  defp deliver_sync_value(record, store, config, value) do
    case append(store, record, store_opts(config)) do
      :ok -> {:ok, value}
      {:error, reason} -> handle_value_error(reason, config, value)
    end
  end

  defp emit_record(record, config) do
    Spectre.Telemetry.emit(
      [:journal, :record],
      %{count: 1},
      %{phase: record.phase, schema_version: record.schema_version},
      config
    )
  end

  defp handle_value_error(reason, config, value) do
    case Keyword.get(config, :on_error, :warn) do
      :error ->
        {:error, {:journal_append_failed, reason}}

      :warn ->
        log_warning(reason, nil, nil)
        {:ok, value}

      :ignore ->
        {:ok, value}

      policy ->
        {:error, {:invalid_journal_error_policy, policy}}
    end
  end

  @spec redact_record(Record.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  defp redact_record(%Record{} = record, config) do
    case Keyword.get(config, :redact) do
      nil ->
        {:ok, record}

      function when is_function(function, 1) ->
        normalize_redacted(function.(record))

      {module, function} when is_atom(module) and is_atom(function) ->
        normalize_redacted(apply(module, function, [record]))

      {module, function, extra} when is_atom(module) and is_atom(function) and is_list(extra) ->
        normalize_redacted(apply(module, function, [record | extra]))

      invalid ->
        {:error, {:invalid_journal_redactor, invalid}}
    end
  rescue
    exception -> {:error, {:redactor_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:redactor_failure, kind, reason_code(reason)}}
  end

  defp normalize_redacted(%Record{} = record), do: {:ok, record}
  defp normalize_redacted(record) when is_map(record), do: {:ok, Record.new(record)}
  defp normalize_redacted({:ok, record}), do: normalize_redacted(record)
  defp normalize_redacted({:error, reason}), do: {:error, reason}
  defp normalize_redacted(other), do: {:error, {:invalid_redactor_reply, reply_shape(other)}}

  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other

  @spec sample_rate(keyword(), atom()) :: number()
  defp sample_rate(config, phase) do
    configured = Keyword.get(config, :sample_rates, %{})

    case configured do
      rates when is_map(rates) -> Map.get(rates, phase, default_sample_rate(config, phase))
      rates when is_list(rates) -> Keyword.get(rates, phase, default_sample_rate(config, phase))
      _other -> default_sample_rate(config, phase)
    end
  end

  defp default_sample_rate(_config, phase) when phase in [:policy, :execution], do: 1.0
  defp default_sample_rate(config, _phase), do: Keyword.get(config, :sample_rate, 1.0)

  @spec deliver(Record.t(), module(), keyword(), Context.t()) ::
          {:ok, Context.t()} | {:error, term()}
  defp deliver(record, store, config, context) do
    case Keyword.get(config, :mode, :async) do
      :sync ->
        case append(store, record, store_opts(config)) do
          :ok -> {:ok, context}
          {:error, reason} -> handle_sync_error(reason, config, context)
        end

      :async ->
        start_async_append(store, record, config)
        {:ok, context}

      mode ->
        {:error, {:invalid_journal_mode, mode}}
    end
  end

  @spec start_async_append(module(), Record.t(), keyword()) :: :ok
  defp start_async_append(store, record, config) do
    delivery = fn ->
      case append(store, record, store_opts(config)) do
        :ok ->
          :ok

        {:error, reason} = error ->
          handle_async_error(reason, config, record)
          error
      end
    end

    buffer_opts =
      config
      |> Keyword.take([:buffer_size, :overflow])
      |> Keyword.put(:partition, store)

    case Buffer.enqueue(delivery, buffer_opts) do
      :ok -> :ok
      {:ok, :dropped_oldest} -> handle_async_error(:journal_buffer_dropped_oldest, config, record)
      {:error, reason} -> handle_async_error(reason, config, record)
    end
  catch
    :exit, reason -> handle_async_error({:journal_buffer_exit, reason}, config, record)
  end

  @spec append(module(), Record.t(), keyword()) :: :ok | {:error, term()}
  defp append(store, record, opts) do
    call_opts = Keyword.put(opts, :purpose, :journal_append)
    adapter_opts = Keyword.drop(opts, [:journal_timeout, :provider_timeout])

    case Call.run(
           :journal,
           fn -> normalize_append_reply(store.append(record, adapter_opts)) end,
           call_opts
         ) do
      {:ok, :appended} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_append_reply(term()) :: {:ok, :appended} | {:error, term()}
  defp normalize_append_reply(:ok), do: {:ok, :appended}
  defp normalize_append_reply({:ok, _value}), do: {:ok, :appended}
  defp normalize_append_reply({:error, reason}), do: {:error, reason}

  defp normalize_append_reply(other),
    do: {:error, Failure.invalid_reply(:journal, other)}

  @spec handle_sync_error(term(), keyword(), Context.t()) ::
          {:ok, Context.t()} | {:error, term()}
  defp handle_sync_error(reason, config, context) do
    case Keyword.get(config, :on_error, :warn) do
      :error ->
        {:error, {:journal_append_failed, reason}}

      :warn ->
        log_warning(reason, nil, context)
        {:ok, context}

      :ignore ->
        {:ok, context}

      policy ->
        {:error, {:invalid_journal_error_policy, policy}}
    end
  end

  @spec handle_async_error(term(), keyword(), Record.t()) :: :ok
  defp handle_async_error(reason, config, record) do
    case Keyword.get(config, :on_error, :warn) do
      :ignore -> :ok
      _policy -> log_warning(reason, record, nil)
    end
  end

  @spec log_warning(term(), Record.t() | nil, Context.t() | nil) :: :ok
  defp log_warning(reason, record, context) do
    {record_id, record_agent} = record_identity(record)
    agent = first_present([record_agent, context_agent(context)])

    Logger.warning(
      "spectre_journal append_failed agent=#{inspect(agent)} " <>
        "record_id=#{inspect(record_id)} reason=#{inspect(reason, limit: 8)}"
    )
  end

  @spec record_identity(Record.t() | nil) :: {String.t() | nil, module() | nil}
  defp record_identity(%Record{} = record), do: {record.id, record.agent}
  defp record_identity(_record), do: {nil, nil}

  @spec context_agent(Context.t() | nil) :: module() | nil
  defp context_agent(%Context{} = context), do: Keyword.get(context.opts, :spectre_agent)
  defp context_agent(_context), do: nil

  @spec sampled?(Record.t(), number()) :: boolean()
  defp sampled?(_record, rate) when is_number(rate) and rate >= 1, do: true
  defp sampled?(_record, rate) when is_number(rate) and rate <= 0, do: false

  defp sampled?(%Record{id: id}, rate) when is_number(rate) do
    <<bucket::unsigned-big-32, _rest::binary>> = :crypto.hash(:sha256, id)
    bucket / 4_294_967_296 < rate
  end

  @spec store_opts(keyword()) :: keyword()
  defp store_opts(config) do
    configured = Keyword.get(config, :store_opts, [])
    passthrough = Keyword.drop(config, @recorder_keys)
    Keyword.merge(passthrough, configured)
  end
end
