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

  alias Spectre.{Adapter, Portable, Router}
  alias Spectre.Agent.{Collection, Publication}
  alias Spectre.Canonical.Value
  alias Spectre.Input.Pipeline

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

  # Keep recognition of the opaque plan inside its owning module, as with
  # Pipeline.fetch/1. Consumers need not inspect its internal representation.
  @doc false
  @spec fetch(term()) :: {:ok, t()} | {:error, :invalid_agent_flow}
  def fetch(%__MODULE__{} = flow), do: {:ok, flow}
  def fetch(_value), do: {:error, :invalid_agent_flow}

  @doc false
  def from_code(module, name, opts) when is_binary(name) do
    with :ok <- Adapter.validate(module, __spectre_plan__: 0),
         {:ok, owner, declaration} <- find_flow(module, String.split(name, "/")),
         {:ok, prepared} <-
           new(Publication.code_ref(owner), name, Publication.flow_body(declaration, name), opts) do
      {:ok, prepared, declaration}
    end
  end

  def from_code(_module, _name, _opts), do: {:error, :invalid_agent_flow}

  @doc false
  def route_message(module, name, input, opts) do
    with {:ok, flow, declaration} <- from_code(module, name, opts) do
      {_normalized, result} = route_with_input(flow, input)
      {message, _branch, _selection} = message(declaration, result, input)
      {:ok, message}
    end
  end

  # One conversion for offline handler tests and live turns. This never invokes
  # callbacks, constructs authentication or records routing as GAM Evidence.
  @doc false
  def message(declaration, {:ok, selection}, _input) do
    local = Map.fetch!(declaration.routes, selection.candidate).local
    {{declaration.local, local, selection.matched || %{}}, local, selection}
  end

  def message(declaration, result, input) do
    {status, details} =
      case result do
        :no_match -> {:no_match, input}
        {:ambiguous, refs} -> {:ambiguous, refs}
        {:halt, halted} -> {:halted, halted}
        {:unrouted, normalized} -> {:unrouted, normalized}
        {:error, reason} -> {:error, reason}
      end

    {{declaration.local, status, details}, nil, nil}
  end

  defp find_flow(module, [name]) do
    case Map.fetch(module.__spectre_plan__().flows, name) do
      {:ok, declaration} -> {:ok, module, declaration}
      :error -> {:error, :unknown_agent_flow}
    end
  end

  defp find_flow(module, [component | rest]) do
    case Map.fetch(module.__spectre_plan__().components, component) do
      {:ok, child} -> find_flow(child.module, rest)
      :error -> {:error, :unknown_agent_flow}
    end
  end

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
