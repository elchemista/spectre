defmodule Spectre.Router.Arbitration do
  @moduledoc """
  Input passed to a router arbitrator.

  Arbitration snapshots the router context at the decision boundary. The
  arbitrator receives the normalized input, candidate list, labels, rules, and
  original context without needing to know how each plug produced its evidence.
  """

  @doc """
  Builds an arbitration payload from a router context.

      arbitration = Spectre.Router.Arbitration.from_context(router_context)
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
