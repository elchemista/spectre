defmodule Spectre.Transition do
  @moduledoc """
  Immutable result of one validated lifecycle transition.

  It carries both state snapshots and the affected entities so persistence,
  journaling, and host dispatch can reason about a transition without
  reconstructing it from mutable-looking structs.
  """

  defstruct [
    :event,
    :from,
    :to,
    :effect,
    :awaitable,
    :entity_id,
    replayed?: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          event: atom(),
          from: Spectre.State.t(),
          to: Spectre.State.t(),
          effect: Spectre.Effect.t() | nil,
          awaitable: Spectre.Awaitable.t() | nil,
          entity_id: term(),
          replayed?: boolean(),
          metadata: map()
        }

  @doc false
  @spec new(atom(), Spectre.State.t(), Spectre.State.t(), keyword()) :: t()
  def new(event, from, to, opts \\ []) do
    %__MODULE__{
      event: event,
      from: from,
      to: to,
      effect: Keyword.get(opts, :effect),
      awaitable: Keyword.get(opts, :awaitable),
      entity_id: Keyword.get(opts, :entity_id),
      replayed?: Keyword.get(opts, :replayed?, false),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
