defmodule Spectre.Server.PendingLifecycle do
  @moduledoc false

  alias Spectre.Server.Command

  @commands [:close_pending, :close_pending_after, :cancel_pending_close]

  def configured?(state) do
    case state.gam do
      {module, config} -> configured_port?(module, config, state.opts)
      module -> configured_port?(module, [], state.opts)
    end
  end

  defp configured_port?(module, config, opts) do
    is_atom(module) and not is_nil(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :record_lifecycle, 3) and
      (Keyword.get(opts, :pending_lifecycle, false) or
         (function_exported?(module, :lifecycle_configured?, 1) and
            module.lifecycle_configured?(config)))
  end

  def command?(state, %Command{kind: kind, opts: opts}) do
    kind in @commands or
      (configured?(state) and
         (kind in [:resume_pending, :explain_pending] or
            (kind == :route_current_input and Keyword.has_key?(opts, :suspend))))
  end

  def active?(state, pending_id) do
    Enum.any?(state.outbox, fn {_id, entry} ->
      get_in(entry, [:lifecycle, :requested, :pending_id]) == pending_id
    end)
  end

  def prepare(state, id, entry) do
    {kind, pending_id} = operation(entry.command)

    with :ok <- capability(state),
         {:ok, pending} <- fetch_pending(state, pending_id),
         false <- active?(state, pending_id) do
      opts = entry.command.opts
      revision = Keyword.get(opts, :if_revision, Map.get(pending, :revision, 1))

      deadline =
        Keyword.get(
          opts,
          :deadline,
          deadline(kind, entry.command.args) || get_in(pending, [:close_schedule, :deadline])
        )

      requested = %{
        id: id <> ":requested",
        command_id: id,
        phase: :requested,
        kind: kind,
        pending_id: pending_id,
        revision: revision,
        requested_revision: revision,
        reason: Keyword.get(opts, :reason, default_reason(kind)),
        deadline: deadline,
        timer_owner:
          Keyword.get(opts, :timer, get_in(pending, [:close_schedule, :timer_owner]) || :runtime),
        schedule_id:
          if(kind == :schedule_close,
            do: id,
            else: get_in(pending, [:close_schedule, :command_id])
          ),
        policy_ref: Keyword.get(opts, :policy_ref),
        domain_ref: Map.get(pending, :domain_ref),
        scope_ref: Map.get(pending, :scope_ref),
        principal_ref: Map.get(pending, :principal_ref),
        candidate_ref: reference(Map.get(pending, :candidate)),
        show_ref: show_reference(pending),
        origin_id: event_id(Map.get(pending, :origin)),
        input_id: event_id(entry.event),
        source:
          Keyword.get(
            opts,
            :source,
            if(opts[:if_schedule],
              do: %{schedule_id: opts[:if_schedule]},
              else: schedule_source(pending)
            )
          ),
        from_status: pending.status
      }

      {:ok, %{requested: requested, event: requested, stage: :requested}}
    else
      true ->
        {:error, :lifecycle_reconciliation_required}

      {:error, _} = error ->
        error

      :error ->
        {:ignored,
         %{status: :ignored, kind: kind, pending_id: pending_id, reason: :unknown_pending}}
    end
  end

  defp capability(state) do
    cond do
      is_nil(Keyword.get(state.opts, :checkpoint)) -> {:error, :checkpoint_required}
      not configured?(state) -> {:error, :lifecycle_not_configured}
      true -> :ok
    end
  end

  defp fetch_pending(state, id), do: Map.fetch(state.pending, id)
  defp operation(%Command{kind: :close_pending, args: [id]}), do: {:close, id}

  defp operation(%Command{kind: :close_pending_after, args: [id, _delay]}),
    do: {:schedule_close, id}

  defp operation(%Command{kind: :cancel_pending_close, args: [id]}), do: {:cancel_close, id}
  defp operation(%Command{kind: :resume_pending, args: [id]}), do: {:resume, id}
  defp operation(%Command{kind: :explain_pending, args: [id]}), do: {:resume, id}
  defp operation(%Command{kind: :route_current_input, opts: opts}), do: {:suspend, opts[:suspend]}
  defp deadline(:schedule_close, [_id, delay]), do: System.system_time(:millisecond) + delay
  defp deadline(_kind, _args), do: nil
  defp default_reason(:schedule_close), do: :idle_timeout
  defp default_reason(_), do: :policy
  defp schedule_source(%{close_schedule: %{command_id: id}}), do: %{schedule_id: id}
  defp schedule_source(_), do: :server

  def apply_transition(state, lifecycle) do
    requested = lifecycle.requested
    pending = Map.get(state.pending, requested.pending_id)
    {state, status, reason} = transition(state, pending, requested)
    current = Map.get(state.pending, requested.pending_id)

    report =
      requested
      |> Map.merge(%{
        id: requested.command_id <> ":" <> Atom.to_string(status),
        phase: status,
        from_status: if(pending, do: pending.status, else: :closed),
        status: status,
        outcome_reason: reason,
        to_status: if(current, do: current.status, else: :closed)
      })

    {state, %{lifecycle | event: report, stage: :report}, report}
  end

  defp transition(state, nil, _event), do: {state, :ignored, :already_closed}

  defp transition(state, pending, event) do
    cond do
      Map.get(pending, :revision, 1) != event.revision -> {state, :ignored, :stale_revision}
      stale_schedule?(pending, event.source) -> {state, :ignored, :stale_schedule}
      pending.status in [:resolving, :uncertain] -> ignore_busy(state, pending, event)
      governed_obligation?(state, pending.id) -> ignore_busy(state, pending, event)
      true -> apply_operation(state, pending, event)
    end
  end

  defp ignore_busy(state, pending, %{kind: :close, source: %{schedule_id: _}}) do
    pending = Map.update!(pending, :close_schedule, &Map.put(&1, :fired, true))

    {%{state | pending: Map.put(state.pending, pending.id, pending)}, :ignored,
     :governed_operation_pending}
  end

  defp ignore_busy(state, _pending, _event), do: {state, :ignored, :governed_operation_pending}

  defp stale_schedule?(pending, %{schedule_id: id}),
    do: get_in(pending, [:close_schedule, :command_id]) != id

  defp stale_schedule?(_pending, _source), do: false

  defp governed_obligation?(state, id) do
    Enum.any?(state.outbox, fn {_command_id, entry} ->
      entry.command.kind in [:confirm_pending, :reject_pending, :explain_pending, :resume_pending] and
        entry.command.args == [id] and not Map.has_key?(entry, :lifecycle) and
        not Map.has_key?(entry, :blocked_by)
    end)
  end

  defp apply_operation(state, pending, %{kind: :close}) do
    {drop_pending(state, pending.id), :applied, :closed_by_policy}
  end

  defp apply_operation(state, pending, %{kind: :schedule_close} = event) do
    schedule =
      Map.take(event, [:command_id, :revision, :deadline, :reason, :policy_ref, :timer_owner])

    pending = Map.put(pending, :close_schedule, schedule)
    {%{state | pending: Map.put(state.pending, pending.id, pending)}, :applied, :scheduled}
  end

  defp apply_operation(state, pending, %{kind: :cancel_close}) do
    pending = Map.delete(pending, :close_schedule)
    {%{state | pending: Map.put(state.pending, pending.id, pending)}, :applied, :cancelled}
  end

  defp apply_operation(state, pending, %{kind: :suspend}) do
    pending = %{pending | status: :suspended}

    state = %{
      state
      | pending: Map.put(state.pending, pending.id, pending),
        foreground: foreground(state, pending.id)
    }

    {state, :applied, :suspended}
  end

  defp apply_operation(state, pending, %{kind: :resume}) do
    {%{state | pending: Map.put(state.pending, pending.id, pending)}, :applied, :resume_requested}
  end

  defp drop_pending(state, id),
    do: %{state | pending: Map.delete(state.pending, id), foreground: foreground(state, id)}

  defp foreground(%{foreground: id}, id), do: nil
  defp foreground(state, _id), do: state.foreground

  def continuation(%Command{kind: :route_current_input} = command),
    do: %{command | opts: Keyword.delete(command.opts, :suspend)}

  def continuation(%Command{kind: kind} = command)
      when kind in [:resume_pending, :explain_pending],
      do: command

  def continuation(_command), do: nil

  def receipt?(%{event: event}, {:lifecycle_recorded, receipt}) do
    is_map(receipt) and Map.get(receipt, :event_id) == event.id and
      Map.get(receipt, :event_digest) == Spectre.GAM.Canonical.Value.digest!(event) and
      is_list(Map.get(receipt, :evidence_refs)) and Map.get(receipt, :evidence_refs) != []
  end

  def receipt?(_lifecycle, _result), do: false
  defp reference(%{ref: ref}), do: ref
  defp reference(_), do: nil
  defp show_reference(%{show: %{primary: %{act: %{ref: ref}}}}), do: ref
  defp show_reference(_), do: nil
  defp event_id(%{id: id}), do: id
  defp event_id(_), do: nil
end
