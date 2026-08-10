defmodule Spectre.Instance.Events do
  @moduledoc false

  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Event.Envelope
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Lifecycle
  alias Spectre.Instance.Loops
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Invocation
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref, as: RunRef

  @event_limit 512
  @run_classes [:reply, :policy_answer, :flow_progress, :flow_completion]
  @operation_classes [:work_progress, :work_completion, :vigil_progress, :vigil_completion]

  @spec admit(InstanceState.t(), Envelope.t() | map() | keyword(), keyword()) ::
          {:ok, Envelope.t(), InstanceState.t()} | {:error, term()}
  def admit(%InstanceState{} = data, value, opts) when is_list(opts) do
    with {:ok, pending} <- pending_envelope(value),
         :new <- existing_event(data, pending),
         resolution <- resolve_owner(data, pending, opts),
         {:ok, envelope} <- materialize_admission(data, resolution, opts),
         {:ok, next} <- commit_event(data, envelope) do
      {:ok, envelope, next}
    else
      {:existing, %Envelope{} = envelope} -> {:ok, envelope, data}
      {:conflict, id} -> {:error, {:event_id_conflict, id}}
      {:error, _reason} = error -> error
    end
  end

  @spec list(InstanceState.t(), :admitted | :quarantined, keyword()) :: [Envelope.t()]
  def list(%InstanceState{} = data, status, opts \\ [])
      when status in [:admitted, :quarantined] and is_list(opts) do
    section = event_section(status)
    event_class = Keyword.get(opts, :event_class)
    limit = normalize_limit(Keyword.get(opts, :limit, @event_limit))

    data.canonical
    |> Canonical.fetch(section)
    |> case do
      {:ok, %{records: records}} -> records
      _invalid -> []
    end
    |> Enum.filter(&(is_nil(event_class) or &1.event_class == event_class))
    |> Enum.take(limit)
  end

  @spec lifecycle(InstanceState.t(), DefinitionRef.t()) :: Lifecycle.t()
  def lifecycle(%InstanceState{} = data, %DefinitionRef{} = definition_ref) do
    active = active_definition_ref(data)
    activation = if same_ref?(active, definition_ref), do: :active, else: :inactive
    Lifecycle.fetch(lifecycle_map(data), definition_ref, activation: activation)
  end

  @spec authorize(InstanceState.t(), DefinitionRef.t(), atom()) :: :ok | {:error, term()}
  def authorize(%InstanceState{} = data, %DefinitionRef{} = definition_ref, operation) do
    data
    |> lifecycle(definition_ref)
    |> Lifecycle.authorize(operation)
  end

  @spec transition_lifecycle(
          InstanceState.t(),
          DefinitionRef.t(),
          Lifecycle.axis(),
          atom(),
          keyword()
        ) :: {:ok, Lifecycle.t(), InstanceState.t()} | {:error, term()}
  def transition_lifecycle(
        %InstanceState{} = data,
        %DefinitionRef{} = definition_ref,
        axis,
        value,
        opts
      )
      when axis in [:admission, :authority, :retention] and is_list(opts) do
    current = lifecycle(data, definition_ref)

    with :ok <- retention_transition_safe(data, current, axis, value),
         {:ok, lifecycle} <- Lifecycle.transition(current, axis, value, opts),
         lifecycles <- Map.put(lifecycle_map(data), Lifecycle.key(lifecycle), lifecycle),
         {:ok, next} <-
           Commit.canonical_sections(data, %{lifecycles: lifecycles},
             correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
             causation_id: Keyword.get(opts, :causation_id),
             provenance:
               Keyword.get(opts, :provenance, %{
                 source: :definition_lifecycle,
                 definition_ref: Lifecycle.key(lifecycle)
               }),
             metadata: %{
               transition: :definition_lifecycle_changed,
               axis: axis,
               value: value,
               lifecycle_revision: lifecycle.revision,
               authority_epoch: lifecycle.authority_epoch
             }
           ) do
      {:ok, lifecycle, next}
    end
  end

  def transition_lifecycle(%InstanceState{}, _definition_ref, axis, value, _opts),
    do: {:error, {:invalid_definition_lifecycle_transition, axis, value}}

  @spec activation_lifecycles(InstanceState.t(), Activation.t()) ::
          {:ok, map()} | {:error, term()}
  def activation_lifecycles(%InstanceState{} = data, %Activation{} = activation) do
    Lifecycle.activate(lifecycle_map(data), data.activation, activation,
      changed_at: activation.activated_at
    )
  end

  @spec active_definition_ref(InstanceState.t()) :: DefinitionRef.t()
  def active_definition_ref(%InstanceState{activation: %Activation{} = activation}),
    do: activation.definition_ref

  def active_definition_ref(%InstanceState{} = data), do: Run.definition_ref(data.agent)

  @spec operation_definition_ref(InstanceState.t(), OperationLoop.t()) :: DefinitionRef.t()
  def operation_definition_ref(%InstanceState{} = data, %OperationLoop{} = loop) do
    case Map.get(loop.metadata, :spectre_definition_ref) do
      %DefinitionRef{} = ref -> ref
      _missing -> active_definition_ref(data)
    end
  end

  @spec current_authority_epoch(InstanceState.t()) :: non_neg_integer()
  def current_authority_epoch(%InstanceState{} = data) do
    lifecycle_epoch =
      data
      |> lifecycle_map()
      |> Map.values()
      |> Enum.map(fn
        %Lifecycle{authority_epoch: epoch} -> epoch
        _invalid -> 0
      end)
      |> Enum.max(fn -> 0 end)

    max(lifecycle_epoch, Activation.authority_epoch(data.activation))
  end

  defp pending_envelope(%Envelope{} = envelope) do
    with {:ok, envelope} <- Envelope.new(envelope),
         :pending <- envelope.status do
      {:ok, envelope}
    else
      status when status in [:admitted, :quarantined] ->
        {:error, {:event_already_admitted, envelope.id, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp pending_envelope(value), do: Envelope.new(value)

  defp existing_event(data, pending) do
    [:event_admissions, :event_quarantine]
    |> Enum.find_value(:new, &find_existing_event(data.canonical, &1, pending))
  end

  defp find_existing_event(canonical, section, pending) do
    case Canonical.fetch(canonical, section) do
      {:ok, %{records: records}} -> compare_existing_event(records, pending)
      _missing -> false
    end
  end

  defp compare_existing_event(records, pending) do
    case Enum.find(records, &(&1.id == pending.id)) do
      %Envelope{} = existing ->
        if same_intent?(existing, pending),
          do: {:existing, existing},
          else: {:conflict, pending.id}

      nil ->
        false
    end
  end

  defp same_intent?(existing, pending) do
    fields = [
      :id,
      :event_class,
      :class_ref,
      :causation_id,
      :correlation_id,
      :origin_definition_ref,
      :payload_schema_ref,
      :payload,
      :provenance,
      :authenticity,
      :emitted_at
    ]

    Map.take(existing, fields) == Map.take(pending, fields) and
      (is_nil(pending.continuation_ref) or pending.continuation_ref == existing.continuation_ref)
  end

  defp resolve_owner(data, %Envelope{event_class: event_class} = pending, opts)
       when event_class in [:input, :global] do
    cond do
      not is_nil(pending.continuation_ref) ->
        quarantine(pending, :unexpected_continuation, nil)

      event_class == :global and not Keyword.get(opts, :schema_compatible?, true) ->
        quarantine(pending, :payload_schema_incompatible, nil)

      true ->
        owner = active_definition_ref(data)
        admit_or_quarantine(data, pending, owner, :new_admission)
    end
  end

  defp resolve_owner(data, %Envelope{event_class: event_class} = pending, _opts)
       when event_class in @run_classes do
    case resolve_run_continuation(data, pending) do
      {:ok, pending, run} -> admit_or_quarantine(data, pending, run.definition_ref, :continuation)
      {:quarantine, reason, pending} -> quarantine(pending, reason, nil)
    end
  end

  defp resolve_owner(data, %Envelope{event_class: event_class} = pending, _opts)
       when event_class in @operation_classes do
    case resolve_operation_continuation(data, pending) do
      {:ok, pending, loop} ->
        owner = operation_definition_ref(data, loop)
        admit_or_quarantine(data, pending, owner, :continuation)

      {:quarantine, reason, pending} ->
        quarantine(pending, reason, nil)
    end
  end

  defp admit_or_quarantine(data, pending, owner, operation) do
    case authorize(data, owner, operation) do
      :ok -> {:admit, pending, owner}
      {:error, reason} -> quarantine(pending, {:lifecycle_blocked, reason}, owner)
    end
  end

  defp quarantine(pending, reason, owner), do: {:quarantine, pending, reason, owner}

  defp resolve_run_continuation(data, %Envelope{continuation_ref: %RunRef{} = ref} = pending) do
    case Map.get(data.runs, ref.run_id) do
      %Run{} = run ->
        if run_ref_matches?(run, ref) and run_class_matches?(pending.event_class, ref),
          do: {:ok, pending, run},
          else: {:quarantine, :continuation_mismatch, pending}

      nil ->
        reason =
          if Map.has_key?(data.tombstones, ref.run_id),
            do: :continuation_expired,
            else: :continuation_not_found

        {:quarantine, reason, pending}
    end
  end

  defp resolve_run_continuation(data, %Envelope{continuation_ref: nil} = pending) do
    candidates =
      data.runs
      |> Map.values()
      |> Enum.filter(fn run ->
        run.correlation_id == pending.correlation_id and match?(%RunRef{}, current_run_ref(run))
      end)

    case candidates do
      [run] ->
        bind_implicit_run_continuation(run, pending)

      [] ->
        {:quarantine, :continuation_not_found, pending}

      many ->
        refs = many |> Enum.map(&current_run_ref/1) |> Enum.map(&RunRef.token/1) |> Enum.sort()
        {:quarantine, {:ambiguous_continuation, refs}, pending}
    end
  end

  defp resolve_run_continuation(_data, pending),
    do: {:quarantine, :invalid_continuation_class, pending}

  defp bind_implicit_run_continuation(run, pending) do
    ref = current_run_ref(run)

    if run_class_matches?(pending.event_class, ref),
      do: rebuild_with_run_continuation(run, ref, pending),
      else: {:quarantine, :continuation_mismatch, pending}
  end

  defp rebuild_with_run_continuation(run, ref, pending) do
    case Envelope.new(%{pending | continuation_ref: ref}) do
      {:ok, pending} -> {:ok, pending, run}
      {:error, _reason} -> {:quarantine, :continuation_mismatch, pending}
    end
  end

  defp run_ref_matches?(run, ref), do: current_run_ref(run) == ref

  defp current_run_ref(%Run{waiting: %Boundary{ref: %RunRef{} = ref}}), do: ref
  defp current_run_ref(%Run{waiting: %Invocation{ref: %RunRef{} = ref}}), do: ref
  defp current_run_ref(%Run{}), do: nil

  defp run_class_matches?(:policy_answer, %RunRef{kind: :policy}), do: true
  defp run_class_matches?(:reply, %RunRef{kind: :reply}), do: true

  defp run_class_matches?(event_class, %RunRef{})
       when event_class in [:flow_progress, :flow_completion], do: true

  defp run_class_matches?(_event_class, _ref), do: false

  defp resolve_operation_continuation(
         data,
         %Envelope{continuation_ref: %OperationRef{} = ref} = pending
       ) do
    case Loops.operation_loop(data, ref.id) do
      {:ok, loop, _control} ->
        if operation_ref_matches?(loop, ref) and
             operation_class_matches?(pending.event_class, loop),
           do: {:ok, pending, loop},
           else: {:quarantine, :continuation_mismatch, pending}

      {:error, _reason} ->
        {:quarantine, :continuation_not_found, pending}
    end
  end

  defp resolve_operation_continuation(data, %Envelope{continuation_ref: nil} = pending) do
    candidates =
      data
      |> Loops.all_operation_loops()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(fn loop ->
        loop.correlation_id == pending.correlation_id and
          operation_class_matches?(pending.event_class, loop)
      end)

    case candidates do
      [loop] ->
        ref = OperationRef.from_loop(loop)

        case Envelope.new(%{pending | continuation_ref: ref}) do
          {:ok, pending} -> {:ok, pending, loop}
          {:error, _reason} -> {:quarantine, :continuation_mismatch, pending}
        end

      [] ->
        {:quarantine, :continuation_not_found, pending}

      many ->
        refs = many |> Enum.map(& &1.id) |> Enum.sort()
        {:quarantine, {:ambiguous_continuation, refs}, pending}
    end
  end

  defp resolve_operation_continuation(_data, pending),
    do: {:quarantine, :invalid_continuation_class, pending}

  defp operation_ref_matches?(loop, ref) do
    loop.id == ref.id and loop.kind == ref.kind and loop.subject_id == ref.subject_id
  end

  defp operation_class_matches?(event_class, %OperationLoop{kind: :work}),
    do: event_class in [:work_progress, :work_completion]

  defp operation_class_matches?(event_class, %OperationLoop{kind: :vigil}),
    do: event_class in [:vigil_progress, :vigil_completion]

  defp operation_class_matches?(_event_class, %OperationLoop{}), do: false

  defp materialize_admission(data, {:admit, pending, owner}, opts) do
    lifecycle = lifecycle(data, owner)

    Envelope.admit(pending,
      owner_definition_ref: owner,
      admitted_activation_generation: Activation.generation(data.activation),
      authority_epoch: lifecycle.authority_epoch,
      owner_fencing_token: data.owner_lease.fencing_token,
      admission_revision: data.canonical.revision + 1,
      status: :admitted,
      admitted_at: Keyword.get(opts, :admitted_at, System.system_time(:millisecond))
    )
  end

  defp materialize_admission(data, {:quarantine, pending, reason, owner}, opts) do
    authority_epoch =
      case owner do
        %DefinitionRef{} -> lifecycle(data, owner).authority_epoch
        nil -> current_authority_epoch(data)
      end

    Envelope.admit(pending,
      owner_definition_ref: owner,
      admitted_activation_generation: Activation.generation(data.activation),
      authority_epoch: authority_epoch,
      owner_fencing_token: data.owner_lease.fencing_token,
      admission_revision: data.canonical.revision + 1,
      status: :quarantined,
      quarantine_reason: reason,
      admitted_at: Keyword.get(opts, :admitted_at, System.system_time(:millisecond))
    )
  end

  defp commit_event(data, envelope) do
    section = event_section(envelope.status)
    {:ok, current} = Canonical.fetch(data.canonical, section)
    records = Enum.take([envelope | current.records], @event_limit)
    ids = Map.new(records, &{&1.id, &1.admission_receipt})

    Commit.canonical_sections(data, %{section => %{records: records, ids: ids}},
      correlation_id: envelope.correlation_id,
      causation_id: envelope.causation_id,
      provenance: %{
        source: :event_admission,
        event_id: envelope.id,
        event_class: envelope.event_class
      },
      metadata: %{
        transition: :event_admitted,
        disposition: envelope.status,
        owner_definition_ref: ref_string(envelope.owner_definition_ref),
        activation_generation: envelope.admitted_activation_generation,
        authority_epoch: envelope.authority_epoch
      }
    )
  end

  defp lifecycle_map(data) do
    case Canonical.fetch(data.canonical, :lifecycles) do
      {:ok, lifecycles} when is_map(lifecycles) -> lifecycles
      _invalid -> %{}
    end
  end

  defp retention_transition_safe(data, lifecycle, :retention, :purged) do
    definition_ref = lifecycle.definition_ref

    referenced? =
      same_ref?(active_definition_ref(data), definition_ref) or
        Enum.any?(data.runs, fn {_id, run} -> same_ref?(run.definition_ref, definition_ref) end) or
        Enum.any?(Loops.all_operation_loops(data), fn {loop, _control} ->
          same_ref?(operation_definition_ref(data, loop), definition_ref)
        end) or SkillStates.definition_referenced?(data, definition_ref)

    if referenced?,
      do: {:error, {:definition_retention_referenced, Lifecycle.key(lifecycle)}},
      else: :ok
  end

  defp retention_transition_safe(_data, _lifecycle, _axis, _value), do: :ok

  defp event_section(:admitted), do: :event_admissions
  defp event_section(:quarantined), do: :event_quarantine

  defp same_ref?(%DefinitionRef{} = left, %DefinitionRef{} = right),
    do: DefinitionRef.to_string(left) == DefinitionRef.to_string(right)

  defp ref_string(nil), do: nil
  defp ref_string(%DefinitionRef{} = ref), do: DefinitionRef.to_string(ref)

  defp normalize_limit(value) when is_integer(value) and value >= 0,
    do: min(value, @event_limit)

  defp normalize_limit(_value), do: @event_limit
end
