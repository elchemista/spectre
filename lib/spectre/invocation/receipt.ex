defmodule Spectre.Invocation.Receipt do
  @moduledoc """
  Compatibility name for the original correlated internal receipt.

  New runtime code uses a separate internal worker-receipt struct that makes
  the BEAM-local capability boundary explicit. This compatibility struct
  remains readable so existing integrations and persisted API manifests do
  not break.
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
