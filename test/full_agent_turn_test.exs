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

    cond do
      prompt =~ "classify track classified delivery" -> {:ok, "TRACK_DELIVERY"}
      prompt =~ "classify show portfolio please" -> {:ok, "PORTFOLIO"}
      true -> {:ok, "UNKNOWN"}
    end
  end
end

defmodule SpectreFullAgentTurnTest.ClassifierPrompt do
  @moduledoc false

  def build(assigns) do
    """
    classify #{assigns.text} among:
    #{assigns.label_tree}
    agent context: #{assigns.agent_context || "none"}
    active flow: #{assigns.active_flow || "none"}
    """
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
    llm_opts: [max_tokens: 8],
    context: "Project workspace agent with delivery tracking.",
    label_examples: 1
  )

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
    attempts(2, then: :cancel_pending)
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

    flow :delivery do
      on :TRACK_DELIVERY,
        embedding: ["where is my delivery?", "track my package"],
        via: [:llm_classifier],
        cache: false do
        reply(:delivery_status, renderer: {SpectreFullAgentTurnTest.Renderer, :render})
      end
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

  test "normalizes input and handles a global regex interrupt" do
    assert {:ok, help_turn} = turn("  HELP  ")
    assert {:reply, help_result} = help_turn.decision
    assert help_result.input.text == "help"
    assert help_result.route.label == :HELP
    assert help_result.route.flow == nil
    assert help_result.route.strategy == :regex
    assert help_result.reply_text == "reply:help:help"
    refute_received {:full_agent_local_classifier, _text}
    refute_received {:full_agent_llm_classifier, _prompt, _opts}
  end

  test "routes a bag classifier turn without falling through to the LLM" do
    assert {:ok, bag_turn} = turn("show all projects")
    assert {:reply, bag_result} = bag_turn.decision
    assert bag_result.route.label == :LIST_PROJECTS
    assert bag_result.route.flow == :workspace
    assert bag_result.route.strategy == :bag
    assert bag_result.reply_text == "reply:projects:show all projects"
    assert_receive {:full_agent_local_classifier, "show all projects"}
    refute_received {:full_agent_llm_classifier, _prompt, _opts}
  end

  test "routes an accepted local classifier turn" do
    assert {:ok, local_turn} = turn("billing classified")
    assert {:reply, local_result} = local_turn.decision
    assert local_result.route.label == :BILLING
    assert local_result.route.strategy == :local_classifier
    assert local_result.reply_text == "reply:billing:billing classified"
    assert_receive {:full_agent_local_classifier, "billing classified"}
    refute_received {:full_agent_llm_classifier, _prompt, _opts}
  end

  test "falls back to the dedicated LLM classifier when deterministic evidence is missing" do
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

  test "routes a nested flow through the full agent and exposes its classifier context" do
    state = %State{current_flow: :delivery}

    assert {:ok, nested_turn} = turn("track classified delivery", state: state)
    assert {:reply, nested_result} = nested_turn.decision
    assert nested_result.route.label == :TRACK_DELIVERY
    assert nested_result.route.flow == :delivery
    assert nested_result.route.rule.flow_path == [:workspace, :delivery]
    assert nested_result.route.strategy == :llm_classifier

    assert nested_result.reply_text ==
             "reply:delivery_status:track classified delivery"

    assert_receive {:full_agent_local_classifier, "track classified delivery"}
    assert_receive {:full_agent_llm_classifier, prompt, classifier_opts}
    assert prompt =~ "workspace/"
    assert prompt =~ "  delivery/\n    TRACK_DELIVERY — e.g. \"where is my delivery?\""
    refute prompt =~ "track my package"
    assert prompt =~ "agent context: Project workspace agent with delivery tracking."
    assert prompt =~ "active flow: workspace/delivery"
    refute Keyword.has_key?(classifier_opts, :context)
    refute Keyword.has_key?(classifier_opts, :label_examples)
  end

  test "returns no_response for a routed handler with no visible output or effect" do
    assert {:ok, silent_turn} = turn("silent")
    assert {:no_response, silent_result} = silent_turn.decision
    assert silent_result.route.label == :SILENT
    refute Result.visible_reply?(silent_result)
    assert Result.pending_effect(silent_result) == nil
    assert Result.latest_completion(silent_result) == nil
  end

  test "moves an unprotected action from needs to completed" do
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
  end

  test "blocks a protected action then advances awaiting through approval to completed" do
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

    assert rejected_result.input.text == "no"
    assert rejected_result.state.pending_effects == []

    assert [%Awaitable{name: :terms, status: :rejected, label: :rejected_terms}] =
             rejected_result.state.awaitables

    refute_receive {:full_agent_local_classifier, "no"}
    refute_receive {:full_agent_action, :create_project, _args}

    assert {:ok, missing} = execute(rejected_result)
    assert missing.effects == []
    assert missing.events == [%{type: :effect_missing}]
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "unmatched policy reply stays awaiting and bypasses normal classifiers" do
    assert {:ok, awaiting_turn} = turn("start classified project")
    assert {:awaiting, _awaitable, awaiting_result} = awaiting_turn.decision

    assert {:ok, retry_turn} =
             turn(" MAYBE ", state: awaiting_result.state)

    assert {:awaiting, %Awaitable{status: :open, attempts: 1}, retry_result} =
             retry_turn.decision

    assert retry_result.input.text == "maybe"
    assert [%Effect{status: :waiting_policy}] = retry_result.state.pending_effects
    refute_receive {:full_agent_local_classifier, "maybe"}
    refute_receive {:full_agent_llm_classifier, _prompt, _opts}
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "policy attempts exhaustion cancels pending work without executing it" do
    assert {:ok, awaiting_turn} = turn("start classified project")
    assert {:awaiting, _awaitable, awaiting_result} = awaiting_turn.decision

    assert {:ok, retry_turn} =
             turn("maybe", state: awaiting_result.state)

    assert {:awaiting, _awaitable, retry_result} = retry_turn.decision

    assert {:ok, cancelled_turn} =
             turn("still unsure", state: retry_result.state)

    assert {:completed, %Effect{status: :cancelled} = cancelled, cancelled_result} =
             cancelled_turn.decision

    assert Effect.outcome(cancelled) == {:cancelled, :policy_attempts_exceeded}
    assert cancelled_result.state.pending_effects == []

    assert [%Awaitable{status: :cancelled, attempts: 2}] =
             cancelled_result.state.awaitables

    assert {:ok, missing} = execute(cancelled_result)
    assert missing.events == [%{type: :effect_missing}]
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "trusted host rejection produces the same terminal cancellation as user rejection" do
    assert {:ok, awaiting_turn} = turn("start classified project")

    assert {:ok, rejected_turn} =
             Turn.resolve_policy(awaiting_turn, {:reject, :rejected_terms})

    assert {:completed, %Effect{status: :cancelled} = cancelled, rejected_result} =
             rejected_turn.decision

    assert Effect.outcome(cancelled) ==
             {:cancelled, {:policy_rejected, :rejected_terms}}

    assert rejected_result.state.pending_effects == []

    assert Enum.any?(
             rejected_result.events,
             &match?(%{type: :policy_resolved, source: :host, kind: :reject}, &1)
           )

    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "invalid trusted policy label leaves live session state unchanged" do
    session = start_session()

    assert {:ok, awaiting_turn} =
             Spectre.turn(session, "start classified project", test_pid: self())

    state_before = Spectre.state(session)

    assert {:error, {:unknown_policy_resolution_label, :terms, :reject, :unknown}} =
             Turn.resolve_policy(awaiting_turn, {:reject, :unknown})

    assert Spectre.state(session) == state_before
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "trusted host rejection clears pending work in the live session" do
    session = start_session()

    assert {:ok, awaiting_turn} =
             Spectre.turn(session, "start classified project", test_pid: self())

    assert {:ok, rejected_turn} =
             Turn.resolve_policy(awaiting_turn, {:reject, :rejected_terms})

    assert {:completed, %Effect{status: :cancelled}, rejected_result} =
             rejected_turn.decision

    assert rejected_result.state.pending_effects == []
    assert Spectre.state(session) == rejected_result.state
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "a policy cannot be resolved twice after host approval" do
    session = start_session()

    assert {:ok, awaiting_turn} =
             Spectre.turn(session, "start classified project", test_pid: self())

    assert {:ok, approved_turn} =
             Turn.resolve_policy(awaiting_turn, {:accept, :accepted_terms})

    state_after_approval = Spectre.state(session)
    assert {:needs, %Effect{status: :approved}, _result} = approved_turn.decision

    assert {:error, :no_open_policy} =
             Turn.resolve_policy(approved_turn, {:accept, :accepted_terms})

    assert Spectre.state(session) == state_after_approval
    refute_receive {:full_agent_action, :create_project, _args}
  end

  test "session turns retain session identity and host policy resolution updates live state" do
    child_id = {:full_agent_session, System.unique_integer([:positive])}

    session =
      start_supervised!({Spectre.Session, agent: Agent, state: %State{}, id: child_id})

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

  defp start_session do
    child_id = {:full_agent_negative_session, System.unique_integer([:positive])}

    start_supervised!({Spectre.Session, agent: Agent, state: %State{}, id: child_id})
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
