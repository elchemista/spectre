defmodule Spectre.Turn do
  @moduledoc """
  High-level host-facing turn result.

  A turn wraps the raw `%Spectre.Result{}` and a lifecycle decision that tells
  the host what to do next without encoding capability-specific branches in the
  decision vocabulary. This is Spectre's canonical local host result whether
  the input was routed normally or claimed by a pre-route
  `Spectre.Turn.Handler`.

  Transport protocols should map their envelope into `Spectre.turn/3` and map
  this result back out. Addressing, correlation, remote task state, retries,
  and delivery guarantees remain transport concerns.
  """

  alias Spectre.Result
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
  Resolves this turn's active policy from a trusted host decision and returns
  the next lifecycle decision.

  This keeps application adapters from synthesizing user text or manually
  rebuilding approved effects.
  """
  @spec resolve_policy(t(), Spectre.Policy.resolution(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def resolve_policy(%__MODULE__{} = turn, resolution, opts \\ []) do
    opts = Keyword.merge(turn.opts, opts)

    with {:ok, %Result{} = result} <-
           Spectre.resolve_policy(turn.agent, turn.result, resolution, opts) do
      {:ok, from_result(turn.agent, turn.input, opts, result)}
    end
  end

  @doc """
  Builds a turn from an already available result.
  """
  @spec from_result(module() | GenServer.server(), term(), keyword(), Spectre.Result.t()) :: t()
  def from_result(agent, input, opts, %Result{} = result) do
    decision = Decision.decide(result)

    %__MODULE__{
      agent: agent,
      input: input,
      opts: opts,
      result: result,
      decision: decision,
      metadata: %{lifecycle: Result.lifecycle(result)}
    }
  end
end
