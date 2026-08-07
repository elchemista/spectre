defmodule Spectre.Instance.Telemetry do
  @moduledoc false

  alias Spectre.AgentRef
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Subject

  @doc "Emits one Instance telemetry event with owner-identifying metadata."
  @spec emit(atom(), InstanceState.t(), map()) :: :ok
  def emit(event, %InstanceState{} = data, measurements) do
    Spectre.Telemetry.emit(
      [:instance, event],
      measurements,
      %{
        agent: data.agent,
        agent_ref: AgentRef.key(data.agent_ref),
        subject: Subject.key(data.subject),
        generation: data.generation
      },
      data.base_opts
    )
  end

  @doc "Reduces an arbitrary failure term to a privacy-safe atom class."
  @spec reason_class(term()) :: atom()
  def reason_class(%{kind: kind}) when is_atom(kind), do: kind
  def reason_class({kind, _detail}) when is_atom(kind), do: kind
  def reason_class(reason) when is_atom(reason), do: reason
  def reason_class(_reason), do: :error
end
