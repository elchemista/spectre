defmodule Spectre.ActionConfig do
  @moduledoc """
  Resolves provider-neutral action configuration from an Agent definition.

  `actions MyApp.Actions` remains the compatibility shorthand for one local
  provider. Optional libraries contribute providers or a planner through
  `Spectre.Extension`, keeping their implementation out of the core.
  """

  alias Spectre.Action.Provider.Mount
  alias Spectre.Definition
  alias Spectre.Extension

  @type action_config :: {module(), keyword()} | nil
  @type planner_config :: {module(), keyword()} | nil

  @doc """
  Returns the legacy local action module configuration.
  """
  @spec actions(module()) :: action_config()
  def actions(agent) when is_atom(agent) and not is_nil(agent) do
    case Definition.fetch(agent) do
      {:ok, definition} ->
        normalize_legacy_actions(Keyword.get(definition.config, :actions))

      {:error, _reason} ->
        nil
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  def actions(_agent), do: nil

  @doc """
  Returns all provider mounts visible to an Agent.
  """
  @spec providers(module()) :: [Mount.t()]
  def providers(agent) when is_atom(agent) and not is_nil(agent) do
    definition = Definition.fetch!(agent)

    configured =
      definition.config
      |> Keyword.get(:action_providers, [])
      |> normalize_provider_list!()

    contributed =
      Enum.flat_map(definition.extensions, &Extension.action_providers/1)

    legacy =
      case normalize_legacy_actions(Keyword.get(definition.config, :actions)) do
        {module, opts} ->
          [
            Mount.new(
              :local,
              Spectre.Action.Provider.Local,
              Keyword.put(opts, :module, module)
            )
          ]

        nil ->
          []
      end

    unique_providers!(legacy ++ configured ++ contributed)
  end

  @doc """
  Resolves a provider by its stable identifier.
  """
  @spec provider(module(), Spectre.Action.provider_ref()) :: {:ok, Mount.t()} | {:error, term()}
  def provider(agent, id) do
    case Enum.find(providers(agent), &(&1.id == id)) do
      %Mount{} = mount -> {:ok, mount}
      nil -> {:error, {:unknown_action_provider, id}}
    end
  end

  @doc """
  Returns the one configured action planner, if present.

  An explicit `action_planner/2` declaration and extension-contributed planner
  are mutually exclusive. Multiple planners are rejected instead of relying on
  compile or mount order.
  """
  @spec planner(module()) :: planner_config()
  def planner(agent) when is_atom(agent) and not is_nil(agent) do
    definition = Definition.fetch!(agent)

    explicit =
      definition.config
      |> Keyword.get(:action_planner)
      |> normalize_explicit_planner!()

    contributed =
      definition.extensions
      |> Enum.map(&Extension.action_planner/1)
      |> Enum.reject(&is_nil/1)

    select_planner!(explicit ++ contributed)
  end

  @doc """
  Builds the options passed to the planner port.

  Per-handler/runtime options override extension defaults.
  """
  @spec planner_opts(Spectre.Context.t() | map(), keyword()) :: keyword()
  def planner_opts(%{agent: agent}, opts) when is_list(opts) do
    providers = providers(agent)

    case planner(agent) do
      {module, planner_opts} ->
        planner_opts
        |> Keyword.merge(opts)
        |> Keyword.put(:action_planner, module)
        |> Keyword.put(:action_providers, providers)

      nil ->
        Keyword.put(opts, :action_providers, providers)
    end
  end

  @spec normalize_legacy_actions(term()) :: action_config()
  defp normalize_legacy_actions({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp normalize_legacy_actions(module) when is_atom(module) and not is_nil(module),
    do: {module, []}

  defp normalize_legacy_actions(_other), do: nil

  @spec normalize_explicit_planner!(term()) :: [planner_config()]
  defp normalize_explicit_planner!(nil), do: []

  defp normalize_explicit_planner!(module) when is_atom(module) and not is_nil(module),
    do: [{module, []}]

  defp normalize_explicit_planner!({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts) do
    validate_planner_opts!(opts)
    [{module, opts}]
  end

  defp normalize_explicit_planner!(invalid),
    do: raise(ArgumentError, "invalid action planner: #{inspect(invalid)}")

  @spec validate_planner_opts!(list()) :: :ok
  defp validate_planner_opts!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "action planner options must be a keyword list")

    :ok
  end

  @spec select_planner!([planner_config()]) :: planner_config()
  defp select_planner!([]), do: nil
  defp select_planner!([planner]), do: planner

  defp select_planner!(planners),
    do: raise(ArgumentError, "multiple action planners configured: #{inspect(planners)}")

  @spec normalize_provider_list!(term()) :: [Mount.t()]
  defp normalize_provider_list!(providers) when is_list(providers) do
    Enum.map(providers, fn
      %Mount{} = mount -> mount
      {id, module} -> Mount.new(id, module, [])
      {id, module, opts} -> Mount.new(id, module, opts)
      invalid -> raise ArgumentError, "invalid action provider: #{inspect(invalid)}"
    end)
  end

  defp normalize_provider_list!(providers),
    do: raise(ArgumentError, "invalid action providers: #{inspect(providers)}")

  @spec unique_providers!([Mount.t()]) :: [Mount.t()]
  defp unique_providers!(providers) do
    case duplicate_provider_id(providers) do
      nil -> providers
      id -> raise ArgumentError, "duplicate action provider: #{inspect(id)}"
    end
  end

  @spec duplicate_provider_id([Mount.t()]) :: term() | nil
  defp duplicate_provider_id(providers) do
    providers
    |> Enum.reduce_while(MapSet.new(), fn %Mount{id: id}, seen ->
      if MapSet.member?(seen, id),
        do: {:halt, id},
        else: {:cont, MapSet.put(seen, id)}
    end)
    |> case do
      %MapSet{} -> nil
      id -> id
    end
  end
end
