defmodule Spectre.Invocation.WorkerReceipt do
  @moduledoc false

  @enforce_keys [
    :invocation_id,
    :run_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :capability,
    :outcome
  ]
  defstruct [
    :invocation_id,
    :run_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :capability,
    :outcome,
    :attempt_id,
    :control_revision,
    :stream_epoch,
    :sequence,
    kind: :effect,
    provider_started: false,
    usage: %{},
    usage_quality: :unavailable,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          invocation_id: String.t(),
          run_id: String.t(),
          run_revision: non_neg_integer(),
          generation: String.t(),
          dispatch_id: String.t(),
          capability: reference(),
          outcome: term(),
          attempt_id: String.t() | nil,
          control_revision: non_neg_integer() | nil,
          stream_epoch: String.t() | nil,
          sequence: non_neg_integer() | nil,
          kind: :effect | :inference,
          provider_started: boolean(),
          usage: map(),
          usage_quality: :provider | :estimated | :unavailable,
          metadata: map()
        }
end
