defmodule Spectre.Skill do
  @moduledoc """
  Organizational DSL for reusable, scoped Spectre behavior.

  Skills use the same flow, policy, prompt, and handler declarations as an
  Agent. They inherit runtime infrastructure from the Agent that mounts them;
  they do not create sessions, execute tools directly, or introduce workflow
  semantics.

      defmodule MyApp.Skills.Support do
        use Spectre.Skill,
          id: :support,
          prompt_root: "priv/skills/support/prompts"

        flow :support do
          on :question, regex: ~r/support/i do
            ask :answer
          end
        end
      end
  """

  @doc """
  Initializes a Skill definition using the shared Spectre DSL compiler.
  """
  defmacro __using__(opts) when is_list(opts) do
    opts = Keyword.put(opts, :__spectre_kind__, :skill)

    quote do
      use Spectre.Agent, unquote(opts)
    end
  end
end
