defmodule Spectre.Execution.Admission do
  @moduledoc false

  alias Spectre.Authority.Envelope
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Execution.Closure
  alias Spectre.Execution.Materialization
  alias Spectre.Execution.Program
  alias Spectre.Instance.Activation
  alias Spectre.Skill.Definition, as: SkillDefinition

  @spec verify(
          Materialization.t(),
          Spectre.Definition.Store.config() | nil,
          Activation.t() | nil,
          keyword()
        ) ::
          :ok | {:error, term()}
  def verify(materialization, store, activation, opts \\ [])

  def verify(%Materialization{} = materialization, store, %Activation{} = activation, opts)
      when not is_nil(store) and is_list(opts) do
    with :ok <- Materialization.verify(materialization),
         {:ok, resolution} <- resolve(store, activation, opts),
         :ok <- activation_binding(resolution, activation),
         {:ok, skill} <- mounted_skill(resolution.definition, materialization.mount_id),
         :ok <- definition_binding(skill, materialization),
         :ok <- route_binding(skill, materialization),
         :ok <- closure_binding(resolution.manifest.execution_closure, materialization) do
      authority_binding(resolution.manifest.authority, materialization.program)
    end
  end

  def verify(%Materialization{}, nil, %Activation{}, _opts),
    do: {:error, :execution_definition_store_not_configured}

  def verify(%Materialization{}, _store, nil, _opts),
    do: {:error, :execution_requires_active_definition}

  def verify(%Materialization{}, _store, %Activation{}, _opts),
    do: {:error, :invalid_execution_admission_options}

  @spec resolve(Spectre.Definition.Store.config(), Activation.t(), keyword()) ::
          {:ok, Resolver.resolution()} | {:error, term()}
  defp resolve(store, activation, opts) do
    resolver_opts = Keyword.put_new(opts, :observe_builds, true)

    case Resolver.resolve(store, activation.definition_ref, resolver_opts) do
      {:ok, resolution} -> {:ok, resolution}
      :not_found -> {:error, :active_execution_definition_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp activation_binding(resolution, activation) do
    cond do
      resolution.definition_ref != activation.definition_ref ->
        {:error, :execution_activation_definition_mismatch}

      Manifest.digest(resolution.manifest) != activation.manifest_digest ->
        {:error, :execution_activation_manifest_mismatch}

      Closure.digest(resolution.manifest.execution_closure) != activation.closure_digest ->
        {:error, :execution_activation_closure_mismatch}

      resolution.drift.status != :matched ->
        {:error, {:execution_build_not_verified, resolution.drift.status}}

      build_evidence(activation) != resolution.drift ->
        {:error, :execution_activation_build_evidence_mismatch}

      true ->
        :ok
    end
  end

  defp build_evidence(%Activation{provenance: provenance}) do
    Map.get(provenance, :build_evidence, Map.get(provenance, "build_evidence"))
  end

  defp mounted_skill(definition, mount_id) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         mounts when is_list(mounts) <- value(component.payload, :mounts, []),
         mount when is_map(mount) <- Enum.find(mounts, &same_ref?(value(&1, :id), mount_id)),
         data when is_map(data) <- value(mount, :definition),
         {:ok, canonical} <- Canonical.from_data(data),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical),
         :ok <- mount_ref_binding(mount, skill) do
      {:ok, skill}
    else
      nil -> {:error, {:execution_skill_mount_not_active, stable_ref(mount_id)}}
      false -> {:error, {:execution_skill_mount_not_active, stable_ref(mount_id)}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_active_execution_skill_mount, stable_ref(mount_id)}}
    end
  end

  defp mount_ref_binding(mount, skill) do
    expected = skill |> SkillDefinition.ref() |> to_string()

    if value(mount, :definition_ref) == expected,
      do: :ok,
      else: {:error, :execution_skill_mount_definition_mismatch}
  end

  defp definition_binding(skill, materialization) do
    expected = skill |> SkillDefinition.ref() |> to_string()

    with true <- expected == materialization.definition_ref,
         {:ok, declared} <- SkillDefinition.work(skill, materialization.program.id),
         true <- declared.digest == materialization.program.digest do
      :ok
    else
      false -> {:error, :execution_materialization_not_in_active_definition}
      {:error, _reason} = error -> error
    end
  end

  defp route_binding(skill, materialization) do
    route =
      Enum.find(SkillDefinition.routes(skill), fn route ->
        same_ref?(value(route, :label), materialization.route_label)
      end)

    case route && value(route, :handler) do
      handler when is_map(handler) ->
        if value(handler, :kind) in [:work, "work"] and
             same_ref?(value(handler, :work_ref), materialization.program.id) do
          :ok
        else
          {:error, :execution_materialization_route_program_mismatch}
        end

      _missing ->
        {:error, :execution_materialization_route_not_active}
    end
  end

  defp closure_binding(%Closure{} = closure, materialization) do
    with :ok <- Program.validate_profile_pinning(materialization.program),
         :ok <- required_contracts(closure, Program.operation_refs(materialization.program)),
         :ok <- required_prompts(closure, materialization.prompt_receipts),
         :ok <- required_profiles(closure, Program.profile_refs(materialization.program)) do
      required_projection(closure, materialization.projection)
    end
  end

  defp required_contracts(closure, operation_refs) do
    required = Enum.map(operation_refs, &("spectre.operation:" <> stable_ref(&1)))
    missing = required -- closure.contract_refs

    if missing == [], do: :ok, else: {:error, {:execution_closure_missing_contracts, missing}}
  end

  defp required_prompts(closure, receipts) do
    missing = Enum.map(receipts, & &1.fragment_digest) -- closure.prompt_fragment_digests

    if missing == [], do: :ok, else: {:error, {:execution_closure_missing_prompts, missing}}
  end

  defp required_profiles(closure, profile_refs) do
    missing = profile_refs -- closure.model_profile_refs

    if missing == [], do: :ok, else: {:error, {:execution_closure_missing_profiles, missing}}
  end

  defp required_projection(closure, projection) do
    if Enum.any?(closure.projection_generators, fn generator ->
         generator.id == projection.generator_id and
           generator.version == projection.generator_version
       end) do
      :ok
    else
      {:error,
       {:execution_closure_missing_projection,
        {projection.generator_id, projection.generator_version}}}
    end
  end

  defp authority_binding(%Envelope{} = authority, program) do
    with :ok <- operation_authority(authority, program),
         :ok <- model_authority(authority, program) do
      budget_authority(authority, program)
    end
  end

  defp operation_authority(authority, program) do
    case Enum.find(Program.operation_refs(program), fn ref ->
           not Enum.any?(authority.operations, &same_ref?(&1, ref))
         end) do
      nil -> :ok
      ref -> {:error, {:execution_operation_not_authorized, ref}}
    end
  end

  defp model_authority(authority, program) do
    cond do
      Program.uses_inference?(program) and
          not Enum.any?(authority.model_purposes, &same_ref?(&1, :data_driven_work)) ->
        {:error, {:execution_model_purpose_not_authorized, program.id, :data_driven_work}}

      profile =
          Enum.find(Program.profile_refs(program), fn profile ->
            not Enum.any?(authority.model_profiles, &same_ref?(&1, profile))
          end) ->
        {:error, {:execution_model_profile_not_authorized, program.id, profile}}

      true ->
        :ok
    end
  end

  defp budget_authority(authority, program) do
    excess =
      [cost: :max_cost, duration_ms: :max_duration_ms, pages: :max_pages]
      |> Enum.find_value(&budget_excess(program, authority, &1))

    if is_nil(excess), do: :ok, else: {:error, excess}
  end

  defp budget_excess(program, authority, {budget_field, authority_field}) do
    case Map.fetch(authority.limits, authority_field) do
      :error ->
        nil

      {:ok, ceiling} ->
        requested = Map.get(program.budget, budget_field)

        if is_number(requested) and requested <= ceiling,
          do: nil,
          else: {:execution_budget_not_authorized, program.id, budget_field, requested, ceiling}
    end
  end

  defp same_ref?(left, right), do: stable_ref(left) == stable_ref(right)

  defp stable_ref(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_ref(value) when is_binary(value), do: value
  defp stable_ref(value), do: inspect(value)

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
