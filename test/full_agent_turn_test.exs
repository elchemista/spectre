defmodule SpectreFullAgentTurnTest.Renderer do
  @moduledoc false

  def render(prompt, input, _ctx), do: "reply:#{prompt}:#{input.text}"
end

defmodule SpectreFullAgentTurnTest.LocalClassifier do
  @moduledoc false

  def classify(text, opts) do
    notify(opts, {:full_agent_local_classifier, text})

    case text do
      "billing classified" -> accepted("BILLING")
      "start classified project" -> accepted("START_PROJECT")
      _other -> {:error, :no_local_match}
    end
  end

  defp accepted(label) do
    {:ok,
     %{
       label: label,
       accepted?: true,
       confidence: 0.99,
       margin: 0.5,
       strategy: :local_classifier
     }}
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, message)
    :ok
  end
end

defmodule SpectreFullAgentTurnTest.ClassifierLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:full_agent_llm_classifier, prompt, opts})
    end

    if prompt =~ "portfolio" do
      {:ok, "PORTFOLIO"}
    else
      {:ok, "UNKNOWN"}
    end
  end
end

defmodule SpectreFullAgentTurnTest.ClassifierPrompt do
  @moduledoc false

  def build(assigns) do
    "classify #{assigns.text} among #{Enum.join(assigns.labels, ",")}"
  end
end

defmodule SpectreFullAgentTurnTest.FallbackToLLMArbitrator do
  @moduledoc false
  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Arbitrators.Default

  @impl Spectre.Router.Arbitrator
  def decide(arbitration, opts) do
    case Default.decide(arbitration, opts) do
      {:clarify, _message} -> {:llm, arbitration}
      decision -> decision
    end
  end
end

defmodule SpectreFullAgentTurnTest.Actions do
  @moduledoc false

  def health_check(args, ctx), do: execute(:health_check, args, ctx)
  def create_project(args, ctx), do: execute(:create_project, args, ctx)

  defp execute(action, args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:full_agent_action, action, args})
    end

    {:ok, %{action: action, args: args}}
  end
end

defmodule SpectreFullAgentTurnTest.Agent do
  @moduledoc false

  use Spectre.Agent

  classifier(SpectreFullAgentTurnTest.ClassifierLLM,
    prompt: &SpectreFullAgentTurnTest.ClassifierPrompt.build/1,
    local: SpectreFullAgentTurnTest.LocalClassifier,
    llm_opts: [max_tokens: 8]
  )

  arbitrator(SpectreFullAgentTurnTest.FallbackToLLMArbitrator)
  router(via: [:regex, :bag, :classifier, :llm_classifier])

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText, trim?: true, case: :downcase)
  end

  actions SpectreFullAgentTurnTest.Actions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    accept(:accepted_terms, regex: ~r/^yes$/i)
    reject(:rejected_terms, regex: ~r/^no$/i)
  end

  interrupt :HELP,
    regex: ~r/^help$/i,
    via: [:regex],
    cache: false do
    reply(:help, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
  end

  flow :workspace do
    on :LIST_PROJECTS,
      bag: ["show all projects"],
      via: [:bag],
      cache: false do
      reply(:projects, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
    end

    on :BILLING,
      via: [:classifier],
      cache: false do
      reply(:billing, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
    end

    on :PORTFOLIO,
      via: [:llm_classifier],
      cache: false do
      reply(:portfolio, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
    end

    on :START_PROJECT,
      via: [:classifier],
      cache: false do
      action :create_project, args: %{source: "classifier"} do
        reply(:confirm_project, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
      end
    end

    on :HEALTH,
      regex: ~r/^health$/i,
      via: [:regex],
      cache: false do
      action(:health_check, args: %{probe: "deep"})
    end

    on :SILENT,
      regex: ~r/^silent$/i,
      via: [:regex],
      cache: false do
      run(:silent)
    end
  end

  def silent(input, ctx) do
    {:ok,
     %Spectre.Result{
       input: input,
       route: ctx.route,
       state: ctx.state
     }}
  end
end

defmodule SpectreFullAgentTurnTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.State
  alias Spectre.Turn

  alias SpectreFullAgentTurnTest.Agent

  test "one agent routes normalized turns through interrupt, bag, local and LLM classifiers" do
    assert {:ok, help_turn} = turn("  HELP  ")
    assert {:reply, help_result} = help_turn.decision
    assert help_result.input.text == "help"
    assert help_result.route.label == :HELP
    assert help_result.route.flow == nil
    assert help_result.route.strategy == :regex
    assert help_result.reply_text == "reply:help:help"

    assert {:ok, bag_turn} = turn("show all projects")
    assert {:reply, bag_result} = bag_turn.decision
    assert bag_result.route.label == :LIST_PROJECTS
    assert bag_result.route.flow == :workspace
    assert bag_result.route.strategy == :bag
    assert bag_result.reply_text == "reply:projects:show all projects"

    assert {:ok, local_turn} = turn("billing classified")
    assert {:reply, local_result} = local_turn.decision
    assert local_result.route.label == :BILLING
    assert local_result.route.strategy == :local_classifier
    assert local_result.reply_text == "reply:billing:billing classified"
    assert_receive {:full_agent_local_classifier, "billing classified"}

    assert {:ok, llm_turn} = turn("show portfolio please")
    assert {:reply, llm_result} = llm_turn.decision
    assert llm_result.route.label == :PORTFOLIO
    assert llm_result.route.strategy == :llm_classifier
    assert llm_result.reply_text == "reply:portfolio:show portfolio please"
    assert_receive {:full_agent_local_classifier, "show portfolio please"}

    assert_receive {:full_agent_llm_classifier, prompt, classifier_opts}
    assert prompt =~ "show portfolio please"
    assert prompt =~ "PORTFOLIO"
    assert Keyword.fetch!(classifier_opts, :purpose) == :classifier
    assert Keyword.fetch!(classifier_opts, :max_tokens) == 8
  end

  test "one agent covers no_response, needs, awaiting and completed turn lifecycles" do
    assert {:ok, silent_turn} = turn("silent")
    assert {:no_response, silent_result} = silent_turn.decision
    assert silent_result.route.label == :SILENT
    refute Result.visible_reply?(silent_result)

    assert {:ok, health_turn} = turn("health")

    assert {:needs, %Effect{name: :health_check, status: :pending} = pending, health_result} =
             health_turn.decision

    assert Effect.executable?(pending)
    assert {:ok, health_execution} = execute(health_result)

    health_completion =
      Turn.from_result(
        Agent,
        health_result.input,
        [test_pid: self()],
        health_execution
      )

    assert {:completed, %Effect{name: :health_check, status: :completed}, ^health_execution} =
             health_completion.decision

    assert Result.action_outcome(health_execution) ==
             {:ok, %{action: :health_check, args: %{probe: "deep"}}}

    assert_receive {:full_agent_action, :health_check, %{probe: "deep"}}

    assert {:ok, awaiting_turn} = turn("start classified project")

    assert {:awaiting, %Awaitable{name: :terms, status: :open}, awaiting_result} =
             awaiting_turn.decision

    assert [%Effect{status: :waiting_policy} = waiting] = awaiting_result.state.pending_effects

    assert {:error, {:effect_not_approved, waiting_id}} = execute(awaiting_result)
    assert waiting_id == waiting.id

    assert {:ok, approved_turn} =
             turn("  YES  ", state: awaiting_result.state)

    assert {:needs, %Effect{name: :create_project, status: :approved}, approved_result} =
             approved_turn.decision

    assert approved_result.input.text == "yes"
    refute_receive {:full_agent_local_classifier, "yes"}

    assert {:ok, project_execution} = execute(approved_result)

    project_completion =
      Turn.from_result(
        Agent,
        approved_result.input,
        [test_pid: self()],
        project_execution
      )

    assert {:completed, %Effect{name: :create_project, status: :completed}, ^project_execution} =
             project_completion.decision

    assert Result.action_outcome(project_execution) ==
             {:ok, %{action: :create_project, args: %{source: "classifier"}}}

    assert_receive {:full_agent_action, :create_project, %{source: "classifier"}}
  end

  test "policy rejection becomes a completed cancellation and clears pending work" do
    assert {:ok, awaiting_turn} = turn("start classified project")
    assert {:awaiting, _awaitable, awaiting_result} = awaiting_turn.decision

    assert {:ok, rejected_turn} = turn(" NO ", state: awaiting_result.state)

    assert {:completed, %Effect{status: :cancelled} = cancelled, rejected_result} =
             rejected_turn.decision

    assert Effect.outcome(cancelled) ==
             {:cancelled, {:policy_rejected, :rejected_terms}}

    assert rejected_result.state.pending_effects == []

    assert [%Awaitable{name: :terms, status: :rejected, label: :rejected_terms}] =
             rejected_result.state.awaitables

    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "session turns retain session identity and host policy resolution updates live state" do
    child_id = {:full_agent_session, System.unique_integer([:positive])}

    session =
      start_supervised!(
        {Spectre.Session,
         agent: Agent,
         state: %State{},
         id: child_id}
      )

    assert {:ok, awaiting_turn} =
             Spectre.turn(session, "start classified project", test_pid: self())

    assert awaiting_turn.agent == session
    assert {:awaiting, %Awaitable{name: :terms}, _result} = awaiting_turn.decision

    assert {:ok, approved_turn} =
             Turn.resolve_policy(awaiting_turn, {:accept, :accepted_terms})

    assert approved_turn.agent == session
    assert {:needs, %Effect{status: :approved}, approved_result} = approved_turn.decision
    assert Spectre.state(session) == approved_result.state

    assert {:ok, executed} = execute(approved_result)
    assert :ok = Spectre.reset(session, executed.state)

    assert {:ok, help_turn} = Spectre.turn(session, "HELP", test_pid: self())
    assert help_turn.agent == session
    assert {:reply, help_result} = help_turn.decision
    assert help_result.route.label == :HELP
    assert help_result.input.text == "help"
  end

  defp turn(text, opts \\ []) do
    Spectre.turn(Agent, text, Keyword.put_new(opts, :test_pid, self()))
  end

  defp execute(%Result{} = result) do
    Spectre.execute(result.state, %{
      agent: Agent,
      input: result.input,
      state: result.state,
      opts: [test_pid: self()]
    })
  end
end
