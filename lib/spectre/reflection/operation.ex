defmodule Spectre.Reflection.Operation do
  @moduledoc """
  Compiled, policy-gated operation executor for Reflection.

  Runtime input can select only the definition Ref and snapshot time. Actor,
  purpose, stores, Activation and policy come exclusively from trusted host
  operation options under `:reflection`.
  """

  alias Spectre.Operation.Spec
  alias Spectre.Projection.Reflection, as: ReflectionProjection

  @doc "Returns the operation spec hosts may add to their closed registry."
  @spec spec() :: Spec.t()
  def spec do
    Spec.new(%{
      id: :spectre_reflection,
      kind: :function,
      executor: __MODULE__,
      input: :map,
      output: :map,
      side_effect: :none,
      description: "Inspect the active Spectre Definition through a host-owned policy",
      metadata: %{plane: :reflection, instruction_semantics: :quoted_data_only}
    })
  end

  @doc false
  def execute(input, context) when is_map(input) do
    with {:ok, config} <- trusted_config(context),
         {:ok, projection} <-
           Spectre.Reflection.reflect(
             Map.fetch!(config, :definition_store),
             get(input, :definition_ref),
             Map.fetch!(config, :activation),
             policy: Map.fetch!(config, :policy),
             actor_ref: Map.fetch!(config, :actor_ref),
             purpose: Map.fetch!(config, :purpose),
             as_of: get(input, :as_of),
             experience_store: Map.get(config, :experience_store),
             component_registry: Map.get(config, :component_registry)
           ) do
      {:ok, ReflectionProjection.to_data(projection)}
    end
  end

  def execute(_input, _context), do: {:error, :invalid_reflection_operation_input}

  defp trusted_config(%{opts: opts}) when is_list(opts) do
    case Keyword.get(opts, :reflection) do
      config when is_map(config) -> required_config(config)
      _value -> {:error, :reflection_operation_not_configured}
    end
  end

  defp trusted_config(_context), do: {:error, :reflection_operation_not_configured}

  defp required_config(config) do
    required = [:definition_store, :activation, :policy, :actor_ref, :purpose]

    if Enum.all?(required, &Map.has_key?(config, &1)) and
         is_binary(Map.get(config, :actor_ref)) and Map.get(config, :actor_ref) != "" and
         is_binary(Map.get(config, :purpose)) and Map.get(config, :purpose) != "",
       do: {:ok, config},
       else: {:error, :reflection_operation_not_configured}
  end

  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
