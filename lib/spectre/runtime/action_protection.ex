defmodule Spectre.ActionProtection do
  @moduledoc """
  Matches action effects against agent `protect` declarations.

  Protection is action-centric. A dangerous action must be protected whether it
  came from a deterministic DSL `action/2` handler or from Action Language
  extracted from an LLM reply.
  """

  alias Spectre.Effect

  @doc """
  Returns the policy protecting an action, if any.

      :confirm_delete = Spectre.ActionProtection.protected_by(agent, effect)
  """
  @spec protected_by(module(), Effect.t()) :: term()
  def protected_by(agent, %Effect{} = effect) when is_atom(agent) do
    agent
    |> Spectre.Definition.protections()
    |> Enum.find_value(fn protection ->
      matching_policy(protection, effect)
    end)
  end

  @spec matching_policy(map(), Effect.t()) :: term()
  defp matching_policy(%{action: protected, policy: policy}, %Effect{} = effect) do
    if action_matches?(protected, effect), do: policy
  end

  @spec action_matches?(atom() | String.t() | {:al, String.t()} | term(), Effect.t()) ::
          boolean()
  defp action_matches?(protected, %Effect{name: name} = effect) when is_atom(protected) do
    name == protected or selected_tool_function(effect) == Atom.to_string(protected)
  end

  defp action_matches?({:al, al}, %Effect{} = effect) when is_binary(al),
    do: normalize_al(Effect.al(effect)) == normalize_al(al)

  defp action_matches?(protected, %Effect{} = effect)
       when is_binary(protected),
       do: Effect.selected_tool(effect) == protected

  defp action_matches?(_protected, _action), do: false

  @spec selected_tool_function(Effect.t()) :: String.t() | nil
  defp selected_tool_function(%Effect{} = effect) do
    case Effect.selected_tool(effect) do
      tool when is_binary(tool) ->
        tool
        |> String.split(".")
        |> List.last()
        |> case do
          nil -> nil
          function_arity -> function_arity |> String.split("/", parts: 2) |> List.first()
        end

      _other ->
        nil
    end
  end

  @spec normalize_al(String.t() | nil) :: String.t() | nil
  defp normalize_al(nil), do: nil

  defp normalize_al(al) do
    al
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
