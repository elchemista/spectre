defmodule Spectre.Instance.Restore do
  @moduledoc false

  # Rebuilds the durable boot snapshot before the Instance starts scheduling.
  # Store resolution, closure verification, Morph compatibility, and fencing
  # floors intentionally form one fail-closed recovery boundary.

  alias Spectre.Definition.Resolver, as: DefinitionResolver
  alias Spectre.Event.Envelope, as: EventEnvelope
  alias Spectre.Governance.Verifier, as: GovernanceVerifier
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Boot
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.DefinitionCompatibility
  alias Spectre.Instance.Runs
  alias Spectre.Run
  alias Spectre.Skill.StateBinding

  @doc false
  @spec activation(Canonical.t(), term(), term(), keyword()) ::
          {:ok, Activation.t() | nil} | {:error, term()}
  def activation(canonical, definition_store, checkpoint_store, base_opts) do
    with {:ok, activation} <- Canonical.fetch(canonical, :activation) do
      validate_activation(activation, definition_store, checkpoint_store, base_opts)
    end
  end

  @doc false
  @spec runs(Canonical.t(), term(), term(), keyword(), pos_integer(), keyword()) ::
          {:ok, %{optional(String.t()) => Run.t()}} | {:error, term()}
  def runs(
        canonical,
        definition_store,
        checkpoint_store,
        base_opts,
        max_runs,
        boot_opts \\ []
      ) do
    with {:ok, checkpoints} <- Canonical.fetch(canonical, :runs),
         true <- is_map(checkpoints) and not is_struct(checkpoints),
         true <- map_size(checkpoints) <= max_runs do
      restore_checkpoints(
        checkpoints,
        definition_store,
        checkpoint_store,
        base_opts,
        boot_opts
      )
    else
      false ->
        {:error, {:restored_run_capacity_exceeded, map_size(canonical_runs(canonical)), max_runs}}

      {:error, _reason} = error ->
        error
    end
  end

  defp restore_checkpoints(checkpoints, definition_store, checkpoint_store, base_opts, boot_opts) do
    decoded =
      checkpoints
      |> Enum.with_index()
      |> Boot.map(
        fn {entry, index} -> decode_run(entry, index) end,
        boot_opts
      )

    with {:ok, decoded} <- decoded_runs(decoded),
         {:ok, verified} <-
           verify_runs(decoded, definition_store, checkpoint_store, base_opts, boot_opts) do
      {:ok, Map.new(verified, fn {_index, run_id, run} -> {run_id, run} end)}
    end
  end

  defp decode_run({run_id, checkpoint}, index) do
    with true <- is_binary(run_id) and is_binary(checkpoint),
         {:ok, %Run{id: ^run_id} = run} <- Run.restore(checkpoint) do
      {:ok, index, run_id, run}
    else
      false ->
        {:error, {:invalid_restored_run_checkpoint, run_id}}

      {:ok, %Run{id: other_id}} ->
        {:error, {:restored_run_id_mismatch, run_id, other_id}}

      {:error, reason} ->
        {:error, {:restored_run_invalid, run_id, reason}}
    end
  end

  defp decoded_runs(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, index, run_id, run}, {:ok, decoded} ->
        {:cont, {:ok, [{index, run_id, run} | decoded]}}

      {:error, _reason} = error, _decoded ->
        {:halt, error}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_runs(decoded, definition_store, checkpoint_store, base_opts, boot_opts) do
    groups = ordered_groups(decoded)

    results =
      Boot.map(
        groups,
        fn group ->
          verify_group(group, definition_store, checkpoint_store, base_opts)
        end,
        boot_opts
      )

    with {:ok, entries} <- verified_group_entries(results) do
      entries
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn
        {index, run_id, {:ok, run}}, {:ok, verified} ->
          {:cont, {:ok, [{index, run_id, run} | verified]}}

        {_index, _run_id, {:error, _reason} = error}, _verified ->
          {:halt, error}
      end)
      |> case do
        {:ok, verified} -> {:ok, Enum.reverse(verified)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp verified_group_entries(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:group, entries}, {:ok, groups} ->
        {:cont, {:ok, [entries | groups]}}

      {:error, _reason} = error, _groups ->
        {:halt, error}
    end)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_groups(decoded) do
    {order, groups} =
      Enum.reduce(decoded, {[], %{}}, fn {index, run_id, run} = entry, {order, groups} ->
        key =
          if run.activation_generation == 0,
            do: {:legacy, index},
            else: {:definition, run.definition_ref}

        case Map.fetch(groups, key) do
          {:ok, entries} -> {order, Map.put(groups, key, [entry | entries])}
          :error -> {[key | order], Map.put(groups, key, [{index, run_id, run}])}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn key -> groups |> Map.fetch!(key) |> Enum.reverse() end)
  end

  defp verify_group(
         [{_index, _run_id, %Run{activation_generation: 0}} | _rest] = group,
         _store,
         _checkpoint,
         _opts
       ) do
    {:group, Enum.map(group, fn {index, run_id, run} -> {index, run_id, {:ok, run}} end)}
  end

  defp verify_group(group, definition_store, checkpoint_store, base_opts) do
    {_index, _run_id, first} = hd(group)

    resolution =
      DefinitionCompatibility.resolve_pinned_run(
        first,
        definition_store,
        checkpoint_store,
        base_opts
      )

    entries =
      Enum.map(group, fn {index, run_id, run} ->
        outcome =
          with {:ok, resolution} <- resolution,
               :ok <-
                 DefinitionCompatibility.verify_pinned_run_against_resolution(run, resolution) do
            {:ok, run}
          else
            {:error, reason} -> {:error, {:restored_run_invalid, run_id, reason}}
          end

        {index, run_id, outcome}
      end)

    {:group, entries}
  end

  @doc false
  @spec terminal_ids(%{optional(String.t()) => Run.t()}) :: MapSet.t(String.t())
  def terminal_ids(runs) when is_map(runs) do
    runs
    |> Enum.filter(fn {_id, run} -> Runs.terminal_run?(run) end)
    |> Enum.map(fn {id, _run} -> id end)
    |> MapSet.new()
  end

  @doc false
  @spec completed_queue(%{optional(String.t()) => Run.t()}) :: :queue.queue(String.t())
  def completed_queue(runs) when is_map(runs) do
    runs
    |> terminal_ids()
    |> MapSet.to_list()
    |> Enum.sort()
    |> :queue.from_list()
  end

  @doc false
  @spec owner_fencing_floor(Activation.t() | nil, Canonical.t()) :: non_neg_integer()
  def owner_fencing_floor(activation, canonical) do
    [
      activation_fencing_token(activation),
      correlation_fencing_token(canonical)
      | persisted_section_fencing_tokens(canonical)
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp validate_activation(nil, _definition_store, _checkpoint_store, _base_opts),
    do: {:ok, nil}

  defp validate_activation(%Activation{}, nil, _checkpoint_store, _base_opts),
    do: {:error, :restored_activation_requires_definition_store}

  defp validate_activation(
         %Activation{} = activation,
         definition_store,
         checkpoint_store,
         base_opts
       ) do
    opts = recovery_resolver_opts(base_opts, checkpoint_store)

    with {:ok, %{candidate: candidate, resolution: resolution} = candidate_resolution} <-
           DefinitionResolver.resolve_candidate_for_activation(
             definition_store,
             activation.candidate_ref,
             opts
           ),
         :ok <- DefinitionCompatibility.verify_profile(base_opts, resolution.definition),
         :ok <-
           DefinitionCompatibility.verify_activation_marker(activation, resolution.definition),
         :ok <- GovernanceVerifier.verify_recovery(definition_store, candidate_resolution, opts),
         {:ok, rebuilt} <-
           Activation.new(candidate, resolution,
             generation: activation.generation,
             authority_epoch: activation.authority_epoch,
             owner_fencing_token: activation.owner_fencing_token,
             state_bindings: activation.state_bindings,
             activated_at: activation.activated_at,
             provenance: activation.provenance
           ),
         true <- rebuilt == activation do
      {:ok, activation}
    else
      false -> {:error, :restored_activation_integrity_mismatch}
      :not_found -> {:error, :restored_activation_candidate_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp validate_activation(value, _definition_store, _checkpoint_store, _base_opts),
    do: {:error, {:invalid_restored_activation, value}}

  defp recovery_resolver_opts(base_opts, checkpoint_store) do
    base_opts
    |> Keyword.put(:checkpoint_store, checkpoint_store)
    |> Keyword.put(:observe_builds, true)
    |> Keyword.put(:on_drift, :reject)
  end

  defp canonical_runs(canonical) do
    case Canonical.fetch(canonical, :runs) do
      {:ok, runs} when is_map(runs) -> runs
      _invalid -> %{}
    end
  end

  defp activation_fencing_token(%Activation{owner_fencing_token: token}), do: token
  defp activation_fencing_token(nil), do: 0

  defp correlation_fencing_token(canonical) do
    case Canonical.fetch(canonical, :correlations) do
      {:ok, %{owner_fencing_token: token}} when is_integer(token) and token > 0 -> token
      _missing -> 0
    end
  end

  defp persisted_section_fencing_tokens(canonical) do
    skill_state_fencing_tokens(canonical) ++ event_fencing_tokens(canonical)
  end

  defp skill_state_fencing_tokens(canonical) do
    case Canonical.fetch(canonical, :skill_states) do
      {:ok, states} when is_map(states) ->
        Enum.flat_map(states, fn
          {_skill_id, %{branches: branches}} when is_map(branches) ->
            Enum.flat_map(branches, fn
              {_branch_id, %StateBinding{fencing_token: token}} -> [token]
              _invalid -> []
            end)

          _invalid ->
            []
        end)

      _missing ->
        []
    end
  end

  defp event_fencing_tokens(canonical) do
    Enum.flat_map([:event_admissions, :event_quarantine], fn section ->
      case Canonical.fetch(canonical, section) do
        {:ok, %{records: records}} when is_list(records) ->
          Enum.flat_map(records, fn
            %EventEnvelope{owner_fencing_token: token} when is_integer(token) -> [token]
            _invalid -> []
          end)

        _missing ->
          []
      end
    end)
  end
end
