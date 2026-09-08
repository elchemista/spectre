defmodule Spectre.Agent.Flow do
  @moduledoc """
  Reusable, process-free routing plan for one exact declared flow.

  Prepare through `Spectre.Agent.flow/3` using an explicitly published Definition.
  `:pipelines` is a host map of names to prepared `Spectre.Input.Pipeline`
  objects; `:adapters` is the existing Router registry. Definitions contain
  only pipeline names and routing data, never executable pipeline modules.

  Each flow chooses its own ordered pipelines and router. Nested names and
  Skill installation do not inherit a parent's router or pipeline policy.
  Plans can be reused across turns; they retain no Turn, Evidence or state.

  `route/2` preserves matches, misses, ambiguity, errors and pipeline halts.
  A flow with no routing declaration returns `{:unrouted, input}`. An ordinary
  Mind handler decides what each case means. This module neither calls that
  handler nor builds a prompt, records Evidence or submits any Candidate.
  Transformations are local: govern remote inference through an Act.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Agent.Collection
  alias Spectre.Input.Pipeline
  alias Spectre.{Portable, Router}

  @enforce_keys [:definition_ref, :name, :pipelines, :router]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            definition_ref: String.t(),
            name: String.t(),
            pipelines: [Pipeline.t()],
            router: Router.t() | nil
          }
  @type result ::
          {:ok, Spectre.Router.Selection.t()}
          | :no_match
          | {:ambiguous, [String.t()]}
          | {:halt, term()}
          | {:unrouted, term()}
          | {:error, term()}

  @doc false
  def new(definition_ref, name, data, opts) do
    with {:ok, opts} <- Portable.normalize_attrs(opts, [:pipelines, :adapters], :agent_flow),
         {:ok, pipelines} <- pipelines(data["pipelines"], Map.get(opts, :pipelines, %{})),
         {:ok, router} <- router(Map.get(data, "routing"), Map.get(opts, :adapters, [])) do
      {:ok,
       %__MODULE__{
         definition_ref: definition_ref,
         name: name,
         pipelines: pipelines,
         router: router
       }}
    end
  end

  @doc "Normalizes and routes explicit input without making an application decision."
  @spec route(t(), term()) :: result()
  def route(%__MODULE__{} = flow, input) do
    {_normalized, result} = route_with_input(flow, input)
    result
  end

  def route(_flow, _input), do: {:error, :invalid_agent_flow}

  @doc false
  @spec route_with_input(t(), term()) :: {term(), result()}
  def route_with_input(%__MODULE__{} = flow, input) do
    with :ok <- Value.validate(input, max_bytes: 65_536),
         {:ok, input} <- normalize(flow.pipelines, input) do
      {input, if(flow.router, do: Router.route(flow.router, input), else: {:unrouted, input})}
    else
      stopped -> {input, stopped}
    end
  end

  defp pipelines(names, registry) when is_map(registry) and not is_struct(registry) do
    Collection.map(names, fn name ->
      with {:ok, value} <- Map.fetch(registry, name),
           {:ok, pipeline} <- Pipeline.fetch(value) do
        {:ok, pipeline}
      else
        {:error, :invalid_input_pipeline} ->
          {:error, {:invalid_flow_pipeline, name}}

        :error ->
          {:error, {:unwired_flow_pipeline, name}}
      end
    end)
  end

  defp pipelines(_names, _registry), do: {:error, :invalid_flow_pipeline_registry}

  defp router(nil, _adapters), do: {:ok, nil}

  defp router(data, adapters),
    do: Router.new(data["rules"], Map.put(data["config"], "adapters", adapters))

  defp normalize(pipelines, input) do
    Enum.reduce_while(pipelines, {:ok, input}, fn pipeline, {:ok, current} ->
      case Pipeline.run(pipeline, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        stopped -> {:halt, stopped}
      end
    end)
  end
end
