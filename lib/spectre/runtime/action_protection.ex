defmodule Spectre.ActionProtection do
  @moduledoc """
  Matches action effects against agent `protect` declarations.

  Protection is action-centric. A dangerous action must be protected whether it
  came from a deterministic DSL `action/2` handler or from an optional planner
  inspecting an LLM reply.
  """

  alias Spectre.Action
  alias Spectre.Effect

  @doc """
  Returns the policy protecting an action, if any.

      :confirm_delete = Spectre.ActionProtection.protected_by(agent, effect)
  """
  @spec protected_by(module(), Effect.t()) :: term()
  def protected_by(agent, %Effect{} = effect) when is_atom(agent) do
    protected_by(agent, effect, Effect.scope(effect))
  end

  @doc """
  Returns the matching policy in the active route scope.

  Agent protections are global. Skill protections apply only to effects staged
  by that mounted Skill, preventing two Skills bound to the same concrete
  action from stealing each other's policy.
  """
  @spec protected_by(module(), Effect.t(), Spectre.Definition.scope() | nil) :: term()
  def protected_by(agent, %Effect{} = effect, scope) when is_atom(agent) do
    case protection_for(agent, effect, scope) do
      %{policy: policy} -> policy
      nil -> nil
    end
  end

  @doc false
  @spec protection_for(module(), Effect.t()) :: map() | nil
  def protection_for(agent, %Effect{} = effect) when is_atom(agent) do
    protection_for(agent, effect, Effect.scope(effect))
  end

  @doc false
  @spec protection_for(module(), Effect.t(), Spectre.Definition.scope() | nil) :: map() | nil
  def protection_for(agent, %Effect{} = effect, scope) when is_atom(agent) do
    agent
    |> Spectre.Definition.protections()
    |> Enum.find_value(fn protection ->
      if protection_scope_matches?(protection, scope) do
        matching_protection(protection, effect)
      end
    end)
  end

  @spec protection_scope_matches?(map(), Spectre.Definition.scope() | nil) :: boolean()
  defp protection_scope_matches?(%{scope: :agent}, _scope), do: true
  defp protection_scope_matches?(%{scope: nil}, _scope), do: true
  defp protection_scope_matches?(%{scope: scope}, scope), do: true
  defp protection_scope_matches?(_protection, _scope), do: false

  @spec matching_protection(map(), Effect.t()) :: map() | nil
  defp matching_protection(%{action: protected} = protection, %Effect{} = effect) do
    if action_matches?(protected, effect), do: protection
  end

  @spec action_matches?(term(), Effect.t()) :: boolean()
  defp action_matches?({:al, al}, %Effect{} = effect) when is_binary(al),
    do: normalize_al(Effect.al(effect)) == normalize_al(al)

  defp action_matches?(protected, %Effect{} = effect)
       when is_binary(protected) do
    Action.matches_ref?(protected, effect) or Effect.selected_tool(effect) == protected
  end

  defp action_matches?(protected, %Effect{} = effect),
    do: Action.matches_ref?(protected, effect)

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
