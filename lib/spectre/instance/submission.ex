defmodule Spectre.Instance.Submission do
  @moduledoc false

  # Owns admission of conversational and internal cognitive Runs. It validates
  # ownership and Definition authority, reserves stream capacity, persists the
  # admitted input receipt, and attaches the original caller before scheduling
  # any work. No provider or Effect is started from this module.

  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Input
  alias Spectre.Instance.Conversation
  alias Spectre.Instance.DefinitionCompatibility
  alias Spectre.Instance.Events
  alias Spectre.Instance.Idle
  alias Spectre.Instance.InferenceCapacity
  alias Spectre.Instance.Owner
  alias Spectre.Instance.ReceiptCoordinator
  alias Spectre.Instance.Receipts
  alias Spectre.Instance.RunExecution
  alias Spectre.Instance.RunQueue
  alias Spectre.Instance.Runs
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Value
  alias Spectre.Runtime

  @doc false
  def submit(input, opts, projection, from, %InstanceState{} = data) do
    case {owner_guard(data, :admission), DefinitionCompatibility.validate_turn(data, opts)} do
      {:ok, :ok} -> submit_owned(input, opts, projection, from, data)
      {{:error, reason}, _guard} -> {:reply, {:error, reason}, Idle.arm(data)}
      {:ok, {:error, reason}} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  # Cognitive operations use the same Run/Invocation lifecycle as every other
  # inference, but their Run is internal and state-neutral. A deterministic
  # Run id lets a restarted Operation Runner attach to work already recovered
  # by the Instance instead of dispatching the model twice.
  @doc false
  def submit_cognitive(
        %InferenceRequest{} = request,
        opts,
        from,
        data
      )
      when is_list(opts) do
    input = Keyword.get(opts, :inference_input, %Input{})
    run_id = cognitive_inference_run_id(data, request, opts)

    with :ok <- owner_guard(data, :admission),
         :ok <- Receipts.admission_available?(data),
         :ok <- valid_cognitive_inference_run_id(run_id) do
      case Map.get(data.runs, run_id) do
        %Run{} = run ->
          attach_cognitive_inference(run, request, from, data)

        nil ->
          admit_cognitive_inference(run_id, request, input, opts, from, data)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  def submit_cognitive(request, _opts, _from, data),
    do: {:reply, {:error, {:invalid_cognitive_request, execution_shape(request)}}, Idle.arm(data)}

  defp admit_cognitive_inference(run_id, request, input, opts, from, data) do
    data = Runs.prune_for_new_run(data)

    with true <- map_size(data.runs) < data.max_runs,
         :ok <- Events.authorize(data, Events.active_definition_ref(data), :new_admission),
         admission_opts <- cognitive_inference_admission_opts(run_id, request, opts),
         runtime_opts <- RuntimeOptions.build(data, admission_opts, input),
         {:ok, %Run{} = run} <-
           Runtime.admit_inference(
             data.agent,
             request,
             input,
             data.state,
             runtime_opts,
             admission_opts
           ) do
      entry = %{
        run_id: run.id,
        operation: {:inference, request},
        projection: :inference_response,
        input: run.input,
        opts: runtime_opts,
        state_revision: data.state.revision,
        internal?: true,
        commit_state?: false,
        admitted?: false
      }

      payload = %{
        input: run.input,
        entrypoint: :inference,
        inference_request_id: request.id,
        recoverable?: run.start_continuation.recoverable?,
        recovery_reason: run.start_continuation.reason
      }

      receipt_opts = [
        causation_id: Keyword.get(admission_opts, :causation_id, request.id),
        payload_schema_ref: "spectre.run.input-admitted/1",
        privacy: :confidential
      ]

      retained =
        data
        |> Runs.put_run(run)
        |> put_or_replace_cognitive_caller(run.id, from)

      case Receipts.prepare_run(
             retained,
             data.state,
             run,
             :run_input_admitted,
             payload,
             receipt_opts
           ) do
        {:ok, prepared_receipt} ->
          next =
            ReceiptCoordinator.commit_run(
              retained,
              run,
              {:run_input_admitted, entry},
              prepared_receipt
            )

          {:noreply, next}

        {:error, reason} ->
          {:noreply, RunExecution.fail(retained, run, reason)}
      end
    else
      false -> {:reply, {:error, :instance_run_capacity_reached}, Idle.arm(data)}
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp attach_cognitive_inference(run, request, from, data) do
    with :ok <- cognitive_inference_run_matches(run, request),
         :ok <- Events.authorize(data, run.definition_ref, :continuation) do
      reply_to_cognitive_caller(run, from, data)
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp reply_to_cognitive_caller(%Run{status: :complete} = run, _from, data),
    do: {:reply, RunExecution.cognitive_response(run.result), Idle.arm(data)}

  defp reply_to_cognitive_caller(%Run{status: :failed} = run, _from, data),
    do: {:reply, {:error, run.last_error || :cognitive_inference_failed}, Idle.arm(data)}

  defp reply_to_cognitive_caller(%Run{} = run, from, data) do
    case attach_cognitive_caller(data, run.id, from) do
      {:ok, next} -> {:noreply, Idle.disarm(next)}
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp cognitive_inference_admission_opts(run_id, request, opts) do
    attempt_id = Keyword.get(opts, :operation_attempt_id)
    loop_id = Keyword.get(opts, :operation_loop_id)

    metadata =
      opts
      |> Keyword.get(:run_metadata, %{})
      |> Map.merge(%{
        internal_cognitive_inference: true,
        inference_request_id: request.id,
        inference_purpose: request.purpose,
        operation_attempt_id: attempt_id,
        operation_loop_id: loop_id
      })

    opts
    |> Keyword.delete(:timeout)
    |> Keyword.delete(:inference_input)
    |> Keyword.put(:run_id, run_id)
    |> Keyword.put_new(:trace_id, run_id)
    |> Keyword.put_new(:causation_id, attempt_id || request.id)
    |> Keyword.put_new(:correlation_id, loop_id || attempt_id || request.id)
    |> Keyword.put(:run_metadata, metadata)
  end

  defp cognitive_inference_run_id(data, request, opts) do
    Keyword.get(opts, :run_id) ||
      Value.token(
        "cognitive-inference-run",
        {data.ref.key, Keyword.get(opts, :operation_attempt_id), request.id}
      )
  end

  defp valid_cognitive_inference_run_id(value) when is_binary(value) and value != "", do: :ok
  defp valid_cognitive_inference_run_id(_value), do: {:error, :invalid_cognitive_inference_run_id}

  defp cognitive_inference_run_matches(
         %Run{
           metadata: %{
             internal_cognitive_inference: true,
             inference_request_id: request_id,
             inference_purpose: purpose
           }
         },
         %InferenceRequest{id: request_id, purpose: purpose}
       ),
       do: :ok

  defp cognitive_inference_run_matches(_run, _request),
    do: {:error, :cognitive_inference_run_conflict}

  defp attach_cognitive_caller(data, run_id, from) do
    new_pid = elem(from, 0)

    case Map.get(data.callers, run_id) do
      nil ->
        {:ok, put_or_replace_cognitive_caller(data, run_id, from)}

      {^new_pid, _old_tag} ->
        # A caller may retry after its previous GenServer.call timed out. The
        # new tag must replace the one that can no longer receive a reply.
        {:ok, put_or_replace_cognitive_caller(data, run_id, from)}

      {old_pid, _old_tag} when is_pid(old_pid) ->
        if process_alive?(old_pid),
          do: {:error, :cognitive_inference_already_attached},
          else: {:ok, put_or_replace_cognitive_caller(data, run_id, from)}
    end
  end

  defp put_or_replace_cognitive_caller(data, run_id, from),
    do: %{data | callers: Map.put(data.callers, run_id, from)}

  defp process_alive?(pid) do
    Process.alive?(pid)
  rescue
    _exception -> false
  end

  defp submit_owned(input, opts, projection, from, data) do
    data = Runs.prune_for_new_run(data)

    ownership =
      {Receipts.admission_available?(data), Conversation.policy_owner(data, input, opts)}

    submit_with_owner(ownership, input, opts, projection, from, data)
  end

  defp submit_with_owner({{:error, reason}, _owner}, _input, _opts, _projection, _from, data),
    do: {:reply, {:error, reason}, Idle.arm(data)}

  defp submit_with_owner({:ok, :none}, input, opts, projection, from, data) do
    with :ok <- Events.authorize(data, Events.active_definition_ref(data), :new_admission),
         :ok <- ensure_run_capacity(data) do
      reserve_submitted_run(input, opts, projection, from, data)
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp submit_with_owner(
         {:ok, {:ok, %Run{}}},
         _input,
         _opts,
         :stream,
         _from,
         data
       ),
       do: {:reply, {:error, {:streaming_unsupported, :policy_continuation}}, Idle.arm(data)}

  defp submit_with_owner({:ok, {:ok, %Run{} = owner}}, input, opts, projection, from, data) do
    case Events.authorize(data, owner.definition_ref, :continuation) do
      :ok -> submit_lifecycle_input(input, opts, projection, from, owner, data)
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp submit_with_owner({:ok, {:error, reason}}, _input, _opts, _projection, _from, data),
    do: {:reply, {:error, reason}, Idle.arm(data)}

  defp ensure_run_capacity(data) do
    if map_size(data.runs) < data.max_runs,
      do: :ok,
      else: {:error, :instance_run_capacity_reached}
  end

  defp submit_lifecycle_input(input, opts, projection, from, %Run{} = run, data) do
    case run do
      %Run{status: :boundary, cursor: :policy, waiting: %Boundary{}} ->
        if RunQueue.active?(data, run.id) do
          {:reply, {:error, {:run_already_active, run.id}}, Idle.arm(data)}
        else
          entry = %{
            run_id: run.id,
            operation: {:resume, {:input, input}},
            projection: projection,
            input: input,
            opts: RuntimeOptions.build(data, opts, input),
            state_revision: data.state.revision,
            internal?: false
          }

          {:noreply, data |> RunQueue.enqueue(entry, true) |> RunQueue.put_caller(run.id, from)}
        end

      _invalid ->
        {:reply, {:error, {:run_not_waiting_for_policy, run.id}}, Idle.arm(data)}
    end
  end

  defp reserve_submitted_run(input, opts, projection, from, data) do
    runtime_opts = RuntimeOptions.build(data, opts, input)

    case Runtime.admit(data.agent, input, data.state, runtime_opts, opts) do
      {:ok, %Run{} = run} ->
        reserve_admitted_run(run, input, opts, projection, from, data)

      {:error, reason} ->
        {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp reserve_admitted_run(run, input, opts, projection, from, data) do
    with :ok <- ensure_unique_run(data, run),
         {:ok, reserved, reservation} <- InferenceCapacity.reserve(data, run.id, projection) do
      commit_reserved_run(reserved, run, input, opts, projection, from, reservation)
    else
      {:error, reason} -> {:reply, {:error, reason}, Idle.arm(data)}
    end
  end

  defp ensure_unique_run(data, run) do
    if Map.has_key?(data.runs, run.id) or Map.has_key?(data.tombstones, run.id),
      do: {:error, {:duplicate_instance_run, run.id}},
      else: :ok
  end

  defp commit_reserved_run(reserved, run, input, opts, projection, from, reservation) do
    entry = submitted_run_entry(reserved, run, input, opts, projection, reservation)
    retained = reserved |> Runs.put_run(run) |> RunQueue.put_caller(run.id, from)

    case prepare_admission_receipt(retained, reserved.state, run) do
      {:ok, prepared_receipt} ->
        next =
          ReceiptCoordinator.commit_run(
            retained,
            run,
            {:run_input_admitted, entry},
            prepared_receipt
          )

        {:noreply, next}

      {:error, reason} ->
        next = retained |> InferenceCapacity.release(run.id) |> RunExecution.fail(run, reason)
        {:noreply, next}
    end
  end

  defp submitted_run_entry(reserved, run, input, opts, projection, reservation) do
    %{
      run_id: run.id,
      operation: {:start, input},
      projection: projection,
      input: input,
      opts: opts,
      state_revision: reserved.state.revision,
      internal?: false,
      admitted?: true,
      stream_capacity_reservation: reservation
    }
  end

  defp prepare_admission_receipt(data, state, run) do
    payload = %{
      input: run.input,
      recoverable?: run.start_continuation.recoverable?,
      recovery_reason: run.start_continuation.reason
    }

    receipt_opts = [
      causation_id: run.trace_id,
      payload_schema_ref: "spectre.run.input-admitted/1",
      privacy: :confidential
    ]

    Receipts.prepare_run(data, state, run, :run_input_admitted, payload, receipt_opts)
  end

  defp execution_shape(value) when is_map(value), do: :map
  defp execution_shape(value) when is_list(value), do: :list
  defp execution_shape(value) when is_binary(value), do: :binary
  defp execution_shape(value) when is_tuple(value), do: :tuple
  defp execution_shape(value) when is_atom(value), do: :atom
  defp execution_shape(_value), do: :other

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end
end
