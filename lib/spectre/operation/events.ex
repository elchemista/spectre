defmodule Spectre.Operation.Events do
  @moduledoc """
  Local subscription boundary for already-committed operational events.

  Subscription is delivery-neutral: it sends an event envelope to the caller's
  mailbox and never contacts a user or a channel. Proactive human delivery still
  requires `Spectre.Operation.Delivery` authorization.
  """

  alias Spectre.Instance.Ref
  alias Spectre.Inference.Event, as: InferenceEvent
  alias Spectre.Operation.Event

  @registry Spectre.Operation.EventRegistry

  @spec subscribe(GenServer.server() | Ref.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def subscribe(instance_or_ref, opts \\ []) do
    with {:ok, ref} <- instance_ref(instance_or_ref) do
      filters = %{
        types: normalize_filter(Keyword.get(opts, :types)),
        kinds: normalize_filter(Keyword.get(opts, :kinds)),
        loop_ids: normalize_filter(Keyword.get(opts, :loop_ids))
      }

      Registry.register(@registry, ref.key, filters)
    end
  end

  @spec unsubscribe(GenServer.server() | Ref.t()) :: :ok | {:error, term()}
  def unsubscribe(instance_or_ref) do
    with {:ok, ref} <- instance_ref(instance_or_ref) do
      Registry.unregister(@registry, ref.key)
    end
  end

  @doc false
  @spec publish(Ref.t(), Event.t() | InferenceEvent.t()) :: :ok
  def publish(%Ref{} = ref, %Event{} = event) do
    Registry.dispatch(@registry, ref.key, fn entries ->
      Enum.each(entries, fn {pid, filters} ->
        if matches?(event, filters), do: send(pid, {:spectre, :operation_event, event})
      end)
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  def publish(%Ref{} = ref, %InferenceEvent{} = event) do
    Registry.dispatch(@registry, ref.key, fn entries ->
      Enum.each(entries, fn {pid, filters} ->
        if matches?(event, filters), do: send(pid, {:spectre, :inference_event, event})
      end)
    end)

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp instance_ref(%Ref{} = ref), do: {:ok, ref}

  defp instance_ref(server) do
    {:ok, Spectre.Instance.ref(server)}
  catch
    :exit, reason -> {:error, {:instance_reference_unavailable, reason}}
  end

  defp matches?(%Event{} = event, filters) do
    allowed?(filters.types, event.type) and allowed?(filters.kinds, event.loop_kind) and
      allowed?(filters.loop_ids, event.loop_id)
  end

  defp matches?(%InferenceEvent{} = event, filters) do
    allowed?(filters.types, event.type) and allowed?(filters.kinds, :inference) and
      allowed?(filters.loop_ids, event.inference_id)
  end

  defp allowed?(nil, _value), do: true
  defp allowed?(values, value), do: value in values
  defp normalize_filter(nil), do: nil
  defp normalize_filter(value), do: List.wrap(value)
end
