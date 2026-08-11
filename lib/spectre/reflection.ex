defmodule Spectre.Reflection do
  @moduledoc """
  Policy-gated host boundary for inspecting the active canonical Definition.

  The result is always a mechanical `Spectre.Projection.Reflection`; no model
  is called and no inspected prompt or Skill instruction is executed.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Instance.Activation
  alias Spectre.Projection.Reflection, as: ReflectionProjection
  alias Spectre.Reflection.Policy

  @doc "Creates the exact Reflection projection allowed by a host policy."
  @spec reflect(Store.config(), Ref.t() | String.t(), Activation.t(), keyword()) ::
          {:ok, Spectre.Projection.t()} | {:error, term()}
  def reflect(store, definition_ref, activation, opts \\ [])

  def reflect(store, definition_ref, %Activation{} = activation, opts)
      when is_list(opts) do
    with :ok <- options(opts),
         {:ok, policy} <- policy(Keyword.get(opts, :policy)),
         :ok <-
           Policy.authorize(
             policy,
             Keyword.get(opts, :actor_ref),
             Keyword.get(opts, :purpose)
           ),
         {:ok, as_of} <- as_of(Keyword.get(opts, :as_of)),
         {:ok, artifact} <- fetch(store, definition_ref, opts),
         resolved_ref = Canonical.ref(artifact.definition),
         :ok <- active_definition(resolved_ref, activation),
         {:ok, snapshot} <- snapshot(resolved_ref, policy, as_of, opts) do
      ReflectionProjection.generate(
        artifact.definition,
        artifact.manifest,
        activation,
        snapshot,
        reflection_options(opts)
      )
    end
  end

  def reflect(_store, _definition_ref, activation, opts),
    do: {:error, {:invalid_reflection_request, shape(activation), shape(opts)}}

  defp policy(%Policy{} = policy), do: Policy.new(policy)
  defp policy(nil), do: {:error, :reflection_policy_required}
  defp policy(value), do: Policy.new(value)

  defp as_of(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp as_of(nil), do: {:error, :reflection_as_of_required}
  defp as_of(value), do: {:error, {:invalid_reflection_as_of, value}}

  defp fetch(store, definition_ref, opts) do
    store_opts =
      case Keyword.get(opts, :component_registry) do
        nil -> []
        registry -> [component_registry: registry]
      end

    case Store.fetch(store, definition_ref, store_opts) do
      {:ok, artifact} -> {:ok, artifact}
      :not_found -> {:error, :reflection_definition_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp active_definition(definition_ref, activation) do
    if definition_ref == activation.definition_ref,
      do: :ok,
      else: {:error, :reflection_definition_not_active}
  end

  defp snapshot(definition_ref, policy, as_of, opts) do
    case Keyword.get(opts, :experience_store) do
      nil ->
        ExperienceStore.empty_snapshot(definition_ref, as_of)

      store ->
        ExperienceStore.snapshot(store, definition_ref,
          as_of: as_of,
          limit: policy.max_evidence
        )
    end
  end

  defp reflection_options(opts) do
    case Keyword.get(opts, :component_registry) do
      nil -> []
      registry -> [component_registry: registry]
    end
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_reflection_options}
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
