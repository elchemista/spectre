defmodule Spectre.Agent.Prompt do
  @moduledoc false

  alias Spectre.{Adapter, Portable}
  alias Spectre.Agent.{Collection, Context}

  @doc "Renders only the selected ask, retaining ordered system/task parts and template identities."
  def render(owner, turn, name, assigns) when is_map(assigns) do
    with {:ok, ask} <- Map.fetch(owner.plan.asks, to_string(name)),
         {:ok, base} <- Map.fetch(ask, :prompt),
         :ok <- reserved_assigns(assigns),
         assigns = Map.merge(assigns, Map.take(turn.context, [:history, :memory])),
         injections = injections(owner.plan, turn, base),
         {before, after_parts} = Enum.split_with(injections, &(&1.position == :start)),
         names = Enum.map(before, & &1.prompt) ++ [base] ++ Enum.map(after_parts, & &1.prompt),
         {:ok, system} <- parts(owner, names, :system, assigns),
         {:ok, task} <- parts(owner, List.wrap(ask[:task]), :task, assigns),
         parts = system ++ task ++ Context.prompt_parts(turn.context),
         :ok <- budget(parts) do
      {:ok,
       %{
         "parts" => parts,
         "definition_ref" => turn.definition_ref,
         "turn_ref" => turn.ref,
         "configuration" => Map.drop(ask, [:prompt, :task, :class])
       }}
    else
      :error -> {:error, {:invalid_ask_declaration, name}}
      error -> error
    end
  end

  def render(_owner, _turn, _name, _assigns), do: {:error, :invalid_prompt_assigns}

  defp reserved_assigns(assigns) do
    if Map.has_key?(assigns, :history) or Map.has_key?(assigns, :memory),
      do: {:error, :reserved_context_assigns},
      else: :ok
  end

  defp injections(plan, turn, base) do
    flow = Map.get(plan.flows, to_string(turn.flow))
    flow_injections = if flow, do: flow.injections, else: []
    branch = if flow, do: Map.get(flow.routes, to_string(turn.branch)), else: nil
    route_injections = if branch, do: branch.injections, else: []

    (plan.injections ++ flow_injections ++ route_injections)
    |> Enum.filter(&(is_nil(&1.into) or &1.into === base))
  end

  defp parts(owner, names, role, assigns) do
    Collection.map(names, fn name ->
      with {:ok, template} <- Map.fetch(owner.plan.prompts, to_string(name)),
           {:ok, text} <- render_template(owner.module, name, assigns) do
        {:ok,
         %{
           "role" => role,
           "name" => to_string(name),
           "text" => text,
           "template_ref" => Portable.content_ref!(:prompt_template, template.text)
         }}
      else
        :error -> {:error, {:unknown_prompt, name}}
        {:error, _} = error -> error
      end
    end)
  end

  @doc false
  def render_template(module, name, assigns)
      when (is_atom(name) or is_binary(name)) and is_map(assigns) and not is_struct(assigns) do
    with :ok <- Adapter.validate(module, __spectre_render__: 2),
         {:ok, reply} <- Adapter.invoke(module, :__spectre_render__, [to_string(name), assigns]) do
      rendered(reply, name)
    end
  end

  def render_template(_module, _name, _assigns), do: {:error, :invalid_prompt_assigns}

  defp rendered({:error, _} = error, _name), do: error

  defp rendered(text, name) when is_binary(text) and byte_size(text) <= 65_536 do
    if String.valid?(text), do: {:ok, text}, else: {:error, {:invalid_rendered_prompt, name}}
  end

  defp rendered(_reply, name), do: {:error, {:invalid_rendered_prompt, name}}

  defp budget(parts) do
    if length(parts) <= 64 and Enum.reduce(parts, 0, &(byte_size(&1["text"]) + &2)) <= 65_536,
      do: :ok,
      else: {:error, :prompt_budget_exceeded}
  end
end
