defmodule Spectre.Router.Arbitration do
  @moduledoc """
  Input passed to a router arbitrator.

  Arbitration snapshots the router context at the decision boundary. The
  arbitrator receives the normalized input, candidate list, labels, rules, and
  original context without needing to know how each plug produced its evidence.
  """

  defstruct [
    :input,
    :state,
    :rules,
    :labels,
    :candidates,
    :context
  ]

  @type t :: %__MODULE__{
          input: Spectre.Input.t(),
          state: Spectre.State.t() | nil,
          rules: [Spectre.Rule.t()],
          labels: [atom()],
          candidates: [Spectre.Router.Candidate.t()],
          context: Spectre.Router.Context.t()
        }

  @doc """
  Builds an arbitration payload from a completed evidence-collection context.

  Candidates are restored to evaluation order because router contexts prepend
  evidence as plugs run. The original context is retained so custom
  arbitrators can inspect traces and options without reconstructing them.

      arbitration = Spectre.Router.Arbitration.from_context(router_context)
  """
  @spec from_context(Spectre.Router.Context.t()) :: t()
  def from_context(%Spectre.Router.Context{} = context) do
    %__MODULE__{
      input: context.input,
      state: context.host_context && Map.get(context.host_context, :state),
      rules: context.rules,
      labels: context.labels,
      candidates: Enum.reverse(context.candidates || []),
      context: context
    }
  end
end
