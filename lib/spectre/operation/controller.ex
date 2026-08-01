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
  @callback init(term(), context()) :: {:ok, term()} | {:error, term()}

  @callback next(term(), context()) ::
              {:run, Request.t()}
              | {:run, atom() | String.t(), term()}
              | {:wait, Spectre.Operation.Wait.t()}
              | {:blocked, term()}
              | {:complete, term()}
              | {:error, term()}

  @callback apply_result(term(), Request.t(), Result.t(), context()) ::
              {:ok, term()}
              | {:ok, term(), keyword() | map()}
              | {:error, term()}

  @callback complete(term(), context()) ::
              :continue
              | false
              | {:complete, term()}
              | {:blocked, term()}
              | {:error, term()}

  @callback apply_update(term(), term(), Spectre.Operation.Update.t(), context()) ::
              {:ok, term(), term()}
              | {:ok, term(), term(), keyword() | map()}
              | {:error, term()}

  @callback handle_trigger(term(), term(), context()) ::
              {:ok, term()} | {:ok, term(), keyword() | map()} | {:error, term()}

  @callback budget_exhausted(term(), map(), context()) ::
              :terminate
              | {:terminate, term()}
              | {:terminate, term(), map() | keyword()}

  @callback checkpoint_compatible?(term(), term()) :: boolean()

  @optional_callbacks apply_update: 4,
                      handle_trigger: 3,
                      budget_exhausted: 3,
                      checkpoint_compatible?: 2
end
