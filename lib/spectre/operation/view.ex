defmodule Spectre.Operation.View do
  @moduledoc "Privacy-safe, read-only projection of a committed operational loop."

  # The projection is intentionally flat so consumers cannot traverse canonical state.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :id,
    :kind,
    :definition,
    :definition_version,
    :status,
    :control_state,
    :pause_requested,
    :terminal_category,
    :phase,
    :operation,
    :next_operation,
    :cycles,
    :attempts,
    :retries,
    :observations,
    :progress,
    :checkpoint,
    :partial_results,
    :artifacts,
    :blocker,
    :updated_at,
    :context_revision,
    :revision,
    :last_update,
    :pending_command,
    :invalidations,
    :cognitive,
    :last_crash,
    :reconciliation,
    :next_trigger,
    :trigger_generation,
    :budget,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec from_loop(Spectre.Operation.Loop.t(), Spectre.Operation.Control.t()) :: t()
  def from_loop(%Spectre.Operation.Loop{} = loop, %Spectre.Operation.Control{} = control) do
    %__MODULE__{
      id: loop.id,
      kind: loop.kind,
      definition: loop.controller_id,
      definition_version: loop.controller_version,
      status: loop.status,
      control_state: control.state,
      pause_requested: control.state == :pause_requested,
      terminal_category: loop.outcome && loop.outcome.category,
      phase: loop.phase,
      operation: loop.operation,
      next_operation: redacted_request(loop.next_operation),
      cycles: loop.cycles,
      attempts: loop.attempts,
      retries: loop.retries,
      observations: loop.observations,
      progress: loop.last_progress,
      checkpoint: redacted_checkpoint(loop),
      partial_results: published(loop, :publish_results, loop.results),
      artifacts: published(loop, :publish_artifacts, loop.artifacts),
      blocker: loop.blocker,
      updated_at: loop.updated_at,
      context_revision: loop.context_revision,
      revision: loop.revision,
      last_update: redacted_update(loop.last_update),
      pending_command: redacted_command(control.pending),
      invalidations: loop.invalidations,
      cognitive: redacted_cognitive(loop.cognitive),
      last_crash: loop.last_crash,
      reconciliation: reconciliation(loop),
      next_trigger: loop.wait && loop.wait.due_at,
      trigger_generation: loop.trigger_generation,
      budget: %{
        limits: loop.budget.limits,
        consumed: loop.budget.consumed,
        remaining: remaining_budget(loop.budget)
      },
      metadata: Map.take(loop.metadata, [:label, :progress_unit, :last_significant_change])
    }
  end

  defp redacted_checkpoint(loop) do
    %{
      status: loop.status,
      phase: loop.phase,
      context_revision: loop.context_revision,
      revision: loop.revision,
      wait: loop.wait && %{kind: loop.wait.kind, due_at: loop.wait.due_at}
    }
  end

  defp redacted_request(nil), do: nil

  defp redacted_request(request) do
    %{
      id: request.id,
      operation: request.operation,
      phase: request.phase,
      branch: request.branch
    }
  end

  defp published(loop, key, value) do
    policy = Map.get(loop.metadata, :publication, Map.get(loop.metadata, "publication", %{}))

    if Map.get(policy, key, true),
      do: value,
      else: :redacted
  end

  defp redacted_cognitive(cognitive) do
    Map.take(cognitive, [
      :requested_profile,
      :effective_profile,
      :effective_selection,
      :fallback?,
      :privacy,
      :cost_tier,
      :latency_tier
    ])
  end

  defp redacted_update(nil), do: nil

  defp redacted_update(update) do
    %{
      id: update.id,
      status: update.status,
      requested_at: update.requested_at,
      applied_at: update.applied_at,
      context_revision: update.applied_context_revision,
      invalidations: update.invalidations
    }
  end

  defp redacted_command(nil), do: nil

  defp redacted_command(command) do
    %{
      id: command.id,
      action: command.action,
      mode: command.mode,
      status: command.status,
      desired_state: command.desired_state,
      requested_at: command.requested_at
    }
  end

  defp reconciliation(%{wait: %{kind: :reconciliation}}), do: :required
  defp reconciliation(_loop), do: nil

  defp remaining_budget(budget) do
    Map.new([:steps, :attempts, :retries, :duration_ms, :cost], fn dimension ->
      {dimension, Spectre.Operation.Budget.remaining(budget, dimension)}
    end)
  end
end
