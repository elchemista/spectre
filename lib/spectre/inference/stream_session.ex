defmodule Spectre.Inference.StreamSession do
  @moduledoc false

  @behaviour :gen_statem

  alias Spectre.Determinism
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Failure
  alias Spectre.Inference.IncrementalSanitizer
  alias Spectre.Inference.Prepared
  alias Spectre.Inference.Progress
  alias Spectre.Inference.ProviderProtocol
  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.Response
  alias Spectre.Inference.StreamCapacity
  alias Spectre.Inference.StreamCheckpoint
  alias Spectre.Inference.StreamEvent
  alias Spectre.Inference.Usage
  alias Spectre.Inference.UsageAccounting
  alias Spectre.Invocation
  alias Spectre.Invocation.WorkerReceipt
  alias Spectre.Run.Value

  @default_attach_timeout 30_000
  @default_open_timeout 15_000
  @default_provider_stall_timeout 30_000
  @default_consumer_idle_timeout 30_000
  @default_max_duration :timer.minutes(5)
  @default_terminal_retention 60_000
  @default_max_transport_chunk_bytes 256_000
  @default_max_parser_residual_bytes 256_000
  @default_max_delta_bytes 64_000
  @default_max_response_bytes 1_000_000
  @default_max_buffer_events 64
  @default_max_buffer_bytes 256_000
  @default_max_events_per_transport_item 64
  @default_heartbeat_interval 1_000
  @default_max_awaiters 16
  @max_timer_delay 4_294_967_295

  @type state_name ::
          :awaiting_consumer
          | :opening
          | :streaming
          | :committing_terminal
          | :awaiting_result
          | :terminal
          | :superseded
          | :interrupted

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    invocation = Keyword.fetch!(opts, :invocation)

    %{
      id: {__MODULE__, invocation.id, invocation.stream_epoch},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) when is_list(opts) do
    invocation = Keyword.fetch!(opts, :invocation)
    registry = Keyword.get(opts, :registry, Spectre.Inference.StreamRegistry)
    key = {invocation.id, invocation.stream_epoch}
    name = {:via, Registry, {registry, key, registry_metadata(invocation)}}
    :gen_statem.start_link(name, __MODULE__, opts, [])
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    # This process owns a live provider transport. Trapping the supervisor's
    # orderly shutdown lets `terminate/3` release that external resource; an
    # untrapped `:shutdown` would terminate the process before the callback.
    Process.flag(:trap_exit, true)

    # Streaming attempts outlive the caller that dispatched them. Install the
    # deterministic port in this process so provider-facing IDs and wall-clock
    # observations are retained in the same terminal receipt as the result.
    :ok = Determinism.begin_capture(Keyword.get(opts, :determinism_opts, []))

    with {:ok, data} <- build_data(opts),
         :ok <-
           StreamCapacity.transfer(
             data.capacity_reservation,
             self(),
             data.capacity_server
           ) do
      monitor = Process.monitor(data.instance)
      max_timer = arm_max_duration(data)
      deadline_timer = arm_budget_deadline(data.budget_snapshot)

      data = %{
        data
        | instance_monitor: monitor,
          max_duration_timer: max_timer,
          budget_deadline_timer: deadline_timer
      }

      data = heartbeat(data, :awaiting_consumer)
      {:ok, :awaiting_consumer, data, [phase_timeout(data, :attach)]}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl :gen_statem
  def handle_event(
        {:call, from},
        {:next, token, consumer, claim, demand},
        :awaiting_consumer,
        data
      ) do
    with :ok <- authorize(data, token),
         :ok <- valid_demand(demand),
         :ok <- attachable_consumer(data, consumer, claim) do
      monitor = Process.monitor(consumer)

      data = %{
        data
        | consumer: consumer,
          consumer_claim: claim,
          consumer_monitor: monitor,
          pending_next: %{from: from, demand: demand}
      }

      data = heartbeat(data, :opening)

      {:next_state, :opening, data, [{:next_event, :internal, :open}, phase_timeout(data, :open)]}
    else
      {:error, :already_consumed} ->
        {:keep_state_and_data, [{:reply, from, {:ok, [control_event(data, :already_consumed)]}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:next, token, consumer, claim, demand}, state, data)
      when state in [:opening, :streaming, :committing_terminal, :awaiting_result] do
    with :ok <- authorize(data, token),
         :ok <- valid_demand(demand),
         :ok <- same_consumer(data, consumer, claim),
         :ok <- no_pending_next(data) do
      data = %{data | pending_next: %{from: from, demand: demand}}
      continue_after_demand(state, data)
    else
      {:error, :already_consumed} ->
        {:keep_state_and_data, [{:reply, from, {:ok, [control_event(data, :already_consumed)]}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:next, token, consumer, claim, demand}, state, data)
      when state in [:terminal, :superseded, :interrupted] do
    with :ok <- authorize(data, token),
         :ok <- valid_demand(demand),
         {:ok, data} <- attach_terminal_consumer(data, consumer, claim) do
      case take_batch(data, demand) do
        {[], data} ->
          event = data.terminal_event || control_event(data, terminal_kind(state))
          {:keep_state, data, [{:reply, from, {:ok, [event]}}]}

        {events, data} ->
          {:keep_state, data, [{:reply, from, {:ok, events}}]}
      end
    else
      {:error, :already_consumed} ->
        {:keep_state_and_data, [{:reply, from, {:ok, [control_event(data, :already_consumed)]}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:cancel, token, reason}, state, data) do
    case authorize(data, token) do
      :ok when state in [:terminal, :superseded, :interrupted] ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      :ok when state in [:committing_terminal, :awaiting_result] ->
        {:keep_state_and_data, [{:reply, from, {:error, :invocation_terminal}}]}

      :ok ->
        {cancel_status, data} = cancel_provider(data, reason)

        data =
          begin_terminal_receipt(data, {:error, {:cancelled, reason}}, :cancelled, cancel_status)

        {:next_state, :committing_terminal, data,
         [{:reply, from, :ok}, phase_timeout(data, :commit)]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event(
        {:call, from},
        {:await_result, token, awaiter_ref},
        :awaiting_consumer,
        data
      ) do
    with :ok <- authorize(data, token),
         :ok <- valid_awaiter_ref(awaiter_ref),
         :ok <- result_waiter_capacity(data) do
      data =
        data
        |> Map.put(:consumer, :result_only)
        |> Map.put(:consumer_claim, :result_only)
        |> Map.put(:result_only?, true)
        |> add_result_waiter(from, awaiter_ref)
        |> heartbeat(:opening)

      {:next_state, :opening, data, [{:next_event, :internal, :open}, phase_timeout(data, :open)]}
    else
      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event({:call, from}, {:await_result, token, awaiter_ref}, _state, data) do
    case authorize(data, token) do
      :ok ->
        await_result_reply(data, from, awaiter_ref)

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def handle_event(
        :cast,
        {:abandon_result_waiter, token, awaiter_ref},
        state,
        data
      ) do
    with :ok <- authorize(data, token),
         :ok <- valid_awaiter_ref(awaiter_ref) do
      data = drop_result_waiter(data, awaiter_ref)
      cancel_unobserved_result_only(state, data)
    else
      {:error, _reason} -> {:keep_state_and_data, []}
    end
  end

  def handle_event(:internal, :open, :opening, data) do
    opts =
      data.prepared.provider_opts
      |> Keyword.merge(data.prepared.stream_adapter_opts)
      |> Keyword.put(:max_transport_chunk_bytes, data.max_transport_chunk_bytes)
      |> Keyword.put(:max_parser_residual_bytes, data.max_parser_residual_bytes)
      |> Keyword.put(:model, data.prepared.selection.model)
      |> Keyword.delete(:fallback)

    case open_provider(data, opts) do
      {:ok, adapter_state, metadata} when is_map(metadata) ->
        data = %{
          data
          | adapter_state: adapter_state,
            provider_metadata: sanitize_provider_metadata(metadata),
            provider_started?: true
        }

        # `open/2` only initiates the provider transport. Keep the state in
        # :opening until the first owned transport item arrives so the connect
        # timeout measures a real provider signal rather than callback return.
        data = heartbeat(data, :opening)
        continue_opening(data)

      {:error, reason} ->
        data = begin_terminal_receipt(data, {:error, reason}, :failed, :not_started)
        {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}

      reply ->
        reason = {:invalid_stream_adapter_open_reply, reply_class(reply)}
        data = begin_terminal_receipt(data, {:error, reason}, :failed, :ambiguous)
        {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
    end
  end

  def handle_event(:state_timeout, :attach_timeout, :awaiting_consumer, data) do
    data =
      begin_terminal_receipt(
        data,
        {:error, :consumer_never_attached},
        :cancelled_before_provider_start,
        :not_started
      )

    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(:state_timeout, :open_timeout, :opening, data) do
    {cancel_status, data} = cancel_provider(data, :provider_open_timeout)
    data = begin_terminal_receipt(data, {:error, :provider_open_timeout}, :failed, cancel_status)
    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(:state_timeout, :provider_stall_timeout, :streaming, data) do
    {cancel_status, data} = cancel_provider(data, :provider_stall_timeout)
    data = begin_terminal_receipt(data, {:error, :provider_stall_timeout}, :failed, cancel_status)
    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(:state_timeout, :consumer_idle_timeout, :streaming, data) do
    {cancel_status, data} = cancel_provider(data, :consumer_too_slow)
    data = begin_terminal_receipt(data, {:error, :consumer_too_slow}, :failed, cancel_status)
    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(:state_timeout, :commit_timeout, :committing_terminal, data) do
    data = terminate_locally(data, :ambiguous, :terminal_commit_timeout)
    {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
  end

  def handle_event(:state_timeout, :result_timeout, :awaiting_result, data) do
    data = terminate_locally(data, :failed, :stream_result_timeout)
    {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
  end

  def handle_event(:state_timeout, :terminal_retention, state, data)
      when state in [:terminal, :superseded, :interrupted] do
    {:stop, :normal, data}
  end

  def handle_event(:info, :stream_max_duration, state, data)
      when state in [:awaiting_consumer, :opening, :streaming] do
    if Determinism.monotonic_time(:millisecond) < data.max_duration_deadline do
      {:keep_state, %{data | max_duration_timer: arm_max_duration(data)}}
    else
      {cancel_status, data} = cancel_provider(data, :stream_max_duration_exceeded)

      data =
        begin_terminal_receipt(
          data,
          {:error, :stream_max_duration_exceeded},
          :failed,
          cancel_status
        )

      {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
    end
  end

  def handle_event(:info, :stream_budget_deadline, state, data)
      when state in [:awaiting_consumer, :opening, :streaming] do
    deadline = data.budget_snapshot.deadline_at

    if Determinism.system_time(:millisecond) < deadline do
      # `Process.send_after/3` has a finite portable range. Long budget
      # deadlines are armed in bounded chunks and rechecked against the
      # original absolute deadline without weakening the hard limit.
      timer = arm_budget_deadline(data.budget_snapshot)
      {:keep_state, %{data | budget_deadline_timer: timer}}
    else
      {cancel_status, data} = cancel_provider(data, :inference_deadline_exceeded)

      data =
        begin_terminal_receipt(
          data,
          {:error, :inference_deadline_exceeded},
          :failed,
          cancel_status
        )

      {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
    end
  end

  def handle_event(
        :info,
        {:spectre, :stream_attempt_committed, invocation_id, %Response{} = response},
        :committing_terminal,
        %{invocation: %{id: invocation_id}} = data
      ) do
    case Response.validate(response) do
      :ok ->
        # Terminal control events have two reserved slots outside the bounded
        # content capacity, so a full delta queue can still drain in order.
        data = enqueue_terminal_event(data, public_event(data, :inference_completed, response))
        data = flush_result_or_pending(data)
        {:next_state, :awaiting_result, data, [phase_timeout(data, :result)]}

      {:error, reason} ->
        data = terminate_locally(data, :failed, reason)
        {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
    end
  end

  def handle_event(
        :info,
        {:spectre, :stream_attempt_failed, invocation_id, reason},
        state,
        %{invocation: %{id: invocation_id}} = data
      )
      when state in [
             :awaiting_consumer,
             :opening,
             :streaming,
             :committing_terminal,
             :awaiting_result
           ] do
    data = terminate_locally(data, failure_kind(reason), reason)
    {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
  end

  def handle_event(
        :info,
        {:spectre, :stream_result, invocation_id, {:ok, result}},
        :awaiting_result,
        %{invocation: %{id: invocation_id}} = data
      ) do
    data = complete_result(data, {:ok, result}, :result)
    {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
  end

  def handle_event(
        :info,
        {:spectre, :stream_result, invocation_id, {:error, reason}},
        :awaiting_result,
        %{invocation: %{id: invocation_id}} = data
      ) do
    data = complete_result(data, {:error, reason}, failure_kind(reason))
    {:next_state, :terminal, data, [phase_timeout(data, :terminal)]}
  end

  def handle_event(
        :info,
        {:spectre, :stream_superseded, invocation_id, metadata},
        state,
        %{invocation: %{id: invocation_id}} = data
      )
      when state in [:awaiting_consumer, :opening, :streaming, :committing_terminal] do
    {_cancel_status, data} = cancel_provider(data, :superseded)
    data = complete_result(data, {:error, :superseded}, :superseded, metadata)
    {:next_state, :superseded, data, [phase_timeout(data, :terminal)]}
  end

  # Duplicate or late Instance notifications are expected around terminal
  # commit/reply hand-off. They must not append another terminal event or
  # renew the bounded retention timeout.
  def handle_event(
        :info,
        {:spectre, kind, invocation_id, _payload},
        state,
        %{invocation: %{id: invocation_id}} = data
      )
      when kind in [:stream_attempt_failed, :stream_result, :stream_superseded] and
             state in [:terminal, :superseded, :interrupted],
      do: {:keep_state, data}

  def handle_event(
        :info,
        {:spectre, :stream_result, invocation_id, _result},
        _state,
        %{invocation: %{id: invocation_id}} = data
      ),
      do: {:keep_state, data}

  def handle_event(
        :info,
        {:spectre, :stream_cancel_committed, invocation_id, reason, command_id},
        state,
        %{invocation: %{id: invocation_id}} = data
      )
      when state in [:awaiting_consumer, :opening, :streaming] do
    {cancel_status, data} = cancel_provider(data, reason)

    data =
      data
      |> Map.put(:control_command_digest, provider_digest(command_id))
      |> begin_terminal_receipt({:error, {:cancelled, reason}}, :cancelled, cancel_status)

    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(
        :info,
        {:spectre, :stream_cancel_committed, invocation_id, _reason, _command_id},
        _state,
        %{invocation: %{id: invocation_id}} = data
      ),
      do: {:keep_state, data}

  def handle_event(
        :info,
        {:DOWN, monitor, :process, pid, reason},
        state,
        %{instance_monitor: monitor, instance: pid} = data
      ) do
    {_cancel_status, data} = cancel_provider(data, :instance_down)

    data =
      complete_result(data, {:error, :interrupted}, :interrupted, %{reason: reason_class(reason)})

    if state in [:terminal, :superseded, :interrupted] do
      {:keep_state, data}
    else
      {:next_state, :interrupted, data, [phase_timeout(data, :terminal)]}
    end
  end

  def handle_event(
        :info,
        {:DOWN, monitor, :process, pid, reason},
        state,
        %{consumer_monitor: monitor, consumer: pid} = data
      )
      when state in [:opening, :streaming] do
    {cancel_status, data} = cancel_provider(data, :consumer_down)

    data =
      begin_terminal_receipt(
        data,
        {:error, {:consumer_down, reason_class(reason)}},
        :cancelled,
        cancel_status
      )

    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  def handle_event(:info, {:DOWN, monitor, :process, _pid, _reason}, state, data) do
    case drop_result_waiter_by_monitor(data, monitor) do
      {:ok, data} -> cancel_unobserved_result_only(state, data)
      :error -> {:keep_state, data}
    end
  end

  def handle_event(:info, {:stream_transport_request_failed, reason}, state, data)
      when state in [:opening, :streaming] do
    {cancel_status, data} = cancel_provider(data, reason)
    failure = {:provider_stream_request_failed, reason}
    data = begin_terminal_receipt(data, {:error, failure}, :failed, cancel_status)

    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  # All remaining messages while opening/streaming are offered to the provider
  # adapter. The adapter explicitly distinguishes unowned mailbox traffic from
  # a consumed transport item that happened to produce no logical events.
  # The Instance never forwards raw deltas through its own mailbox.
  def handle_event(:info, message, state, data) when state in [:opening, :streaming] do
    case safe_adapter_call(data.adapter, :handle_transport, [message, data.adapter_state]) do
      {:ok, events, adapter_state} when is_list(events) ->
        # A normalized reply consumes exactly one requested transport item,
        # even when it contains no logical event.
        data = %{data | adapter_state: adapter_state, transport_pending?: false}

        with :ok <- ProviderProtocol.validate_batch(events, data.max_events_per_transport_item),
             {:ok, next_state, data} <- apply_provider_events(events, data) do
          continue_after_transport(state, next_state, data, events)
        else
          {:error, reason} ->
            {cancel_status, data} = cancel_provider(data, reason)
            data = begin_terminal_receipt(data, {:error, reason}, :failed, cancel_status)

            {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
        end

      {:ignore, adapter_state} ->
        # Unowned mailbox traffic must not release pull credit: doing so could
        # issue a second `request_transport_item/1` while the first is live.
        continue_after_ignored_transport(state, %{data | adapter_state: adapter_state})

      {:error, reason, adapter_state} ->
        data = %{data | adapter_state: adapter_state}
        {cancel_status, data} = cancel_provider(data, reason)
        data = begin_terminal_receipt(data, {:error, reason}, :failed, cancel_status)

        {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}

      reply ->
        reason = {:invalid_stream_adapter_transport_reply, reply_class(reply)}
        {cancel_status, data} = cancel_provider(data, reason)
        data = begin_terminal_receipt(data, {:error, reason}, :failed, cancel_status)

        {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
    end
  end

  def handle_event(:info, _message, _state, data), do: {:keep_state, data}

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    cancel_timer(data.max_duration_timer)
    cancel_timer(data.budget_deadline_timer)

    if data.provider_started? and is_nil(data.terminal_outcome) do
      _ = cancel_provider(data, :session_terminated)
    end

    :ok
  end

  defp await_result_reply(%{result: {:ok, result}}, from, _awaiter_ref),
    do: {:keep_state_and_data, [{:reply, from, {:ok, result}}]}

  defp await_result_reply(%{result: {:error, reason}}, from, _awaiter_ref),
    do: {:keep_state_and_data, [{:reply, from, {:error, reason}}]}

  defp await_result_reply(%{result: nil} = data, from, awaiter_ref) do
    with :ok <- valid_awaiter_ref(awaiter_ref),
         :ok <- result_waiter_capacity(data) do
      {:keep_state, add_result_waiter(data, from, awaiter_ref)}
    else
      {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp build_data(opts) do
    with %Invocation{kind: :inference} = invocation <- Keyword.get(opts, :invocation),
         :ok <- Invocation.validate(invocation),
         %Prepared{stream_adapter: adapter} = prepared <- Keyword.get(opts, :prepared),
         true <- is_atom(adapter) and not is_nil(adapter),
         true <- Keyword.keyword?(prepared.provider_opts),
         true <- Keyword.keyword?(prepared.stream_adapter_opts),
         instance when is_pid(instance) <- Keyword.get(opts, :instance),
         token when is_binary(token) and token != "" <- Keyword.get(opts, :consumer_token),
         reservation when not is_nil(reservation) <- Keyword.get(opts, :capacity_reservation),
         capability when is_reference(capability) <- Keyword.get(opts, :capability),
         generation when is_binary(generation) and generation != "" <-
           Keyword.get(opts, :generation),
         dispatch_id when is_binary(dispatch_id) and dispatch_id != "" <-
           Keyword.get(opts, :dispatch_id),
         :ok <- validate_budget_snapshot(Keyword.get(opts, :budget_snapshot)),
         {:ok, config} <- stream_config(prepared, opts) do
      started_at = Determinism.monotonic_time(:millisecond)

      {recovery_usage, recovery_usage_quality} =
        UsageAccounting.initialize(
          recovery_usage(opts),
          recovery_usage_quality(opts),
          Keyword.get(opts, :budget_snapshot)
        )

      data =
        Map.merge(config, %{
          adapter: adapter,
          adapter_state: nil,
          budget_snapshot: Keyword.get(opts, :budget_snapshot),
          capacity_reservation: reservation,
          capacity_server: Keyword.get(opts, :capacity_server, StreamCapacity),
          capability: capability,
          consumer: nil,
          consumer_claim: nil,
          consumer_monitor: nil,
          result_only?: false,
          consumer_token: token,
          control_command_digest: nil,
          dispatch_id: dispatch_id,
          generation: generation,
          instance: instance,
          instance_monitor: nil,
          invocation: invocation,
          prepared: prepared,
          provider_metadata: %{},
          provider_request_id: recovery_value(opts, :provider_request_id),
          provider_request_digest: provider_digest(recovery_value(opts, :provider_request_id)),
          provider_sequence: recovery_provider_sequence(opts),
          provider_event_seen?: false,
          provider_started?: false,
          resume_cursor: recovery_value(opts, :resume_cursor),
          resume_cursor_digest: provider_digest(recovery_value(opts, :resume_cursor)),
          open_mode: recovery_open_mode(opts),
          sequence: 0,
          queue: [],
          queue_bytes: 0,
          pending_next: nil,
          transport_pending?: false,
          # A resumed session starts from the last durable usage floor. Adapter
          # events remain cumulative for the logical attempt, so `Usage.merge/2`
          # cannot regress accounting after an Instance restart.
          usage: recovery_usage,
          duration_floor: recovery_usage.duration_ms,
          started_at: started_at,
          max_duration_deadline: started_at + config.max_duration_ms,
          usage_quality: recovery_usage_quality,
          output_bytes: recovery_output_bytes(opts),
          sanitizer:
            IncrementalSanitizer.new(
              sanitize_reply: Keyword.get(prepared.provider_opts, :sanitize_reply, true),
              max_sanitizer_lookahead_bytes: config.max_sanitizer_lookahead_bytes
            ),
          terminal_outcome: nil,
          terminal_event: nil,
          capacity_released?: false,
          result: nil,
          result_waiters: [],
          last_heartbeat_at: nil,
          max_duration_timer: nil,
          budget_deadline_timer: nil
        })

      {:ok, data}
    else
      false -> {:error, :invalid_stream_session_adapter}
      nil -> {:error, :invalid_stream_session_options}
      _invalid -> {:error, :invalid_stream_session_options}
    end
  rescue
    exception -> {:error, {:invalid_stream_session_options, exception.__struct__}}
  end

  defp stream_config(prepared, opts) do
    source = Keyword.merge(prepared.provider_opts, opts)

    fields = [
      attach_timeout: {:stream_attach_timeout, @default_attach_timeout},
      open_timeout: {:stream_open_timeout, @default_open_timeout},
      provider_stall_timeout: {:stream_provider_stall_timeout, @default_provider_stall_timeout},
      consumer_idle_timeout: {:stream_consumer_idle_timeout, @default_consumer_idle_timeout},
      max_duration_ms: {:stream_max_duration_ms, @default_max_duration},
      terminal_retention: {:stream_terminal_retention, @default_terminal_retention},
      result_timeout: {:stream_result_timeout, @default_terminal_retention},
      max_transport_chunk_bytes:
        {:stream_max_transport_chunk_bytes, @default_max_transport_chunk_bytes},
      max_parser_residual_bytes:
        {:stream_max_parser_residual_bytes, @default_max_parser_residual_bytes},
      max_delta_bytes: {:stream_max_delta_bytes, @default_max_delta_bytes},
      max_response_bytes: {:model_reply_max_bytes, @default_max_response_bytes},
      max_buffer_events: {:stream_max_buffer_events, @default_max_buffer_events},
      max_buffer_bytes: {:stream_max_buffer_bytes, @default_max_buffer_bytes},
      max_events_per_transport_item:
        {:stream_max_events_per_transport_item, @default_max_events_per_transport_item},
      heartbeat_interval: {:inference_heartbeat_interval, @default_heartbeat_interval},
      max_awaiters: {:stream_max_awaiters, @default_max_awaiters},
      max_sanitizer_lookahead_bytes:
        {:max_sanitizer_lookahead_bytes, IncrementalSanitizer.new().max_lookahead_bytes}
    ]

    with {:ok, config} <-
           Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
             put_stream_config(source, field, acc)
           end),
         :ok <- validate_state_timeout_ranges(config) do
      {:ok, config}
    end
  end

  defp put_stream_config(source, {field, {key, default}}, acc) do
    value = Keyword.get(source, key, default)

    if is_integer(value) and value > 0 do
      {:cont, {:ok, Map.put(acc, field, value)}}
    else
      {:halt, {:error, {:invalid_stream_option, key, value}}}
    end
  end

  # Calls made while a phase is already in progress must not renew that
  # phase's deadline. A `:state_timeout` survives same-state callbacks unless
  # it is explicitly replaced, so returning no timeout action preserves the
  # deadline armed when the state was entered.
  defp continue_after_demand(:opening, data), do: {:keep_state, data}

  defp continue_after_demand(:committing_terminal, data) do
    {data, actions} = flush_pending(data)
    {:keep_state, data, actions}
  end

  defp continue_after_demand(:awaiting_result, data) do
    {data, actions} = flush_pending(data)
    {:keep_state, data, actions}
  end

  defp continue_after_demand(:streaming, data), do: continue_streaming(data, :demand)

  defp continue_opening(data) do
    # Returning `:keep_state` without a state-timeout action preserves the
    # original open deadline while another pull item is requested.
    {:keep_state, maybe_request_transport(data)}
  end

  defp continue_after_transport(:opening, :streaming, data, []) do
    continue_opening(data)
  end

  defp continue_after_transport(_current, next_state, data, events) do
    data =
      if events == [],
        do: data,
        else: heartbeat(data, progress_state(next_state))

    continue_after_provider(next_state, data, events != [])
  end

  defp continue_after_ignored_transport(:opening, data), do: {:keep_state, data}

  defp continue_after_ignored_transport(:streaming, data),
    do: continue_streaming(data, :ignored)

  defp continue_streaming(data, reason) do
    pending_before? = not is_nil(data.pending_next)
    {data, replies} = flush_pending(data)
    data = maybe_request_transport(data)
    timeouts = stream_timeout_actions(data, pending_before?, reason)
    {:next_state, :streaming, data, replies ++ timeouts}
  end

  defp continue_after_provider(:streaming, data, true),
    do: continue_streaming(data, :provider_progress)

  defp continue_after_provider(:streaming, data, false),
    do: continue_streaming(data, :ignored)

  defp continue_after_provider(:committing_terminal, data, _progress?) do
    {data, replies} = flush_pending(data)

    {:next_state, :committing_terminal, data, replies ++ [phase_timeout(data, :commit)]}
  end

  defp maybe_request_transport(%{pending_next: nil, result_only?: false} = data), do: data
  defp maybe_request_transport(%{transport_pending?: true} = data), do: data

  defp maybe_request_transport(data) do
    if MapSet.member?(data.prepared.stream_capabilities, :pull_transport) do
      case safe_adapter_call(data.adapter, :request_transport_item, [data.adapter_state]) do
        {:ok, adapter_state} ->
          %{data | adapter_state: adapter_state, transport_pending?: true}

        {:error, reason} ->
          send(self(), {:stream_transport_request_failed, reason})
          data

        reply ->
          send(self(), {:stream_transport_request_failed, {:invalid_reply, reply_class(reply)}})
          data
      end
    else
      data
    end
  end

  defp apply_provider_events(events, data) do
    Enum.reduce_while(events, {:ok, :streaming, data}, fn event, {:ok, state, acc} ->
      with :ok <-
             ProviderProtocol.validate_sequence(acc.provider_sequence, event.provider_sequence),
           {:ok, next_state, next} <- apply_provider_event(event, state, acc) do
        next = %{
          next
          | provider_sequence:
              ProviderProtocol.next_sequence(acc.provider_sequence, event.provider_sequence)
        }

        {:cont, {:ok, next_state, next}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_provider_event(
         %ProviderEvent{kind: :started} = event,
         :streaming,
         %{provider_event_seen?: false} = data
       ) do
    provider_request_id = event.provider_request_id || data.provider_request_id
    resume_cursor = event.cursor || data.resume_cursor

    data = %{
      data
      | provider_request_id: provider_request_id,
        provider_request_digest: provider_digest(provider_request_id),
        resume_cursor: resume_cursor,
        resume_cursor_digest: provider_digest(resume_cursor),
        provider_event_seen?: true
    }

    {:ok, :streaming, data}
  end

  defp apply_provider_event(%ProviderEvent{kind: :started}, :streaming, _data),
    do: {:error, :provider_started_event_out_of_order}

  defp apply_provider_event(%ProviderEvent{kind: :delta, payload: text} = event, :streaming, data) do
    with :ok <- validate_delta(text, data.max_delta_bytes),
         {:ok, clean, sanitizer} <- IncrementalSanitizer.push(data.sanitizer, text) do
      output_bytes = data.output_bytes + byte_size(text)

      {usage, usage_quality} =
        UsageAccounting.merge_stream(
          data.usage,
          [event.usage],
          data.budget_snapshot,
          data.usage_quality,
          event.usage_quality,
          output_bytes: output_bytes
        )

      output_bytes = usage.output_bytes

      data = %{
        data
        | sanitizer: sanitizer,
          output_bytes: output_bytes,
          usage: usage,
          usage_quality: usage_quality,
          provider_event_seen?: true,
          resume_cursor: event.cursor || data.resume_cursor,
          resume_cursor_digest: provider_digest(event.cursor) || data.resume_cursor_digest
      }

      with :ok <- check_budget(data),
           {:ok, data} <- enqueue_delta(data, clean) do
        {:ok, :streaming, data}
      end
    end
  end

  defp apply_provider_event(%ProviderEvent{kind: :usage} = event, :streaming, data) do
    {usage, usage_quality} =
      UsageAccounting.merge_stream(
        data.usage,
        [event.usage],
        data.budget_snapshot,
        data.usage_quality,
        event.usage_quality
      )

    data = %{
      data
      | usage: usage,
        output_bytes: usage.output_bytes,
        usage_quality: usage_quality,
        provider_event_seen?: true
    }

    with :ok <- check_budget(data),
         {:ok, data} <- enqueue_event(data, public_event(data, :usage, usage, usage: usage)) do
      {:ok, :streaming, data}
    end
  end

  defp apply_provider_event(
         %ProviderEvent{kind: :completed, payload: %Response{} = response} = event,
         :streaming,
         data
       ) do
    with :ok <- validate_completed_response(response, data.max_response_bytes),
         {:ok, trailing, sanitizer} <- IncrementalSanitizer.finish(data.sanitizer) do
      {usage, usage_quality} =
        UsageAccounting.merge_stream(
          data.usage,
          [event.usage, response.usage],
          data.budget_snapshot,
          data.usage_quality,
          event.usage_quality,
          output_bytes: byte_size(response.text)
        )

      data = %{
        data
        | sanitizer: sanitizer,
          provider_event_seen?: true,
          usage: usage,
          output_bytes: usage.output_bytes,
          usage_quality: usage_quality
      }

      with :ok <- check_budget(data),
           {:ok, data} <- enqueue_delta(data, trailing) do
        response = %{response | usage: Usage.to_map(data.usage)}

        {:ok, :committing_terminal,
         begin_terminal_receipt(data, {:ok, response}, :completed, :confirmed)}
      end
    end
  end

  defp apply_provider_event(%ProviderEvent{kind: :failed, payload: reason}, :streaming, data) do
    data = %{data | provider_event_seen?: true}

    {:ok, :committing_terminal,
     begin_terminal_receipt(data, {:error, reason}, :failed, :confirmed)}
  end

  defp apply_provider_event(%ProviderEvent{}, _state, _data),
    do: {:error, :provider_event_after_terminal}

  defp apply_provider_event(_event, _state, _data), do: {:error, :invalid_provider_event}

  defp begin_terminal_receipt(data, outcome, semantic, remote_status) do
    data = update_duration(data)
    outcome = Failure.sanitize_outcome(outcome)

    if is_nil(data.terminal_outcome) do
      receipt = %WorkerReceipt{
        invocation_id: data.invocation.id,
        run_id: data.invocation.run_id,
        run_revision: data.invocation.run_revision,
        generation: data.generation,
        dispatch_id: data.dispatch_id,
        capability: data.capability,
        kind: :inference,
        attempt_id: data.invocation.attempt_id,
        control_revision: data.invocation.control_revision,
        stream_epoch: data.invocation.stream_epoch,
        sequence: data.sequence,
        provider_started: data.provider_started?,
        usage: Usage.to_map(data.usage),
        usage_quality: data.usage_quality,
        outcome: outcome,
        metadata: %{
          semantic: semantic,
          remote_status: remote_status,
          provider_request_digest: data.provider_request_digest,
          resume_cursor_digest: data.resume_cursor_digest,
          control_command_digest: data.control_command_digest,
          nondeterminism_samples: Determinism.samples()
        }
      }

      send(data.instance, {:spectre, :invocation_result, data.invocation.id, receipt})
      %{data | terminal_outcome: outcome}
    else
      data
    end
  end

  defp enqueue_delta(data, ""), do: {:ok, data}

  defp enqueue_delta(data, text) do
    enqueue_event(
      data,
      public_event(data, :delta, text,
        content_class: if(data.sanitizer.sanitize?, do: :provisional, else: :unsanitized)
      )
    )
  end

  defp enqueue_event(data, %StreamEvent{} = event) do
    bytes = event_bytes(event)

    cond do
      data.result_only? ->
        # `await_result/2` drives the normal provider, budget and sanitizer
        # path while intentionally exposing no provisional data-plane event.
        {:ok, %{data | sequence: max(data.sequence, event.sequence)}}

      length(data.queue) >= data.max_buffer_events ->
        {:error, :consumer_too_slow}

      data.queue_bytes + bytes > data.max_buffer_bytes ->
        {:error, :consumer_too_slow}

      true ->
        {:ok, append_event(data, event, bytes)}
    end
  end

  defp enqueue_terminal_event(data, %StreamEvent{} = event) do
    if data.result_only?,
      do: %{data | sequence: max(data.sequence, event.sequence)},
      else: append_event(data, event, event_bytes(event))
  end

  defp append_event(data, event, bytes) do
    %{
      data
      | queue: data.queue ++ [event],
        queue_bytes: data.queue_bytes + bytes,
        sequence: max(data.sequence, event.sequence)
    }
  end

  defp flush_pending(%{pending_next: nil} = data), do: {data, []}
  defp flush_pending(%{queue: []} = data), do: {data, []}

  defp flush_pending(data) do
    %{from: from, demand: demand} = data.pending_next
    {events, data} = take_batch(data, demand)
    {%{data | pending_next: nil}, [{:reply, from, {:ok, events}}]}
  end

  defp take_batch(data, demand) do
    {events, rest} = Enum.split(data.queue, demand)
    bytes = Enum.reduce(events, 0, &(&2 + event_bytes(&1)))
    {events, %{data | queue: rest, queue_bytes: max(data.queue_bytes - bytes, 0)}}
  end

  defp flush_result_or_pending(data) do
    {data, actions} = flush_pending(data)
    run_actions(actions)
    data
  end

  # This helper is used only for internal Instance notifications, outside a
  # state-machine return. Replies remain correlated through the stored From.
  defp run_actions(actions) do
    Enum.each(actions, fn
      {:reply, from, reply} -> :gen_statem.reply(from, reply)
      _other -> :ok
    end)
  end

  defp complete_result(data, result, kind, metadata \\ %{})

  defp complete_result(%{result: result} = data, _next_result, _kind, _metadata)
       when not is_nil(result),
       do: data

  defp complete_result(data, result, kind, metadata) do
    payload =
      case result do
        {:ok, value} -> value
        {:error, reason} -> reason
      end

    event = public_event(data, kind, payload, metadata: metadata)
    data = %{enqueue_terminal_event(data, event) | terminal_event: event, result: result}
    data = release_capacity(data)
    {data, actions} = flush_pending(data)
    run_actions(actions)
    reply_result_waiters(data.result_waiters, result)
    %{data | result_waiters: []}
  end

  defp terminate_locally(data, kind, reason),
    do: complete_result(data, {:error, reason}, kind)

  defp release_capacity(%{capacity_released?: true} = data), do: data

  defp release_capacity(data) do
    _ = safe_capacity_release(data.capacity_reservation, data.capacity_server)
    %{data | capacity_released?: true}
  end

  defp public_event(data, kind, payload, opts \\ []) do
    sequence = data.sequence + 1

    StreamEvent.new(kind,
      inference_id: data.invocation.inference_id,
      invocation_id: data.invocation.id,
      attempt_id: data.invocation.attempt_id,
      run_revision: data.invocation.run_revision,
      generation: data.generation,
      dispatch_id: data.dispatch_id,
      control_revision: data.invocation.control_revision,
      stream_epoch: data.invocation.stream_epoch,
      sequence: sequence,
      payload: payload,
      usage: Keyword.get(opts, :usage, data.usage),
      usage_quality: Keyword.get(opts, :usage_quality, data.usage_quality),
      content_class: Keyword.get(opts, :content_class, :control),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp control_event(data, kind), do: public_event(data, kind, kind)

  defp heartbeat(data, state) do
    data = update_duration(data)
    now = Determinism.monotonic_time(:millisecond)

    if is_nil(data.last_heartbeat_at) or
         now - data.last_heartbeat_at >= data.heartbeat_interval do
      progress =
        Progress.new(
          inference_id: data.invocation.inference_id,
          invocation_id: data.invocation.id,
          attempt_id: data.invocation.attempt_id,
          run_revision: data.invocation.run_revision,
          generation: data.generation,
          dispatch_id: data.dispatch_id,
          control_revision: data.invocation.control_revision,
          stream_epoch: data.invocation.stream_epoch,
          sequence: data.sequence,
          provider_request_digest: data.provider_request_digest,
          output_bytes: data.output_bytes,
          usage: data.usage,
          usage_quality: data.usage_quality,
          provider_cursor_digest: data.resume_cursor_digest,
          state: state,
          # Heartbeats are ephemeral liveness signals, not nondeterministic
          # boundaries that must be captured for replay.
          at: System.system_time(:millisecond)
        )

      checkpoint = stream_checkpoint(data)

      send(
        data.instance,
        {:spectre, :inference_heartbeat, data.invocation.id, progress, checkpoint}
      )

      %{data | last_heartbeat_at: now}
    else
      data
    end
  end

  defp cancel_provider(%{provider_started?: false} = data, _reason), do: {:not_started, data}

  defp cancel_provider(data, reason) do
    case safe_adapter_call(data.adapter, :cancel, [data.adapter_state, reason]) do
      :ok -> {:confirmed, data}
      {:error, _reason} -> {:ambiguous, data}
      _reply -> {:ambiguous, data}
    end
  end

  defp safe_adapter_call(module, function, args) do
    apply(module, function, args)
  rescue
    exception -> {:error, {:stream_adapter_exception, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:stream_adapter_failure, function, kind, reason_class(reason)}}
  end

  defp open_provider(%{open_mode: :open} = data, opts),
    do: safe_adapter_call(data.adapter, :open, [data.prepared.descriptor, opts])

  defp open_provider(%{open_mode: :resume, resume_cursor: cursor} = data, opts) do
    opts =
      opts
      |> Keyword.put(:resume_provider_request_id, data.provider_request_id)
      |> Keyword.put(:resume_usage, data.usage)
      |> Keyword.put(:resume_usage_quality, data.usage_quality)
      |> Keyword.put(:resume_output_bytes, data.output_bytes)
      |> Keyword.put(:resume_provider_sequence, data.provider_sequence)

    safe_adapter_call(data.adapter, :resume, [data.prepared.descriptor, cursor, opts])
  end

  defp recovery_open_mode(opts) do
    case Keyword.get(opts, :resume_from) do
      %{resume_cursor: cursor} when not is_nil(cursor) -> :resume
      _fresh -> :open
    end
  end

  defp recovery_value(opts, key) do
    case Keyword.get(opts, :resume_from) do
      recovery when is_map(recovery) -> Map.get(recovery, key)
      _fresh -> nil
    end
  end

  defp recovery_usage(opts), do: opts |> recovery_value(:usage) |> Usage.new()

  defp recovery_usage_quality(opts) do
    case recovery_value(opts, :usage_quality) do
      quality when quality in [:provider, :estimated, :unavailable] -> quality
      nil -> :unavailable
      quality -> raise ArgumentError, "invalid resumed stream usage quality: #{inspect(quality)}"
    end
  end

  defp recovery_output_bytes(opts) do
    usage = recovery_usage(opts)

    case recovery_value(opts, :output_bytes) do
      nil -> usage.output_bytes
      bytes when is_integer(bytes) and bytes >= 0 and bytes == usage.output_bytes -> bytes
      _invalid -> raise ArgumentError, "invalid resumed stream output byte count"
    end
  end

  defp recovery_provider_sequence(opts) do
    case recovery_value(opts, :provider_sequence) do
      nil -> nil
      sequence when is_integer(sequence) and sequence >= 0 -> sequence
      _invalid -> raise ArgumentError, "invalid resumed provider sequence"
    end
  end

  defp validate_budget_snapshot(nil), do: :ok

  defp validate_budget_snapshot(%BudgetSnapshot{} = snapshot),
    do: BudgetSnapshot.validate(snapshot)

  defp validate_budget_snapshot(_snapshot), do: {:error, :invalid_budget_snapshot}

  defp validate_completed_response(%Response{} = response, limit) do
    with :ok <- Response.validate(response) do
      if byte_size(response.text) <= limit,
        do: :ok,
        else: {:error, {:provider_response_too_large, byte_size(response.text), limit}}
    end
  end

  # Duration is local monotonic time plus the durable floor restored from the
  # previous session. It is never allowed to regress behind provider usage.
  defp update_duration(data) do
    elapsed = max(Determinism.monotonic_time(:millisecond) - data.started_at, 0)
    duration = max(data.usage.duration_ms, data.duration_floor + elapsed)
    %{data | usage: %{data.usage | duration_ms: duration}}
  end

  defp safe_capacity_release(reservation, server) do
    StreamCapacity.release(reservation, server)
  catch
    :exit, _reason -> :ok
  end

  defp validate_delta(text, limit)
       when is_binary(text) and byte_size(text) <= limit,
       do: :ok

  defp validate_delta(text, _limit) when is_binary(text), do: {:error, :provider_delta_too_large}
  defp validate_delta(_text, _limit), do: {:error, :invalid_provider_delta}

  defp check_budget(%{budget_snapshot: nil}), do: :ok

  defp check_budget(data) do
    current = update_duration(data)

    case BudgetSnapshot.exceeded(current.budget_snapshot, current.usage) do
      :ok -> :ok
      {:error, field} -> {:error, {:inference_budget_exceeded, field}}
    end
  end

  # There is exactly one active streaming deadline. Satisfying demand starts
  # the consumer-idle clock; outstanding demand starts (or, on real provider
  # progress, renews) the provider-stall clock. Ignored transport messages do
  # not buy either side more time.
  defp stream_timeout_actions(data, true, _reason) when is_nil(data.pending_next),
    do: [phase_timeout(data, :consumer_idle)]

  defp stream_timeout_actions(%{result_only?: true} = data, _pending_before?, reason)
       when reason in [:entered, :demand, :provider_progress],
       do: [phase_timeout(data, :provider_stall)]

  defp stream_timeout_actions(data, _pending_before?, reason)
       when not is_nil(data.pending_next) and
              reason in [:entered, :demand, :provider_progress],
       do: [phase_timeout(data, :provider_stall)]

  defp stream_timeout_actions(_data, _pending_before?, _reason), do: []

  defp phase_timeout(data, :attach),
    do: state_timeout(data.attach_timeout, :attach_timeout)

  defp phase_timeout(data, :open),
    do: state_timeout(data.open_timeout, :open_timeout)

  defp phase_timeout(data, :provider_stall),
    do: state_timeout(data.provider_stall_timeout, :provider_stall_timeout)

  defp phase_timeout(data, :consumer_idle),
    do: state_timeout(data.consumer_idle_timeout, :consumer_idle_timeout)

  defp phase_timeout(data, :commit),
    do: state_timeout(data.provider_stall_timeout, :commit_timeout)

  defp phase_timeout(data, :result),
    do: state_timeout(data.result_timeout, :result_timeout)

  defp phase_timeout(data, :terminal),
    do: state_timeout(data.terminal_retention, :terminal_retention)

  defp state_timeout(timeout, event), do: {:state_timeout, timeout, event}

  defp authorize(data, token) do
    if is_binary(token) and byte_size(token) == byte_size(data.consumer_token) and
         :crypto.hash_equals(data.consumer_token, token),
       do: :ok,
       else: {:error, :invalid_stream_consumer_token}
  rescue
    _exception -> {:error, :invalid_stream_consumer_token}
  end

  defp attachable_consumer(%{consumer: nil}, consumer, claim)
       when is_pid(consumer) and is_reference(claim),
       do: :ok

  defp attachable_consumer(_data, _consumer, _claim), do: {:error, :already_consumed}

  defp same_consumer(%{consumer: consumer, consumer_claim: claim}, consumer, claim)
       when is_pid(consumer) and is_reference(claim),
       do: :ok

  defp same_consumer(_data, _consumer, _claim), do: {:error, :already_consumed}

  defp attach_terminal_consumer(%{consumer: nil} = data, consumer, claim)
       when is_pid(consumer) and is_reference(claim) do
    {:ok,
     %{
       data
       | consumer: consumer,
         consumer_claim: claim,
         consumer_monitor: Process.monitor(consumer)
     }}
  end

  defp attach_terminal_consumer(data, consumer, claim) do
    case same_consumer(data, consumer, claim) do
      :ok -> {:ok, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_demand(demand) when is_integer(demand) and demand > 0, do: :ok
  defp valid_demand(_demand), do: {:error, :invalid_stream_demand}

  defp no_pending_next(%{pending_next: nil}), do: :ok
  defp no_pending_next(_data), do: {:error, :stream_next_already_pending}

  defp valid_awaiter_ref(ref) when is_reference(ref), do: :ok
  defp valid_awaiter_ref(_ref), do: {:error, :invalid_stream_awaiter}

  defp result_waiter_capacity(data) do
    if length(data.result_waiters) < data.max_awaiters,
      do: :ok,
      else: {:error, :stream_awaiter_capacity_reached}
  end

  defp add_result_waiter(data, from, ref) do
    pid = elem(from, 0)
    waiter = %{from: from, ref: ref, monitor: Process.monitor(pid)}
    %{data | result_waiters: [waiter | data.result_waiters]}
  end

  defp drop_result_waiter(data, ref) do
    {removed, retained} = Enum.split_with(data.result_waiters, &(&1.ref == ref))
    Enum.each(removed, &Process.demonitor(&1.monitor, [:flush]))
    %{data | result_waiters: retained}
  end

  defp drop_result_waiter_by_monitor(data, monitor) do
    case Enum.split_with(data.result_waiters, &(&1.monitor == monitor)) do
      {[], _retained} -> :error
      {_removed, retained} -> {:ok, %{data | result_waiters: retained}}
    end
  end

  defp cancel_unobserved_result_only(state, data)
       when state in [:opening, :streaming] and data.result_only? and
              data.result_waiters == [] do
    {cancel_status, data} = cancel_provider(data, :result_waiter_gone)

    data =
      begin_terminal_receipt(
        data,
        {:error, :result_waiter_gone},
        :cancelled,
        cancel_status
      )

    {:next_state, :committing_terminal, data, [phase_timeout(data, :commit)]}
  end

  defp cancel_unobserved_result_only(_state, data), do: {:keep_state, data}

  defp validate_state_timeout_ranges(config) do
    timeout_fields = [
      {:stream_attach_timeout, config.attach_timeout},
      {:stream_open_timeout, config.open_timeout},
      {:stream_provider_stall_timeout, config.provider_stall_timeout},
      {:stream_consumer_idle_timeout, config.consumer_idle_timeout},
      {:stream_terminal_retention, config.terminal_retention},
      {:stream_result_timeout, config.result_timeout}
    ]

    case Enum.find(timeout_fields, fn {_key, value} -> value > @max_timer_delay end) do
      nil -> :ok
      {key, value} -> {:error, {:invalid_stream_option, key, {:timer_too_large, value}}}
    end
  end

  defp arm_budget_deadline(nil), do: nil
  defp arm_budget_deadline(%BudgetSnapshot{deadline_at: nil}), do: nil

  defp arm_budget_deadline(%BudgetSnapshot{deadline_at: deadline}) do
    delay = max(deadline - Determinism.system_time(:millisecond), 0)
    Process.send_after(self(), :stream_budget_deadline, min(delay, @max_timer_delay))
  end

  defp arm_max_duration(data) do
    delay =
      max(
        data.max_duration_deadline - Determinism.monotonic_time(:millisecond),
        0
      )

    Process.send_after(self(), :stream_max_duration, min(delay, @max_timer_delay))
  end

  defp reply_result_waiters(waiters, result) do
    Enum.each(waiters, fn waiter ->
      Process.demonitor(waiter.monitor, [:flush])
      :gen_statem.reply(waiter.from, result)
    end)
  end

  defp event_bytes(%StreamEvent{kind: :delta, payload: text}) when is_binary(text),
    do: byte_size(text)

  defp event_bytes(_event), do: 0

  defp provider_digest(nil), do: nil
  defp provider_digest(value), do: Value.token("provider", value)

  defp stream_checkpoint(data) do
    max_bytes = Keyword.get(data.prepared.provider_opts, :stream_checkpoint_max_bytes, 32_000)

    case StreamCheckpoint.new(data.provider_request_id, data.resume_cursor,
           max_bytes: max_bytes,
           provider_sequence: data.provider_sequence,
           usage: data.usage,
           usage_quality: data.usage_quality,
           output_bytes: data.output_bytes
         ) do
      {:ok, checkpoint} -> checkpoint
      {:error, _reason} -> nil
    end
  end

  defp sanitize_provider_metadata(metadata) do
    metadata
    |> Map.drop([:provider_request_id, :cursor, "provider_request_id", "cursor"])
    |> case do
      portable when is_map(portable) ->
        if match?(:ok, Value.validate(portable)), do: portable, else: %{}
    end
  end

  defp progress_state(:streaming), do: :streaming
  defp progress_state(:committing_terminal), do: :committing

  defp terminal_kind(:superseded), do: :superseded
  defp terminal_kind(:interrupted), do: :interrupted
  defp terminal_kind(_state), do: :stream_expired

  defp failure_kind(:superseded), do: :superseded
  defp failure_kind(:interrupted), do: :interrupted
  defp failure_kind(:ambiguous), do: :ambiguous
  defp failure_kind({:cancelled, _reason}), do: :cancelled
  defp failure_kind({:inference_attempt_failed, _attempt, reason}), do: failure_kind(reason)
  defp failure_kind(_reason), do: :failed

  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class({reason, _detail}) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :error

  defp reply_class(reply) when is_tuple(reply), do: elem(reply, 0)
  defp reply_class(reply) when is_atom(reply), do: reply
  defp reply_class(_reply), do: :invalid

  defp cancel_timer(reference) when is_reference(reference), do: Process.cancel_timer(reference)
  defp cancel_timer(_reference), do: false

  defp registry_metadata(invocation) do
    %{
      inference_id: invocation.inference_id,
      invocation_id: invocation.id,
      stream_epoch: invocation.stream_epoch
    }
  end
end
