defmodule Spectre.Server.Stream do
  @moduledoc false
  alias Spectre.Inference.{ProviderEvent, ProviderProtocol, StreamAdapter, StreamSanitizer}
  alias Spectre.Server.{PublicProjection, TransportGuard}

  def run(prepared, request, context, opts) do
    with {:ok, adapter, adapter_opts} <- stream_binding(opts),
         {:ok, capabilities} <-
           StreamAdapter.validate(adapter, prepared.selection.level, adapter_opts),
         {:ok, preview?} <- preview(request, opts),
         {:ok, projection} <- PublicProjection.open(Keyword.get(opts, :public_projection)),
         {:ok, sanitizer} <- StreamSanitizer.new(opts),
         {:ok, transport, _metadata} <-
           adapter.open(prepared.descriptor, open_opts(prepared, adapter_opts, opts)) do
      guard = TransportGuard.start(adapter, transport, context, prepared.descriptor.id)

      state = %{
        guard: guard,
        adapter: adapter,
        transport: transport,
        capabilities: capabilities,
        outstanding: false,
        text: "",
        sanitizer: sanitizer,
        projection: projection,
        sequence: nil,
        started: false,
        bytes: 0,
        max_bytes: Keyword.get(opts, :max_output_bytes, 1_000_000),
        preview?: preview?,
        context: context,
        generation: prepared.descriptor.id,
        stall_timeout: Keyword.get(opts, :stream_stall_timeout, 30_000)
      }

      try do
        result = loop(state)
        TransportGuard.finish(guard, result)
        result
      after
        # On exceptions this still releases the transport. If the worker is
        # killed, its monitored guard performs the same cleanup independently.
        TransportGuard.finish(guard, {:error, :stream_interrupted})
      end
    end
  end

  defp stream_binding(opts) do
    case Keyword.get(opts, :stream_adapter) do
      {module, adapter_opts} when is_atom(module) and is_list(adapter_opts) ->
        {:ok, module, adapter_opts}

      module when is_atom(module) and not is_nil(module) ->
        {:ok, module, Keyword.get(opts, :stream_adapter_opts, [])}

      _ ->
        {:error, {:streaming_unsupported, :adapter}}
    end
  end

  defp preview(request, opts) do
    planner_safe? = not request.planning or not is_nil(Keyword.get(opts, :public_projection))

    case request.preview do
      :off -> {:ok, false}
      :auto -> {:ok, planner_safe?}
      :required when planner_safe? -> {:ok, true}
      :required -> {:error, {:preview_unsupported, :planner_cleaner_not_incremental}}
      _ -> {:error, :invalid_preview_mode}
    end
  end

  defp open_opts(prepared, adapter_opts, opts) do
    prepared.provider_opts
    |> Keyword.merge(adapter_opts)
    |> Keyword.put(:model, prepared.selection.model)
    |> Keyword.put(:spectre_bounds,
      max_transport_chunk_bytes: Keyword.get(opts, :stream_max_transport_chunk_bytes, 256_000),
      max_parser_residual_bytes: Keyword.get(opts, :stream_max_parser_residual_bytes, 256_000)
    )
  end

  defp loop(state) do
    case demand(state) do
      {:error, _} = error ->
        error

      {:ok, state} ->
        receive do
          message ->
            case state.adapter.handle_transport(message, state.transport) do
              {:ignore, transport} ->
                TransportGuard.update(state.guard, transport)
                loop(%{state | transport: transport})

              {:ok, events, transport} ->
                TransportGuard.update(state.guard, transport)

                with :ok <- ProviderProtocol.validate_batch(events, 128),
                     {:ok, state, terminal} <-
                       events(%{state | transport: transport, outstanding: false}, events) do
                  if terminal, do: terminal, else: loop(state)
                end

              {:error, reason, transport} ->
                TransportGuard.update(state.guard, transport)
                {:error, reason}

              other ->
                {:error, {:invalid_stream_transport_reply, other}}
            end
        after
          state.stall_timeout -> {:error, :provider_stall_timeout}
        end
    end
  end

  defp demand(%{outstanding: false} = state) do
    if MapSet.member?(state.capabilities, :pull_transport) do
      case state.adapter.request_transport_item(state.transport) do
        {:ok, transport} ->
          TransportGuard.update(state.guard, transport)
          {:ok, %{state | transport: transport, outstanding: true}}

        {:error, _} = error ->
          error
      end
    else
      {:ok, state}
    end
  end

  defp demand(state), do: {:ok, state}

  defp events(state, events) do
    Enum.reduce_while(events, {:ok, state, nil}, fn event, {:ok, state, nil} ->
      case event(state, event) do
        {:ok, _, _} = result -> {:cont, result}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp event(state, %ProviderEvent{} = event) do
    with :ok <- ProviderProtocol.validate_sequence(state.sequence, event.provider_sequence) do
      state = %{
        state
        | sequence: ProviderProtocol.next_sequence(state.sequence, event.provider_sequence)
      }

      consume(state, event)
    end
  end

  defp consume(%{started: true}, %ProviderEvent{kind: :started}),
    do: {:error, :duplicate_provider_started}

  defp consume(state, %ProviderEvent{kind: :started}), do: {:ok, %{state | started: true}, nil}
  defp consume(state, %ProviderEvent{kind: :usage}), do: {:ok, state, nil}

  defp consume(state, %ProviderEvent{kind: :delta, payload: chunk}) do
    if state.bytes + byte_size(chunk) > state.max_bytes do
      {:error, :provider_stream_overflow}
    else
      with {:ok, clean, sanitizer} <- StreamSanitizer.push(state.sanitizer, chunk),
           {:ok, public, projection} <- PublicProjection.push(state.projection, clean) do
        emit(state, public)

        {:ok,
         %{
           state
           | text: state.text <> chunk,
             bytes: state.bytes + byte_size(chunk),
             sanitizer: sanitizer,
             projection: projection
         }, nil}
      end
    end
  end

  defp consume(state, %ProviderEvent{kind: :completed, payload: response}) do
    with {:ok, clean, _sanitizer} <- StreamSanitizer.finish(state.sanitizer),
         {:ok, trailing, projection} <- PublicProjection.push(state.projection, clean),
         {:ok, finish} <- PublicProjection.finish(projection),
         true <- byte_size(response.text) <= state.max_bytes,
         true <- response.text == state.text or state.text == "" do
      emit(state, trailing <> finish)
      {:ok, state, {:ok, response}}
    else
      false -> {:error, :provider_terminal_text_mismatch}
      {:error, _} = error -> error
    end
  end

  defp consume(_state, %ProviderEvent{kind: :failed, payload: reason}), do: {:error, reason}

  defp emit(
         %{
           preview?: true,
           context: %{consumer: consumer, interaction: id} = context,
           generation: generation
         },
         text
       )
       when is_pid(consumer) and text != "" do
    Spectre.Server.Runtime.notify_consumer(
      consumer,
      context[:runtime],
      {:preview, id, generation, text},
      if(context[:skill], do: context[:session])
    )
  end

  defp emit(_state, _text), do: :ok
end
