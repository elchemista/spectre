defmodule Spectre.Agent.Declaration do
  @moduledoc false

  alias Spectre.Agent.Publication
  alias Spectre.{Definition, Portable, Router}
  alias Spectre.Router.Rule

  @type t :: %{
          templates: map(),
          components: map(),
          flows: map(),
          operations: map()
        }

  @doc "Reads portable authoring declarations without loading or interpreting executable modules."
  @spec read(Definition.t()) :: {:ok, t()} | {:error, term()}
  def read(%Definition{} = definition) do
    with {:ok, definition} <- Definition.new(definition), do: read_verified(definition)
  end

  def read(_definition), do: {:error, :not_an_agent_declaration}

  defp read_verified(%Definition{
         body: %{"format" => "spectre-agent-declaration-v3", "authoring" => authoring} = body
       })
       when map_size(body) == 2 and is_map(authoring) do
    with %{"plan" => plan, "code_ref" => code, "component_definitions" => children}
         when map_size(authoring) == 3 <- authoring,
         :ok <- Portable.validate_ref(code, :code_ref),
         true <- is_map(plan) and is_map(children),
         %{requests: requests, flows: flows, prompts: prompts, asks: asks, settings: settings} <-
           plan,
         :ok <- entries(requests, &template/1),
         :ok <- entries(flows, &flow/1),
         :ok <- entries(prompts, &prompt/1),
         true <- is_map(asks) and is_map(settings) do
      own = %{
        templates: requests,
        components: %{},
        flows: Map.new(flows, fn {name, flow} -> {name, Publication.flow_body(flow, name)} end),
        operations: operation_classes(asks, settings)
      }

      # Publication stores each child once. Diagnostics and the low-level
      # reader flatten only what they need, without evaluating loaded modules.
      Enum.reduce_while(children, {:ok, own}, &include_child/2)
    else
      {:error, _} = error -> error
      _invalid -> {:error, :not_an_agent_declaration}
    end
  end

  defp read_verified(_definition), do: {:error, :not_an_agent_declaration}

  defp include_child({name, value}, {:ok, parent}) do
    with :ok <- Rule.local_name(name),
         {:ok, child} <- Definition.from_canonical(value),
         {:ok, declaration} <- read_verified(child) do
      merged =
        Map.new(parent, fn {field, values} ->
          nested =
            Map.new(declaration[field], fn {key, data} ->
              {name <> "/" <> key, qualify(field, name, data)}
            end)

          {field, Map.merge(values, nested)}
        end)

      {:cont, {:ok, put_in(merged.components[name], child.ref)}}
    else
      error -> {:halt, error}
    end
  end

  defp qualify(:flows, name, flow) do
    flow = Map.update!(flow, "pipelines", &Enum.map(&1, fn key -> name <> "/" <> key end))

    if flow["routing"] do
      update_in(flow, ["routing", "rules"], fn rules ->
        Map.new(rules, fn {key, rule} -> {name <> "/" <> key, rule} end)
      end)
    else
      flow
    end
  end

  defp qualify(_field, _name, value), do: value

  defp operation_classes(asks, settings) do
    asks = Map.new(asks, fn {name, value} -> {"ask/" <> name, class_only(value)} end)

    classifiers =
      for {"classifier/" <> _ = name, value} <- settings, into: %{}, do: {name, class_only(value)}

    Map.merge(asks, classifiers)
  end

  defp class_only(%{class: class}), do: %{"class" => class}
  defp class_only(_value), do: %{}

  @doc "Validates bounded, unique pipeline names; the host must still wire their implementations."
  def pipeline_names(names) when is_list(names) and length(names) <= 64 do
    with :ok <- Portable.validate(names),
         true <- length(Enum.uniq(names)) == length(names) do
      Spectre.Validation.all(names, &Rule.path/1)
    else
      false -> {:error, :duplicate_flow_pipeline}
      error -> error
    end
  end

  def pipeline_names(_names), do: {:error, :invalid_flow_pipelines}

  defp flow(%{
         pipelines: pipelines,
         routes: routes,
         routing: config,
         binding: binding,
         injections: injections,
         local: local
       })
       when is_atom(local) and is_map(routes) and is_map(binding) and is_list(injections) do
    with :ok <- pipeline_names(pipelines),
         {:ok, normalized} <- Router.configuration(config || []),
         true <- is_nil(config) or normalized === config do
      entries(routes, fn
        %{rule: rule, local: local, injections: injections}
        when is_atom(local) and is_list(injections) ->
          with {:ok, value} <- Rule.new(to_string(local), rule),
               true <- value.to === Atom.to_string(local),
               true <- Rule.canonical(value) === rule,
               do: :ok,
               else: (_invalid -> {:error, :invalid_agent_route})

        _invalid ->
          {:error, :invalid_agent_route}
      end)
    else
      false -> {:error, :invalid_agent_routing}
      error -> error
    end
  end

  defp flow(_flow), do: {:error, :invalid_agent_flow}

  defp prompt(%{text: text}) when is_binary(text), do: Portable.validate(text)
  defp prompt(_value), do: {:error, :invalid_prompt_declaration}

  defp template(value) do
    with {:ok, canonical} <- Spectre.Agent.RequestBuilder.template(value) do
      if canonical === value, do: :ok, else: {:error, :noncanonical_candidate_template}
    end
  end

  defp entries(values, validate) when is_map(values) and not is_struct(values) do
    Spectre.Validation.all(values, fn {name, value} ->
      with :ok <- Rule.local_name(name), do: validate.(value)
    end)
  end

  defp entries(_values, _validate), do: {:error, :invalid_agent_entries}
end
