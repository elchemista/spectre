defmodule Spectre.Governance.Composer do
  @moduledoc """
  Trusted host composer for governed Definition Candidates.

  Composition re-reads the observed parent Definition, validates the exact
  Activation evidence, applies a closed ChangeSet through a compiled handler
  registry, seals a child Manifest, publishes it durably, emits structural gate
  receipts, and finally publishes only a `Candidate.Ref`.
  """

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Gate.Receipt
  alias Spectre.Gate.Receipt.Ref, as: ReceiptRef
  alias Spectre.Governance.Authority
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Registry
  alias Spectre.Governance.Composition
  alias Spectre.Governance.Constraints
  alias Spectre.Instance.Activation
  alias Spectre.Skill.Definition, as: SkillDefinition

  @builtin_gates [:structural, :authority, :closure, :prompt_budget, :applicability]
  @checker_version 1

  @doc "Composes, publishes, and returns a governed Candidate Ref."
  @spec compose(Store.config(), ChangeSet.t() | map() | keyword(), keyword()) ::
          {:ok, CandidateRef.t()} | {:error, term()}
  def compose(store, change_set, opts \\ [])

  def compose(store, change_set, opts) when is_list(opts) do
    with {:ok, change_set} <- ChangeSet.new(change_set),
         %Activation{} = activation <- Keyword.get(opts, :activation),
         :ok <-
           ChangeSet.verify_base(change_set, activation, Keyword.get(opts, :evidence, %{})),
         {:ok, registry} <- registry(Keyword.get(opts, :handler_registry)),
         {:ok, parent} <-
           Resolver.resolve_for_activation(
             store,
             change_set.observed_definition_ref,
             resolver_opts(opts)
           ),
         :ok <- verify_parent_activation(parent, activation),
         {:ok, authority} <- effective_authority(parent.manifest.authority, opts),
         {:ok, constraints} <- Constraints.new(authority, opts),
         {:ok, composition} <-
           Registry.apply(
             registry,
             change_set.operations,
             Composition.new(parent.definition),
             composition_context(authority, constraints, opts)
           ),
         {:ok, definition} <- finalize_definition(composition.definition, change_set),
         {:ok, closure} <- derive_closure(parent.manifest.execution_closure, definition),
         :ok <- require_protected_corpus(closure),
         :ok <- verify_composed_skills(definition),
         :ok <- Constraints.verify_definition(definition, authority, constraints),
         :ok <- Authority.no_expansion(parent.manifest.authority, authority),
         {:ok, manifest} <-
           build_manifest(definition, authority, closure, parent, change_set, opts),
         {:ok, publication_receipt} <-
           Store.publish(store, definition, manifest, resolver_opts(opts)),
         {:ok, governance} <-
           candidate_state(definition, closure, composition, constraints, change_set, opts),
         {:ok, receipts} <- builtin_receipts(governance, composition, manifest, opts),
         {:ok, receipt_refs} <- publish_receipts(store, receipts, resolver_opts(opts)),
         {:ok, governance} <- attach_receipts(governance, receipt_refs),
         {:ok, candidate} <-
           Candidate.from_resolution(
             %{
               definition_ref: Canonical.ref(definition),
               manifest: manifest,
               publication_receipt: publication_receipt
             },
             source: :governed_host,
             parent_ref: activation.candidate_ref,
             provenance_refs: ["changeset:sha256:" <> ChangeSet.digest(change_set)],
             governance: governance,
             created_at: Keyword.get(opts, :created_at, change_set.created_at)
           ),
         {:ok, candidate_ref} <- Store.publish_candidate(store, candidate, resolver_opts(opts)) do
      {:ok, candidate_ref}
    else
      nil -> {:error, :governance_composer_requires_activation}
      :not_found -> {:error, :governance_parent_definition_not_found}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_composer_input, shape(value)}}
    end
  end

  def compose(_store, _change_set, opts),
    do: {:error, {:invalid_governance_composer_options, shape(opts)}}

  defp registry(nil), do: {:ok, Registry.default()}
  defp registry(%Registry{} = registry), do: {:ok, registry}
  defp registry(value), do: {:error, {:invalid_governance_handler_registry, value}}

  defp verify_parent_activation(parent, activation) do
    closure_digest = Closure.digest(parent.manifest.execution_closure)

    cond do
      parent.definition_ref != activation.definition_ref ->
        {:error, :governance_parent_activation_definition_mismatch}

      closure_digest != activation.closure_digest ->
        {:error, :governance_parent_activation_closure_mismatch}

      true ->
        :ok
    end
  end

  defp effective_authority(parent, opts) do
    case Keyword.fetch(opts, :authority_ceiling) do
      :error -> {:ok, parent}
      {:ok, ceiling} -> Envelope.compose(parent, ceiling)
    end
  end

  defp composition_context(authority, constraints, opts) do
    %{
      authority: authority,
      prompt_token_ceiling: constraints.prompt_token_ceiling,
      mutable_config_paths: Keyword.get(opts, :mutable_config_paths, %{}),
      applicability_ceilings: constraints.applicability_ceilings,
      registered_migrations: Keyword.get(opts, :registered_migrations, [])
    }
  end

  defp finalize_definition(definition, change_set) do
    declared_version = %{
      "base" => definition.declared_version,
      "change_set" => ChangeSet.digest(change_set)
    }

    definition
    |> Map.from_struct()
    |> Map.put(:declared_version, declared_version)
    |> Canonical.new()
  end

  defp derive_closure(parent, definition) do
    with {:ok, skills} <- mounted_skills(definition) do
      prompt_digests =
        skills
        |> Enum.flat_map(&SkillDefinition.prompt_fragments/1)
        |> Enum.map(& &1.digest)
        |> Enum.reject(&is_nil/1)

      contract_refs =
        skills
        |> Enum.flat_map(&SkillDefinition.operation_refs/1)
        |> Enum.map(&("spectre.operation:" <> stable_ref(&1)))

      generators =
        skills
        |> Enum.flat_map(fn skill -> projection_generators(SkillDefinition.canonical(skill)) end)

      parent
      |> Map.from_struct()
      |> Map.update!(:prompt_fragment_digests, &(&1 ++ prompt_digests))
      |> Map.update!(:contract_refs, &(&1 ++ contract_refs))
      |> Map.update!(:projection_generators, &merge_generators(&1, generators))
      |> Closure.new()
    end
  end

  defp mounted_skills(definition) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- get(payload, :mounts, []) do
      restore_mounted_skills(mounts)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governed_skill_mounts, shape(value)}}
    end
  end

  defp restore_mounted_skills(mounts) do
    mounts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &restore_mounted_skill/2)
    |> then(fn
      {:ok, skills} -> {:ok, Enum.reverse(skills)}
      {:error, _reason} = error -> error
    end)
  end

  defp restore_mounted_skill({mount, index}, {:ok, skills}) when is_map(mount) do
    case {get(mount, :id), get(mount, :definition)} do
      {mount_id, data} when is_map(data) ->
        if valid_mount_id?(mount_id) do
          restore_mounted_skill_data(data, index, skills)
        else
          {:halt, {:error, {:invalid_governed_skill_mount, index, :invalid_mount_id}}}
        end

      {mount_id, _data} ->
        reason =
          if valid_mount_id?(mount_id), do: :definition_snapshot_required, else: :invalid_mount_id

        {:halt, {:error, {:invalid_governed_skill_mount, index, reason}}}
    end
  end

  defp restore_mounted_skill({_mount, index}, _acc),
    do: {:halt, {:error, {:invalid_governed_skill_mount, index}}}

  defp restore_mounted_skill_data(data, index, skills) do
    with {:ok, canonical} <- Canonical.from_data(data),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical) do
      {:cont, {:ok, [skill | skills]}}
    else
      {:error, reason} -> {:halt, {:error, {:invalid_governed_skill_mount, index, reason}}}
    end
  end

  defp projection_generators(canonical) do
    case Canonical.fetch_component(canonical, :projection) do
      {:ok, %{payload: payload}} when is_map(payload) ->
        payload
        |> get(:generators, [])
        |> Enum.flat_map(&projection_generator/1)

      _other ->
        []
    end
  end

  defp projection_generator(generator) do
    case {get(generator, :id), get(generator, :version)} do
      {id, version} when is_binary(id) and is_integer(version) and version > 0 ->
        [%{id: id, version: version}]

      _other ->
        []
    end
  end

  defp merge_generators(parent, added) do
    (parent ++ added)
    |> Enum.uniq_by(&{&1.id, &1.version})
    |> Enum.sort_by(&{&1.id, &1.version})
  end

  defp verify_composed_skills(definition) do
    with {:ok, skills} <- mounted_skills(definition) do
      Enum.reduce_while(skills, :ok, &verify_composed_skill/2)
    end
  end

  defp verify_composed_skill(skill, :ok) do
    case SkillDefinition.anti_hijack(skill) do
      {:ok, _evidence} -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp build_manifest(definition, authority, closure, parent, change_set, opts) do
    Manifest.new(definition, authority, closure,
      component_registry: Keyword.get(opts, :component_registry, ContractRegistry.default()),
      parent_refs: [parent.definition_ref],
      publisher_ref: change_set.author_ref,
      provenance_refs: ["changeset:sha256:" <> ChangeSet.digest(change_set)],
      receipt_refs: []
    )
  end

  defp candidate_state(definition, closure, composition, constraints, change_set, opts) do
    candidate_case_ids = composition.eval_cases |> Enum.map(&Map.fetch!(&1, "id")) |> Enum.sort()

    evaluation_cases_digest =
      Value.digest!(%{
        "protected_corpus_digest" => closure.evaluation_corpus_digest,
        "candidate_cases" => composition.eval_cases
      })

    with {:ok, required} <- required_gates(composition.risk, opts) do
      CandidateState.new(%{
        change_set_digest: ChangeSet.digest(change_set),
        base_activation_receipt: change_set.base_activation_receipt,
        base_candidate_ref: CandidateRef.to_string(change_set.base_candidate_ref),
        parent_definition_ref: Ref.to_string(change_set.observed_definition_ref),
        candidate_definition_ref: definition |> Canonical.ref() |> Ref.to_string(),
        observed_authority_epoch: change_set.observed_authority_epoch,
        observed_evidence_digest: change_set.observed_evidence_digest,
        closure_digest: Closure.digest(closure),
        evaluation_cases_digest: evaluation_cases_digest,
        protected_cases_digest: closure.evaluation_corpus_digest,
        prompt_token_ceiling: constraints.prompt_token_ceiling,
        applicability_ceilings: constraints.applicability_ceilings,
        candidate_cases: composition.eval_cases,
        candidate_case_ids: candidate_case_ids,
        state_migrations: composition.state_migrations,
        risk: composition.risk,
        required_gates: required,
        state: :composed,
        gate_receipt_refs: [],
        approval_receipt_ref: nil,
        report_digest: nil,
        lineage_refs: [CandidateRef.to_string(change_set.base_candidate_ref)]
      })
    end
  end

  defp required_gates(risk, opts) do
    case Keyword.get(opts, :required_gates, []) do
      gates when is_list(gates) ->
        required = CandidateState.constitutional_gates(risk) ++ gates

        required =
          if Keyword.get(opts, :require_semantic_live?, false),
            do: required ++ [:semantic_live],
            else: required

        {:ok, Enum.uniq(required)}

      value ->
        {:error, {:invalid_governance_required_gates, value}}
    end
  end

  defp require_protected_corpus(%Closure{evaluation_corpus_digest: digest})
       when is_binary(digest),
       do: :ok

  defp require_protected_corpus(%Closure{}), do: {:error, :governance_protected_corpus_required}

  defp builtin_receipts(governance, composition, manifest, opts) do
    issued_at = Keyword.get(opts, :created_at, System.system_time(:millisecond))

    @builtin_gates
    |> Enum.reduce_while({:ok, []}, fn gate, {:ok, receipts} ->
      result = builtin_result(gate, composition, manifest)

      attrs = %{
        gate_class: gate,
        candidate_digest: governance.proposal_digest,
        parent_definition_ref: governance.parent_definition_ref,
        candidate_definition_ref: governance.candidate_definition_ref,
        closure_digest: governance.closure_digest,
        checker_id: "spectre.gate.#{gate}",
        checker_version: @checker_version,
        evaluation_cases_digest: governance.evaluation_cases_digest,
        profile_ref: nil,
        issued_at: issued_at,
        expires_at: nil,
        status: :passed,
        result_digest: Value.digest!(result),
        provenance: %{
          source: :spectre_composer,
          changed_components: composition.changed_components
        }
      }

      case Receipt.new(attrs) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      {:error, _reason} = error -> error
    end)
  end

  defp builtin_result(:structural, composition, manifest),
    do: %{
      definition_ref: Ref.to_string(manifest.definition_ref),
      operations: composition.operation_types
    }

  defp builtin_result(:authority, _composition, manifest),
    do: %{authority_digest: Envelope.digest(manifest.authority)}

  defp builtin_result(:closure, _composition, manifest),
    do: %{closure_digest: Closure.digest(manifest.execution_closure)}

  defp builtin_result(:prompt_budget, composition, _manifest),
    do: %{changed: :prompt_fragments in composition.changed_components}

  defp builtin_result(:applicability, composition, _manifest),
    do: %{changed: :applicability in composition.changed_components}

  defp publish_receipts(store, receipts, opts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, refs} ->
      case Store.publish_gate_receipt(store, receipt, opts) do
        {:ok, ref} -> {:cont, {:ok, [ReceiptRef.to_string(ref) | refs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, _reason} = error -> error
    end)
  end

  defp attach_receipts(governance, refs) do
    governance
    |> Map.from_struct()
    |> Map.put(:gate_receipt_refs, refs)
    |> CandidateState.new()
  end

  defp resolver_opts(opts) do
    Keyword.take(opts, [
      :checkpoint_store,
      :component_registry,
      :observed_builds,
      :on_drift,
      :now
    ])
  end

  defp stable_ref(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_ref(value) when is_binary(value), do: value
  defp stable_ref(value), do: Value.digest!(value)

  defp valid_mount_id?(value) when is_binary(value) and value != "",
    do: not String.starts_with?(value, "Elixir.")

  defp valid_mount_id?(_value), do: false

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_value, _key, default), do: default

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
