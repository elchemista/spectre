defmodule Spectre.Inference.Events do
  @moduledoc """
  Local, lossy observer lane for committed inference lifecycle facts.

  It shares the existing operation Registry so a host needs one subscription
  boundary. Raw deltas are never accepted by this module.
  """

  alias Spectre.Inference.Event
  alias Spectre.Instance.Ref

  @spec subscribe(GenServer.server() | Ref.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defdelegate subscribe(instance_or_ref, opts \\ []), to: Spectre.Operation.Events

  @spec unsubscribe(GenServer.server() | Ref.t()) :: :ok | {:error, term()}
  defdelegate unsubscribe(instance_or_ref), to: Spectre.Operation.Events

  @doc false
  @spec publish(Ref.t(), Event.t()) :: :ok
  def publish(%Ref{} = ref, %Event{} = event), do: Spectre.Operation.Events.publish(ref, event)
end
