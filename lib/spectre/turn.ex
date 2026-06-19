defmodule Spectre.Turn do
  @moduledoc """
  High-level host-facing turn result.

  A turn wraps the raw `%Spectre.Result{}` and a lifecycle decision that tells
  the host what to do next without encoding capability-specific branches in the
  decision vocabulary.
  """

  alias Spectre.Turn.Decision

  defstruct [
    :agent,
    :input,
    opts: [],
    result: nil,
    decision: nil,
    metadata: %{}
  ]

  @type decision ::
          {:awaiting, Spectre.Awaitable.t(), Spectre.Result.t()}
          | {:needs, Spectre.Effect.t(), Spectre.Result.t()}
          | {:completed, Spectre.Effect.t() | Spectre.Awaitable.t(), Spectre.Result.t()}
          | {:reply, Spectre.Result.t()}
          | {:no_response, Spectre.Result.t()}

  @type t :: %__MODULE__{
          agent: module() | GenServer.server(),
          input: Spectre.Input.t() | String.t() | map(),
          opts: keyword(),
          result: Spectre.Result.t(),
          decision: decision(),
          metadata: map()
        }

  @doc """
  Runs `Spectre.ask/3` and reduces the result into a turn decision.
  """
  @spec run(module(), Spectre.Input.t() | String.t() | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def run(agent, input, opts \\ []) when is_atom(agent) and is_list(opts) do
    with {:ok, result} <- Spectre.ask(agent, input, opts) do
      {:ok, from_result(agent, input, opts, result)}
    end
  end

  @doc """
  Builds a turn from an already available result.
  """
  @spec from_result(module() | GenServer.server(), term(), keyword(), Spectre.Result.t()) :: t()
  def from_result(agent, input, opts, %Spectre.Result{} = result) do
    %__MODULE__{
      agent: agent,
      input: input,
      opts: opts,
      result: result,
      decision: Decision.decide(result)
    }
  end
end
