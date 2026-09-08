defmodule Spectre.Stack do
  @moduledoc """
  Reusable authoring configuration, not a dependency resolver or runtime.

  Use the same adapter, history, memory, classifier and extension declarations
  as in an Agent. The Agent's stack option copies those declarations. A local
  replacement requires override: true; host resources are always wired and
  supervised explicitly. Stack composition creates no GAM authority.
  """

  defmacro __using__(_opts) do
    quote do: use(Spectre.Agent.Compiler, kind: :stack)
  end
end
