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

  @spec run(module() | AgentRef.t() | Ref.t(), term(), keyword()) ::
          {:ok, Proof.t()} | {:error, term()}
  def run(agent_or_ref, subject, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, ref, agent} <- instance_ref(agent_or_ref, subject),
         :ok <- confirmation(ref, opts),
         {:ok, config} <- configuration(agent, ref, opts),
         :ok <- CheckpointStore.erasure_capability(config.checkpoint_store),
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
           {:ok, keys} <- erase_observations(confirmed, ref, owner_lease, config) do
        Proof.new(ref,
          outcome: proof_outcome(keys),
          owner_fencing_token: owner_lease.fencing_token,
          completed_at: now(config),
          keys: keys
        )
      end
    after
      _ = Owner.release(config.owner, ref, owner_lease, config.base_opts)
    end
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
         {:ok, activation} <- Canonical.fetch(canonical, :activation) do
      {:ok,
       %{
         kind: kind,
         ref: ref,
         prior_state: :present,
         checkpoint: checkpoint,
         revision: report.revision,
         digest: report.digest,
         fencing_floor: Restore.owner_fencing_floor(activation, canonical),
         status: nil
       }}
    else
      {:error, reason} -> {:error, {:instance_erasure_checkpoint_invalid, kind, reason}}
    end
  end

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

        {:error, _reason} ->
          completed = keys |> Enum.map(& &1.kind) |> Enum.reverse()

          {:halt,
           {:error,
            {:ambiguous,
             {:instance_erasure_partial, completed, :instance_checkpoint_erase_failed}}}}
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
         {:ok, owner} <- owner(agent, opts, base_opts) |> Owner.normalize() do
      requested_at = Keyword.get(opts, :now, System.system_time(:millisecond))

      if is_integer(requested_at) and requested_at >= 0 do
        {:ok,
         %{
           base_opts: Keyword.put(base_opts, :instance_ref, ref),
           checkpoint_store: checkpoint_store,
           erasure_id: Keyword.get(opts, :erasure_id),
           owner: owner,
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
