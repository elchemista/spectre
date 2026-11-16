defmodule Spectre.GAM.Proposal.Result do
  @moduledoc """
  Capability-free result of a public proposal and its declared fallback.

  `primary` is always the durable result of the caller's Candidate.  A fallback
  is either not applicable, explicit silence, or the durable result of one
  fresh Candidate that crossed the normal kernel boundary.  Fallbacks never
  recurse.
  """

  alias Spectre.GAM.Attempt.Runner

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

  @typedoc "Independent admission, durable attempt and observed outcome facts; nil means no Outcome."
  @type status :: %{
          admission: Spectre.GAM.Decision.outcome(),
          act_committed?: boolean(),
          attempted?: boolean(),
          outcome: Spectre.GAM.Outcome.status() | nil
        }

  @doc """
  Projects the result without equating admission with successful execution.

  The primary and fallback remain separate. `outcome: nil` means this result
  contains no Outcome, not failure or proof of no effect. An Act without an
  Attempt may be an intrinsic governance operation or an undispatched external
  operation; this helper does not invent a lifecycle status from that absence.
  No query, retry or repair is performed.
  """
  @spec status(t()) :: %{primary: status(), fallback: :not_applicable | :silence | map()}
  def status(%__MODULE__{} = result) do
    %{primary: summarize(result.primary), fallback: fallback_status(result.fallback)}
  end

  defp summarize(%Runner.Result{} = result) do
    %{
      admission: result.decision.outcome,
      act_committed?: not is_nil(result.act),
      attempted?: not is_nil(result.attempt),
      outcome: if(result.outcome, do: result.outcome.status)
    }
  end

  defp fallback_status(value) when value in [:not_applicable, :silence], do: value

  defp fallback_status(%{mode: mode, result: result}),
    do: %{mode: mode, result: summarize(result)}
end
