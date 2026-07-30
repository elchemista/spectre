defmodule Spectre.Invocation.Receipt do
  @moduledoc """
  Correlated internal receipt returned to an Agent Instance mailbox.

  The receipt fences a worker result to one Instance generation, Run revision,
  Invocation, and dispatch. It is technical evidence for the actor; it is not
  a public Turn projection or a provider payload.
  """

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
    :outcome
  ]

  @type t :: %__MODULE__{
          invocation_id: String.t(),
          run_id: String.t(),
          run_revision: non_neg_integer(),
          generation: String.t(),
          dispatch_id: String.t(),
          capability: reference(),
          outcome: Spectre.Runtime.step_result()
        }
end
