defmodule Spectre.Instance.Ref do
  @moduledoc """
  Logical key for one Agent Instance.

  The default Instance granularity is exactly `AgentRef + Subject`. This value
  is safe to persist or route and intentionally contains no process location.
  """

  alias Spectre.AgentRef
  alias Spectre.Run.Value
  alias Spectre.Subject

  @schema_version 2

  @enforce_keys [:schema_version, :agent_ref, :subject, :key]
  defstruct schema_version: @schema_version, agent_ref: nil, subject: nil, key: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          agent_ref: AgentRef.t(),
          subject: Subject.t(),
          key: String.t()
        }

  @doc "Returns the current stable Instance Ref schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

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

    key =
      Value.token(
        "instance-v2",
        {@schema_version, AgentRef.key(agent_ref), Subject.key(subject)}
      )

    %__MODULE__{
      schema_version: @schema_version,
      agent_ref: agent_ref,
      subject: subject,
      key: key
    }
  end

  @doc """
  Reconstructs the pre-0.2.3 Instance Ref for an explicit key migration.

  It returns an error when the AgentRef no longer carries the compiled source
  hints needed to reproduce the legacy address.
  """
  @spec legacy(t()) :: {:ok, t()} | {:error, term()}
  def legacy(%__MODULE__{} = ref) do
    with {:ok, agent_key} <- AgentRef.legacy_key(ref.agent_ref) do
      {:ok,
       %__MODULE__{
         schema_version: 1,
         agent_ref: ref.agent_ref,
         subject: ref.subject,
         key: Value.token("instance", {agent_key, Subject.key(ref.subject)})
       }}
    end
  end
end
