defmodule Spectre.Skill do
  @moduledoc """
  Reusable flow/handler authoring with one local state namespace per mount.

  Uses the Agent grammar and callback contract. Mount with
  skill MyApp.CustomerSkill, as: :customer. A Skill receives local flow/route
  names, its own state and its own results. The parent exposes namespaced flows
  and ports without creating another process, Scope, Mandate or budget.
  """
  defmacro __using__(opts) do
    quote do: use(Spectre.Agent, Keyword.put(unquote(opts), :kind, :skill))
  end
end
