defmodule Spectre.Projection.Routing do
  @moduledoc """
  Deterministic, non-executable routing view of a canonical Definition.

  The projection is rebuildable from the Definition and a versioned index
  profile. It exposes selectors and stable handler references, but strips
  compiled callback descriptors and prompt content.
  """

  @behaviour Spectre.Projection

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Router.IndexProfile

  @generator_id "spectre.projection.routing"
  @generator_version 1

  @impl true
  @spec id() :: String.t()
  def id, do: @generator_id

  @impl true
  @spec version() :: pos_integer()
  def version, do: @generator_version

  @impl true
  @spec project(Canonical.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def project(%Canonical{} = canonical, opts) when is_list(opts) do
    with {:ok, profile} <- index_profile(Keyword.get(opts, :index_profile, %{})),
         {:ok, applicability} <- component_payload(canonical, :applicability),
         {:ok, routing} <- component_payload(canonical, :routing),
         {:ok, prompts} <- component_payload(canonical, :prompt_fragments),
         {:ok, routes} <- map_entries(routing, :rules, :route),
         {:ok, fragments} <- map_entries(prompts, :fragments, :prompt_fragment) do
      definition_ref = canonical |> Canonical.ref() |> Ref.to_string()
      profile_data = IndexProfile.to_data(profile)

      {:ok,
       %{
         schema_version: 1,
         definition_ref: definition_ref,
         skill: %{
           id: canonical.id,
           declared_version: canonical.declared_version,
           origin: canonical.origin
         },
         applicability: applicability,
         routes: Enum.map(routes, &route_summary/1),
         prompt: prompt_summary(prompts, fragments),
         index_profile: profile_data,
         cache_key:
           Value.digest!(%{
             generator: {@generator_id, @generator_version},
             definition_ref: definition_ref,
             index_profile: profile_data
           })
       }}
    end
  end

  def project(%Canonical{}, opts), do: {:error, {:invalid_routing_projection_options, opts}}

  @spec component_payload(Canonical.t(), atom()) :: {:ok, map()} | {:error, term()}
  defp component_payload(canonical, type) do
    with {:ok, component} <- Canonical.fetch_component(canonical, type),
         true <- is_map(component.payload) do
      {:ok, component.payload}
    else
      false -> {:error, {:invalid_routing_projection_component, type}}
      {:error, _reason} = error -> error
    end
  end

  @spec index_profile(term()) :: {:ok, IndexProfile.t()} | {:error, term()}
  defp index_profile(%IndexProfile{} = profile), do: IndexProfile.new(profile)
  defp index_profile(profile), do: IndexProfile.new(profile)

  @spec map_entries(map(), atom(), :prompt_fragment | :route) ::
          {:ok, [map()]} | {:error, term()}
  defp map_entries(payload, key, type) do
    case get(payload, key, []) do
      entries when is_list(entries) -> validate_map_entries(entries, type)
      value -> {:error, {invalid_collection_error(type), shape(value)}}
    end
  end

  @spec validate_map_entries([term()], :prompt_fragment | :route) ::
          {:ok, [map()]} | {:error, term()}
  defp validate_map_entries(entries, type) do
    case Enum.find_index(entries, &(not is_map(&1))) do
      nil -> {:ok, entries}
      index -> {:error, {invalid_entry_error(type), index, shape(Enum.at(entries, index))}}
    end
  end

  defp invalid_collection_error(:route), do: :invalid_routing_projection_routes

  defp invalid_collection_error(:prompt_fragment),
    do: :invalid_routing_projection_prompt_fragments

  defp invalid_entry_error(:route), do: :invalid_routing_projection_route

  defp invalid_entry_error(:prompt_fragment),
    do: :invalid_routing_projection_prompt_fragment

  @spec route_summary(map()) :: map()
  defp route_summary(rule) do
    %{
      label: get(rule, :label),
      flow_path: get(rule, :flow_path, []),
      checks: get(rule, :checks, []),
      regex: get(rule, :regex, []),
      bag: get(rule, :bag, []),
      jaro: get(rule, :jaro, []),
      embedding: get(rule, :embedding, []),
      handler: handler_summary(get(rule, :handler, %{}))
    }
  end

  @spec handler_summary(term()) :: map()
  defp handler_summary(handler) when is_map(handler) do
    kind = get(handler, :kind)

    case kind do
      :operation ->
        %{
          kind: :operation,
          operation_ref: get(handler, :operation_ref),
          input: get(handler, :input)
        }

      :reply ->
        %{kind: :reply, prompt: get(handler, :prompt)}

      :action ->
        %{kind: :action, action: get(handler, :action)}

      kind when kind in [:ask, :reason, :act] ->
        %{kind: kind, prompt: get(handler, :prompt)}

      kind when kind in [:run, :work] ->
        %{kind: kind, executable_ref: :compiled_definition_only}

      other ->
        %{kind: other}
    end
  end

  defp handler_summary(_handler), do: %{kind: :unknown}

  @spec prompt_summary(map(), [map()]) :: map()
  defp prompt_summary(prompts, fragments) do
    %{
      budget: get(prompts, :budget),
      fragments:
        Enum.map(fragments, fn fragment ->
          %{
            id: get(fragment, :id),
            digest: get(fragment, :digest),
            target: get(fragment, :target),
            trust: get(fragment, :trust),
            visibility: get(fragment, :visibility),
            budget_class: get(fragment, :budget_class),
            token_cap: get(fragment, :token_cap)
          }
        end)
    }
  end

  @spec get(map(), atom(), term()) :: term()
  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
