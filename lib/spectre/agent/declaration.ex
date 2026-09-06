defmodule Spectre.Agent.Declaration do
  @moduledoc false

  alias Spectre.Candidate.Template
  alias Spectre.{Definition, Portable, Router}
  alias Spectre.Router.Rule

  @base_keys ["format", "candidates", "components"]
  @keys @base_keys ++ ["routing", "assets"]

  # Optional sections are omitted when empty. Every present section is strict:
  # portable content alone does not establish an authoring schema or authority.
  def read(%Definition{body: body}) do
    with :ok <- envelope(body),
         :ok <- entries(body["candidates"], &template/1),
         :ok <- entries(body["components"], &Portable.validate_ref(&1, :component_ref)),
         :ok <- entries(Map.get(body, "assets", %{}), &Portable.validate/1),
         {:ok, routing} <- routing(Map.fetch(body, "routing"), body["candidates"]) do
      {:ok,
       %{
         templates: body["candidates"],
         components: body["components"],
         assets: Map.get(body, "assets", %{}),
         routes: routing.rules,
         router: routing.config
       }}
    end
  end

  def read(_definition), do: {:error, :not_an_agent_declaration}

  def body(templates, components, routes, router, assets) do
    base = %{
      "format" => "spectre-agent-declaration-v1",
      "candidates" => templates,
      "components" => components
    }

    base = if assets == %{}, do: base, else: Map.put(base, "assets", assets)

    if routes == %{} and router == nil do
      base
    else
      {:ok, config} = Router.configuration(router || [])
      Map.put(base, "routing", %{"rules" => routes, "config" => config})
    end
  end

  defp envelope(
         %{
           "format" => "spectre-agent-declaration-v1",
           "candidates" => templates,
           "components" => components
         } = body
       )
       when is_map(templates) and is_map(components) do
    if Enum.all?(Map.keys(body), &(&1 in @keys)),
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
