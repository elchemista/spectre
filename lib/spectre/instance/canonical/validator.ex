defmodule Spectre.Instance.Canonical.Validator do
  @moduledoc false

  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Operation.Control
  alias Spectre.Operation.Delivery.Consent, as: DeliveryConsent
  alias Spectre.Operation.Delivery.Receipt, as: DeliveryReceipt
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Operation.Runtime, as: OperationRuntime
  alias Spectre.Run
  alias Spectre.State
  alias Spectre.State.Codec, as: StateCodec

  @default_event_limit 512
  @required_loop_correlation_keys MapSet.new([:loop_id, :loop_kind, :revision])
  @loop_correlation_keys MapSet.new([:loop_id, :loop_kind, :revision, :causation_id])

  @spec validate(Canonical.t(), Spectre.Instance.Ref.t(), keyword()) ::
          :ok | {:error, term()}
  def validate(canonical, instance_ref, opts \\ []) do
    event_limit = normalize_event_limit(Keyword.get(opts, :event_limit, @default_event_limit))

    with :ok <- Canonical.validate(canonical),
         {:ok, %State{} = flow} <- Canonical.fetch(canonical, :flow),
         :ok <- validate_flow(flow),
         {:ok, activation} <- Canonical.fetch(canonical, :activation),
         :ok <- validate_activation(activation),
         {:ok, runs} <- Canonical.fetch(canonical, :runs),
         :ok <- validate_runs(runs),
         {:ok, loops} <- validate_loops(canonical),
         :ok <- validate_controls(canonical, loops, instance_ref),
         :ok <- validate_events(canonical, loops, event_limit),
         :ok <- validate_correlations(canonical, loops, instance_ref) do
      :ok
    else
      {:ok, value} -> {:error, {:invalid_canonical_flow_state, value}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_flow(%State{} = state) do
    case StateCodec.encode(state) do
      {:ok, _encoded} -> :ok
      {:error, reason} -> {:error, {:invalid_canonical_flow_state, reason}}
    end
  end

  defp validate_activation(nil), do: :ok

  defp validate_activation(%Activation{} = activation) do
    case Activation.build(Map.from_struct(activation)) do
      {:ok, ^activation} -> :ok
      {:ok, _rebuilt} -> {:error, :canonical_activation_integrity_mismatch}
      {:error, reason} -> {:error, {:invalid_canonical_activation, reason}}
    end
  end

  defp validate_activation(value), do: {:error, {:invalid_canonical_activation, value}}

  defp validate_runs(runs) when is_map(runs) and not is_struct(runs) do
    Enum.reduce_while(runs, :ok, fn
      {run_id, checkpoint}, :ok
      when is_binary(run_id) and run_id != "" and is_binary(checkpoint) ->
        case Run.restore(checkpoint) do
          {:ok, %Run{id: ^run_id}} ->
            {:cont, :ok}

          {:ok, %Run{id: restored_id}} ->
            {:halt, {:error, {:canonical_run_id_mismatch, run_id, restored_id}}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_canonical_run_checkpoint, run_id, reason}}}
        end

      {run_id, _checkpoint}, :ok ->
        {:halt, {:error, {:invalid_canonical_run_entry, run_id}}}
    end)
  end

  defp validate_runs(value), do: {:error, {:invalid_canonical_runs, value}}

  defp validate_loops(canonical) do
    Enum.reduce_while([:work, :vigil, :directive], {:ok, %{}}, fn kind, {:ok, loops} ->
      with {:ok, section} <- Canonical.fetch(canonical, kind),
           true <- is_map(section) and not is_struct(section),
           {:ok, validated} <- validate_loop_section(section, kind) do
        if Enum.any?(Map.keys(validated), &Map.has_key?(loops, &1)) do
          {:halt, {:error, :duplicate_canonical_operational_loop}}
        else
          {:cont, {:ok, Map.merge(loops, validated)}}
        end
      else
        false -> {:halt, {:error, {:invalid_canonical_loop_section, kind}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_loop_section(section, kind) do
    Enum.reduce_while(section, {:ok, %{}}, fn
      {id, %OperationLoop{id: id, kind: ^kind} = loop}, {:ok, loops}
      when is_binary(id) and id != "" ->
        case OperationLoop.validate(loop) do
          :ok -> {:cont, {:ok, Map.put(loops, id, loop)}}
          {:error, reason} -> {:halt, {:error, {:invalid_canonical_loop, id, reason}}}
        end

      {id, _loop}, _acc ->
        {:halt, {:error, {:invalid_canonical_loop_entry, kind, id}}}
    end)
  end

  defp validate_controls(canonical, loops, instance_ref) do
    with {:ok, controls} <- Canonical.fetch(canonical, :control),
         true <- is_map(controls) and not is_struct(controls),
         true <- MapSet.new(Map.keys(controls)) == MapSet.new(Map.keys(loops)) do
      env = %{
        agent: instance_ref.agent_ref.definition,
        subject_id: instance_ref.subject.id,
        epoch: "checkpoint-validation",
        snapshot_id: "checkpoint-validation",
        canonical_revision: canonical.revision,
        committed: %{},
        now: System.system_time(:millisecond)
      }

      Enum.reduce_while(loops, :ok, fn {id, loop}, :ok ->
        case Map.fetch(controls, id) do
          {:ok, %Control{loop_id: ^id} = control} ->
            case OperationRuntime.validate_checkpoint(loop, control, env) do
              :ok ->
                {:cont, :ok}

              {:error, reason} ->
                {:halt, {:error, {:invalid_canonical_operational_checkpoint, id, reason}}}
            end

          _invalid ->
            {:halt, {:error, {:invalid_canonical_loop_control, id}}}
        end
      end)
    else
      false -> {:error, :canonical_loop_control_set_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_events(canonical, loops, event_limit) do
    with {:ok, events} <- Canonical.fetch(canonical, :events),
         true <- is_map(events) and not is_struct(events),
         true <- MapSet.new(Map.keys(events)) == MapSet.new([:records, :ids]),
         records when is_list(records) <- Map.get(events, :records),
         ids when is_map(ids) and not is_struct(ids) <- Map.get(events, :ids),
         true <- length(records) <= event_limit,
         :ok <- validate_event_records(records, loops, canonical.revision),
         true <- ids == Map.new(records, &{&1.id, &1.revision}) do
      :ok
    else
      false -> {:error, :invalid_canonical_operation_events}
      nil -> {:error, :invalid_canonical_operation_events}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_canonical_operation_events}
    end
  end

  defp validate_event_records(records, loops, canonical_revision) do
    ids =
      Enum.map(records, fn
        %OperationEvent{id: id} -> id
        _invalid -> nil
      end)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_canonical_operation_event}
    else
      Enum.reduce_while(records, :ok, fn
        %OperationEvent{} = event, :ok ->
          case {OperationEvent.validate(event), Map.get(loops, event.loop_id)} do
            {:ok, %OperationLoop{kind: kind}}
            when kind == event.loop_kind and event.revision <= canonical_revision ->
              {:cont, :ok}

            {:ok, _loop} ->
              {:halt, {:error, {:operation_event_loop_mismatch, event.id}}}

            {{:error, reason}, _loop} ->
              {:halt, {:error, {:invalid_canonical_operation_event, event.id, reason}}}
          end

        _invalid, :ok ->
          {:halt, {:error, :invalid_canonical_operation_event}}
      end)
    end
  end

  defp validate_correlations(canonical, loops, instance_ref) do
    with {:ok, correlations} <- Canonical.fetch(canonical, :correlations),
         true <- is_map(correlations) and not is_struct(correlations),
         :ok <- validate_instance_key(correlations, instance_ref) do
      loop_correlation_ids =
        loops
        |> Map.values()
        |> MapSet.new(& &1.correlation_id)

      Enum.reduce_while(correlations, :ok, fn
        {:instance_key, _key}, :ok ->
          {:cont, :ok}

        {key, %DeliveryConsent{} = consent}, :ok ->
          validate_consent_correlation(key, consent, instance_ref)

        {key, %DeliveryReceipt{} = receipt}, :ok ->
          validate_receipt_correlation(key, receipt, loops, instance_ref)

        {key, value}, :ok when is_map(value) ->
          if loop_correlation?(key, value, loop_correlation_ids) do
            validate_loop_correlation(key, value, loops, canonical.revision)
          else
            {:cont, :ok}
          end

        {_key, _extension_value}, :ok ->
          {:cont, :ok}
      end)
    else
      false -> {:error, :invalid_canonical_correlations}
      {:error, _reason} = error -> error
    end
  end

  defp validate_consent_correlation(key, consent, instance_ref) do
    case DeliveryConsent.validate(consent) do
      :ok when consent.subject_id != instance_ref.subject.id ->
        {:halt, {:error, :delivery_consent_subject_mismatch}}

      :ok when key != "delivery:consent:" <> consent.id ->
        {:halt, {:error, :delivery_consent_key_mismatch}}

      :ok ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, {:invalid_delivery_consent, reason}}}
    end
  end

  defp validate_receipt_correlation(key, receipt, loops, instance_ref) do
    case {DeliveryReceipt.validate(receipt), Map.get(loops, receipt.loop_id)} do
      {:ok, %OperationLoop{subject_id: subject_id}}
      when subject_id == receipt.subject_id and subject_id == instance_ref.subject.id ->
        if key == "delivery:receipt:" <> receipt.id,
          do: {:cont, :ok},
          else: {:halt, {:error, :delivery_receipt_key_mismatch}}

      {:ok, _loop} ->
        {:halt, {:error, :delivery_receipt_loop_mismatch}}

      {{:error, reason}, _loop} ->
        {:halt, {:error, {:invalid_delivery_receipt, reason}}}
    end
  end

  defp loop_correlation?(key, value, loop_correlation_ids) do
    keys = MapSet.new(Map.keys(value))

    MapSet.member?(loop_correlation_ids, key) or
      MapSet.subset?(@required_loop_correlation_keys, keys)
  end

  defp validate_loop_correlation(key, correlation, loops, canonical_revision) do
    keys = MapSet.new(Map.keys(correlation))

    with true <- is_binary(key) and key != "",
         true <- MapSet.subset?(@required_loop_correlation_keys, keys),
         true <- MapSet.subset?(keys, @loop_correlation_keys),
         %{loop_id: loop_id, loop_kind: kind, revision: revision} <- correlation,
         true <- is_binary(loop_id) and loop_id != "",
         true <- kind in [:work, :vigil, :directive],
         true <- is_integer(revision) and revision >= 0 and revision <= canonical_revision,
         true <- valid_optional_binary?(Map.get(correlation, :causation_id)),
         %OperationLoop{kind: ^kind} <- Map.get(loops, loop_id) do
      {:cont, :ok}
    else
      %OperationLoop{} -> {:halt, {:error, :canonical_loop_correlation_mismatch}}
      nil -> {:halt, {:error, :canonical_loop_correlation_mismatch}}
      false -> {:halt, {:error, :invalid_canonical_loop_correlation}}
      _invalid -> {:halt, {:error, :invalid_canonical_loop_correlation}}
    end
  end

  defp validate_instance_key(correlations, instance_ref) do
    case Map.get(correlations, :instance_key) do
      key when key == instance_ref.key -> :ok
      _other -> {:error, :canonical_checkpoint_instance_mismatch}
    end
  end

  defp valid_optional_binary?(nil), do: true
  defp valid_optional_binary?(value), do: is_binary(value) and value != ""

  defp normalize_event_limit(value) when is_integer(value) and value >= 0, do: value
  defp normalize_event_limit(_value), do: @default_event_limit
end
