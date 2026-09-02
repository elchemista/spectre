defmodule Spectre.Proposal.Result do
  @moduledoc """
  Capability-free result of a public proposal and its declared fallback.

  `primary` is always the durable result of the caller's Candidate.  A fallback
  is either not applicable, explicit silence, or the durable result of one
  fresh Candidate that crossed the normal kernel boundary.  Fallbacks never
  recurse.
  """

  alias Spectre.Attempt.Runner

  @enforce_keys [:primary, :fallback]
  defstruct @enforce_keys

  @type fallback ::
          :not_applicable
          | :silence
          | %{
              required(:mode) => :candidate_template | :governed_handoff,
              required(:result) => Runner.Result.t()
            }

  @type t :: %__MODULE__{primary: Runner.Result.t(), fallback: fallback()}
end
