defmodule Spectre.Agent.Declaration do
  @moduledoc false

  alias Spectre.Candidate.Template
  alias Spectre.{Definition, Portable, Router}
  alias Spectre.Router.Rule

  @base_keys ["format", "candidates", "components"]
  @keys @base_keys ++ ["routing", "assets", "flows"]

  # Optional sections are omitted when empty. Every present section is strict:
  # portable content alone does not establish an authoring schema or authority.
  def read(%Definition{body: body}) do
    with :ok <- envelope(body),
         :ok <- entries(body["candidates"], &template/1),
         :ok <- entries(body["components"], &Portable.validate_ref(&1, :component_ref)),
         :ok <- entries(Map.get(body, "assets", %{}), &Portable.validate/1),
         {:ok, routing} <- routing(Map.fetch(body, "routing"), body["candidates"]),
         :ok <- entries(Map.get(body, "flows", %{}), &flow(&1, body["candidates"])) do
      {:ok,
       %{
         templates: body["candidates"],
         components: body["components"],
         assets: Map.get(body, "assets", %{}),
         routes: routing.rules,
         router: routing.config,
         flows: Map.get(body, "flows", %{})
       }}
    end
  end

  def read(_definition), do: {:error, :not_an_agent_declaration}

  def body(templates, components, routes, router, assets, flows \\ %{}) do
    base = %{
      "format" => "spectre-agent-declaration-v1",
      "candidates" => templates,
      "components" => components
    }

    base = if assets == %{}, do: base, else: Map.put(base, "assets", assets)

    base =
      if flows == %{},
        do: base,
        else:
          base
          |> Map.put("format", "spectre-agent-declaration-v2")
          |> Map.put("flows", Map.new(flows, fn {name, flow} -> {name, flow_body(flow)} end))

    if routes == %{} and router == nil do
      base
    else
      {:ok, config} = Router.configuration(router || [])
      Map.put(base, "routing", %{"rules" => routes, "config" => config})
    end
  end

  defp envelope(
         %{
           "format" => format,
           "candidates" => templates,
           "components" => components
         } = body
       )
       when is_map(templates) and is_map(components) and
              format in ["spectre-agent-declaration-v1", "spectre-agent-declaration-v2"] do
    if Enum.all?(Map.keys(body), &(&1 in @keys)) and
         (format == "spectre-agent-declaration-v2" or not Map.has_key?(body, "flows")),
       do: :ok,
       else: {:error, :not_an_agent_declaration}
  end

  defp envelope(_body), do: {:error, :not_an_agent_declaration}

  defp routing(:error, _templates) do
    {:ok, config} = Router.configuration([])
    {:ok, %{rules: %{}, config: config}}
  end

  defp routing({:ok, %{"rules" => rules, "config" => config} = data}, templates)
       when map_size(data) == 2 do
    with {:ok, normalized} <- Router.configuration(config),
         true <- normalized === config,
         {:ok, parsed} <- Router.rules(rules),
         true <-
           Enum.all?(parsed, fn {name, rule} ->
             Rule.canonical(rule) === rules[name] and Map.has_key?(templates, rule.to)
           end) do
      {:ok, %{rules: rules, config: config}}
    else
      false -> {:error, :invalid_agent_routing}
      {:error, _} = error -> error
    end
  end

  defp routing(_data, _templates), do: {:error, :invalid_agent_routing}

  def pipeline_names(names) when is_list(names) and length(names) <= 64 do
    with :ok <- Portable.validate(names),
         true <- length(Enum.uniq(names)) == length(names) do
      validate_names(names)
    else
      false -> {:error, :duplicate_flow_pipeline}
      {:error, _} = error -> error
    end
  end

  def pipeline_names(_names), do: {:error, :invalid_flow_pipelines}

  defp validate_names(names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case Rule.path(name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def mount_flow(flow, prefix) do
    raw = %{
      pipelines: Enum.map(flow["pipelines"], &(prefix <> "/" <> &1)),
      routes: %{},
      router: nil
    }

    case Map.fetch(flow, "routing") do
      :error ->
        raw

      {:ok, routing} ->
        %{
          raw
          | router: routing["config"],
            routes:
              Map.new(routing["rules"], fn {name, rule} ->
                {name, Map.update!(rule, "to", &(prefix <> "/" <> &1))}
              end)
        }
    end
  end

  defp flow_body(%{routes: routes, router: router, pipelines: pipelines}) do
    base = %{"pipelines" => pipelines || []}

    if routes == %{} and router == nil do
      base
    else
      {:ok, config} = Router.configuration(router || [])
      Map.put(base, "routing", %{"rules" => routes, "config" => config})
    end
  end

  defp flow(%{"pipelines" => pipelines} = flow, templates) when map_size(flow) in [1, 2] do
    with true <- Enum.all?(Map.keys(flow), &(&1 in ["pipelines", "routing"])),
         :ok <- pipeline_names(pipelines),
         {:ok, _} <- routing(Map.fetch(flow, "routing"), templates) do
      :ok
    else
      false -> {:error, :invalid_agent_flow}
      {:error, _} = error -> error
    end
  end

  defp flow(_flow, _templates), do: {:error, :invalid_agent_flow}

  defp entries(values, validate) when is_map(values) and not is_struct(values) do
    Enum.reduce_while(values, :ok, fn {name, value}, :ok ->
      with :ok <- Rule.path(name), :ok <- validate.(value) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp entries(_values, _validate), do: {:error, :invalid_agent_entries}

  defp template(value) do
    with {:ok, canonical} <- Template.new(value) do
      if canonical === value, do: :ok, else: {:error, :noncanonical_candidate_template}
    end
  end
end
