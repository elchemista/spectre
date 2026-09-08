defmodule Spectre.Instance.Request do
  @moduledoc """
  Capability-free ticket for one prepared alternative.

  The owning Instance compares the entire ticket with its retained original
  before reserving it. Changing a Candidate, copying the ticket to another
  Instance, or presenting it after a newer turn cannot replace that original.
  The reference is also the Candidate's occurrence identity for direct DSL
  requests, so an incident can be correlated without replaying the executor.
  """

  @enforce_keys [
    :ref,
    :operation,
    :candidate,
    :instance_ref,
    :definition_ref,
    :turn_ref,
    :revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ref: String.t(),
          operation: {atom(), atom() | String.t()},
          candidate: Spectre.Candidate.t(),
          instance_ref: String.t(),
          definition_ref: String.t(),
          turn_ref: String.t(),
          revision: non_neg_integer()
        }
end
