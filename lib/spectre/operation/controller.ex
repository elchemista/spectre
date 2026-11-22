defmodule Spectre.Operation.Controller do
  @moduledoc """
  Behaviour shared by Work, Vigil and library-owned operational controllers.

  Controller callbacks are deterministic reducers. They run briefly inside
  the Agent owner; external work must be represented by a registered
  `Spectre.Operation.Request` and is executed by a temporary Runner.

  A `kind: :directive` Definition with `can_start: [:work]` may return
  `start_loops: [{:work, controller, input, opts}]` from a successful
  `apply_result/4`. Each intent requires a stable `:intent_id`; the Agent
  validates and commits the parent Result and every new Work atomically.
  Work and Vigil controllers cannot acquire this capability.
  """

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result

  @type context :: map()

  @callback __spectre_loop_definition__() :: Definition.t()

  @doc "Initializes the loop's portable reducer state from its validated input and context."
  @callback init(term(), context()) :: {:ok, term()} | {:error, term()}

  @doc "Chooses the next registered operation, wait, blocker, completion, or failure."
  @callback next(term(), context()) ::
              {:run, Request.t()}
              | {:run, atom() | String.t(), term()}
              | {:wait, Spectre.Operation.Wait.t()}
              | {:blocked, term()}
              | {:complete, term()}
              | {:error, term()}

  @doc "Reduces a successful attempt into new state and optional transition data."
  @callback apply_result(term(), Request.t(), Result.t(), context()) ::
              {:ok, term()}
              | {:ok, term(), keyword() | map()}
              | {:error, term()}

  @doc "Evaluates completion after a successful reduction. Return `:continue` or `false` to proceed."
  @callback complete(term(), context()) ::
              :continue
              | false
              | {:complete, term()}
              | {:blocked, term()}
              | {:error, term()}

  @doc "Applies an update to the current reducer state and effective input. Return both updated values."
  @callback apply_update(term(), term(), Spectre.Operation.Update.t(), context()) ::
              {:ok, term(), term()}
              | {:ok, term(), term(), keyword() | map()}
              | {:error, term()}

  @doc "Reduces a trigger that wakes the loop into new state and optional transition data."
  @callback handle_trigger(term(), term(), context()) ::
              {:ok, term()} | {:ok, term(), keyword() | map()} | {:error, term()}

  @doc "Customizes the terminal reason and metadata when `on_budget_exhausted: :controller` is configured."
  @callback budget_exhausted(term(), map(), context()) ::
              :terminate
              | {:terminate, term()}
              | {:terminate, term(), map() | keyword()}

  @doc "Checks whether a stored checkpoint contract is compatible with the current contract."
  @callback checkpoint_compatible?(term(), term()) :: boolean()

  @optional_callbacks apply_update: 4,
                      handle_trigger: 3,
                      budget_exhausted: 3,
                      checkpoint_compatible?: 2
end
