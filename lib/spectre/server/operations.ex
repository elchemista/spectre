defmodule Spectre.Server.Operations do
  @moduledoc false

  def record(state, worker, {:governed, %{act: %{ref: act_ref} = act, outcome: outcome}} = result) do
    if terminal?(outcome) do
      operations =
        Map.reject(state.operations, fn {_id, operation} -> operation.act_ref == act_ref end)

      %{state | operations: operations}
    else
      retain(state, worker, act, result)
    end
  end

  def record(state, _worker, _result), do: state

  def matching(state, id, act) do
    case Map.get(state.operations, id) do
      %{act_ref: ref, candidate_identity_key: identity, scope_ref: scope, material_digest: digest}
      when ref == act.ref and identity == act.candidate_identity_key and scope == act.scope_ref and
             digest == act.material_digest ->
        :ok

      nil ->
        {:error, :unknown_command_continuation}

      _ ->
        {:error, :result_continuation_mismatch}
    end
  end

  def continuation(state, id) do
    case Map.fetch(state.operations, id) do
      {:ok, operation} ->
        {:ok, %{kind: :delivery, tag: operation.tag, event: operation.event, command_id: id}}

      :error ->
        {:error, :unknown_command_continuation}
    end
  end

  def seen_result?(state, id, result_key) do
    case Map.get(state.operations, id) do
      %{result_keys: keys} -> result_key in keys
      _ -> false
    end
  end

  defp retain(state, worker, act, result) do
    pending = Map.get(state.pending, Map.get(worker, :pending_id), %{})
    id = Map.get(worker, :command_id) || Map.get(pending, :command_id)

    if id do
      previous = Map.get(state.operations, id, %{})
      {:ok, key} = Spectre.Server.GAM.result_key(result)

      operation = %{
        act_ref: act.ref,
        candidate_identity_key: act.candidate_identity_key,
        scope_ref: act.scope_ref,
        material_digest: act.material_digest,
        result_keys: Enum.uniq([key | Map.get(previous, :result_keys, [])]),
        tag: worker.tag,
        event: worker.event
      }

      %{state | operations: Map.put(state.operations, id, operation)}
    else
      state
    end
  end

  # A no-effect report can be contradicted by a later authenticated observation.
  # Keep its continuation until the kernel records success or failure.
  defp terminal?(%{status: status}) when status in [:succeeded, :failed],
    do: true

  defp terminal?(_), do: false
end
