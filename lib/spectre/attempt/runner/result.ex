defmodule Spectre.Attempt.Runner.Result do
  @moduledoc """
  Ephemeral summary of one Zone X orchestration.

  A result deliberately excludes the Grant and the checked-out capability. The
  fields it does expose are either durable records or the exact Evidence
  records acknowledged by the Domain sequencer.
  """

  alias Spectre.{Act, Attempt, Decision, Evidence, Outcome}

  @enforce_keys [:decision, :act, :attempt, :evidence, :outcome]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          decision: Decision.t(),
          act: Act.t() | nil,
          attempt: Attempt.t() | nil,
          evidence: [Evidence.t()],
          outcome: Outcome.t() | nil
        }

  @doc false
  @spec ok(Decision.t(), Act.t() | nil, Attempt.t() | nil, [Evidence.t()], Outcome.t() | nil) ::
          {:ok, t()}
  def ok(decision, act, attempt, evidence, outcome) do
    {:ok,
     %__MODULE__{
       decision: decision,
       act: act,
       attempt: attempt,
       evidence: evidence,
       outcome: outcome
     }}
  end
end
