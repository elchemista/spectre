defmodule Spectre.Test.Authoring do
  @moduledoc false

  # Deterministic publication metadata belongs to fixtures, not production DSL
  # defaults. These helpers use real 0.4 publication and materialization; they
  # do not activate a Definition, mint authority or fake a governed result.
  defmacro __using__(_opts) do
    quote do
      def definition, do: Spectre.Test.Authoring.publish(__MODULE__)

      def candidate(name, turn, attrs),
        do: Spectre.Agent.candidate(definition(), name, turn, attrs)
    end
  end

  def publish(module) do
    children =
      Map.new(module.__spectre_plan__().components, fn {name, child} ->
        {name, publish(child.module)}
      end)

    module.definition(revision: 1, declared_at: 0, components: children)
  end

  def requests(definition) do
    {:ok, templates, _components} = Spectre.Agent.declarations(definition)
    templates
  end

  # A data-authored successor is deliberately not an upgrade of loaded code.
  # Low-level Mind/GAM lifecycle fixtures use it to test governed revision; the
  # handler Instance's exact code pin is exercised separately.
  def replace_requests(definition, requests) do
    definition.body
    |> put_in(["authoring", "plan", :requests], requests)
    |> put_in(["authoring", "component_definitions"], %{})
  end
end
