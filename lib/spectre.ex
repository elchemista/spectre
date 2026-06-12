defmodule Spectre do
  @moduledoc """
  OTP-native conversational runtime for Elixir agents.

  `Spectre` owns the thin, boring middle of an agent: route a user turn, render
  prompts, keep conversation state, stage Action Language, and enforce policy
  gates before anything with side effects can execute.
  """

  alias Spectre.{Input, Runtime, State}

  @doc """
  Asks either an agent module or a supervised session to handle one turn.

  When the first argument is an agent module built with `use Spectre.Agent`,
  Spectre runs a stateless turn and uses the configured state adapter or the
  explicit `:state` option. When the first argument is a session pid/name,
  Spectre sends the turn to that supervised process.
  """
  @spec ask(module() | GenServer.server(), Input.t() | String.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def ask(agent_or_session, input, opts \\ [])

  def ask(agent, input, opts) when is_atom(agent) and is_list(opts) do
    if agent_module?(agent) do
      Runtime.handle(agent, Input.new(input), opts)
    else
      Spectre.Session.ask(agent, input, opts)
    end
  end

  def ask(session, input, opts) when is_list(opts) do
    Spectre.Session.ask(session, input, opts)
  end

  @doc """
  Summons a conversation-scoped session process directly.
  """
  @spec summon(keyword()) :: GenServer.on_start()
  def summon(opts) when is_list(opts) do
    Spectre.Session.start_link(opts)
  end

  @doc """
  Summons a session under a `Spectre.Supervisor`.
  """
  @spec summon(GenServer.server(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def summon(supervisor, agent, opts) when is_atom(agent) and is_list(opts) do
    Spectre.Supervisor.summon(supervisor, agent, opts)
  end

  @doc """
  Dismisses a session supervised by `Spectre.Supervisor`.
  """
  @spec dismiss(GenServer.server(), pid()) :: :ok | {:error, term()}
  def dismiss(supervisor, pid) when is_pid(pid) do
    Spectre.Supervisor.dismiss(supervisor, pid)
  end

  @doc """
  Returns the current in-memory state of a supervised session.
  """
  @spec state(GenServer.server()) :: State.t()
  def state(session), do: Spectre.Session.state(session)

  @doc """
  Replaces the current in-memory state of a supervised session.
  """
  @spec reset(GenServer.server(), State.t() | map() | keyword()) :: :ok
  def reset(session, state \\ %State{}), do: Spectre.Session.reset(session, state)

  @doc """
  Cancels the active policy/pending action and returns an updated result.
  """
  @spec cancel(Input.t() | String.t() | map(), Spectre.Context.t() | map()) ::
          {:ok, Spectre.Result.t()}
  def cancel(input, ctx) do
    state =
      ctx
      |> Map.get(:state, %State{})
      |> State.cancel_pending()

    {:ok,
     %Spectre.Result{
       input: Input.new(input),
       state: state,
       reply_text: "",
       events: [%{type: :cancelled}]
     }}
  end

  @doc """
  Executes the currently pending action, if the configured action module exposes
  a matching function.
  """
  @spec execute(State.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def execute(%State{} = state, ctx, opts \\ []) do
    Spectre.ActionExecutor.execute_pending(state, ctx, opts)
  end

  @doc """
  Compatibility alias for `ask/3`.
  """
  @spec handle(module(), Input.t() | String.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def handle(agent_or_input, input_or_agent, opts \\ [])

  def handle(agent, input, opts) when is_atom(agent) and is_list(opts) do
    ask(agent, input, opts)
  end

  @spec handle(Input.t() | String.t() | map(), module(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def handle(input, agent, opts) when is_atom(agent) and is_list(opts) do
    ask(agent, input, opts)
  end

  @doc """
  Compatibility alias for `summon/1`.
  """
  @spec start_session(keyword()) :: GenServer.on_start()
  def start_session(opts) when is_list(opts), do: summon(opts)

  @doc """
  Compatibility alias for `summon/3`.
  """
  @spec start_session(GenServer.server(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_session(supervisor, agent, opts) when is_atom(agent) and is_list(opts) do
    summon(supervisor, agent, opts)
  end

  @doc """
  Compatibility alias for `ask/3` when addressing a supervised session.
  """
  @spec call(GenServer.server(), Input.t() | String.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def call(session, input, opts \\ []), do: ask(session, input, opts)

  @doc """
  Compatibility alias for `cancel/2`.
  """
  @spec cancel_current(Input.t() | String.t() | map(), Spectre.Context.t() | map()) ::
          {:ok, Spectre.Result.t()}
  def cancel_current(input, ctx), do: cancel(input, ctx)

  @doc """
  Compatibility alias for `execute/3`.
  """
  @spec execute_pending(State.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def execute_pending(%State{} = state, ctx, opts \\ []), do: execute(state, ctx, opts)

  defp agent_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__spectre_config__, 0)
  end
end
