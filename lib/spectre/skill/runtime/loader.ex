defmodule Spectre.Skill.Runtime.Loader do
  @moduledoc """
  Restores the governed Skill runtime for one exact Agent Definition Ref.

  Every load resolves the published Definition and Manifest from the Store,
  verifies optional Run closure evidence, rebuilds runtime Skill definitions
  from their canonical snapshots, and checks each embedded Ref. There is no
  fallback to the currently loaded Agent module.
  """

  alias Spectre.Authority.Envelope
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure
  alias Spectre.Morph.Surface
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime

  @typedoc "The verified, exact runtime view restored from a Definition Store."
  @type loaded :: %{
          agent: module(),
          runtime: Runtime.t(),
          definition: Canonical.t(),
          manifest: Spectre.Definition.Manifest.t(),
          surface: Surface.t()
        }
  @typep mount_id :: String.t() | atom() | integer()
  @typep mounted_skill :: {mount_id(), SkillDefinition.t()}
  @typep shape :: :list | :map | :tuple | :other

  @doc "Loads the exact runtime view pinned by a Definition Ref."
  @spec load(Store.config(), Ref.t() | String.t(), module()) ::
          {:ok, loaded()} | {:error, term()}
  @spec load(Store.config(), Ref.t() | String.t(), module(), keyword()) ::
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

  # The effective prompt window can only narrow the constitutional Surface.
  # An authority grant never expands the per-Agent ceiling stored in Definition.
  @spec runtime(module(), Envelope.t(), Surface.t()) ::
          {:ok, Runtime.t()} | {:error, term()}
  defp runtime(agent, authority, surface) do
    authority_max = Map.get(authority.limits, :max_tokens)
    maximum = prompt_window(authority_max, surface.prompt_token_ceiling)

    available = min(maximum, surface.prompt_token_ceiling)

    Runtime.new(agent, authority,
      max_prompt_tokens: maximum,
      kernel_prompt_tokens: maximum - available,
      per_skill_prompt_cap: available
    )
  end

  # Envelope limits are numeric, while token windows are integral. Rounding a
  # positive fractional grant down preserves least authority and keeps a valid
  # Envelope loadable without ever allocating beyond its ceiling.
  @spec prompt_window(number() | nil, pos_integer()) :: non_neg_integer()
  defp prompt_window(value, _surface_ceiling) when is_integer(value) and value >= 0, do: value
  defp prompt_window(value, _surface_ceiling) when is_float(value) and value > 0, do: trunc(value)
  defp prompt_window(_value, surface_ceiling), do: surface_ceiling

  @spec mounted_skills(Canonical.t()) :: {:ok, [mounted_skill()]} | {:error, term()}
  defp mounted_skills(definition) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- get(payload, :mounts, []) do
      mounts
      |> Stream.with_index()
      |> Enum.reduce_while({:ok, []}, &load_mount/2)
      |> reverse_mounts()
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_runtime_skill_mounts, shape(value)}}
    end
  end

  @spec load_mount({term(), non_neg_integer()}, {:ok, [mounted_skill()]}) ::
          {:cont, {:ok, [mounted_skill()]}} | {:halt, {:error, term()}}
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

  @spec reverse_mounts({:ok, [mounted_skill()]} | {:error, term()}) ::
          {:ok, [mounted_skill()]} | {:error, term()}
  defp reverse_mounts({:ok, mounts}), do: {:ok, Enum.reverse(mounts)}
  defp reverse_mounts({:error, _reason} = error), do: error

  @spec mount_all(Runtime.t(), [mounted_skill()]) ::
          {:ok, Runtime.t()} | {:error, term()}
  defp mount_all(runtime, mounts) do
    Enum.reduce_while(mounts, {:ok, runtime}, fn {mount_id, definition}, {:ok, current} ->
      case Runtime.mount(current, mount_id, definition, expected_revision: current.revision) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Runtime-only consumers execute data-authored Skills. Compiled mounts stay
  # owned by the ordinary Agent router and cannot enter the runtime data path.
  @spec filter_mounts([mounted_skill()], keyword()) :: [mounted_skill()]
  defp filter_mounts(mounts, opts) do
    if Keyword.get(opts, :runtime_only?, false) do
      Enum.filter(mounts, fn {_mount_id, definition} ->
        SkillDefinition.origin(definition) == :runtime
      end)
    else
      mounts
    end
  end

  # A nested canonical Definition is accepted only when its advertised Ref is
  # exactly the Ref recomputed from its bytes; no surrounding mount may rename it.
  @spec verify_embedded_ref(Canonical.t(), term()) :: :ok | {:error, term()}
  defp verify_embedded_ref(canonical, embedded) when is_binary(embedded) do
    actual = canonical |> Canonical.ref() |> Ref.to_string()

    if actual == embedded,
      do: :ok,
      else: {:error, {:runtime_skill_definition_ref_mismatch, embedded, actual}}
  end

  defp verify_embedded_ref(_canonical, value),
    do: {:error, {:invalid_runtime_skill_definition_ref, value}}

  @spec verify_closure(Closure.t(), keyword()) :: :ok | {:error, term()}
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

  # The host module is code authority, not a convenient rendering hint. It must
  # match the compiled-only owner sealed into the exact Agent Definition.
  @spec verify_agent_binding(Canonical.t(), module()) :: :ok | {:error, term()}
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

  @spec normalize_ref(term()) :: {:ok, Ref.t()} | {:error, term()}
  defp normalize_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_definition_ref, ref}}
  end

  defp normalize_ref(value) when is_binary(value), do: Ref.parse(value)
  defp normalize_ref(value), do: {:error, {:invalid_definition_ref, value}}

  # Build observation and reject-on-drift are constitutional here. Callers may
  # provide evidence or adapters, but cannot disable either enforcement point.
  @spec resolver_opts(keyword()) :: keyword()
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

  @spec valid_mount_id?(term()) :: boolean()
  defp valid_mount_id?(value),
    do:
      (is_binary(value) and value != "") or (is_atom(value) and not is_nil(value)) or
        is_integer(value)

  @spec get(map(), atom()) :: term()
  @spec get(map(), atom(), term()) :: term()
  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec shape(term()) :: shape()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
