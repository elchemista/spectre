defmodule Spectre.Operation.Monitor do
  @moduledoc "Classifies Runner termination without deciding retry outside the Agent."

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Spec

  @type decision :: {:retry, non_neg_integer()} | {:reconcile, term()} | {:fail, term()}

  @spec classify(Attempt.t(), Spec.t(), term()) :: decision()
  def classify(%Attempt{} = attempt, %Spec{} = spec, reason) do
    failure_class = if reason == :timeout, do: :timeout, else: :crash

    cond do
      reason == :normal ->
        {:fail, :runner_terminated_without_result}

      spec.side_effect == :reconcilable ->
        {:reconcile, {:runner_crash, reason}}

      spec.side_effect == :non_idempotent ->
        {:fail, {:side_effect_outcome_unknown, attempt.operation, reason}}

      Spectre.Operation.Retry.retry?(spec.retry, failure_class, attempt.retry_number + 1) ->
        {:retry, Spectre.Operation.Retry.delay(spec.retry, attempt.retry_number + 1)}

      true ->
        {:fail, {:runner_crashed, reason}}
    end
  end
end
