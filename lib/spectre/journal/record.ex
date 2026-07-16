defmodule Spectre.Journal.Record do
  @moduledoc """
  Versioned, privacy-aware explanation record for one runtime decision.

  Input and reply content are absent by default. Applications must opt in to
  content recording through their journal configuration.
  """

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            agent: nil,
            agent_version: nil,
            conversation_id: nil,
            turn_id: nil,
            sequence: 1,
            trace_id: nil,
            state_revision: nil,
            phase: nil,
            decision: %{},
            reason: %{},
            evidence: [],
            transition: nil,
            policy: nil,
            effect: nil,
            input: nil,
            reply: nil,
            duration_native: nil,
            metadata: %{},
            occurred_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          agent: module() | nil,
          agent_version: term(),
          conversation_id: term(),
          turn_id: term(),
          sequence: non_neg_integer(),
          trace_id: term(),
          state_revision: non_neg_integer() | nil,
          phase: atom(),
          decision: map(),
          reason: map(),
          evidence: [map()],
          transition: map() | nil,
          policy: map() | nil,
          effect: map() | nil,
          input: map() | nil,
          reply: String.t() | nil,
          duration_native: integer() | nil,
          metadata: map(),
          occurred_at: DateTime.t()
        }

  @doc """
  Builds a journal record and derives a stable record identifier from its turn,
  phase, sequence, and agent.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    turn_id = Map.get(attrs, :turn_id) || Spectre.Identity.uuid7()
    phase = Map.get(attrs, :phase, :unknown)
    sequence = Map.get(attrs, :sequence, 1)
    agent = Map.get(attrs, :agent)
    trace_id = Map.get(attrs, :trace_id) || turn_id
    occurred_at = Map.get(attrs, :occurred_at) || DateTime.utc_now()
    id = Map.get(attrs, :id) || stable_id(turn_id, phase, sequence, agent)

    attrs =
      attrs
      |> Map.put(:turn_id, turn_id)
      |> Map.put(:trace_id, trace_id)
      |> Map.put(:occurred_at, occurred_at)
      |> Map.put(:id, id)

    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @spec stable_id(term(), atom(), non_neg_integer(), module() | nil) :: String.t()
  defp stable_id(turn_id, phase, sequence, agent) do
    digest =
      {turn_id, phase, sequence, agent}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "journal:" <> binary_part(digest, 0, 32)
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
