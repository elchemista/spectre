defmodule Spectre.Skill.Runtime.Loader do
  @moduledoc """
  Restores the governed Skill runtime for one exact Agent Definition Ref.

  Every load resolves the published Definition and Manifest from the Store,
  verifies optional Run closure evidence, rebuilds runtime Skill definitions
  from their canonical snapshots, and checks each embedded Ref. There is no
  fallback to the currently loaded Agent module.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Resolver
  alias Spectre.Execution.Closure
  alias Spectre.Morph.Surface
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime

  @type loaded :: %{
          agent: module(),
          runtime: Runtime.t(),
          definition: Canonical.t(),
          manifest: Spectre.Definition.Manifest.t(),
          surface: Surface.t()
        }

  @doc "Loads the exact runtime view pinned by a Definition Ref."
  @spec load(term(), Ref.t() | String.t(), module(), keyword()) ::
          {:ok, loaded()} | {:error, term()}
  def load(store, definition_ref, agent, opts \\ [])

  def load(store, definition_ref, agent, opts)
      when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, definition_ref} <- normalize_ref(definition_ref),
           {:ok, resolution} <- Resolver.resolve(store, definition_ref, resolver_opts(opts)),
           :ok <- verify_agent_binding(resolution.definition, agent),
           :ok <- verify_closure(resolution.manifest.execution_closure, opts),
           {:ok, surface} <- Surface.from_canonical(resolution.definition),
           {:ok, runtime} <- runtime(agent, resolution.manifest.authority, surface),
           {:ok, mounts} <- mounted_skills(resolution.definition),
           mounts = filter_mounts(mounts, opts),
           {:ok, runtime} <- mount_all(runtime, mounts) do
        {:ok,
         %{
           agent: agent,
           runtime: runtime,
           definition: resolution.definition,
           manifest: resolution.manifest,
           surface: surface
         }}
      end
    else
      {:error, {:invalid_skill_runtime_loader_options, opts}}
    end
  end

  def load(_store, _definition_ref, agent, _opts),
    do: {:error, {:invalid_skill_runtime_loader_agent, agent}}

  defp runtime(agent, authority, surface) do
    authority_max = Map.get(authority.limits, :max_tokens)

    maximum =
      if is_integer(authority_max) and authority_max > 0,
        do: authority_max,
        else: surface.prompt_token_ceiling

    available = min(maximum, surface.prompt_token_ceiling)

    Runtime.new(agent, authority,
      max_prompt_tokens: maximum,
      kernel_prompt_tokens: maximum - available,
      per_skill_prompt_cap: available
    )
  end

  defp mounted_skills(definition) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- get(payload, :mounts, []) do
      mounts
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, &load_mount/2)
      |> then(fn
        {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
        {:error, _reason} = error -> error
      end)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_runtime_skill_mounts, shape(value)}}
    end
  end

  defp load_mount({mount, index}, {:ok, loaded}) when is_map(mount) do
    mount_id = get(mount, :id)
    definition_data = get(mount, :definition)
    embedded_ref = get(mount, :definition_ref)

    with true <- valid_mount_id?(mount_id),
         true <- is_map(definition_data),
         {:ok, canonical} <- Canonical.from_data(definition_data),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical),
         :ok <- verify_embedded_ref(canonical, embedded_ref) do
      {:cont, {:ok, [{mount_id, skill} | loaded]}}
    else
      false -> {:halt, {:error, {:invalid_runtime_skill_mount, index}}}
      {:error, reason} -> {:halt, {:error, {:invalid_runtime_skill_mount, index, reason}}}
    end
  end

  defp load_mount({_mount, index}, _acc),
    do: {:halt, {:error, {:invalid_runtime_skill_mount, index}}}

  defp mount_all(runtime, mounts) do
    Enum.reduce_while(mounts, {:ok, runtime}, fn {mount_id, definition}, {:ok, current} ->
      case Runtime.mount(current, mount_id, definition, expected_revision: current.revision) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp filter_mounts(mounts, opts) do
    if Keyword.get(opts, :runtime_only?, false) do
      Enum.filter(mounts, fn {_mount_id, definition} ->
        SkillDefinition.origin(definition) == :runtime
      end)
    else
      mounts
    end
  end

  defp verify_embedded_ref(canonical, embedded) when is_binary(embedded) do
    actual = canonical |> Canonical.ref() |> Ref.to_string()

    if actual == embedded,
      do: :ok,
      else: {:error, {:runtime_skill_definition_ref_mismatch, embedded, actual}}
  end

  defp verify_embedded_ref(_canonical, value),
    do: {:error, {:invalid_runtime_skill_definition_ref, value}}

  defp verify_closure(closure, opts) do
    case Keyword.get(opts, :closure_digest) do
      nil ->
        :ok

      expected when is_binary(expected) ->
        actual = Closure.digest(closure)

        if actual == expected,
          do: :ok,
          else: {:error, {:runtime_skill_closure_mismatch, expected, actual}}

      value ->
        {:error, {:invalid_runtime_skill_closure_digest, value}}
    end
  end

  defp verify_agent_binding(definition, agent) do
    with {:ok, component} <- Canonical.fetch_component(definition, :identity),
         payload when is_map(payload) <- component.payload,
         owner when is_map(owner) <- get(payload, :owner_ref),
         "code_ref" <- get(owner, :"$spectre_type"),
         "module" <- get(owner, :kind),
         "compiled_only" <- get(owner, :mode),
         expected when is_binary(expected) <- get(owner, :module),
         true <- expected == Atom.to_string(agent) do
      :ok
    else
      {:error, _reason} = error -> error
      _value -> {:error, {:runtime_skill_agent_definition_mismatch, Atom.to_string(agent)}}
    end
  end

  defp normalize_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_definition_ref, ref}}
  end

  defp normalize_ref(value) when is_binary(value), do: Ref.parse(value)
  defp normalize_ref(value), do: {:error, {:invalid_definition_ref, value}}

  defp resolver_opts(opts) do
    opts
    |> Keyword.take([
      :checkpoint_store,
      :component_registry,
      :observe_builds,
      :observed_builds,
      :build_modules
    ])
    |> Keyword.put(:observe_builds, true)
    |> Keyword.put(:on_drift, :reject)
  end

  defp valid_mount_id?(value),
    do:
      (is_binary(value) and value != "") or (is_atom(value) and not is_nil(value)) or
        is_integer(value)

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
