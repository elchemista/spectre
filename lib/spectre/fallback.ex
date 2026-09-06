defmodule Spectre.Fallback do
  @moduledoc """
  Fail-closed handling for a declared refusal policy.

  A fallback is either silence or a fresh Candidate built from a static
  template. It applies only to `:refused`: `:undecidable` and `:unknown_class`
  remain distinct queryable outcomes. It never reuses the refused Candidate's
  Evidence, Presentation or resolved Mandate. The returned Candidate still
  crosses normal admission and receives no special authority. The public
  proposal driver executes at most one fallback and returns its result without
  applying this policy again. This pure builder does not infer execution origin
  from an application-controlled identity key.
  """

  alias Spectre.Candidate
  alias Spectre.Decision
  alias Spectre.Fallback.Policy
  alias Spectre.SubmissionContext

  @type result :: :silence | {:candidate_template | :governed_handoff, Candidate.t()}

  @doc "Materializes the one declared response to an explicitly refused Decision."
  @spec materialize(Policy.t() | map() | atom(), Decision.t(), SubmissionContext.t()) ::
          {:ok, result()} | {:error, term()}
  def materialize(policy, %Decision{} = decision, %SubmissionContext{} = context) do
    with {:ok, policy} <- Policy.new(policy),
         {:ok, decision} <- Decision.new(decision),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- refused(decision),
         :ok <- decision_context(decision, context) do
      materialize_policy(policy, decision, context)
    end
  end

  def materialize(_policy, _decision, _context), do: {:error, :invalid_fallback_input}

  defp materialize_policy(%Policy{mode: :silence}, _decision, _context),
    do: {:ok, :silence}

  defp materialize_policy(%Policy{} = policy, decision, context) do
    attrs =
      policy.template
      |> Map.put("identity_key", "fallback:" <> decision.ref)
      |> Map.put("proposer_ref", context.authenticated_principal_ref)
      |> Map.put("scope_ref", context.scope_ref)

    with {:ok, candidate} <- Candidate.new(attrs), do: {:ok, {policy.mode, candidate}}
  end

  defp refused(%Decision{outcome: :refused}), do: :ok
  defp refused(%Decision{outcome: outcome}), do: {:error, {:fallback_not_applicable, outcome}}

  defp decision_context(decision, context) do
    with {:ok, expected} <- SubmissionContext.from_decision(decision),
         true <- SubmissionContext.canonical(expected) == SubmissionContext.canonical(context) do
      :ok
    else
      false -> {:error, :fallback_context_mismatch}
      {:error, _reason} = error -> error
    end
  end
end
