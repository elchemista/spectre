defmodule Spectre.Instance.Projection do
  @moduledoc false

  # Builds the read-only diagnostic view returned by `Instance.info/1`. The
  # projection intentionally exposes stable identifiers and revisions while
  # keeping worker capabilities, monitor references, receipt payloads, and
  # provider credentials private.

  alias Spectre.AgentRef
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Loops
  alias Spectre.Instance.Runs
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.View, as: OperationView
  alias Spectre.Subject

  @doc false
  @spec info(InstanceState.t()) :: map()
  def info(%InstanceState{} = data) do
    %{
      ref: data.ref.key,
      agent_ref: AgentRef.key(data.agent_ref),
      subject: Subject.key(data.subject),
      generation: data.generation,
      activation: activation(data.activation),
      owner_fencing_token: data.owner_lease.fencing_token,
      state_revision: data.state.revision,
      canonical_revision: data.canonical.revision,
      conversations: data.conversations,
      runs: Map.new(data.runs, fn {id, run} -> {id, Runs.run_projection(run)} end),
      ready: :queue.to_list(data.ready),
      active_run: data.active && data.active.run_id,
      invocations:
        Map.new(data.invocations, fn {id, ownership} ->
          {id, %{run_id: ownership.run_id, run_revision: ownership.run_revision}}
        end),
      tombstones: data.tombstones,
      operational_loops:
        Map.new(Loops.all_operation_loops(data), fn {loop, control} ->
          {loop.id, OperationView.from_loop(loop, control)}
        end),
      operation_runners:
        Map.new(data.operation_runners, fn {attempt_id, ownership} ->
          {attempt_id, %{loop_id: ownership.loop_id, operation: ownership.operation}}
        end)
    }
  end

  defp activation(nil), do: nil

  defp activation(%Activation{} = activation) do
    %{
      definition_ref: activation.definition_ref,
      candidate_ref: activation.candidate_ref,
      generation: activation.generation,
      authority_epoch: activation.authority_epoch,
      closure_digest: activation.closure_digest
    }
  end
end
