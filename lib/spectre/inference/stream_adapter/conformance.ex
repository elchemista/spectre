defmodule Spectre.Inference.StreamAdapter.Conformance do
  @moduledoc """
  Adapter-neutral checks for the normalized streaming protocol.

  Provider packages pass a portable inference descriptor and deterministic
  transport messages from an isolated fixture. The runner verifies capability
  negotiation, open/resume shape, pull-credit discipline, normalized event
  batches, global provider ordering, UTF-8 reassembly, terminal cardinality,
  optional cancel or reconcile replies, and mandatory enforcement of the raw
  transport-chunk and parser-residual bounds. Real network flow control,
  cancellation, and credentials remain adapter-owned integration tests.
  """

  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.ProviderProtocol
  alias Spectre.Inference.StreamAdapter
  alias Spectre.Inference.Usage
  alias Spectre.Inference.Utf8Buffer

  @default_max_events 64
  @default_max_delta_bytes 64_000
  @default_max_transport_chunk_bytes 256_000
  @default_max_parser_residual_bytes 256_000

  @type report :: %{
          required(:capabilities) => MapSet.t(atom()),
          required(:transport) => :pull | :push,
          required(:transport_requests) => non_neg_integer(),
          required(:transport_items) => non_neg_integer(),
          required(:ignored_messages) => non_neg_integer(),
          required(:events) => non_neg_integer(),
          required(:bounds) => %{
            max_transport_chunk_bytes: pos_integer(),
            max_parser_residual_bytes: pos_integer()
          },
          required(:bound_checks) => %{
            transport_chunk: :enforced,
            parser_residual: :enforced
          },
          required(:terminal) => atom() | nil,
          required(:cancel) => :not_exercised | :accepted | {:error, atom()},
          required(:reconcile) => :not_exercised | atom()
        }

  @doc """
  Runs the protocol contract over deterministic transport messages.

  Important options are `:profile`, `:adapter_opts`, `:open_mode`
  (`:open` or `{:resume, cursor}`), `:require_terminal?`, `:cancel_after?`,
  `:reconcile_provider_request_id`, `:max_events_per_transport_item`, and
  `:max_delta_bytes`. `:max_transport_chunk_bytes` and
  `:max_parser_residual_bytes` are mandatory adapter bounds with safe defaults.
  The adapter must implement `StreamAdapter.conformance_fixture/4`; the runner
  supplies an oversized binary and uses the returned fixture to prove both
  bounds through real `handle_transport/2` calls.
  """
  @spec run(module(), Descriptor.t(), [term()], keyword()) ::
          {:ok, report()} | {:error, term()}
  def run(adapter, descriptor, messages, opts \\ [])

  def run(adapter, %Descriptor{} = descriptor, messages, opts)
      when is_atom(adapter) and is_list(messages) and is_list(opts) do
    if Keyword.keyword?(opts) do
      do_run(adapter, descriptor, messages, opts)
    else
      failure(:options, :invalid_options)
    end
  end

  def run(_adapter, _descriptor, _messages, _opts),
    do: failure(:options, :invalid_arguments)

  defp do_run(adapter, descriptor, messages, opts) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    profile = Keyword.get(opts, :profile)

    with :ok <- valid_adapter_opts(adapter_opts),
         {:ok, bounds} <- stream_bounds(opts),
         adapter_opts <- put_spectre_bounds(adapter_opts, bounds),
         :ok <- Descriptor.validate(descriptor),
         {:ok, capabilities} <- validated_capabilities(adapter, profile, adapter_opts),
         {:ok, bound_checks} <-
           verify_adapter_bounds(adapter, descriptor, adapter_opts, bounds),
         {:ok, adapter_state, metadata} <-
           open_adapter(adapter, descriptor, capabilities, adapter_opts, opts),
         :ok <- valid_metadata(metadata),
         {:ok, protocol} <-
           consume_messages(adapter, adapter_state, capabilities, messages, opts),
         :ok <- require_terminal(protocol, opts),
         {:ok, cancel} <- maybe_cancel(adapter, protocol.adapter_state, opts),
         {:ok, reconcile} <-
           maybe_reconcile(adapter, descriptor, capabilities, adapter_opts, opts) do
      {:ok,
       %{
         capabilities: capabilities,
         transport: transport(capabilities),
         transport_requests: protocol.transport_requests,
         transport_items: protocol.transport_items,
         ignored_messages: protocol.ignored_messages,
         events: protocol.events,
         bounds: bounds,
         bound_checks: bound_checks,
         terminal: protocol.terminal,
         cancel: cancel,
         reconcile: reconcile
       }}
    else
      {:error, {:stream_adapter_conformance_failed, _phase, _reason}} = error -> error
      {:error, reason} -> failure(:protocol, reason)
    end
  end

  defp validated_capabilities(adapter, profile, adapter_opts) do
    case StreamAdapter.validate(adapter, profile, adapter_opts) do
      {:ok, capabilities} -> {:ok, capabilities}
      {:error, reason} -> failure(:capabilities, reason)
    end
  end

  defp verify_adapter_bounds(adapter, descriptor, adapter_opts, bounds) do
    with :ok <- require_bound_fixture_callback(adapter),
         :ok <-
           verify_adapter_bound(
             adapter,
             :transport_chunk,
             :transport_chunk_bound,
             descriptor,
             adapter_opts,
             bounds.max_transport_chunk_bytes
           ),
         :ok <-
           verify_adapter_bound(
             adapter,
             :parser_residual,
             :parser_residual_bound,
             descriptor,
             adapter_opts,
             bounds.max_parser_residual_bytes
           ) do
      {:ok, %{transport_chunk: :enforced, parser_residual: :enforced}}
    end
  end

  defp require_bound_fixture_callback(adapter) do
    if function_exported?(adapter, :conformance_fixture, 4),
      do: :ok,
      else:
        failure(
          :bounds,
          {:stream_adapter_callback_missing, adapter, :conformance_fixture, 4}
        )
  end

  defp verify_adapter_bound(adapter, kind, phase, descriptor, adapter_opts, limit) do
    oversized = :binary.copy("x", limit + 1)

    adapter
    |> safe_call(:conformance_fixture, [kind, oversized, descriptor, adapter_opts])
    |> verify_bound_fixture(adapter, phase, limit)
  end

  defp verify_bound_fixture({:ok, {:ok, message, adapter_state}}, adapter, phase, limit) do
    adapter
    |> safe_call(:handle_transport, [message, adapter_state])
    |> verify_bound_reply(phase, limit)
  end

  defp verify_bound_fixture({:ok, {:error, reason}}, _adapter, phase, _limit),
    do: failure(phase, {:fixture_error, reason_class(reason)})

  defp verify_bound_fixture({:ok, reply}, _adapter, phase, _limit),
    do: failure(phase, {:invalid_fixture_reply, value_class(reply)})

  defp verify_bound_fixture({:error, reason}, _adapter, phase, _limit),
    do: failure(phase, reason)

  defp verify_bound_reply(
         {:ok, {:error, :provider_stream_overflow, _adapter_state}},
         _phase,
         _limit
       ),
       do: :ok

  defp verify_bound_reply({:ok, {:error, reason, _adapter_state}}, phase, limit),
    do: failure(phase, {:unexpected_overflow_reason, reason_class(reason), limit})

  defp verify_bound_reply({:ok, reply}, phase, limit),
    do: failure(phase, {:bound_not_enforced, value_class(reply), limit})

  defp verify_bound_reply({:error, reason}, phase, _limit), do: failure(phase, reason)

  defp open_adapter(adapter, descriptor, capabilities, adapter_opts, opts) do
    case Keyword.get(opts, :open_mode, :open) do
      :open ->
        normalize_open_reply(safe_call(adapter, :open, [descriptor, adapter_opts]), :open)

      {:resume, cursor} ->
        if MapSet.member?(capabilities, :resume) do
          normalize_open_reply(
            safe_call(adapter, :resume, [descriptor, cursor, adapter_opts]),
            :resume
          )
        else
          failure(:resume, :capability_unavailable)
        end

      _invalid ->
        failure(:options, :invalid_open_mode)
    end
  end

  defp normalize_open_reply({:ok, {:ok, adapter_state, metadata}}, _phase),
    do: {:ok, adapter_state, metadata}

  defp normalize_open_reply({:ok, {:error, reason}}, phase),
    do: failure(phase, {:adapter_error, reason_class(reason)})

  defp normalize_open_reply({:ok, reply}, phase),
    do: failure(phase, {:invalid_reply, value_class(reply)})

  defp normalize_open_reply({:error, reason}, phase), do: failure(phase, reason)

  defp consume_messages(adapter, adapter_state, capabilities, messages, opts) do
    config = %{
      max_events: positive_option(opts, :max_events_per_transport_item, @default_max_events),
      max_delta_bytes: positive_option(opts, :max_delta_bytes, @default_max_delta_bytes)
    }

    with {:ok, max_events} <- config.max_events,
         {:ok, max_delta_bytes} <- config.max_delta_bytes do
      initial = %{
        adapter_state: adapter_state,
        pull?: MapSet.member?(capabilities, :pull_transport),
        outstanding?: false,
        transport_requests: 0,
        transport_items: 0,
        ignored_messages: 0,
        events: 0,
        terminal: nil,
        provider_event_seen?: false,
        provider_sequence: nil,
        usage: %Usage{},
        utf8: Utf8Buffer.new(),
        max_events: max_events,
        max_delta_bytes: max_delta_bytes
      }

      Enum.reduce_while(messages, {:ok, initial}, fn message, {:ok, protocol} ->
        consume_protocol_message(adapter, message, protocol)
      end)
    end
  end

  defp consume_protocol_message(adapter, message, protocol) do
    case consume_message(adapter, message, protocol) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp consume_message(_adapter, _message, %{terminal: terminal}) when not is_nil(terminal),
    do: failure(:events, :message_after_terminal)

  defp consume_message(adapter, message, protocol) do
    with {:ok, protocol} <- maybe_request_transport(adapter, protocol) do
      adapter
      |> safe_call(:handle_transport, [message, protocol.adapter_state])
      |> consume_transport_reply(protocol)
    end
  end

  defp consume_transport_reply({:ok, {:ignore, adapter_state}}, protocol) do
    {:ok,
     %{
       protocol
       | adapter_state: adapter_state,
         ignored_messages: protocol.ignored_messages + 1
     }}
  end

  defp consume_transport_reply({:ok, {:ok, events, adapter_state}}, protocol)
       when is_list(events) do
    protocol = %{
      protocol
      | adapter_state: adapter_state,
        outstanding?: false,
        transport_items: protocol.transport_items + 1
    }

    with :ok <- ProviderProtocol.validate_batch(events, protocol.max_events),
         {:ok, protocol} <- apply_events(events, protocol) do
      {:ok, protocol}
    else
      {:error, reason} -> failure(:events, reason)
    end
  end

  defp consume_transport_reply({:ok, {:error, reason, _adapter_state}}, _protocol),
    do: failure(:transport, {:adapter_error, reason_class(reason)})

  defp consume_transport_reply({:ok, reply}, _protocol),
    do: failure(:transport, {:invalid_reply, value_class(reply)})

  defp consume_transport_reply({:error, reason}, _protocol), do: failure(:transport, reason)

  defp maybe_request_transport(_adapter, %{pull?: false} = protocol), do: {:ok, protocol}
  defp maybe_request_transport(_adapter, %{outstanding?: true} = protocol), do: {:ok, protocol}

  defp maybe_request_transport(adapter, protocol) do
    case safe_call(adapter, :request_transport_item, [protocol.adapter_state]) do
      {:ok, {:ok, adapter_state}} ->
        {:ok,
         %{
           protocol
           | adapter_state: adapter_state,
             outstanding?: true,
             transport_requests: protocol.transport_requests + 1
         }}

      {:ok, {:error, reason}} ->
        failure(:demand, {:adapter_error, reason_class(reason)})

      {:ok, reply} ->
        failure(:demand, {:invalid_reply, value_class(reply)})

      {:error, reason} ->
        failure(:demand, reason)
    end
  end

  defp apply_events(events, protocol) do
    Enum.reduce_while(events, {:ok, protocol}, fn event, {:ok, current} ->
      case apply_event(event, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_event(%ProviderEvent{} = event, protocol) do
    with :ok <- global_event_order(event, protocol),
         :ok <-
           ProviderProtocol.validate_sequence(protocol.provider_sequence, event.provider_sequence),
         :ok <- validate_delta_size(event, protocol.max_delta_bytes),
         {:ok, utf8} <- validate_utf8(event, protocol.utf8) do
      terminal = if event.kind in [:completed, :failed], do: event.kind, else: nil

      {:ok,
       %{
         protocol
         | events: protocol.events + 1,
           terminal: terminal || protocol.terminal,
           provider_event_seen?: true,
           provider_sequence:
             ProviderProtocol.next_sequence(protocol.provider_sequence, event.provider_sequence),
           usage: Usage.merge(protocol.usage, event.usage),
           utf8: utf8
       }}
    end
  end

  defp global_event_order(%ProviderEvent{kind: :started}, %{provider_event_seen?: true}),
    do: {:error, :provider_started_event_out_of_order}

  defp global_event_order(%ProviderEvent{}, %{terminal: terminal}) when not is_nil(terminal),
    do: {:error, :provider_event_after_terminal}

  defp global_event_order(%ProviderEvent{}, _protocol), do: :ok

  defp validate_delta_size(%ProviderEvent{kind: :delta, payload: text}, limit) do
    if byte_size(text) <= limit,
      do: :ok,
      else: {:error, :provider_delta_too_large}
  end

  defp validate_delta_size(%ProviderEvent{}, _limit), do: :ok

  defp validate_utf8(%ProviderEvent{kind: :delta, payload: payload}, utf8) do
    case Utf8Buffer.push(utf8, payload) do
      {:ok, _valid, next} -> {:ok, next}
      {:error, _reason} = error -> error
    end
  end

  defp validate_utf8(%ProviderEvent{kind: kind}, utf8) when kind in [:completed, :failed] do
    case Utf8Buffer.finish(utf8) do
      :ok -> {:ok, utf8}
      {:error, _reason} = error -> error
    end
  end

  defp validate_utf8(%ProviderEvent{}, utf8), do: {:ok, utf8}

  defp require_terminal(%{terminal: nil}, opts) do
    if Keyword.get(opts, :require_terminal?, true),
      do: failure(:terminal, :missing_terminal_event),
      else: :ok
  end

  defp require_terminal(_protocol, _opts), do: :ok

  defp maybe_cancel(adapter, adapter_state, opts) do
    if Keyword.get(opts, :cancel_after?, false) do
      reason = Keyword.get(opts, :cancel_reason, :stream_adapter_conformance)

      case safe_call(adapter, :cancel, [adapter_state, reason]) do
        {:ok, :ok} -> {:ok, :accepted}
        {:ok, {:error, reason}} -> {:ok, {:error, reason_class(reason)}}
        {:ok, reply} -> failure(:cancel, {:invalid_reply, value_class(reply)})
        {:error, reason} -> failure(:cancel, reason)
      end
    else
      {:ok, :not_exercised}
    end
  end

  defp maybe_reconcile(adapter, descriptor, capabilities, adapter_opts, opts) do
    case Keyword.fetch(opts, :reconcile_provider_request_id) do
      :error ->
        {:ok, :not_exercised}

      {:ok, provider_request_id} ->
        reconcile(adapter, descriptor, provider_request_id, capabilities, adapter_opts)
    end
  end

  defp reconcile(adapter, descriptor, provider_request_id, capabilities, adapter_opts) do
    if MapSet.member?(capabilities, :reconcile) do
      case safe_call(adapter, :reconcile, [descriptor, provider_request_id, adapter_opts]) do
        {:ok, {:ok, _response}} -> {:ok, :completed}
        {:ok, result} when result in [:pending, :not_found] -> {:ok, result}
        {:ok, {:error, reason}} -> {:ok, {:error, reason_class(reason)}}
        {:ok, reply} -> failure(:reconcile, {:invalid_reply, value_class(reply)})
        {:error, reason} -> failure(:reconcile, reason)
      end
    else
      failure(:reconcile, :capability_unavailable)
    end
  end

  defp valid_adapter_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: failure(:options, :invalid_adapter_options)
  end

  defp valid_adapter_opts(_opts), do: failure(:options, :invalid_adapter_options)

  defp valid_metadata(metadata) when is_map(metadata) and not is_struct(metadata), do: :ok
  defp valid_metadata(_metadata), do: failure(:open, :invalid_provider_metadata)

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> failure(:options, {:invalid_positive_option, key})
    end
  end

  defp stream_bounds(opts) do
    with {:ok, transport} <-
           positive_option(
             opts,
             :max_transport_chunk_bytes,
             @default_max_transport_chunk_bytes
           ),
         {:ok, residual} <-
           positive_option(
             opts,
             :max_parser_residual_bytes,
             @default_max_parser_residual_bytes
           ) do
      {:ok,
       %{
         max_transport_chunk_bytes: transport,
         max_parser_residual_bytes: residual
       }}
    end
  end

  defp put_spectre_bounds(adapter_opts, bounds) do
    Keyword.put(adapter_opts, :spectre_bounds,
      max_transport_chunk_bytes: bounds.max_transport_chunk_bytes,
      max_parser_residual_bytes: bounds.max_parser_residual_bytes
    )
  end

  defp transport(capabilities) do
    if MapSet.member?(capabilities, :pull_transport), do: :pull, else: :push
  end

  defp safe_call(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    exception -> {:error, {:callback_exception, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:callback_failure, function, kind, reason_class(reason)}}
  end

  defp failure(phase, reason),
    do: {:error, {:stream_adapter_conformance_failed, phase, reason}}

  defp reason_class(reason) when is_atom(reason) and not is_nil(reason), do: reason
  defp reason_class({reason, _detail}) when is_atom(reason) and not is_nil(reason), do: reason
  defp reason_class(%{class: reason}) when is_atom(reason) and not is_nil(reason), do: reason
  defp reason_class(_reason), do: :error

  defp value_class(value) when is_tuple(value), do: :tuple
  defp value_class(value) when is_map(value), do: :map
  defp value_class(value) when is_list(value), do: :list
  defp value_class(value) when is_atom(value), do: value
  defp value_class(_value), do: :other
end
