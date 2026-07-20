defmodule Spectre.ActionExecutor do
  @moduledoc """
  Compatibility facade for the canonical `Spectre.Execution` workflow.

  New integrations should use `Spectre.execute/3`; capability invocation lives
  in `Spectre.ActionDispatcher` and lifecycle mutation in `Spectre.Execution`.
  """

  alias Spectre.Result
  alias Spectre.State

  @type action_result :: {:ok, Result.t()} | {:error, term()}

  @doc """
  Executes the pending action through `Spectre.Execution`.
  """
  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) :: action_result()
  def execute_pending(%State{} = state, ctx, opts \\ []) do
    Spectre.Execution.execute_pending(state, ctx, opts)
  end
end
