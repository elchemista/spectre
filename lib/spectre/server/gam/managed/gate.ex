defmodule Spectre.Server.GAM.Managed.Gate do
  @moduledoc false
  use GenServer
  alias Spectre.Server.GAM.Managed.Approval
  alias Spectre.GAM.Canonical.Value

  @doc false
  def prepare_external(server, presentation, approver, deadline, revision, skill),
    do:
      GenServer.call(
        server,
        {:prepare_external, presentation, approver, deadline, revision, skill}
      )

  @doc false
  def receive_message(server, message),
    do: GenServer.call(server, {:approval_message, message}, :infinity)

  @doc false
  def reply(server, id, decision, caller),
    do: GenServer.call(server, {:approval_reply, id, decision, caller}, :infinity)

  @doc false
  def external_auth(server, proof), do: GenServer.call(server, {:external_auth, proof})

  @doc false
  def pending_decision(server, ref), do: GenServer.call(server, {:pending_decision, ref})

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc false
  @spec authenticate(pid(), binary()) :: {:ok, map()} | {:error, atom()}
  def authenticate(server, token), do: GenServer.call(server, {:authenticate, token})

  @doc false
  @spec show(pid(), map(), pid(), binary() | nil) ::
          :ok | {:error, atom()} | {:error, :ambiguous, atom()}
  def show(server, material, worker, show_ref \\ nil),
    do: GenServer.call(server, {:show, material, worker, show_ref})

  @doc false
  @spec presented(pid(), binary(), pid()) :: :ok | {:error, atom()}
  def presented(server, ref, caller), do: GenServer.call(server, {:presented, ref, caller})

  @doc false
  @spec bind_deadline(pid(), binary(), integer() | nil | :infinity, binary() | nil) ::
          :ok | {:error, atom()}
  def bind_deadline(server, ref, deadline, show_ref \\ nil),
    do: GenServer.call(server, {:bind_deadline, ref, deadline, show_ref})

  @doc false
  @spec close_show(pid(), binary()) :: :ok
  def close_show(server, show_ref), do: GenServer.call(server, {:close_show, show_ref})

  @doc false
  @spec authorize(pid(), binary(), atom(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize(server, ref, decision, caller),
    do: GenServer.call(server, {:authorize, ref, decision, caller})

  @doc false
  @spec authorize_input(pid(), binary(), binary(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize_input(server, ref, text, caller),
    do: GenServer.call(server, {:authorize_input, ref, text, caller})

  @doc false
  @spec consume(pid(), binary(), atom(), binary() | nil, binary() | nil) :: :ok | {:error, atom()}
  def consume(server, ref, stance, proof, source_digest \\ nil),
    do: GenServer.call(server, {:consume, ref, stance, proof, source_digest})

  @doc false
  def io(server, operation, client), do: GenServer.call(server, {:approval_io, operation, client})

  @doc false
  @spec pause_for_reset(pid(), reference()) :: :ok | {:error, atom()}
  def pause_for_reset(server, token), do: GenServer.call(server, {:pause_for_reset, token})

  @doc false
  @spec resume_reset(pid(), reference()) :: :ok | {:error, atom()}
  def resume_reset(server, token), do: GenServer.call(server, {:resume_reset, token})

  @impl true
  def init(config) do
    {:ok, tasks} = Task.Supervisor.start_link()

    state =
      Map.merge(config, %{
        shows: %{},
        proofs: %{},
        prepared: %{},
        deliveries: %{},
        io: %{},
        reset_token: nil,
        tasks: tasks
      })

    if get_in(config, [:approvals, :signer]) && is_pid(config.consumer),
      do: send(self(), :approval_recovery)

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call({:authenticate, token}, _from, state) do
    reply = if token == state.token, do: {:ok, state.auth}, else: {:error, :unauthenticated}
    {:reply, reply, state}
  end

  def handle_call({:pause_for_reset, token}, {caller, _}, state) do
    cond do
      caller != state.owner or not is_reference(token) ->
        {:reply, {:error, :untrusted_reset_transport}, state}

      state.reset_token == token ->
        {:reply, :ok, state}

      state.reset_token || map_size(state.deliveries) > 0 || map_size(state.io) > 0 ->
        {:reply, {:error, :reset_busy}, state}

      true ->
        {:reply, :ok, %{state | reset_token: token}}
    end
  end

  def handle_call({:resume_reset, token}, {caller, _}, state) do
    cond do
      caller != state.owner ->
        {:reply, {:error, :untrusted_reset_transport}, state}

      state.reset_token == token ->
        {:reply, :ok, %{state | reset_token: nil}}

      true ->
        {:reply, {:error, :reset_busy}, state}
    end
  end

  def handle_call(_request, _from, %{reset_token: token} = state) when not is_nil(token),
    do: {:reply, {:error, :reset_busy}, state}

  def handle_call(
        {:prepare_external, presentation, approver, deadline, revision, skill},
        _,
        state
      ) do
    if map_size(state.prepared) < 256 and is_integer(deadline) and
         min(deadline, elem(approver, 1).expires_at) > System.system_time(:millisecond) do
      prepared = %{
        presentation: presentation,
        approver: approver,
        deadline: deadline,
        revision: revision,
        skill: if(skill, do: skill.id),
        expires_at: deadline
      }

      {:reply, :ok, put_in(state, [:prepared, presentation.ref], prepared)}
    else
      {:reply, {:error, :invalid_external_presentation}, state}
    end
  end

  def handle_call({:show, material, worker, show_ref}, _from, state) do
    state = prune(state)
    ref = material["presentation_ref"]

    show = %{
      worker: worker,
      shown: false,
      authorized: false,
      deadline_bound: false,
      show_ref: show_ref,
      expires_at: System.system_time(:millisecond) + state.show_timeout
    }

    {prepared, remaining} = Map.pop(state.prepared, ref)

    show =
      if prepared do
        Process.send_after(self(), :prune_external_shows, state.show_timeout)

        request =
          Approval.request(
            state.approvals,
            prepared.approver,
            prepared.presentation,
            show_ref,
            prepared.deadline,
            prepared.revision
          )
          |> Map.put("domain_ref", state.domain_ref)

        Map.merge(show, %{request: request, skill: prepared.skill})
      else
        show
      end

    state = %{state | prepared: remaining}

    cond do
      not is_pid(state.consumer) ->
        {:reply, {:error, :presentation_consumer_unavailable}, state}

      Map.has_key?(state.shows, ref) ->
        {:reply, {:error, :presentation_already_pending}, state}

      map_size(state.shows) >= 256 ->
        {:reply, {:error, :presentation_capacity_exceeded}, state}

      true ->
        case deliver_show(state, show, material) do
          {:ok, updated} -> {:reply, :ok, %{updated | shows: Map.put(updated.shows, ref, show)}}
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call({:presented, ref, caller}, {runtime, _}, state) do
    case Map.get(state.shows, ref) do
      %{shown: false, worker: worker, expires_at: deadline} = show ->
        if not Map.has_key?(show, :request) and runtime == state.runtime and
             caller == state.consumer and
             System.system_time(:millisecond) <= deadline do
          send(worker, {:spectre_managed_presented, ref})

          {:reply, :ok,
           %{
             state
             | shows:
                 Map.put(state.shows, ref, %{
                   show
                   | shown: true
                 })
           }}
        else
          {:reply, {:error, :presentation_not_authorized}, state}
        end

      _ ->
        {:reply, {:error, :presentation_not_pending}, state}
    end
  end

  def handle_call({:bind_deadline, ref, deadline, show_ref}, {worker, _}, state)
      when is_integer(deadline) or deadline in [nil, :infinity] do
    deadline = if is_nil(deadline), do: :infinity, else: deadline

    case Map.get(state.shows, ref) do
      %{shown: true, deadline_bound: true, expires_at: ^deadline} ->
        {:reply, :ok, state}

      %{shown: true, worker: ^worker, deadline_bound: false} = show ->
        bound = %{show | deadline_bound: true, expires_at: deadline, show_ref: show_ref}
        {:reply, :ok, %{state | shows: Map.put(state.shows, ref, bound)}}

      _ ->
        {:reply, {:error, :presentation_deadline_not_authorized}, state}
    end
  end

  def handle_call({:close_show, show_ref}, _from, state) do
    state =
      Enum.reduce(state.shows, state, fn
        {_, %{show_ref: ^show_ref, request: request}}, acc -> cancel_request(acc, request)
        _, acc -> acc
      end)

    refs = for {ref, %{show_ref: ^show_ref}} <- state.shows, do: ref
    shows = Map.drop(state.shows, refs)
    proofs = Map.reject(state.proofs, fn {_, proof} -> proof.ref in refs end)
    {:reply, :ok, %{state | shows: shows, proofs: proofs}}
  end

  def handle_call({operation, ref, value, caller}, {runtime, _}, state)
      when operation in [:authorize, :authorize_input] do
    state = prune(state)

    with true <- runtime == state.runtime and caller == state.consumer,
         %{shown: true, deadline_bound: true, expires_at: deadline} = show <-
           Map.get(state.shows, ref),
         false <- Map.has_key?(show, :request),
         {:ok, proof} <- local_proof(operation, value) do
      issue_proof(state, ref, show, Map.put(proof, :expires_at, deadline))
    else
      _ -> {:reply, {:error, :consent_transport_not_authorized}, state}
    end
  end

  def handle_call({:consume, ref, stance, proof, source_digest}, _from, state) do
    state = prune(state)

    case Map.get(state.proofs, proof) do
      %{ref: ^ref, kind: :decision, stance: ^stance} ->
        consumed(state, ref, proof)

      %{ref: ^ref, kind: :input, source_digest: ^source_digest}
      when is_binary(source_digest) and stance in [:supports, :contradicts] ->
        consumed(state, ref, proof)

      _ ->
        {:reply, {:error, :consent_transport_proof_required}, state}
    end
  end

  def handle_call({:approval_io, operation, client}, {runtime, _}, state) do
    if runtime == state.runtime and is_tuple(client),
      do: start_io(state, operation, client, :submitted),
      else: {:reply, {:error, :untrusted_consent_transport}, state}
  end

  def handle_call({:approval_reply, id, decision, caller}, {runtime, _} = from, state) do
    if runtime == state.runtime and caller == state.consumer,
      do: start_io(state, {:reply, id, decision}, from, :deferred),
      else: {:reply, {:error, :untrusted_consent_transport}, state}
  end

  def handle_call({:approval_message, message}, {runtime, _} = from, state)
      when is_map(message) do
    cond do
      runtime != state.runtime or is_nil(state[:approvals]) ->
        {:reply, {:error, :external_approvals_not_configured}, state}

      message["type"] in ["approval.request", "approval.cancelled"] ->
        start_io(state, {:message, message}, from, :deferred)

      true ->
        receive_approval(state, message)
    end
  end

  def handle_call({:approval_message, _}, _, state),
    do: {:reply, {:error, :invalid_approval_message}, state}

  def handle_call({:external_auth, proof}, _, state) do
    state = prune(state)

    case Map.get(state.proofs, proof) do
      %{response: response, request: request, principal: principal} ->
        {:reply,
         {:ok,
          Map.merge(state.auth, %{
            principal: principal,
            authentication: "spectre:external-approval:" <> Value.digest!(response),
            session: response["relates_to"],
            response: response,
            request: request
          })}, state}

      _ ->
        {:reply, :local, state}
    end
  end

  def handle_call({:pending_decision, ref}, _, state) do
    state = prune(state)

    case Map.get(state.shows, ref) do
      %{response: response} -> receive_approval(state, response)
      _ -> {:reply, :none, state}
    end
  end

  defp receive_approval(state, message) do
    state = prune(state)

    with {ref, %{request: request} = show} <-
           Enum.find(state.shows, fn {_, show} ->
             get_in(show, [:request, "id"]) == message["relates_to"]
           end),
         {:ok, trust} <- Approval.verify(state.approvals, request, message) do
      receive_response(state, ref, show, trust, message)
    else
      _ -> {:reply, {:error, :external_approval_not_authorized}, state}
    end
  end

  defp receive_response(state, ref, show, _trust, %{"type" => "approval.presented"}) do
    unless show.shown, do: send(show.worker, {:spectre_managed_presented, ref})
    {:reply, :ok, put_in(state, [:shows, ref, :shown], true)}
  end

  defp receive_response(
         state,
         ref,
         show,
         trust,
         %{"type" => "approval.decision", "decision" => decision} = response
       )
       when decision in ["confirm", "reject"] do
    case Map.get(show, :response, response) do
      ^response ->
        unless show.shown, do: send(show.worker, {:spectre_managed_presented, ref})
        show = Map.merge(show, %{shown: true, response: response})
        state = put_in(state, [:shows, ref], show)

        if show.deadline_bound,
          do: authorize_external(state, ref, show, trust, response),
          else: {:reply, :ok, state}

      _ ->
        {:reply, {:error, :approval_already_decided}, state}
    end
  end

  defp receive_response(state, _, _, _, _), do: {:reply, {:error, :approval_not_ready}, state}

  defp authorize_external(state, ref, show, trust, response) do
    decision = response["decision"]
    decision = if decision == "confirm", do: :confirm, else: :reject
    stance = if decision == :confirm, do: :supports, else: :contradicts

    case Enum.find(state.proofs, fn {_, proof} -> proof.ref == ref end) do
      {proof, %{response: ^response}} ->
        {:reply, {:decision, show.skill, ref, decision, proof}, state}

      nil ->
        {:reply, {:ok, proof}, updated} =
          issue_proof(state, ref, show, %{
            kind: :decision,
            stance: stance,
            expires_at: min(show.expires_at, show.request["expires_at"]),
            principal: trust.principal.ref,
            response: response,
            request: show.request
          })

        {:reply, {:decision, show.skill, ref, decision, proof}, updated}

      _ ->
        {:reply, {:error, :approval_already_decided}, state}
    end
  end

  defp deliver_show(state, %{request: request}, material),
    do: dispatch_delivery(state, request, {:show, material["presentation_ref"]})

  defp deliver_show(state, _show, material) do
    send(state.consumer, {Spectre.Server.GAM.Managed, state.owner, {:presentation, material}})
    {:ok, state}
  end

  defp delivery_capacity(state) do
    if map_size(state.deliveries) < 256,
      do: :ok,
      else: {:error, :approval_delivery_capacity_exceeded}
  end

  defp local_proof(:authorize, decision) when decision in [:confirm, :reject],
    do:
      {:ok,
       %{kind: :decision, stance: if(decision == :confirm, do: :supports, else: :contradicts)}}

  defp local_proof(:authorize_input, text) when is_binary(text) and byte_size(text) > 0,
    do:
      {:ok,
       %{kind: :input, source_digest: Base.encode16(:crypto.hash(:sha256, text), case: :lower)}}

  defp local_proof(_, _), do: {:error, :consent_transport_not_authorized}

  defp dispatch_delivery(state, message, kind) do
    with :ok <- delivery_capacity(state) do
      transport = Map.take(state.approvals, [:transport])

      task =
        Task.Supervisor.async_nolink(state.tasks, fn ->
          Approval.send_message(transport, message)
        end)

      timer = Process.send_after(self(), {:delivery_timeout, task.ref}, state.show_timeout)
      delivery = %{task: task, timer: timer, kind: kind, message: message}
      {:ok, put_in(state, [:deliveries, task.ref], delivery)}
    end
  end

  @spec issue_proof(map(), binary(), map(), map()) :: {:reply, {:ok, binary()}, map()}
  defp issue_proof(state, ref, show, value) do
    proof = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    value = Map.put(value, :ref, ref)

    proofs =
      state.proofs |> Map.reject(fn {_, old} -> old.ref == ref end) |> Map.put(proof, value)

    {:reply, {:ok, proof},
     %{state | proofs: proofs, shows: Map.put(state.shows, ref, %{show | authorized: true})}}
  end

  @spec consumed(map(), binary(), binary()) :: {:reply, :ok, map()}
  defp consumed(state, ref, proof),
    do:
      {:reply, :ok,
       %{state | proofs: Map.delete(state.proofs, proof), shows: Map.delete(state.shows, ref)}}

  @impl true
  def handle_info(:prune_external_shows, %{reset_token: token} = state) when not is_nil(token),
    do: {:noreply, state}

  def handle_info(:prune_external_shows, state), do: {:noreply, prune(state)}

  def handle_info(:approval_recovery, %{reset_token: token} = state) when not is_nil(token),
    do: {:noreply, state}

  def handle_info(:approval_recovery, state) do
    case start_io(state, {:recover, []}, nil, :deferred) do
      {:noreply, next} ->
        {:noreply, next}

      {:reply, error, next} ->
        inbox_event(next, %{event: :recovery_failed, result: error})
        {:noreply, next}
    end
  end

  def handle_info(:approval_tick, state) do
    inbox_event(state, %{event: :tick})
    {:noreply, schedule_tick(state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    if Map.has_key?(state.io, ref),
      do: finish_io(state, ref, result),
      else: finish_delivery(state, ref, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    if Map.has_key?(state.io, ref),
      do: finish_io(state, ref, {:error, :approval_storage_unknown}),
      else: finish_delivery(state, ref, {:error, :approval_delivery_unknown})
  end

  def handle_info({:approval_io_timeout, ref}, state) do
    if task = state.io[ref], do: Process.exit(task.task.pid, :kill)
    finish_io(state, ref, {:error, :approval_storage_unknown})
  end

  def handle_info({:delivery_timeout, ref}, state) do
    case Map.get(state.deliveries, ref) do
      %{task: task} -> Process.exit(task.pid, :kill)
      _ -> :ok
    end

    finish_delivery(state, ref, {:error, :approval_delivery_timeout})
  end

  defp start_io(state, operation, client, mode) do
    config = state[:approvals]
    caller = if client, do: elem(client, 0)

    cond do
      is_nil(config) ->
        {:reply, {:error, :external_approvals_not_configured}, state}

      not is_pid(state.consumer) or not io_authorized?(operation, caller, state.consumer) ->
        {:reply, {:error, :untrusted_consent_transport}, state}

      map_size(state.io) >= config.io_workers ->
        storage_failure(state, operation, :approval_store_busy)
        {:reply, {:error, :approval_store_busy}, state}

      true ->
        store = state.store

        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            try do
              run_io(config, store, operation)
            rescue
              _ -> {:error, :approval_storage_unknown}
            catch
              _, _ -> {:error, :approval_storage_unknown}
            end
          end)

        timer = Process.send_after(self(), {:approval_io_timeout, task.ref}, config.io_timeout)
        entry = %{task: task, timer: timer, client: client, operation: operation}
        next = put_in(state, [:io, task.ref], entry)
        if mode == :submitted, do: {:reply, :ok, next}, else: {:noreply, next}
    end
  end

  defp io_authorized?({:message, %{"type" => type}}, _, _)
       when type in ["approval.request", "approval.cancelled"], do: true

  defp io_authorized?({:recover, _}, nil, _), do: true

  defp io_authorized?({kind, _}, caller, consumer) when kind in [:list, :fetch],
    do: caller == consumer

  defp io_authorized?({:reply, _, decision}, caller, consumer)
       when decision in [:presented, :confirm, :reject], do: caller == consumer

  defp io_authorized?(_, _, _), do: false

  defp run_io(config, store, {:message, %{"type" => "approval.request"} = message}),
    do: Approval.receive_request(config, store, message)

  defp run_io(config, store, {:message, message}),
    do: Approval.cancel_inbox(config, store, message)

  defp run_io(config, store, {:reply, reference, decision}),
    do: Approval.prepare_reply(config, store, reference, decision)

  defp run_io(config, store, {:list, opts}), do: Approval.list(config, store, opts)
  defp run_io(config, store, {:fetch, reference}), do: Approval.fetch(config, store, reference)
  defp run_io(config, store, {:recover, _}), do: Approval.list(config, store, limit: 1)

  defp finish_io(state, ref, result) do
    finish_task(state, :io, ref, fn next, entry ->
      {reply, next} = io_result(next, entry.operation, result)
      if entry.client, do: GenServer.reply(entry.client, reply)
      next
    end)
  end

  defp io_result(state, {:message, _}, {:ok, event, view}) do
    cond do
      event in [:received, :duplicate] and view.status == :pending ->
        send(state.consumer, {Spectre.Server, state.runtime, {:approval_request, view.request}})

      event == :cancelled ->
        send(
          state.consumer,
          {Spectre.Server, state.runtime, {:approval_cancelled, view.reference.id}}
        )

      true ->
        :ok
    end

    inbox_event(state, %{event: event, reference: view.reference, status: view.status})
    {:ok, state}
  end

  defp io_result(state, {:reply, _id, decision}, {:ok, response}) do
    inbox_event(state, %{
      event: if(decision == :presented, do: :presented, else: :decided),
      reference: %{id: response["relates_to"], from: response["to"]}
    })

    case dispatch_delivery(state, response, {:reply, response["relates_to"]}) do
      {:ok, next} -> {:ok, next}
      error -> {error, state}
    end
  end

  defp io_result(state, {:recover, _}, result) do
    event = if match?({:ok, _}, result), do: :recovered, else: :recovery_failed
    inbox_event(state, %{event: event})
    if match?({:error, _}, result), do: storage_failure(state, {:recover, []}, elem(result, 1))
    {:ok, state}
  end

  defp io_result(state, operation, {:error, {:approval_store, _} = reason} = result) do
    storage_failure(state, operation, reason)
    {result, state}
  end

  defp io_result(state, operation, {:error, reason} = result)
       when reason in [:approval_storage_unknown, :approval_store_conflict] do
    storage_failure(state, operation, reason)
    {result, state}
  end

  defp io_result(state, _operation, result), do: {result, state}

  defp storage_failure(state, operation, reason) do
    event = Map.merge(storage_operation(operation), %{event: :storage_error, reason: reason})
    inbox_event(state, event)
  end

  defp storage_operation({:message, %{"type" => "approval.request"} = request}),
    do: %{
      operation: :receive,
      reference: %{id: request["id"], from: request["from"]},
      request: request
    }

  defp storage_operation({:message, message}),
    do: %{
      operation: :cancel,
      reference: %{id: message["relates_to"], from: message["from"]},
      message: message
    }

  defp storage_operation({:reply, reference, decision}),
    do: %{operation: :reply, reference: reference, decision: decision}

  defp storage_operation({:fetch, reference}), do: %{operation: :fetch, reference: reference}
  defp storage_operation({operation, _}), do: %{operation: operation}

  defp inbox_event(state, event) do
    if state[:runtime_control] do
      send(state.runtime, {Spectre.Server.Runtime, state.runtime_control, :approval_event, event})
    end

    if is_pid(state.consumer) and event.event in [:recovered, :recovery_failed, :storage_error],
      do: send(state.consumer, {Spectre.Server, state.runtime, {:approval_inbox, event}})

    :ok
  end

  defp schedule_tick(state) do
    interval = if state[:approvals], do: state.approvals.maintenance_interval

    if interval do
      timer = Process.send_after(self(), :approval_tick, interval)
      Map.put(state, :maintenance_timer, timer)
    else
      state
    end
  end

  defp finish_delivery(state, ref, result),
    do: finish_task(state, :deliveries, ref, &delivery_result(&1, &2, result))

  defp finish_task(state, collection, ref, complete) do
    case pop_in(state, [collection, ref]) do
      {nil, _} ->
        {:noreply, state}

      {entry, next} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(ref, [:flush])
        {:noreply, complete.(next, entry)}
    end
  end

  defp delivery_result(state, %{kind: {:show, ref}}, result) do
    case {Map.get(state.shows, ref), result} do
      {_, {:ok, _}} ->
        state

      {%{shown: false} = show, error} ->
        {certainty, reason} = delivery_failure(error)
        send(show.worker, {:spectre_managed_show_failed, ref, certainty, reason})
        cancel_request(%{state | shows: Map.delete(state.shows, ref)}, show.request)

      _ ->
        state
    end
  end

  defp delivery_result(state, %{kind: {:reply, id}, message: message}, result) do
    status =
      case result do
        {:ok, _} -> :accepted
        {:error, %{outcome: :not_sent}} -> :not_sent
        _ -> :unknown
      end

    send(
      state.consumer,
      {Spectre.Server, state.runtime,
       {:approval_delivery,
        %{request_id: id, message_id: message["id"], type: message["type"], status: status}}}
    )

    state
  end

  defp delivery_result(state, _delivery, _result), do: state

  defp delivery_failure({:error, %{outcome: :not_sent}}),
    do: {:definitive_no_effect, :approval_request_not_sent}

  defp delivery_failure(_), do: {:ambiguous, :approval_delivery_unknown}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.merge(state.deliveries, state.io), fn {_, delivery} ->
      Process.cancel_timer(delivery.timer)
      Process.exit(delivery.task.pid, :kill)
      if delivery[:client], do: GenServer.reply(delivery.client, {:error, :approval_store_closed})
    end)

    if state[:maintenance_timer], do: Process.cancel_timer(state.maintenance_timer)
    if Process.alive?(state.tasks), do: Supervisor.stop(state.tasks)
  end

  @impl true
  def format_status(status) do
    state = status.state

    %{
      status
      | state: %{
          pending_presentations: map_size(state.shows),
          pending_decisions: map_size(state.proofs)
        }
    }
  end

  @spec expired?(integer() | :infinity, integer()) :: boolean()
  defp expired?(:infinity, _now), do: false
  defp expired?(deadline, now), do: deadline <= now

  @spec prune(map()) :: map()
  defp prune(state) do
    now = System.system_time(:millisecond)

    state =
      Enum.reduce(state.shows, state, fn
        {_, %{request: request, expires_at: deadline}}, acc ->
          if expired?(deadline, now), do: cancel_request(acc, request), else: acc

        _, acc ->
          acc
      end)

    %{
      state
      | prepared:
          Map.reject(state.prepared, fn {_, value} -> expired?(value.expires_at, now) end),
        shows: Map.reject(state.shows, fn {_, value} -> expired?(value.expires_at, now) end),
        proofs: Map.reject(state.proofs, fn {_, value} -> expired?(value.expires_at, now) end)
    }
  end

  defp cancel_request(state, request) do
    message = %{
      "type" => "approval.cancelled",
      "id" => Spectre.Identity.uuid7(),
      "from" => request["from"],
      "to" => request["to"],
      "relates_to" => request["id"],
      "request_digest" => Value.digest!(request)
    }

    case dispatch_delivery(state, message, :cancel) do
      {:ok, updated} -> updated
      {:error, _} -> state
    end
  end
end
