defmodule Spectre.Instance.Activations do
  @moduledoc false

  # Coordinates Definition activation beneath the Instance mailbox boundary.
  # The GenServer decides whether a result replies or stops the owner; this
  # module owns prospective snapshot construction and its durable commit.

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Commit
  alias Spectre.Instance.DefinitionCompatibility
  alias Spectre.Instance.Events
  alias Spectre.Instance.Owner
  alias Spectre.Instance.SkillStates
  alias Spectre.Instance.State, as: InstanceState

  @doc false
  @spec expected_generation(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def expected_generation(opts) when is_list(opts) do
    case Keyword.fetch(opts, :expected_generation) do
      {:ok, generation} when is_integer(generation) and generation >= 0 -> {:ok, generation}
      {:ok, value} -> {:error, {:invalid_expected_activation_generation, value}}
      :error -> {:error, :expected_activation_generation_required}
    end
  end

  def expected_generation(value),
    do: {:error, {:invalid_activation_options, value}}

  @doc false
  @spec resolver_opts(InstanceState.t(), keyword()) :: keyword()
  def resolver_opts(%InstanceState{} = data, opts) when is_list(opts) do
    data.base_opts
    |> Keyword.merge(opts)
    |> Keyword.drop([
      :timeout,
      :expected_generation,
      :authority_epoch,
      :state_bindings,
      :skill_state_transitions
    ])
    |> Keyword.put(:checkpoint_store, data.checkpoint_store)
    |> Keyword.put(:observe_builds, true)
    |> Keyword.put(:on_drift, :reject)
  end

  @doc false
  @spec build(InstanceState.t(), map(), non_neg_integer(), keyword()) ::
          {:ok, Activation.t(), map()} | {:error, term()}
  def build(
        %InstanceState{} = data,
        %{candidate: candidate, resolution: resolution},
        _expected,
        opts
      ) do
    current_generation = Activation.generation(data.activation)
    current_epoch = Events.current_authority_epoch(data)
    activated_at = Keyword.get(opts, :activated_at, System.system_time(:millisecond))

    base_bindings =
      Keyword.get_lazy(opts, :state_bindings, fn ->
        case data.activation do
          %Activation{state_bindings: bindings} -> bindings
          nil -> %{}
        end
      end)

    provenance =
      Keyword.get(opts, :provenance, %{
        source: :trusted_host,
        instance_ref: data.ref.key
      })
      |> Map.put(:build_evidence, resolution.drift)
      |> Map.put(
        :change_surface?,
        DefinitionCompatibility.change_surface?(resolution.definition)
      )

    with :ok <- DefinitionCompatibility.verify_profile(data.base_opts, resolution.definition),
         {:ok, skill_states, skill_bindings} <-
           SkillStates.prepare_activation(
             data,
             resolution.definition_ref,
             Keyword.put(opts, :activated_at, activated_at)
           ),
         {:ok, state_bindings} <-
           SkillStates.merge_activation_bindings(base_bindings, skill_bindings),
         {:ok, activation} <-
           Activation.new(candidate, resolution,
             generation: current_generation + 1,
             authority_epoch: Keyword.get(opts, :authority_epoch, current_epoch),
             owner_fencing_token: data.owner_lease.fencing_token,
             state_bindings: state_bindings,
             activated_at: activated_at,
             provenance: provenance
           ) do
      {:ok, activation, skill_states}
    end
  end

  @doc false
  @spec commit(InstanceState.t(), Activation.t(), map()) ::
          {:ok, InstanceState.t()} | {:error, term()}
  def commit(%InstanceState{} = data, %Activation{} = activation, skill_states) do
    with :ok <- owner_guard(data, :activation_commit),
         :ok <- checkpoint_ready(data),
         {:ok, lifecycles} <- Events.activation_lifecycles(data, activation),
         {:ok, committed} <-
           Commit.canonical_sections(
             data,
             %{
               activation: activation,
               correlations: owner_fenced_correlations(data),
               lifecycles: lifecycles,
               skill_states: skill_states
             },
             correlation_id: activation.activation_receipt,
             causation_id: CandidateRef.to_string(activation.candidate_ref),
             provenance: %{source: :activation, instance_ref: data.ref.key},
             metadata: %{
               transition: :definition_activated,
               activation_generation: activation.generation,
               authority_epoch: activation.authority_epoch
             },
             checkpoint: :defer
           ),
         {:ok, persisted} <- persist_checkpoint(committed, committed.canonical) do
      _ =
        Spectre.Journal.record(
          data.agent,
          :definition_activated,
          %{
            definition_ref: to_string(activation.definition_ref),
            candidate_ref: CandidateRef.to_string(activation.candidate_ref),
            activation_generation: activation.generation,
            authority_epoch: activation.authority_epoch,
            activation_receipt: activation.activation_receipt
          },
          data.base_opts
        )

      {:ok, %{persisted | activation: activation}}
    end
  end

  @doc false
  @spec require_store(term()) :: {:ok, term()} | {:error, atom()}
  def require_store(nil), do: {:error, :definition_store_not_configured}
  def require_store(store), do: {:ok, store}

  @doc false
  @spec resolve_definition_ref(InstanceState.t(), :active | DefinitionRef.t() | String.t()) ::
          {:ok, DefinitionRef.t()} | {:error, term()}
  def resolve_definition_ref(%InstanceState{} = data, :active),
    do: {:ok, Events.active_definition_ref(data)}

  def resolve_definition_ref(%InstanceState{}, %DefinitionRef{} = definition_ref) do
    if DefinitionRef.valid?(definition_ref),
      do: {:ok, definition_ref},
      else: {:error, {:invalid_definition_lifecycle_ref, definition_ref}}
  end

  def resolve_definition_ref(%InstanceState{} = data, value) when is_binary(value) do
    known =
      [data.activation && data.activation.definition_ref]
      |> Kernel.++(Enum.map(data.runs, fn {_id, run} -> run.definition_ref end))
      |> Kernel.++(
        case Canonical.fetch(data.canonical, :lifecycles) do
          {:ok, lifecycles} ->
            Enum.map(lifecycles, fn {_key, lifecycle} -> lifecycle.definition_ref end)

          _invalid ->
            []
        end
      )
      |> Enum.reject(&is_nil/1)

    case Enum.find(known, &(DefinitionRef.to_string(&1) == value)) do
      %DefinitionRef{} = definition_ref -> {:ok, definition_ref}
      nil -> DefinitionRef.parse(value)
    end
  end

  def resolve_definition_ref(%InstanceState{}, value),
    do: {:error, {:invalid_definition_lifecycle_ref, value}}

  defp checkpoint_ready(%InstanceState{checkpoint_store: nil}), do: :ok

  defp checkpoint_ready(data) do
    cond do
      not is_nil(data.checkpoint_reconciliation) ->
        {:error, Checkpoint.reconciliation_error(data)}

      not is_nil(data.checkpoint_inflight) or not is_nil(data.checkpoint_reconcile_inflight) ->
        {:error, :activation_checkpoint_operation_in_progress}

      not is_nil(data.checkpoint_pending) ->
        {:error, :activation_checkpoint_pending}

      data.checkpoint_revision != data.canonical.revision ->
        {:error,
         {:activation_checkpoint_not_current, data.checkpoint_revision, data.canonical.revision}}

      true ->
        :ok
    end
  end

  defp persist_checkpoint(%InstanceState{checkpoint_store: nil} = data, _canonical),
    do: {:ok, data}

  defp persist_checkpoint(data, canonical) do
    with {:ok, encoded} <- CanonicalCodec.encode_json(canonical),
         :ok <-
           CheckpointStore.persist(
             data.checkpoint_store,
             data.ref,
             encoded,
             data.checkpoint_revision,
             canonical.revision,
             checkpoint_store_opts(data)
           ) do
      {:ok,
       %{
         data
         | checkpoint_revision: canonical.revision,
           checkpoint_persisted: canonical,
           checkpoint_error: nil
       }}
    end
  end

  defp checkpoint_store_opts(data) do
    Keyword.put(data.base_opts, :owner_fencing_token, data.owner_lease.fencing_token)
  end

  defp owner_fenced_correlations(data) do
    {:ok, correlations} = Canonical.fetch(data.canonical, :correlations)
    Map.put(correlations, :owner_fencing_token, data.owner_lease.fencing_token)
  end

  defp owner_guard(data, operation) do
    Owner.assert_current(data.owner, data.ref, data.owner_lease, operation, data.base_opts)
  end
end
