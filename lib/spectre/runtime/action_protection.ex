defmodule Spectre.ActionProtection do
  @moduledoc """
  Matches pending actions against agent `protect` declarations.
  """

  alias Spectre.PendingAction

  @doc """
  Returns the policy protecting an action, if any.
  """
  @spec protected_by(module(), PendingAction.t()) :: atom() | nil
  def protected_by(agent, %PendingAction{} = action) when is_atom(agent) do
    Enum.find_value(agent.__spectre_protections__(), fn protection ->
      matching_policy(protection, action)
    end)
  end

  @spec matching_policy(map(), PendingAction.t()) :: atom() | nil
  defp matching_policy(%{action: protected, policy: policy}, %PendingAction{} = action) do
    if action_matches?(protected, action), do: policy
  end

  @spec action_matches?(atom() | String.t() | {:al, String.t()} | term(), PendingAction.t()) ::
          boolean()
  defp action_matches?(protected, %PendingAction{name: name}) when is_atom(protected),
    do: name == protected

  defp action_matches?({:al, al}, %PendingAction{al: action_al}) when is_binary(al),
    do: normalize_al(action_al) == normalize_al(al)

  defp action_matches?(protected, %PendingAction{selected_tool: selected_tool})
       when is_binary(protected),
       do: selected_tool == protected

  defp action_matches?(_protected, _action), do: false

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
