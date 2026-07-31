defmodule Spectre.Operation.Event do
  @moduledoc "Committed event envelope shared by Work, Vigil and external controllers."

  alias Spectre.Run.Value

  @loop_kinds [:work, :vigil, :directive]

  @enforce_keys [
    :id,
    :agent_id,
    :loop_kind,
    :loop_id,
    :revision,
    :correlation_id,
    :type,
    :timestamp,
    :provenance
  ]
  defstruct [
    :id,
    :agent_id,
    :loop_kind,
    :loop_id,
    :revision,
    :correlation_id,
    :causation_id,
    :type,
    :timestamp,
    :provenance,
    :payload,
    :artifact,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          agent_id: String.t(),
          loop_kind: :work | :vigil | :directive,
          loop_id: String.t(),
          revision: non_neg_integer(),
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          type: atom(),
          timestamp: non_neg_integer(),
          provenance: map(),
          payload: term(),
          artifact: term(),
          metadata: map()
        }

  @spec new(Spectre.Operation.Loop.t(), atom(), keyword()) :: t()
  def new(%Spectre.Operation.Loop{} = loop, type, opts \\ [])
      when is_atom(type) and not is_nil(type) do
    %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      agent_id: Keyword.fetch!(opts, :agent_id),
      loop_kind: loop.kind,
      loop_id: loop.id,
      revision: Keyword.get(opts, :revision, loop.revision),
      correlation_id: Keyword.get(opts, :correlation_id, loop.correlation_id),
      causation_id: Keyword.get(opts, :causation_id),
      type: type,
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond)),
      provenance: Keyword.get(opts, :provenance, loop.provenance),
      payload: Keyword.get(opts, :payload),
      artifact: Keyword.get(opts, :artifact),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = event) do
    cond do
      Enum.any?(
        [event.id, event.agent_id, event.loop_id, event.correlation_id],
        &(not valid_binary?(&1))
      ) ->
        {:error, :invalid_operation_event_identity}

      event.loop_kind not in @loop_kinds ->
        {:error, :invalid_operation_event_loop_kind}

      not is_integer(event.revision) or event.revision < 0 ->
        {:error, :invalid_operation_event_revision}

      not is_nil(event.causation_id) and not valid_binary?(event.causation_id) ->
        {:error, :invalid_operation_event_causation}

      not is_atom(event.type) or is_nil(event.type) ->
        {:error, :invalid_operation_event_type}

      not is_integer(event.timestamp) or event.timestamp < 0 ->
        {:error, :invalid_operation_event_timestamp}

      not is_map(event.provenance) ->
        {:error, :invalid_operation_event_provenance}

      not is_map(event.metadata) ->
        {:error, :invalid_operation_event_metadata}

      true ->
        portable(event)
    end
  end

  defp portable(event) do
    case Value.validate(event, [:operation_event, event.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_event, reason}}
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""

  @doc "Converts a committed event into a normal typed router input."
  @spec to_input(t()) :: Spectre.Input.t()
  def to_input(%__MODULE__{} = event) do
    Spectre.Input.new(%{
      text: "",
      meta: %{
        spectre_event: event,
        event_type: event.type,
        loop_kind: event.loop_kind,
        loop_id: event.loop_id,
        committed_revision: event.revision
      }
    })
  end
end
