defmodule Spectre.Foundation.Conformance do
  @moduledoc """
  Executable compatibility gate for Spectre's durable foundations.

  The gate gives applications and satellite libraries one public place to
  verify legacy checkpoints, the current Definition/Manifest pair, and the
  schema matrix supported by the running Spectre release. It performs real
  decode, migration, validation, and current-writer round trips; it does not
  maintain a second representation of any runtime value.

  This module deliberately has no ExUnit dependency, so downstream projects
  can call it from their own test or release-verification tooling.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical, as: CanonicalDefinition
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Forge.Proposal
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: InstanceCodec
  alias Spectre.Instance.Canonical.Validator, as: InstanceValidator
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Projection
  alias Spectre.Projection.Reflection
  alias Spectre.Run
  alias Spectre.State.Codec, as: StateCodec

  @contract_version 1
  @run_format "spectre/run"

  @type report :: %{
          required(:contract_version) => pos_integer(),
          required(:format) => atom(),
          required(:digest) => String.t(),
          optional(atom()) => term()
        }

  @doc "Returns the executable foundation-conformance contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc """
  Returns the reader/writer and public golden-path matrix for this release.

  Reader lists are normative. A writer always emits only the last version in
  its corresponding family; older versions are accepted solely at recovery
  boundaries and are migrated into the current in-memory model.
  """
  @spec matrix() :: map()
  def matrix do
    %{
      contract_version: @contract_version,
      release: Spectre.version(),
      durable_formats: %{
        state: %{writer: 5, readers: [2, 3, 4, 5]},
        run: %{writer: 3, readers: [1, 2, 3]},
        instance: %{writer: 3, readers: [2, 3]}
      },
      definition: %{
        canonicalization: 1,
        contract: 1,
        manifest_schema: 1,
        manifest_contract: 2,
        candidate_schema: 1
      },
      skill_runtime: %{
        definition_schema: 1,
        applicability_schema: 1,
        prompt_budget_schema: 1,
        routing_projection: 1,
        index_profile: 1
      },
      data_execution: %{
        program_schema: 1,
        handoff_schema: 1,
        prompt_receipt_schema: 1,
        execution_projection: 1,
        migration_receipt_schema: 1,
        rehearsal_report_schema: 1
      },
      governance: %{
        change_set_schema: 1,
        candidate_state_schema: 1,
        gate_receipt_schema: 1,
        human_report_generator: 1,
        evaluation_delta_schema: 1,
        gc_plan_schema: 2
      },
      reflection: %{
        experience_evidence_schema: Spectre.Experience.Evidence.schema_version(),
        experience_artifact_schema: ExperienceStore.artifact_schema_version(),
        reflection_projection: Reflection.version()
      },
      forge: %{
        critique_schema: Spectre.Forge.Critique.schema_version(),
        oracle_approval_schema: Spectre.Forge.OracleApproval.schema_version(),
        proposal_schema: Proposal.schema_version(),
        critic_contract: Spectre.Forge.Critic.contract_version()
      },
      stack: %{module_input_contract: 1, sealed_runtime_contract: 2},
      golden_path: [
        {Spectre, :ask, 2},
        {Spectre, :turn, 2},
        {Spectre, :instance, 3},
        {Spectre, :activate, 2},
        {Spectre, :rollback, 3},
        {Spectre.Definition, :canonical, 1},
        {Spectre.Definition, :manifest, 1},
        {Spectre.Skill.Definition, :new, 1},
        {Spectre.Skill.Runtime, :mount, 4},
        {Spectre.Projection.Routing, :project, 2},
        {Spectre, :start_execution, 2},
        {Spectre.Execution.Program, :new, 1},
        {Spectre.Execution.Materializer, :materialize, 4},
        {Spectre.Execution.Handoff, :new, 1},
        {Spectre.Projection.Execution, :project, 2},
        {Spectre.Execution.Rehearsal, :run, 4},
        {Spectre.Governance.ChangeSet, :new, 1},
        {Spectre.Governance.Composer, :compose, 3},
        {Spectre.Governance.EvaluationDelta, :protected_corpus_digest, 1},
        {Spectre.Governance.Review, :evaluate, 5},
        {Spectre.Governance.Approval, :approve, 3},
        {Spectre.Governance.Approval, :reject, 3},
        {Spectre.Governance.GC, :plan, 3},
        {Spectre.Projection.HumanReport, :project, 3},
        {Spectre.Experience, :record, 3},
        {Spectre.Reflection, :reflect, 4},
        {Spectre.Projection.Reflection, :generate, 5},
        {Spectre.Forge, :propose, 5},
        {Spectre.Forge, :rebase, 5}
      ]
    }
  end

  @doc """
  Verifies a State payload and rewrites it through the current State writer.
  """
  @spec verify_state(binary() | map()) :: {:ok, report()} | {:error, term()}
  def verify_state(payload) do
    with {:ok, state} <- StateCodec.decode(payload),
         {:ok, source} <- json_data(payload),
         {:ok, current} <- StateCodec.encode(state),
         {:ok, source_version} <- version(source, "state_version") do
      {:ok,
       %{
         contract_version: @contract_version,
         format: :state,
         source_version: source_version,
         writer_version: Map.fetch!(current, "state_version"),
         revision: state.revision,
         digest: Value.digest!(current)
       }}
    end
  end

  @doc """
  Verifies a Run checkpoint and rewrites it through the current Run writer.
  """
  @spec verify_run(binary()) :: {:ok, report()} | {:error, term()}
  def verify_run(checkpoint) when is_binary(checkpoint) do
    with {:ok, run} <- Run.restore(checkpoint),
         {:ok, source_version} <- run_version(checkpoint),
         {:ok, current} <- Run.checkpoint(run),
         {:ok, writer_version} <- run_version(current) do
      {:ok,
       %{
         contract_version: @contract_version,
         format: :run,
         source_version: source_version,
         writer_version: writer_version,
         revision: run.revision,
         run_id: run.id,
         digest: binary_digest(current)
       }}
    end
  end

  def verify_run(value), do: {:error, {:invalid_foundation_run_checkpoint, shape(value)}}

  @doc """
  Verifies an Instance checkpoint and rewrites it through the current writer.

  `verify_checkpoint/1` is retained as a concise alias for tooling whose only
  canonical checkpoint family is the Instance checkpoint.
  """
  @spec verify_instance_checkpoint(binary() | map()) ::
          {:ok, report()} | {:error, term()}
  def verify_instance_checkpoint(checkpoint) do
    with {:ok, canonical} <- InstanceCodec.decode(checkpoint) do
      instance_checkpoint_report(checkpoint, canonical)
    end
  end

  @doc """
  Verifies an Instance checkpoint and binds its canonical identity to an
  Instance Ref or opaque Instance key.

  A `Spectre.Instance.Ref` enables the complete Instance canonical validator,
  including subject-bound operation data. A non-empty key verifies the exact
  `correlations[:instance_key]` invariant used by that validator. It does not
  compare the flow's `conversation_id`, which hosts may configure independently
  through `:state_conversation_id`.
  """
  @spec verify_instance_checkpoint(binary() | map(), InstanceRef.t() | String.t()) ::
          {:ok, report()} | {:error, term()}
  def verify_instance_checkpoint(checkpoint, %InstanceRef{} = ref) do
    with {:ok, canonical} <- InstanceCodec.decode(checkpoint),
         :ok <- InstanceValidator.validate(canonical, ref) do
      instance_checkpoint_report(checkpoint, canonical)
    end
  end

  def verify_instance_checkpoint(checkpoint, instance_key)
      when is_binary(instance_key) and instance_key != "" do
    with {:ok, canonical} <- InstanceCodec.decode(checkpoint),
         :ok <- validate_instance_key(canonical, instance_key) do
      instance_checkpoint_report(checkpoint, canonical)
    end
  end

  def verify_instance_checkpoint(_checkpoint, identity),
    do: {:error, {:invalid_foundation_instance_identity, shape(identity)}}

  @spec verify_checkpoint(binary() | map()) :: {:ok, report()} | {:error, term()}
  def verify_checkpoint(checkpoint), do: verify_instance_checkpoint(checkpoint)

  @spec instance_checkpoint_report(binary() | map(), Canonical.t()) ::
          {:ok, report()} | {:error, term()}
  defp instance_checkpoint_report(checkpoint, canonical) do
    with {:ok, source} <- json_data(checkpoint),
         {:ok, current} <- InstanceCodec.encode(canonical),
         {:ok, source_version} <- version(source, "checkpoint_version") do
      {:ok,
       %{
         contract_version: @contract_version,
         format: :instance,
         source_version: source_version,
         writer_version: Map.fetch!(current, "checkpoint_version"),
         state_schema_version: canonical.schema_version,
         revision: canonical.revision,
         digest: Value.digest!(current)
       }}
    end
  end

  @spec validate_instance_key(Canonical.t(), String.t()) :: :ok | {:error, term()}
  defp validate_instance_key(canonical, instance_key) do
    with {:ok, correlations} <- Canonical.fetch(canonical, :correlations),
         true <- is_map(correlations) and not is_struct(correlations),
         ^instance_key <- Map.get(correlations, :instance_key) do
      :ok
    else
      false -> {:error, :invalid_canonical_correlations}
      {:error, _reason} = error -> error
      _other -> {:error, :canonical_checkpoint_instance_mismatch}
    end
  end

  @doc """
  Verifies one canonical Definition and its sealed Manifest.

  Each argument may be the validated struct or its canonical encoded bytes.
  The returned identity is derived from the same canonical model consumed by
  publication and activation.
  """
  @spec verify_definition(CanonicalDefinition.t() | binary(), Manifest.t() | binary()) ::
          {:ok, report()} | {:error, term()}
  def verify_definition(definition, manifest) do
    with {:ok, canonical} <- normalize_definition(definition),
         {:ok, manifest} <- normalize_manifest(manifest),
         :ok <- Manifest.verify(manifest, canonical) do
      ref = CanonicalDefinition.ref(canonical)

      {:ok,
       %{
         contract_version: @contract_version,
         format: :definition,
         definition_ref: DefinitionRef.to_string(ref),
         definition_digest: CanonicalDefinition.digest(canonical),
         manifest_digest: Manifest.digest(manifest),
         manifest_contract: manifest.contract_version,
         authority_digest: Spectre.Authority.Envelope.digest(manifest.authority),
         closure_digest: Spectre.Execution.Closure.digest(manifest.execution_closure),
         digest:
           Value.digest!(%{
             definition_ref: DefinitionRef.to_string(ref),
             manifest_digest: Manifest.digest(manifest)
           })
       }}
    end
  end

  @doc """
  Verifies a transported Reflection projection against all of its exact inputs.

  This gate regenerates the projection; checking its stored digest alone is
  insufficient because effective Activation and Experience may have changed.
  """
  @spec verify_reflection(
          Projection.t() | map() | binary(),
          CanonicalDefinition.t() | binary(),
          Manifest.t() | binary(),
          Activation.t() | map(),
          ExperienceStore.snapshot() | map()
        ) :: {:ok, report()} | {:error, term()}
  def verify_reflection(projection, definition, manifest, activation, snapshot) do
    with {:ok, canonical} <- normalize_definition(definition),
         {:ok, manifest} <- normalize_manifest(manifest),
         {:ok, activation} <- normalize_activation(activation),
         {:ok, snapshot} <- normalize_snapshot(snapshot),
         {:ok, projection} <-
           normalize_reflection(
             projection,
             canonical,
             manifest,
             activation,
             snapshot
           ) do
      {:ok,
       %{
         contract_version: @contract_version,
         format: :reflection,
         definition_ref: DefinitionRef.to_string(projection.definition_ref),
         generator_id: projection.generator_id,
         generator_version: projection.generator_version,
         input_evidence_digest: projection.input_evidence_digest,
         digest: projection.digest
       }}
    end
  end

  @doc "Verifies a transported Forge Proposal and its complete evidence lineage."
  @spec verify_forge_proposal(Proposal.t() | map() | binary()) ::
          {:ok, report()} | {:error, term()}
  def verify_forge_proposal(proposal) do
    with {:ok, proposal} <- normalize_proposal(proposal),
         :ok <- Proposal.verify(proposal) do
      {:ok,
       %{
         contract_version: @contract_version,
         format: :forge_proposal,
         proposal_ref: Proposal.ref(proposal),
         change_set_digest: Spectre.Governance.ChangeSet.digest(proposal.change_set),
         reflection_digest: proposal.reflection_digest,
         experience_snapshot_digest: proposal.experience_snapshot_digest,
         digest: proposal.digest
       }}
    end
  end

  @spec normalize_definition(CanonicalDefinition.t() | binary()) ::
          {:ok, CanonicalDefinition.t()} | {:error, term()}
  defp normalize_definition(%CanonicalDefinition{} = canonical),
    do: CanonicalDefinition.new(Map.from_struct(canonical))

  defp normalize_definition(encoded) when is_binary(encoded),
    do: CanonicalDefinition.decode(encoded)

  defp normalize_definition(value),
    do: {:error, {:invalid_foundation_definition, shape(value)}}

  @spec normalize_manifest(Manifest.t() | binary()) ::
          {:ok, Manifest.t()} | {:error, term()}
  defp normalize_manifest(%Manifest{} = manifest), do: Manifest.new(manifest)
  defp normalize_manifest(encoded) when is_binary(encoded), do: Manifest.decode(encoded)

  defp normalize_manifest(value),
    do: {:error, {:invalid_foundation_manifest, shape(value)}}

  defp normalize_activation(%Activation{} = activation) do
    activation |> Activation.to_data() |> Activation.from_data()
  end

  defp normalize_activation(value) when is_map(value) and not is_struct(value),
    do: Activation.from_data(value)

  defp normalize_activation(value),
    do: {:error, {:invalid_foundation_activation, shape(value)}}

  defp normalize_snapshot(%{definition_ref: %DefinitionRef{}} = snapshot) do
    with :ok <- ExperienceStore.verify_snapshot(snapshot), do: {:ok, snapshot}
  end

  defp normalize_snapshot(value) when is_map(value) and not is_struct(value),
    do: ExperienceStore.snapshot_from_data(value)

  defp normalize_snapshot(value),
    do: {:error, {:invalid_foundation_experience_snapshot, shape(value)}}

  defp normalize_reflection(
         %Projection{} = projection,
         canonical,
         manifest,
         activation,
         snapshot
       ) do
    with :ok <- Reflection.verify(projection, canonical, manifest, activation, snapshot),
         do: {:ok, projection}
  end

  defp normalize_reflection(data, canonical, manifest, activation, snapshot)
       when is_map(data) and not is_struct(data),
       do: Reflection.from_data(data, canonical, manifest, activation, snapshot)

  defp normalize_reflection(encoded, canonical, manifest, activation, snapshot)
       when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded) do
      normalize_reflection(data, canonical, manifest, activation, snapshot)
    end
  end

  defp normalize_reflection(value, _canonical, _manifest, _activation, _snapshot),
    do: {:error, {:invalid_foundation_reflection, shape(value)}}

  defp normalize_proposal(%Proposal{} = proposal), do: Proposal.new(proposal)

  defp normalize_proposal(value) when is_map(value) and not is_struct(value),
    do: Proposal.from_data(value)

  defp normalize_proposal(value) when is_binary(value), do: Proposal.decode(value)
  defp normalize_proposal(value), do: {:error, {:invalid_foundation_forge_proposal, shape(value)}}

  @spec json_data(binary() | map()) :: {:ok, map()} | {:error, term()}
  defp json_data(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_foundation_json_map, shape(value)}}
      {:error, reason} -> {:error, {:invalid_foundation_json, reason}}
    end
  end

  defp json_data(payload) when is_map(payload) and not is_struct(payload), do: {:ok, payload}
  defp json_data(value), do: {:error, {:invalid_foundation_json_map, shape(value)}}

  @spec version(map(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp version(data, "state_version" = key) do
    validate_version(Map.get(data, key, Map.get(data, :state_version)), key)
  end

  defp version(data, "checkpoint_version" = key) do
    validate_version(Map.get(data, key, Map.get(data, :checkpoint_version)), key)
  end

  @spec validate_version(term(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  defp validate_version(value, key) do
    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, {:invalid_foundation_source_version, key, value}}
  end

  @spec run_version(binary()) :: {:ok, pos_integer()} | {:error, term()}
  defp run_version(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{"format" => @run_format, "version" => version}
      when is_integer(version) and version > 0 ->
        {:ok, version}

      _value ->
        {:error, :invalid_foundation_run_envelope}
    end
  rescue
    _exception -> {:error, :invalid_foundation_run_envelope}
  end

  @spec binary_digest(binary()) :: String.t()
  defp binary_digest(binary) do
    binary
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
