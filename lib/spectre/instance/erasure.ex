defmodule Spectre.Instance.Erasure do
  @moduledoc false

  alias Spectre.AgentRef
  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Erasure.Proof
  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Erasure.Status
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Ref
  alias Spectre.Instance.Registry, as: InstanceRegistry
  alias Spectre.Instance.Restore
  alias Spectre.Journal.Store, as: JournalStore
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Stack.PackageData

  @spec run(module() | AgentRef.t() | Ref.t(), term(), keyword()) ::
          {:ok, Proof.t()} | {:error, term()}
  def run(agent_or_ref, subject, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, ref, agent} <- instance_ref(agent_or_ref, subject),
         :ok <- confirmation(ref, opts),
         {:ok, config} <- configuration(agent, ref, opts),
         :ok <- Owner.maintenance_capability(config.owner),
         :ok <- CheckpointStore.erasure_capability(config.checkpoint_store),
         :ok <- JournalStore.erasure_capability(config.journal),
         :ok <- ReceiptSink.payload_erasure_capability(config.receipt_sink),
         :ok <- PackageData.erasure_capability(config.package_data),
         {:ok, reservation} <- InstanceRegistry.reserve(ref, :erasure, config.registry) do
      try do
        erase_reserved(ref, config)
      after
        _ = InstanceRegistry.release_reservation(ref, reservation, config.registry)
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_instance_erasure_identity}
  end

  def run(_agent_or_ref, _subject, _opts), do: {:error, :invalid_instance_erasure_options}

  defp erase_reserved(ref, config) do
    refs = erasure_refs(ref)

    with {:ok, observed} <- observe_all(config.checkpoint_store, refs, config.base_opts),
         floor = fencing_floor(observed),
         {:ok, _owner, owner_lease} <-
           Owner.claim_maintenance(
             config.owner,
             ref,
             :erasure,
             Keyword.put(config.base_opts, :minimum_fencing_token, floor)
           ) do
      erase_claimed(ref, observed, owner_lease, config)
    end
  end

  defp erase_claimed(ref, observed, owner_lease, config) do
    try do
      with {:ok, confirmed} <-
             observe_all(config.checkpoint_store, erasure_refs(ref), config.base_opts),
           :ok <- unchanged(observed, confirmed),
           :ok <- receipt_sink_present(confirmed, config.receipt_sink) do
        erase_configured(ref, confirmed, owner_lease, config)
      end
    after
      _ = Owner.release(config.owner, ref, owner_lease, config.base_opts)
    end
  end

  defp erase_configured(ref, observations, owner_lease, config) do
    with {:ok, journal} <- erase_journal_refs(ref, owner_lease, config),
         {:ok, receipts} <-
           erase_receipt_payloads(observations, ref, owner_lease, journal, config),
         {:ok, package_data} <- erase_package_data(ref, owner_lease, receipts, config),
         {:ok, keys} <-
           erase_checkpoints(observations, ref, owner_lease, package_data, config) do
      Proof.new(ref,
        outcome: proof_outcome(keys),
        owner_fencing_token: owner_lease.fencing_token,
        completed_at: now(config),
        components: proof_components(journal, receipts, package_data, keys),
        keys: keys
      )
    end
  end

  defp erase_journal_refs(_ref, _owner_lease, %{journal: nil}),
    do: {:ok, %{outcome: :not_configured, key_count: 0, completed: []}}

  defp erase_journal_refs(ref, owner_lease, config) do
    ref
    |> erasure_refs()
    |> Enum.reduce_while({:ok, []}, fn {_kind, journal_ref}, {:ok, outcomes} ->
      with :ok <-
             Owner.assert_current(
               config.owner,
               ref,
               owner_lease,
               :instance_journal_erasure,
               config.base_opts
             ),
           {:ok, outcome} <-
             JournalStore.erase_instance(config.journal, journal_ref, config.base_opts) do
        {:cont, {:ok, [outcome | outcomes]}}
      else
        {:error, reason} -> {:halt, journal_error(outcomes, reason)}
      end
    end)
    |> case do
      {:ok, outcomes} ->
        outcomes = Enum.reverse(outcomes)

        {:ok,
         %{
           outcome: aggregate_outcome(outcomes),
           key_count: length(outcomes),
           completed: [:journal]
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp journal_error([], reason), do: {:error, {:instance_journal_erase_failed, reason}}

  defp journal_error(outcomes, reason) do
    {:error,
     {:ambiguous,
      {:instance_erasure_partial, [:journal],
       {:instance_journal_erase_failed, length(outcomes), reason}}}}
  end

  defp erase_receipt_payloads(
         _observations,
         _owner_ref,
         _owner_lease,
         journal,
         %{receipt_sink: nil}
       ) do
    {:ok,
     %{
       outcome: :not_configured,
       payload_count: 0,
       deleted_count: 0,
       not_found_count: 0,
       completed: journal.completed
     }}
  end

  defp erase_receipt_payloads(observations, owner_ref, owner_lease, journal, config) do
    refs = payload_refs(observations)

    refs
    |> Enum.reduce_while({:ok, %{deleted: 0, not_found: 0}}, fn payload_ref, {:ok, counts} ->
      with :ok <-
             Owner.assert_current(
               config.owner,
               owner_ref,
               owner_lease,
               :instance_receipt_payload_erasure,
               config.base_opts
             ),
           {:ok, outcome} <-
             ReceiptSink.delete_payload(config.receipt_sink, payload_ref, config.base_opts) do
        next = Map.update!(counts, outcome, &(&1 + 1))
        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, reason, counts}}
      end
    end)
    |> receipt_outcome(length(refs), journal.completed)
  end

  defp receipt_outcome({:ok, counts}, total, completed) do
    outcome =
      cond do
        total == 0 -> :not_applicable
        counts.deleted > 0 -> :erased
        true -> :already_erased
      end

    {:ok,
     %{
       outcome: outcome,
       payload_count: total,
       deleted_count: counts.deleted,
       not_found_count: counts.not_found,
       completed: completed ++ if(total > 0, do: [:receipt_payloads], else: [])
     }}
  end

  defp receipt_outcome({:error, reason, counts}, _total, completed) do
    completed =
      completed ++ if(counts.deleted + counts.not_found > 0, do: [:receipt_payloads], else: [])

    partial_error(
      completed,
      {:receipt_payload_erase_failed, counts.deleted + counts.not_found, reason}
    )
  end

  defp erase_package_data(ref, owner_lease, receipts, config) do
    authorize = fn ->
      Owner.assert_current(
        config.owner,
        ref,
        owner_lease,
        :instance_package_data_erasure,
        config.base_opts
      )
    end

    case PackageData.erase_instance(ref, config.package_opts, authorize) do
      {:ok, result} ->
        completed =
          receipts.completed ++
            if(result.package_count > 0, do: [:package_data], else: [])

        {:ok, Map.put(result, :completed, completed)}

      {:error, {:package_data_erase_failed, completed, adapter, reason}} ->
        prior = receipts.completed ++ if(completed == [], do: [], else: [:package_data])
        partial_error(prior, {:package_data_erase_failed, completed, adapter, reason})

      {:error, reason} ->
        partial_error(receipts.completed, {:package_data_erase_failed, reason})
    end
  end

  defp erase_checkpoints(observations, ref, owner_lease, package_data, config) do
    case erase_observations(observations, ref, owner_lease, config) do
      {:ok, keys} ->
        {:ok, keys}

      {:error, {:ambiguous, {:instance_erasure_partial, checkpoint_keys, reason}}} ->
        partial_error(package_data.completed ++ checkpoint_keys, reason)

      {:error, reason} ->
        partial_error(package_data.completed, reason)
    end
  end

  defp partial_error([], reason), do: {:error, reason}

  defp partial_error(completed, reason),
    do: {:error, {:ambiguous, {:instance_erasure_partial, completed, reason}}}

  defp proof_components(journal, receipts, package_data, keys) do
    %{
      journal: Map.take(journal, [:outcome, :key_count]),
      receipt_payloads:
        Map.take(receipts, [
          :outcome,
          :payload_count,
          :deleted_count,
          :not_found_count
        ]),
      package_data:
        Map.take(package_data, [
          :outcome,
          :package_count,
          :erased_count,
          :already_erased_count,
          :packages
        ]),
      checkpoint: %{outcome: proof_outcome(keys), key_count: length(keys)}
    }
  end

  defp aggregate_outcome(outcomes) do
    if Enum.all?(outcomes, &(&1 == :already_erased)),
      do: :already_erased,
      else: :erased
  end

  defp receipt_sink_present(observations, nil) do
    if payload_refs(observations) == [],
      do: :ok,
      else: {:error, :receipt_sink_required_for_erasure}
  end

  defp receipt_sink_present(_observations, _sink), do: :ok

  defp payload_refs(observations) do
    observations
    |> Enum.flat_map(& &1.payload_refs)
    |> Enum.uniq()
  end

  defp observe_all(store, refs, opts) do
    Enum.reduce_while(refs, {:ok, [], nil}, fn {kind, ref}, {:ok, entries, stable} ->
      case observe(store, kind, ref, stable, opts) do
        {:ok, observation} ->
          {:cont, {:ok, [observation | entries], next_stable(kind, observation, stable)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, observations, _stable} -> {:ok, Enum.reverse(observations)}
      {:error, _reason} = error -> error
    end
  end

  defp next_stable(:stable, observation, _stable), do: observation_checkpoint(observation)
  defp next_stable(_kind, _observation, stable), do: stable

  defp observe(store, kind, ref, stable_checkpoint, opts) do
    case {CheckpointStore.erasure_status(store, ref, opts),
          CheckpointStore.load(store, ref, opts)} do
      {{:ok, %Status{} = status}, :not_found} ->
        {:ok,
         %{
           kind: kind,
           ref: ref,
           prior_state: :erased,
           checkpoint: nil,
           revision: status.erased_revision,
           digest: status.checkpoint_digest,
           fencing_floor: status.owner_fencing_token,
           payload_refs: [],
           status: status
         }}

      {:not_erased, :not_found} ->
        {:ok,
         %{
           kind: kind,
           ref: ref,
           prior_state: :absent,
           checkpoint: nil,
           revision: nil,
           digest: nil,
           fencing_floor: 0,
           payload_refs: [],
           status: nil
         }}

      {:not_erased, {:ok, checkpoint}} ->
        observe_checkpoint(kind, ref, checkpoint, stable_checkpoint)

      {{:ok, %Status{}}, {:ok, _checkpoint}} ->
        {:error, {:instance_erasure_store_inconsistent, kind}}

      {{:error, reason}, _load} ->
        {:error, {:instance_erasure_status_failed, kind, reason}}

      {_status, {:error, reason}} ->
        {:error, {:instance_erasure_load_failed, kind, reason}}
    end
  end

  defp observe_checkpoint(kind, ref, checkpoint, stable_checkpoint) do
    verifier =
      if kind == :legacy and not is_nil(stable_checkpoint) and checkpoint == stable_checkpoint,
        do: &Foundation.verify_instance_checkpoint/1,
        else: &Foundation.verify_instance_checkpoint(&1, ref)

    with {:ok, report} <- verifier.(checkpoint),
         {:ok, canonical} <- CanonicalCodec.decode(checkpoint),
         {:ok, activation} <- Canonical.fetch(canonical, :activation),
         {:ok, receipt_outbox} <- Canonical.fetch(canonical, :receipt_outbox),
         {:ok, payload_refs} <- receipt_payload_refs(receipt_outbox) do
      {:ok,
       %{
         kind: kind,
         ref: ref,
         prior_state: :present,
         checkpoint: checkpoint,
         revision: report.revision,
         digest: report.digest,
         fencing_floor: Restore.owner_fencing_floor(activation, canonical),
         payload_refs: payload_refs,
         status: nil
       }}
    else
      {:error, reason} -> {:error, {:instance_erasure_checkpoint_invalid, kind, reason}}
    end
  end

  defp receipt_payload_refs(%{entries: entries}) when is_list(entries) do
    refs = Enum.map(entries, &Map.get(&1, :payload_ref))

    if Enum.all?(refs, &(is_binary(&1) and &1 != "")),
      do: {:ok, refs},
      else: {:error, :invalid_receipt_payload_refs}
  end

  defp receipt_payload_refs(_outbox), do: {:error, :invalid_receipt_payload_refs}

  defp unchanged(before, after_claim) do
    before_fingerprints = Enum.map(before, &fingerprint/1)
    after_fingerprints = Enum.map(after_claim, &fingerprint/1)

    if before_fingerprints == after_fingerprints,
      do: :ok,
      else: {:error, :instance_erasure_checkpoint_changed}
  end

  defp fingerprint(observation) do
    {
      observation.kind,
      observation.prior_state,
      observation.revision,
      observation.digest,
      status_digest(observation.status)
    }
  end

  defp status_digest(nil), do: nil
  defp status_digest(%Status{} = status), do: Status.digest(status)

  defp erase_observations(observations, owner_ref, owner_lease, config) do
    erasure_id = config.erasure_id || Spectre.Identity.uuid7()

    observations
    |> Enum.reduce_while({:ok, []}, fn observation, {:ok, keys} ->
      case erase_observation(observation, owner_ref, owner_lease, erasure_id, config) do
        {:ok, key} ->
          {:cont, {:ok, [key | keys]}}

        {:error, reason} when keys == [] ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          completed = keys |> Enum.map(& &1.kind) |> Enum.reverse()

          {:halt, {:error, {:ambiguous, {:instance_erasure_partial, completed, reason}}}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      {:error, _reason} = error -> error
    end
  end

  defp erase_observation(observation, owner_ref, owner_lease, erasure_id, config) do
    with :ok <-
           Owner.assert_current(
             config.owner,
             owner_ref,
             owner_lease,
             :instance_erasure,
             config.base_opts
           ) do
      erase_owned_observation(observation, owner_lease, erasure_id, config)
    end
  end

  defp erase_owned_observation(
         %{prior_state: :erased} = observation,
         _lease,
         _id,
         _config
       ) do
    {:ok, key_proof(observation, :already_erased, observation.status)}
  end

  defp erase_owned_observation(observation, owner_lease, erasure_id, config) do
    request_attrs = [
      erasure_id: erasure_id,
      expected_revision: observation.revision,
      checkpoint_digest: observation.digest,
      owner_fencing_token: owner_lease.fencing_token,
      requested_at: config.requested_at
    ]

    with {:ok, request} <- Request.new(observation.ref, request_attrs),
         {:ok, outcome} <-
           CheckpointStore.erase(
             config.checkpoint_store,
             observation.ref,
             request,
             config.base_opts
           ),
         {:ok, status} <- verify_erased(observation.ref, request, outcome, config) do
      {:ok, key_proof(observation, outcome, status)}
    else
      {:error, reason} ->
        {:error, {:instance_checkpoint_erase_failed, observation.kind, reason}}
    end
  end

  defp verify_erased(ref, request, outcome, config) do
    with :not_found <- CheckpointStore.load(config.checkpoint_store, ref, config.base_opts),
         {:ok, %Status{} = status} <-
           CheckpointStore.erasure_status(config.checkpoint_store, ref, config.base_opts),
         :ok <- verify_marker(status, request, outcome) do
      {:ok, status}
    else
      {:ok, _checkpoint} -> {:error, :instance_erasure_readback_present}
      :not_erased -> {:error, :instance_erasure_marker_missing}
      {:error, _reason} = error -> error
    end
  end

  defp verify_marker(%Status{} = status, %Request{} = request, :erased) do
    if status.erasure_id == request.erasure_id and
         status.instance_key == request.instance_key and
         status.erased_revision == request.expected_revision and
         status.checkpoint_digest == request.checkpoint_digest and
         status.owner_fencing_token == request.owner_fencing_token do
      :ok
    else
      {:error, :instance_erasure_marker_mismatch}
    end
  end

  defp verify_marker(%Status{} = status, %Request{} = request, :already_erased) do
    if status.instance_key == request.instance_key,
      do: :ok,
      else: {:error, :instance_erasure_marker_mismatch}
  end

  defp key_proof(observation, outcome, status) do
    %{
      kind: observation.kind,
      prior_state: observation.prior_state,
      outcome: outcome,
      marker_digest: Status.digest(status)
    }
  end

  defp proof_outcome(keys) do
    if Enum.all?(keys, &(&1.outcome == :already_erased)),
      do: :already_erased,
      else: :erased
  end

  defp configuration(agent, ref, opts) do
    with {:ok, base_opts} <- base_opts(opts),
         {:ok, checkpoint_store} <-
           checkpoint_store(agent, opts, base_opts) |> CheckpointStore.normalize(),
         {:ok, owner} <- owner(agent, opts, base_opts) |> Owner.normalize(),
         {:ok, journal} <- journal(agent, opts, base_opts) |> JournalStore.normalize(),
         {:ok, receipt_sink} <- receipt_sink(agent, opts, base_opts) |> ReceiptSink.normalize(),
         package_opts <- package_opts(opts, base_opts),
         {:ok, package_data} <- PackageData.erasure_plan(ref, package_opts) do
      requested_at = Keyword.get(opts, :now, System.system_time(:millisecond))

      if is_integer(requested_at) and requested_at >= 0 do
        {:ok,
         %{
           base_opts: Keyword.put(base_opts, :instance_ref, ref),
           checkpoint_store: checkpoint_store,
           erasure_id: Keyword.get(opts, :erasure_id),
           journal: journal,
           owner: owner,
           package_data: package_data,
           package_opts: package_opts,
           receipt_sink: receipt_sink,
           registry: Keyword.get(opts, :registry, InstanceRegistry),
           requested_at: requested_at
         }}
      else
        {:error, {:invalid_instance_erasure_option, :now}}
      end
    end
  end

  defp base_opts(opts) do
    case Keyword.get(opts, :opts, []) do
      value when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: {:error, {:invalid_instance_erasure_option, :opts}}

      _invalid ->
        {:error, {:invalid_instance_erasure_option, :opts}}
    end
  end

  @spec package_opts(keyword(), keyword()) :: keyword()
  defp package_opts(opts, base_opts) do
    case Keyword.fetch(opts, :stack_runtime) do
      {:ok, runtime} -> Keyword.put(base_opts, :stack_runtime, runtime)
      :error -> base_opts
    end
  end

  defp checkpoint_store(agent, opts, base_opts) do
    first_configured([
      {opts, :checkpoint_store},
      {base_opts, :checkpoint_store},
      {agent_config(agent), :checkpoint_store}
    ])
  end

  defp owner(agent, opts, base_opts) do
    first_configured([
      {opts, :owner},
      {base_opts, :owner},
      {agent_config(agent), :owner}
    ])
  end

  defp journal(agent, opts, base_opts) do
    first_configured([
      {opts, :journal},
      {base_opts, :journal},
      {agent_config(agent), :journal}
    ])
  end

  defp receipt_sink(agent, opts, base_opts) do
    first_configured([
      {opts, :receipt_sink},
      {base_opts, :receipt_sink},
      {agent_config(agent), :receipt_sink}
    ])
  end

  defp agent_config(agent) when is_atom(agent) and not is_nil(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0),
      do: agent.__spectre_config__(),
      else: []
  end

  defp agent_config(_agent), do: []

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp instance_ref(%Ref{} = ref, subject) do
    supplied = Ref.new(ref.agent_ref, subject)

    if supplied.key == ref.key,
      do: {:ok, ref, ref.agent_ref.definition},
      else: {:error, :instance_erasure_subject_mismatch}
  end

  defp instance_ref(%AgentRef{} = agent_ref, subject) do
    ref = Ref.new(agent_ref, subject)
    {:ok, ref, agent_ref.definition}
  end

  defp instance_ref(agent, subject) when is_atom(agent) and not is_nil(agent) do
    ref = Ref.new(agent, subject)
    {:ok, ref, agent}
  end

  defp instance_ref(_agent, _subject), do: {:error, :invalid_instance_erasure_identity}

  defp confirmation(ref, opts) do
    if Keyword.get(opts, :confirm) == ref.key,
      do: :ok,
      else: {:error, :instance_erasure_confirmation_required}
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, :invalid_instance_erasure_options}
  end

  defp erasure_refs(ref) do
    case Ref.legacy(ref) do
      {:ok, legacy} -> [{:stable, ref}, {:legacy, legacy}]
      {:error, :legacy_agent_ref_source_unavailable} -> [{:stable, ref}]
    end
  end

  defp fencing_floor(observations),
    do: observations |> Enum.map(& &1.fencing_floor) |> Enum.max(fn -> 0 end)

  defp observation_checkpoint(%{prior_state: :present, checkpoint: checkpoint}), do: checkpoint
  defp observation_checkpoint(_observation), do: nil

  defp now(config), do: max(config.requested_at, System.system_time(:millisecond))
end
