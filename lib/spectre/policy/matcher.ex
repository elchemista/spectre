defmodule Spectre.Policy.Matcher do
  @moduledoc """
  Pure matcher for policy accept and reject branches.

  It reads compiled regex evidence and returns a canonical resolution without
  touching conversation state.
  """

  alias Spectre.Policy
  alias Spectre.Policy.Resolution

  @type result :: {:ok, Resolution.t()} | :no_match

  @doc """
  Matches normalized user text. Accept branches intentionally precede reject
  branches to preserve the policy DSL's established precedence.
  """
  @spec match(Policy.t(), String.t()) :: result()
  def match(%Policy{} = policy, text) when is_binary(text) do
    case match_branch(policy.accepts, text) do
      %{label: label} = branch ->
        Resolution.new(:accept, label, :user, branch_metadata(branch))

      nil ->
        case match_branch(policy.rejects, text) do
          %{label: label} = branch ->
            Resolution.new(:reject, label, :user, branch_metadata(branch))

          nil ->
            :no_match
        end
    end
  end

  @spec match_branch([map()], String.t()) :: map() | nil
  defp match_branch(branches, text) do
    Enum.find(branches, fn branch ->
      regexes = branch |> Map.get(:regex, []) |> List.wrap()
      Enum.any?(regexes, &Regex.match?(&1, text))
    end)
  end

  defp branch_metadata(branch) do
    case Map.get(branch, :metadata, %{}) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end
end
