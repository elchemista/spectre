defmodule Spectre.Instance.Ref do
  @moduledoc """
  Logical key for one Agent Instance.

  The default Instance granularity is exactly `AgentRef + Subject`. This value
  is safe to persist or route and intentionally contains no process location.
  """

  alias Spectre.AgentRef
  alias Spectre.Run.Value
  alias Spectre.Subject

  @enforce_keys [:agent_ref, :subject, :key]
  defstruct [:agent_ref, :subject, :key]

  @type t :: %__MODULE__{
          agent_ref: AgentRef.t(),
          subject: Subject.t(),
          key: String.t()
        }

  @doc """
  Builds an Instance reference from logical Agent and Subject identities.
  """
  @spec new(AgentRef.t() | module(), Subject.t() | term(), keyword()) :: t()
  def new(agent, subject, opts \\ []) do
    agent_ref =
      case agent do
        %AgentRef{} ->
          AgentRef.new(agent)

        agent ->
          case Keyword.fetch(opts, :agent_id) do
            {:ok, id} -> AgentRef.new(agent, id: id)
            :error -> AgentRef.new(agent)
          end
      end

    subject = if match?(%Subject{}, subject), do: Subject.new(subject), else: Subject.new(subject)
    key = Value.token("instance", {AgentRef.key(agent_ref), Subject.key(subject)})

    %__MODULE__{agent_ref: agent_ref, subject: subject, key: key}
  end
end
