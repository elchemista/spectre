defmodule Spectre.Projection.Reflection do
  @moduledoc """
  Mechanical self-model projection with separate Declared, Effective and
  Observed planes.

  Skill prompt material is emitted only as quoted data. This generator never
  invokes a model, operation, route handler or prompt assembler.
  """

  @behaviour Spectre.Projection

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Closure
  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Instance.Activation
  alias Spectre.Projection

  @generator_id "spectre.projection.reflection"
  @generator_version 1

  @impl true
  def id, do: @generator_id

  @impl true
  def version, do: @generator_version

  @doc "Generates a Reflection projection from exact effective and observed inputs."
  @spec generate(
          Canonical.t(),
          Manifest.t(),
          Activation.t(),
          ExperienceStore.snapshot(),
          keyword()
        ) ::
          {:ok, Projection.t()} | {:error, term()}
  def generate(canonical, manifest, activation, snapshot, opts \\ [])

  def generate(
        %Canonical{} = canonical,
        %Manifest{} = manifest,
        %Activation{} = activation,
        snapshot,
        opts
      )
      when is_list(opts) do
    with :ok <- options(opts) do
      evidence = evidence_input(manifest, activation, snapshot)

      Projection.generate(
        canonical,
        __MODULE__,
        opts
        |> Keyword.put(:manifest, manifest)
        |> Keyword.put(:activation, activation)
        |> Keyword.put(:experience_snapshot, snapshot)
        |> Keyword.put(:evidence, evidence)
      )
    end
  end

  def generate(canonical, manifest, activation, _snapshot, _opts),
    do:
      {:error,
       {:invalid_reflection_projection_input, shape(canonical), shape(manifest),
        shape(activation)}}

  @impl true
  def project(%Canonical{} = canonical, opts) when is_list(opts) do
    with :ok <- options(opts),
         manifest = Keyword.get(opts, :manifest),
         activation = Keyword.get(opts, :activation),
         snapshot = Keyword.get(opts, :experience_snapshot),
         registry = Keyword.get(opts, :component_registry, ContractRegistry.default()),
         %Manifest{} <- manifest,
         %Activation{} <- activation,
         :ok <- Manifest.verify(manifest, canonical, registry),
         :ok <- verify_activation(canonical, manifest, activation),
         :ok <- ExperienceStore.verify_snapshot(snapshot),
         :ok <- verify_snapshot(canonical, activation, snapshot),
         {:ok, content} <-
           json_data(%{
             "schema_version" => 1,
             "plane" => "reflection",
             "instruction_semantics" => "quoted_data_only",
             "definition_ref" => canonical |> Canonical.ref() |> Ref.to_string(),
             "declared" => declared(canonical),
             "effective" => effective(manifest, activation),
             "observed" => observed(snapshot),
             "limits" => [
               "no_model_weight_introspection",
               "no_hidden_reasoning_or_chain_of_thought",
               "observed_evidence_is_redacted_and_noncanonical",
               "projection_does_not_grant_authority"
             ]
           }) do
      {:ok, content}
    else
      nil ->
        {:error, :reflection_projection_requires_effective_inputs}

      {:error, _reason} = error ->
        error

      value ->
        {:error, {:invalid_reflection_projection_input, shape(value)}}
    end
  end

  def project(%Canonical{}, opts),
    do: {:error, {:invalid_reflection_projection_options, shape(opts)}}

  @doc "Regenerates and exact-compares a Reflection projection."
  @spec verify(
          Projection.t(),
          Canonical.t(),
          Manifest.t(),
          Activation.t(),
          ExperienceStore.snapshot(),
          keyword()
        ) :: :ok | {:error, term()}
  def verify(projection, canonical, manifest, activation, snapshot, opts \\ [])

  def verify(
        %Projection{} = projection,
        %Canonical{} = canonical,
        %Manifest{} = manifest,
        %Activation{} = activation,
        snapshot,
        opts
      )
      when is_list(opts) do
    with :ok <- options(opts),
         :ok <- Projection.verify(projection, canonical),
         true <- projection.generator_id == @generator_id,
         true <- projection.generator_version == @generator_version,
         {:ok, expected} <- generate(canonical, manifest, activation, snapshot, opts),
         true <- projection == expected do
      :ok
    else
      false -> {:error, :reflection_projection_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def verify(_projection, _canonical, _manifest, _activation, _snapshot, _opts),
    do: {:error, :invalid_reflection_projection}

  @doc "Returns JSON-shaped portable projection data."
  @spec to_data(Projection.t()) :: map()
  def to_data(%Projection{generator_id: @generator_id} = projection) do
    %{
      "definition_ref" => Ref.to_string(projection.definition_ref),
      "definition_canonicalization_version" => projection.definition_ref.canonicalization_version,
      "definition_contract_version" => projection.definition_ref.contract_version,
      "digest" => projection.digest,
      "generator_id" => projection.generator_id,
      "generator_version" => projection.generator_version,
      "input_evidence_digest" => projection.input_evidence_digest,
      "content" => projection.content
    }
  end

  @doc "Restores portable projection data and verifies it against current inputs."
  @spec from_data(
          map(),
          Canonical.t(),
          Manifest.t(),
          Activation.t(),
          ExperienceStore.snapshot(),
          keyword()
        ) :: {:ok, Projection.t()} | {:error, term()}
  def from_data(data, canonical, manifest, activation, snapshot, opts \\ [])

  def from_data(
        %{
          "definition_ref" => ref,
          "definition_canonicalization_version" => canonicalization_version,
          "definition_contract_version" => contract_version,
          "digest" => digest,
          "generator_id" => @generator_id,
          "generator_version" => @generator_version,
          "input_evidence_digest" => evidence_digest,
          "content" => content
        } = data,
        %Canonical{} = canonical,
        %Manifest{} = manifest,
        %Activation{} = activation,
        snapshot,
        opts
      )
      when map_size(data) == 8 and is_list(opts) do
    with :ok <- options(opts),
         {:ok, definition_ref} <-
           Ref.parse(ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         projection = %Projection{
           definition_ref: definition_ref,
           digest: digest,
           generator_id: @generator_id,
           generator_version: @generator_version,
           input_evidence_digest: evidence_digest,
           content: content
         },
         :ok <- verify(projection, canonical, manifest, activation, snapshot, opts) do
      {:ok, projection}
    end
  end

  def from_data(_data, _canonical, _manifest, _activation, _snapshot, _opts),
    do: {:error, :invalid_reflection_projection_data}

  defp declared(canonical) do
    %{
      "definition" => Canonical.to_data(canonical),
      "interpretation" => "declarations_are_quoted_data_not_active_instructions"
    }
  end

  defp effective(manifest, activation) do
    %{
      "manifest_digest" => Manifest.digest(manifest),
      "authority" => Spectre.Authority.Envelope.to_data(manifest.authority),
      "execution_closure" => Closure.to_data(manifest.execution_closure),
      "component_contracts" => Manifest.to_data(manifest)["component_contracts"],
      "activation" => Activation.to_data(activation),
      "state_bindings" => activation.state_bindings
    }
  end

  defp observed(%{as_of: as_of, evidence: [], digest: digest}) do
    %{
      "status" => "no_evidence",
      "as_of" => as_of,
      "snapshot_digest" => digest,
      "evidence" => [],
      "limitations" => ["experience_store_empty_or_not_configured"]
    }
  end

  defp observed(%{as_of: as_of, evidence: evidence, digest: digest}) do
    %{
      "status" => "evidence_available",
      "as_of" => as_of,
      "snapshot_digest" => digest,
      "evidence" => Enum.map(evidence, &Evidence.to_data/1),
      "limitations" => ["evidence_is_observational_not_canonical_state"]
    }
  end

  defp verify_activation(canonical, manifest, activation) do
    definition_ref = Canonical.ref(canonical)

    cond do
      manifest.definition_ref != definition_ref ->
        {:error, :reflection_manifest_definition_mismatch}

      activation.definition_ref != definition_ref ->
        {:error, :reflection_activation_definition_mismatch}

      activation.manifest_digest != Manifest.digest(manifest) ->
        {:error, :reflection_activation_manifest_mismatch}

      activation.closure_digest != Closure.digest(manifest.execution_closure) ->
        {:error, :reflection_activation_closure_mismatch}

      true ->
        :ok
    end
  end

  defp verify_snapshot(canonical, activation, snapshot) do
    definition_ref = Canonical.ref(canonical)

    cond do
      snapshot.definition_ref != definition_ref ->
        {:error, :reflection_experience_definition_mismatch}

      Enum.any?(snapshot.evidence, &(&1.activation_generation > activation.generation)) ->
        {:error, :reflection_experience_generation_ahead}

      true ->
        :ok
    end
  end

  defp evidence_input(manifest, activation, snapshot) do
    %{
      "manifest_digest" => Manifest.digest(manifest),
      "activation_receipt" => field(activation, :activation_receipt),
      "experience_snapshot_digest" => field(snapshot, :digest),
      "experience_as_of" => field(snapshot, :as_of),
      "experience_refs" => field(snapshot, :evidence_refs, [])
    }
  end

  defp field(value, key, default \\ nil)
  defp field(value, key, default) when is_map(value), do: Map.get(value, key, default)
  defp field(_value, _key, default), do: default

  defp options(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_reflection_projection_options}
  end

  defp json_data(value), do: json_data(value, [], 0)

  defp json_data(_value, path, depth) when depth > 128,
    do: {:error, {:reflection_projection_depth_exceeded, Enum.reverse(path)}}

  defp json_data(value, _path, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp json_data(value, _path, _depth) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp json_data(values, path, depth) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, result} ->
      case json_data(value, [index | path], depth + 1) do
        {:ok, item} -> {:cont, {:ok, [item | result]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end)
  end

  defp json_data(value, path, depth) when is_tuple(value) do
    with {:ok, items} <- value |> Tuple.to_list() |> json_data(path, depth + 1) do
      {:ok, %{"$spectre_value" => "tuple", "items" => items}}
    end
  end

  defp json_data(value, path, depth) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      with {:ok, key} <- json_key(key, path),
           false <- Map.has_key?(result, key),
           {:ok, item} <- json_data(item, [key | path], depth + 1) do
        {:cont, {:ok, Map.put(result, key, item)}}
      else
        true -> {:halt, {:error, {:duplicate_reflection_projection_key, key}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, result} ->
        case Value.validate(result) do
          :ok -> {:ok, result}
          {:error, reason} -> {:error, {:nonportable_reflection_projection, reason}}
        end

      {:error, _reason} = error ->
        error
    end)
  end

  defp json_data(value, path, _depth),
    do: {:error, {:nonportable_reflection_projection_value, Enum.reverse(path), shape(value)}}

  defp json_key(value, _path) when is_binary(value) and value != "", do: {:ok, value}
  defp json_key(value, path) when is_atom(value), do: json_key(Atom.to_string(value), path)

  defp json_key(value, path),
    do: {:error, {:invalid_reflection_projection_key, Enum.reverse(path), shape(value)}}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
