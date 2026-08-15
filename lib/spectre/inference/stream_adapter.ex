defmodule Spectre.Inference.StreamAdapter do
  @moduledoc """
  Provider-neutral streaming contract owned by the Spectre core.

  Pull adapters should request at most one transport item per
  `request_transport_item/1` call. Push adapters must declare both
  `:push_transport` and `:bounded_push_transport`: the adapter owns the bound
  between its producer and the session mailbox, while Spectre independently
  bounds normalized events inside the session. Declaring only
  `:push_transport` is rejected because an Erlang mailbox is not itself a
  backpressure mechanism.

  Normalized usage counters are cumulative for the logical attempt, including
  after `resume/3`. Spectre passes the durable usage floor in
  `:resume_usage`; adapters for providers that restart counters locally must
  add that floor before emitting `ProviderEvent` values.

  An adapter declaring `:cost_usage` promises that the cumulative `cost`
  counter is authoritative under the immutable pricing reference configured
  for the invocation. Spectre rejects hard cost budgets when this capability
  is absent.

  Callbacks run in the session process and therefore must return promptly.
  Adapters should use asynchronous transport messages instead of blocking
  `open/2`, `resume/3`, `request_transport_item/1`, or `cancel/2` indefinitely.

  `handle_transport/2` must return `{:ignore, state}` only for a mailbox
  message that did not consume the outstanding pull item. A consumed transport
  item that yields no logical events returns `{:ok, [], state}` so Spectre can
  request the next item without allowing two requests in flight.

  Provider packages can run `Spectre.Inference.StreamAdapter.Conformance`
  against deterministic transport fixtures without depending on ExUnit.
  """

  @type adapter_state :: term()
  @type descriptor :: Spectre.Inference.Descriptor.t()
  @type provider_metadata :: map()

  @callback capabilities(term(), keyword()) :: MapSet.t(atom())

  @callback open(descriptor(), keyword()) ::
              {:ok, adapter_state(), provider_metadata()} | {:error, term()}

  @callback request_transport_item(adapter_state()) ::
              {:ok, adapter_state()} | {:error, term()}

  @callback handle_transport(term(), adapter_state()) ::
              {:ok, [Spectre.Inference.ProviderEvent.t()], adapter_state()}
              | {:ignore, adapter_state()}
              | {:error, term(), adapter_state()}

  @callback cancel(adapter_state(), term()) :: :ok | {:error, term()}

  @callback resume(descriptor(), term(), keyword()) ::
              {:ok, adapter_state(), provider_metadata()} | {:error, term()}

  @callback reconcile(descriptor(), term(), keyword()) ::
              {:ok, term()} | :pending | :not_found | {:error, term()}

  # Push transports receive provider-owned messages and therefore have no
  # demand callback. Validation still requires this callback for every adapter
  # that declares `:pull_transport`.
  @optional_callbacks request_transport_item: 1, resume: 3, reconcile: 3

  @transport_capabilities [:pull_transport, :push_transport]

  @spec validate(module(), term(), keyword()) :: {:ok, MapSet.t(atom())} | {:error, term()}
  def validate(adapter, profile, opts \\ []) when is_atom(adapter) and is_list(opts) do
    cond do
      not Code.ensure_loaded?(adapter) ->
        {:error, {:stream_adapter_not_loaded, adapter}}

      not function_exported?(adapter, :capabilities, 2) ->
        {:error, {:stream_adapter_callback_missing, adapter, :capabilities, 2}}

      true ->
        validate_declared_capabilities(adapter, profile, opts)
    end
  rescue
    exception -> {:error, {:stream_adapter_exception, adapter, exception.__struct__}}
  catch
    kind, reason -> {:error, {:stream_adapter_failure, adapter, kind, reason_class(reason)}}
  end

  defp validate_declared_capabilities(adapter, profile, opts) do
    case adapter.capabilities(profile, opts) do
      %MapSet{} = capabilities ->
        with true <- MapSet.member?(capabilities, :stream),
             :ok <- validate_transport_mode(capabilities),
             :ok <- validate_push_bound(capabilities),
             :ok <- validate_callbacks(adapter, capabilities) do
          {:ok, capabilities}
        else
          false -> {:error, {:streaming_unsupported, :adapter_capability}}
          {:error, _reason} = error -> error
        end

      value ->
        {:error, {:invalid_stream_adapter_capabilities, adapter, value_class(value)}}
    end
  end

  defp validate_transport_mode(capabilities) do
    case Enum.filter(@transport_capabilities, &MapSet.member?(capabilities, &1)) do
      [_one] -> :ok
      [] -> {:error, {:streaming_unsupported, :transport}}
      _both -> {:error, :ambiguous_stream_transport_mode}
    end
  end

  defp validate_push_bound(capabilities) do
    if MapSet.member?(capabilities, :push_transport) and
         not MapSet.member?(capabilities, :bounded_push_transport) do
      {:error, {:streaming_unsupported, :unbounded_push_transport}}
    else
      :ok
    end
  end

  defp validate_callbacks(adapter, capabilities) do
    required = [open: 2, handle_transport: 2, cancel: 2]

    required =
      if MapSet.member?(capabilities, :pull_transport),
        do: required ++ [request_transport_item: 1],
        else: required

    required =
      required
      |> maybe_require_callback(capabilities, :resume, {:resume, 3})
      |> maybe_require_callback(capabilities, :reconcile, {:reconcile, 3})

    case Enum.find(required, fn {function, arity} ->
           not function_exported?(adapter, function, arity)
         end) do
      nil -> :ok
      {function, arity} -> {:error, {:stream_adapter_callback_missing, adapter, function, arity}}
    end
  end

  defp maybe_require_callback(required, capabilities, capability, callback) do
    if MapSet.member?(capabilities, capability),
      do: required ++ [callback],
      else: required
  end

  defp value_class(value) when is_map(value), do: :map
  defp value_class(value) when is_list(value), do: :list
  defp value_class(value) when is_tuple(value), do: :tuple
  defp value_class(value) when is_atom(value), do: :atom
  defp value_class(_value), do: :other

  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class({reason, _detail}) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :error
end
