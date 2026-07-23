defmodule Spectre.Turn.Handler.Request do
  @moduledoc """
  Loaded request presented to an optional `Spectre.Turn.Handler`.

  This struct belongs to the pre-route handler boundary; it is not a transport
  envelope and it is not the result of a complete Spectre turn. The canonical
  local host boundary remains `Spectre.turn/3`, which returns a
  `Spectre.Turn`.

  A request is created only after Spectre has normalized input and loaded the
  authoritative state and recalled memory. Remote sender/recipient addresses,
  correlation, delivery, and task lifecycle belong to the protocol adapter
  (for example SpectrePulse). Stable protocol identifiers can be mapped into
  `conversation_id`, `turn_id`, `trace_id`, or `Spectre.Input.meta`.
  """

  alias Spectre.Context
  alias Spectre.Input
  alias Spectre.State

  @enforce_keys [:agent, :input, :state]
  defstruct [
    :agent,
    :input,
    :state,
    :memory,
    :conversation_id,
    :turn_id,
    :trace_id,
    assigns: %{}
  ]

  @type t :: %__MODULE__{
          agent: module(),
          input: Input.t(),
          state: State.t(),
          memory: term(),
          conversation_id: term(),
          turn_id: term(),
          trace_id: term(),
          assigns: map()
        }

  @doc false
  @spec new(Context.t()) :: t()
  def new(%Context{} = context) do
    %__MODULE__{
      agent: context.agent,
      input: context.input,
      state: context.state,
      memory: context.memory,
      conversation_id: conversation_id(context),
      turn_id: Keyword.get(context.opts, :turn_id),
      trace_id: Keyword.get(context.opts, :trace_id),
      assigns: context.assigns
    }
  end

  @spec conversation_id(Context.t()) :: term()
  defp conversation_id(%Context{} = context) do
    Keyword.get(context.opts, :conversation_id) ||
      context.state.conversation_id ||
      input_meta(context.input, :conversation_id)
  end

  @spec input_meta(Input.t(), atom()) :: term()
  defp input_meta(%Input{meta: meta}, key) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  end

  defp input_meta(%Input{}, _key), do: nil
end
