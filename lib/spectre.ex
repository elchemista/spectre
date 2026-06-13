defmodule Spectre do
  @moduledoc """
  OTP-native conversational runtime for Elixir agents.

  `Spectre` owns the thin, boring middle of an agent: route a user turn, render
  prompts, keep conversation state, stage Action Language, and enforce policy
  gates before anything with side effects can execute.

  The runtime is deliberately split into small boundaries:

    * `Spectre.Input` normalizes host input once.
    * `Spectre.Runtime` loads state and memory, then chooses policy resume or
      normal routing.
    * `Spectre.Router` collects route evidence and arbitrates a single route.
    * `Spectre.Runner` executes the route handler without directly performing
      protected side effects.
    * `Spectre.ActionExecutor` is the explicit boundary for executing a pending
      action after policy approval.

  A simple stateless call:

      {:ok, result} = Spectre.ask(MyApp.SupportAgent, "I need help")

  A stateful supervised conversation:

      {:ok, session} = Spectre.summon(agent: MyApp.SupportAgent)
      {:ok, result} = Spectre.ask(session, "create a project")
      state = Spectre.state(session)
  """

  alias Spectre.Input
  alias Spectre.Runtime
  alias Spectre.State

  @doc """
  Asks either an agent module or a supervised session to handle one turn.

  When the first argument is an agent module built with `use Spectre.Agent`,
  Spectre runs a stateless turn and uses the configured state adapter or the
  explicit `:state` option. When the first argument is a session pid/name,
  Spectre sends the turn to that supervised process.

      Spectre.ask(MyApp.Agent, %{text: "hello", meta: %{locale: "en"}})

      {:ok, session} = Spectre.summon(agent: MyApp.Agent)
      Spectre.ask(session, "continue the same conversation")
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

      {:ok, pid} = Spectre.summon(agent: MyApp.Agent, conversation_id: "abc")
  """
  @spec summon(keyword()) :: GenServer.on_start()
  def summon(opts) when is_list(opts) do
    Spectre.Session.start_link(opts)
  end

  @doc """
  Summons a session under a `Spectre.Supervisor`.

      {:ok, pid} = Spectre.summon(MyApp.SpectreSupervisor, MyApp.Agent, [])
  """
  @spec summon(GenServer.server(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def summon(supervisor, agent, opts) when is_atom(agent) and is_list(opts) do
    Spectre.Supervisor.summon(supervisor, agent, opts)
  end

  @doc """
  Dismisses a session supervised by `Spectre.Supervisor`.

      :ok = Spectre.dismiss(MyApp.SpectreSupervisor, pid)
  """
  @spec dismiss(GenServer.server(), pid()) :: :ok | {:error, term()}
  def dismiss(supervisor, pid) when is_pid(pid) do
    Spectre.Supervisor.dismiss(supervisor, pid)
  end

  @doc """
  Returns the current in-memory state of a supervised session.

      %Spectre.State{} = Spectre.state(session)
  """
  @spec state(GenServer.server()) :: State.t()
  def state(session), do: Spectre.Session.state(session)

  @doc """
  Replaces the current in-memory state of a supervised session.

      :ok = Spectre.reset(session, %Spectre.State{current_flow: :checkout})
  """
  @spec reset(GenServer.server(), State.t() | map() | keyword()) :: :ok
  def reset(session, state \\ %State{}), do: Spectre.Session.reset(session, state)

  @doc """
  Cancels the active policy/pending action and returns an updated result.

      {:ok, result} = Spectre.cancel("cancel", ctx)
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

      {:ok, result} = Spectre.execute(state, ctx)
  """
  @spec execute(State.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Spectre.Result.t()} | {:error, term()}
  def execute(%State{} = state, ctx, opts \\ []) do
    Spectre.ActionExecutor.execute_pending(state, ctx, opts)
  end

  @doc """
  Runs configured action lifecycle hooks for a result.

  The common host-app use is to call this after a successful message delivery:

      Spectre.after_action(MyAgent, :delivered, result, ctx)

  Hooks are kept outside route execution so delivery acknowledgements and audit
  events can be retried independently from the user-facing turn.
  """
  @spec after_action(module(), atom(), Spectre.Result.t(), Spectre.Context.t() | map(), keyword()) ::
          :ok | {:error, [term()]}
  def after_action(agent, event, %Spectre.Result{} = result, ctx, opts \\ []) do
    Spectre.ActionHooks.run(agent, event, result, ctx, opts)
  end

  defp agent_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__spectre_config__, 0)
  end
end
