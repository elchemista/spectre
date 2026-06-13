defmodule SpectreKinetic do
  defstruct actions: []

  def extract_al_scan(text) do
    al_blocks =
      ~r/<al\b[^>]*>(.*?)<\/al>/is
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim/1)

    clean_text =
      text
      |> String.replace(~r/<al\b[^>]*>.*?<\/al>/is, "")
      |> String.trim()

    %{clean_text: clean_text, entries: Enum.map(al_blocks, &%{raw: &1, al: &1, error: nil})}
  end

  def plan_chain(_runtime, text, _opts) do
    actions =
      text
      |> extract_al_scan()
      |> Map.fetch!(:entries)
      |> Enum.map(fn entry ->
        %{
          al: entry.al,
          selected_tool: "Elixir.SpectreTest.ProjectActions.create_project/2",
          args: %{"title" => "ciao"},
          status: :ok
        }
      end)

    {:ok, %__MODULE__{actions: actions}}
  end

  def load_runtime(_opts), do: {:ok, :kinetic_runtime}
end

defmodule SpectreKinetic.Tool.Extractor do
  def extract_module(_module), do: {:ok, []}
end

defmodule SpectreTest.ProjectActions do
  def create_project(args, _ctx), do: {:ok, {:created_project, args}}
end

defmodule SpectreTest.HookActions do
  def delete_my_account(_args, _ctx), do: {:ok, %{action: "delete_my_account"}}
end

defmodule SpectreTest.AfterActionHooks do
  def record_agent(action_result, ctx, hook) do
    send(
      Keyword.fetch!(ctx.opts, :test_pid),
      {:agent_after_action, action_result, hook, ctx.assigns}
    )

    :ok
  end

  def record_local(action_result, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:local_after_action, action_result, ctx.assigns})
    :ok
  end
end

defmodule SpectreTest.LLM do
  def complete("PROJECT CREATE" <> _prompt, _opts), do: {:ok, "Risposta dal DSL model."}
  def complete("ACCEPT TERMS" <> _prompt, _opts), do: {:ok, "Accetti i termini?"}
  def complete(_prompt, _opts), do: {:ok, "Risposta generica."}
end

defmodule SpectreTest.FailingLLM do
  @behaviour Spectre.LLM

  def complete(_prompt, _opts), do: {:error, :primary_down}
end

defmodule SpectreTest.FallbackLLM do
  @behaviour Spectre.LLM

  def complete(_prompt, opts), do: {:ok, "Fallback reply after #{inspect(opts[:primary_error])}."}
end

defmodule SpectreTest.ReplyRenderer do
  def render(prompt, input, _ctx), do: "reply:#{prompt}:#{input.text}"
end

defmodule SpectreTest.StateStore do
  def load(_input, _agent, opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    {:ok, :persistent_term.get({__MODULE__, conversation_id}, %Spectre.State{})}
  end

  def persist(state, _input, _agent, opts) do
    conversation_id = state.conversation_id || Keyword.get(opts, :conversation_id)
    :persistent_term.put({__MODULE__, conversation_id}, state)
    :ok
  end
end

defmodule SpectreTest.MemoryStore do
  def recall(text, opts) do
    conversation_id = opts |> Keyword.fetch!(:state) |> Map.get(:conversation_id)
    {:ok, %{conversation_id: conversation_id, cue: text}}
  end

  def remember(payload, opts) do
    conversation_id = opts |> Keyword.fetch!(:state) |> Map.get(:conversation_id)
    :persistent_term.put({__MODULE__, conversation_id}, payload)
    :ok
  end
end

defmodule SpectreTest.EmbeddingAdapter do
  @behaviour Spectre.Classifier.Embedding

  def load("toy", opts), do: {:ok, Keyword.get(opts, :dimensions, 2)}
  def embed("right", _opts), do: {:ok, [1.0, 0.0]}
  def embed("left", _opts), do: {:ok, [-1.0, 0.0]}
  def embed(_text, _opts), do: {:ok, [0.0, 1.0]}
end

defmodule SpectreTest.ProjectAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  actions SpectreTest.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)

    accept(:accepted_terms,
      regex: ~r/^\s*accetto\s*$/i,
      train: "training/policies/terms/accept.jsonl"
    )

    reject(:rejected_terms,
      regex: ~r/^\s*(non accetto|rifiuto|no)\b/i,
      train: "training/policies/terms/reject.jsonl"
    )

    otherwise(ask: :accept_terms_retry)
    attempts(3, then: :cancel_pending)
  end

  flow :project_create do
    on :wants_project_create,
      regex: ~r/\b(crea|creare|nuovo)\b.*\b(progetto|project)\b/i,
      train: "training/project_create/wants_project_create.jsonl" do
      ask(:project_create)
    end
  end

  interrupt :cancel,
    regex: ~r/\b(annulla|ferma|stop)\b/i,
    train: "training/shared/cancel.jsonl" do
    run(:cancel_current)
  end

  def cancel_current(input, ctx), do: Spectre.cancel(input, ctx)
end

defmodule SpectreTest.DurableAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  model(SpectreTest.LLM)
  state(SpectreTest.StateStore)
  memory(SpectreTest.MemoryStore)
  shutdown(50)

  flow :project_create do
    on :wants_project_create, regex: ~r/\b(crea|creare|nuovo)\b.*\b(progetto|project)\b/i do
      ask(:project_create)
    end
  end
end

defmodule SpectreTest.DefaultConfigAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"
end

defmodule SpectreTest.ModelFallbackAgent do
  use Spectre.Agent,
    prompt_root: "tmp/spectre_test/prompts",
    fail: :agent_failure_reply

  model(SpectreTest.FailingLLM, fallback: SpectreTest.FallbackLLM)

  flow :conversation do
    on :FALLBACK, regex: ~r/\S/u do
      ask(:project_create)
    end
  end
end

defmodule SpectreTest.RoutedAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  flow :conversation do
    on :REGEX_ONLY,
      via: [:regex],
      regex: ~r/^regex only$/i do
      reply(:regex_only, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :CLASSIFIER_ONLY,
      via: [:classifier],
      regex: ~r/^classifier only$/i,
      train: ["classifier route example"] do
      reply(:classifier_only, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :FALLBACK, regex: ~r/\S/u do
      reply(:fallback, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.ArbitratedAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  router(via: [:regex, :bag, :classifier, :llm_classifier])

  flow :conversation do
    on :LIST_PROJECTS,
      bag: ["show my projects", "list my projects"],
      strength: :strong,
      via: [:bag, :classifier, :llm_classifier] do
      reply(:list_projects, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :INFO,
      regex: ~r/\bprojects\b/i,
      via: [:regex, :classifier, :llm_classifier] do
      reply(:info, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.FailureAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  fail(:agent_failure)
end

defmodule SpectreTest.ActionAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  protect(:delete_my_account, with: :delete_account)

  policy :delete_account do
    request(:confirm_delete_account)
    accept(:confirmed_delete_account, regex: ~r/^confirm$/i)
    reject(:cancel_delete_account, regex: ~r/^cancel$/i)
  end

  flow :conversation do
    on :DELETE_ACCOUNT, regex: ~r/^delete$/i do
      action :delete_my_account do
        reply(:delete_confirmation_request, renderer: {SpectreTest.ReplyRenderer, :render})
      end
    end
  end
end

defmodule SpectreTest.AfterActionAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  actions SpectreTest.HookActions do
    after_action(:delete_my_account,
      on: :delivered,
      run: {SpectreTest.AfterActionHooks, :record_agent}
    )
  end

  flow :conversation do
    on :DELETE_ACCOUNT, regex: ~r/^delete$/i do
      action :delete_my_account do
        after_action(on: :delivered, run: {SpectreTest.AfterActionHooks, :record_local})
      end
    end
  end
end

defmodule SpectreTest.LanguagePlug do
  @behaviour Spectre.Router.Plug

  alias Spectre.Input
  alias Spectre.Router.Context

  def init(opts), do: opts

  def call(%Context{} = context, _state) do
    meta = Keyword.get(context.opts, :test_input_meta, %{})
    {:cont, Context.put_input(context, Input.merge_meta(context.input, meta))}
  end
end

defmodule SpectreTest.LanguageAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  router(pipeline: [SpectreTest.LanguagePlug, Spectre.Router.Plugs.Regex])

  flow :conversation do
    on :INFO_EN,
      regex: ~r/^info$/i,
      check: {:language, "english"} do
      reply(:platform_info_en, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :INFO_IT,
      regex: ~r/^info$/i,
      check: {:language, ["italian", "it"]} do
      reply(:platform_info_it, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :FALLBACK, regex: ~r/^info$/i do
      reply(:fallback, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.TrainingAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  policy :terms do
    request(:accept_terms)
    accept(:ACCEPT_TERMS, train: ["yes I accept"])
    reject(:REJECT_TERMS, train: ["no thanks"])
  end

  flow :conversation do
    on :GREETING, training: true do
      reply(:greeting)
    end

    on :SPAM, train: ["cheap crypto promo"] do
      reply(:spam)
    end
  end
end

defmodule SpectreTest.NormalizingAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  input_pipeline do
    plug Spectre.Input.Plugs.NormalizeText, case: :downcase
  end

  actions SpectreTest.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)
    accept(:confirmed_terms, regex: ~r/^confermo$/)
  end
end

defmodule SpectreTest do
  use ExUnit.Case

  alias Spectre.Classifier.{Encoder, Math, Trainer}
  alias Spectre.{PendingAction, State}

  @prompt_root Path.expand("tmp/spectre_test/prompts")

  setup_all do
    File.rm_rf!(@prompt_root)
    File.mkdir_p!(Path.join(@prompt_root, "policies/terms"))

    File.write!(
      Path.join(@prompt_root, "project_create.text.heex"),
      """
      PROJECT CREATE
      Message: <%= @input.text %>
      State: <%= inspect(@state.data) %>
      """
    )

    File.write!(
      Path.join(@prompt_root, "policies/terms/accept_terms.text.heex"),
      """
      ACCEPT TERMS
      Message: <%= @input.text %>
      """
    )

    File.write!(
      Path.join(@prompt_root, "policies/terms/accept_terms_retry.text.heex"),
      """
      ACCEPT TERMS RETRY
      """
    )

    File.write!(
      Path.join(@prompt_root, "agent_failure.text.heex"),
      """
      Failed for <%= @input.text %>: <%= inspect(@reason) %>
      """
    )

    :ok
  end

  test "agent DSL compiles flows, policies, protections and interrupts" do
    rules = SpectreTest.ProjectAgent.__spectre_rules__()

    assert Enum.any?(rules, &(&1.label == :wants_project_create and &1.flow == :project_create))
    assert Enum.any?(rules, &(&1.label == :cancel and &1.global?))

    policies = SpectreTest.ProjectAgent.__spectre_policies__()
    assert policies.terms.request == :accept_terms
    assert [%{label: :accepted_terms}] = policies.terms.accepts

    assert [%{action: :create_project, policy: :terms}] =
             SpectreTest.ProjectAgent.__spectre_protections__()
  end

  test "ask renders a prompt, strips AL, stages a protected action and requests policy" do
    model = fn
      "PROJECT CREATE" <> _prompt, _opts ->
        {:ok, "Perfetto, preparo il progetto.\n<al>\nCREATE PROJECT title=\"ciao\"\n</al>"}

      "ACCEPT TERMS" <> _prompt, _opts ->
        {:ok, "Prima di procedere, accetti i termini?"}
    end

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "crea nuovo progetto",
               model: model,
               state: %State{data: %{source: :test}}
             )

    assert result.reply_text ==
             "Perfetto, preparo il progetto.\n\nPrima di procedere, accetti i termini?"

    assert [%PendingAction{name: :create_project, status: :ok, source: :al}] = result.actions
    assert result.state.awaiting.policy == :terms
    assert result.state.pending_action.status == :waiting_policy
    assert result.state.pending_action.policy == :terms
  end

  test "active policy bypasses the normal router and executes pending action on accept" do
    state =
      %State{}
      |> State.put_pending(
        PendingAction.new(%{name: :create_project, args: %{"title" => "ciao"}}),
        :terms
      )

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "accetto",
               state: state,
               model: fn _prompt, _opts -> {:ok, "unused"} end
             )

    assert result.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
    assert result.state.awaiting == nil
    assert result.state.pending_action == nil
    assert [%{type: :policy_accepted, label: :accepted_terms} | _] = result.events
  end

  test "input pipeline normalizes text before policy matching" do
    state =
      %State{}
      |> State.put_pending(
        PendingAction.new(%{name: :create_project, args: %{"title" => "ciao"}}),
        :terms
      )

    assert {:ok, result} =
             Spectre.ask(SpectreTest.NormalizingAgent, "  Confermo  ",
               state: state,
               model: fn _prompt, _opts -> {:ok, "unused"} end
             )

    assert result.input.text == "confermo"
    assert result.input.raw == "  Confermo  "
    assert result.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
    assert [%{type: :policy_accepted, label: :confirmed_terms} | _] = result.events
  end

  test "interrupt handlers can cancel pending state" do
    state =
      %State{}
      |> State.put_pending(PendingAction.new(%{name: :create_project}), :terms)
      |> State.clear_awaiting()

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "stop", state: state)

    assert result.state.pending_action == nil
    assert result.state.awaiting == nil
  end

  test "session GenServer keeps Spectre state between turns" do
    model = fn
      "PROJECT CREATE" <> _prompt, _opts ->
        {:ok, "Ok.\n<al>\nCREATE PROJECT title=\"ciao\"\n</al>"}

      "ACCEPT TERMS" <> _prompt, _opts ->
        {:ok, "Accetti i termini?"}
    end

    start_supervised!(
      {Spectre.Session,
       agent: SpectreTest.ProjectAgent, name: SpectreTest.ProjectSession, opts: [model: model]}
    )

    assert {:ok, first} = Spectre.ask(SpectreTest.ProjectSession, "crea nuovo progetto")
    assert first.state.awaiting.policy == :terms

    assert {:ok, second} = Spectre.ask(SpectreTest.ProjectSession, "accetto")
    assert second.state.awaiting == nil
    assert second.state.pending_action == nil
    assert second.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
  end

  test "dynamic Spectre supervisor starts sessions" do
    supervisor = start_supervised!({Spectre.Supervisor, name: SpectreTest.DynamicSpectre})

    assert {:ok, pid} =
             Spectre.summon(supervisor, SpectreTest.ProjectAgent,
               conversation_id: "chat-1",
               opts: [model: fn _prompt, _opts -> {:ok, "unused"} end]
             )

    assert %State{conversation_id: "chat-1"} = Spectre.state(pid)
  end

  test "agent DSL model adapter is used without per-call model option" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.DurableAgent, "crea nuovo progetto",
               conversation_id: "dsl-model"
             )

    assert result.reply_text == "Risposta dal DSL model."

    assert [%{user: "crea nuovo progetto", assistant: "Risposta dal DSL model."}] =
             result.state.data.chat_history
  end

  test "agent use options set runtime defaults and default arbitrator" do
    config = SpectreTest.DefaultConfigAgent.__spectre_config__()
    router = SpectreTest.DefaultConfigAgent.__spectre_router__()

    assert Keyword.fetch!(config, :shutdown) == :timer.minutes(10)
    assert Keyword.fetch!(config, :history) == 50
    assert Keyword.fetch!(config, :fail) == {:agent_failure_reply, []}
    assert {Spectre.Router.Arbitrators.Default, opts} = Keyword.fetch!(router, :arbitrator)
    assert Keyword.fetch!(opts, :classifier_accept) == 0.93
    assert Keyword.fetch!(opts, :classifier_margin) == 0.08
    assert Keyword.fetch!(opts, :embedding_accept) == 0.84
    assert Keyword.fetch!(opts, :bag_accept) == 0.72
    assert Keyword.fetch!(opts, :conflict) == :llm
    assert Keyword.fetch!(opts, :no_decision) == :clarify
  end

  test "model fallback adapter is used when the primary model fails" do
    assert {:ok, result} = Spectre.ask(SpectreTest.ModelFallbackAgent, "hello")

    assert result.reply_text == "Fallback reply after :primary_down."
  end

  test "session restores persisted state and memory after restart" do
    conversation_id = "restore-1"
    :persistent_term.erase({SpectreTest.StateStore, conversation_id})
    :persistent_term.erase({SpectreTest.MemoryStore, conversation_id})

    {:ok, pid} =
      Spectre.summon(
        agent: SpectreTest.DurableAgent,
        conversation_id: conversation_id,
        shutdown: false
      )

    assert {:ok, first} = Spectre.ask(pid, "crea nuovo progetto")
    assert first.state.conversation_id == conversation_id
    assert length(first.state.data.chat_history) == 1

    assert %{reply_text: "Risposta dal DSL model."} =
             :persistent_term.get({SpectreTest.MemoryStore, conversation_id})

    GenServer.stop(pid)

    {:ok, restarted} =
      Spectre.summon(
        agent: SpectreTest.DurableAgent,
        conversation_id: conversation_id,
        shutdown: false
      )

    assert %State{conversation_id: ^conversation_id, data: %{chat_history: [_turn]}} =
             Spectre.state(restarted)
  end

  test "session stops after configured idle timeout" do
    {:ok, pid} =
      Spectre.summon(
        agent: SpectreTest.DurableAgent,
        conversation_id: "idle-1",
        idle: 20
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 250
  end

  test "router can accept a semantic cache adapter before classifier fallback" do
    semantic_lookup = fn
      "cached please", opts ->
        assert Keyword.get(opts, :semantic_search?) == false

        {:ok,
         %{
           label: :wants_project_create,
           accepted?: true,
           confidence: 0.98,
           strategy: :semantic_cache_exact
         }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "cached please"},
               %Spectre.Context{
                 agent: SpectreTest.ProjectAgent,
                 input: %Spectre.Input{text: "cached please"},
                 state: %State{},
                 opts: [
                   semantic_lookup: semantic_lookup,
                   via: [:semantic_cache, :classifier, :llm]
                 ]
               }
             )

    assert route.label == :wants_project_create
    assert route.strategy == :semantic_cache_exact
    assert route.accepted?
  end

  test "router maps classifier artifact labels onto agent rules" do
    classify = fn
      "classifier please", _opts ->
        {:ok,
         %{
           label: "wants_project_create",
           accepted?: true,
           confidence: 0.94,
           margin: 0.2,
           strategy: :local_classifier
         }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "classifier please"},
               %Spectre.Context{
                 agent: SpectreTest.ProjectAgent,
                 input: %Spectre.Input{text: "classifier please"},
                 state: %State{},
                 opts: [
                   classify: classify,
                   via: [:classifier]
                 ]
               }
             )

    assert route.label == :wants_project_create
    assert route.flow == :project_create
    assert {:ask, :project_create, []} = route.handler
  end

  test "router maps classifier route structs onto agent rules" do
    classify = fn
      "classifier route struct", _opts ->
        {:ok,
         %Spectre.Route{
           label: "wants_project_create",
           accepted?: true,
           confidence: 0.94,
           margin: 0.2,
           strategy: :local_classifier
         }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "classifier route struct"},
               %Spectre.Context{
                 agent: SpectreTest.ProjectAgent,
                 input: %Spectre.Input{text: "classifier route struct"},
                 state: %State{},
                 opts: [
                   classify: classify,
                   via: [:classifier]
                 ]
               }
             )

    assert route.label == :wants_project_create
    assert route.flow == :project_create
    assert {:ask, :project_create, []} = route.handler
    assert :wants_project_create in route.labels
  end

  test "rule via controls which router plug can select a rule" do
    classify = fn
      "classifier only", _opts ->
        {:ok,
         %{
           label: "CLASSIFIER_ONLY",
           accepted?: true,
           confidence: 0.94,
           margin: 0.2,
           strategy: :local_classifier
         }}
    end

    assert {:ok, regex_route} =
             Spectre.Router.route(
               %Spectre.Input{text: "classifier only"},
               %Spectre.Context{
                 agent: SpectreTest.RoutedAgent,
                 input: %Spectre.Input{text: "classifier only"},
                 state: %State{},
                 opts: [via: [:regex]]
               }
             )

    assert regex_route.label == :FALLBACK
    assert regex_route.strategy == :regex

    assert {:ok, classifier_route} =
             Spectre.Router.route(
               %Spectre.Input{text: "classifier only"},
               %Spectre.Context{
                 agent: SpectreTest.RoutedAgent,
                 input: %Spectre.Input{text: "classifier only"},
                 state: %State{},
                 opts: [classify: classify, via: [:classifier]]
               }
             )

    assert classifier_route.label == :CLASSIFIER_ONLY
    assert classifier_route.strategy == :local_classifier
  end

  test "default arbitrator prefers strong bag evidence over weak regex and ambiguous classifier" do
    classify = fn
      "show my projects", _opts ->
        {:ok,
         %{
           label: "INFO",
           accepted?: true,
           confidence: 0.96,
           margin: 0.01,
           strategy: :local_classifier
         }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "show my projects"},
               %Spectre.Context{
                 agent: SpectreTest.ArbitratedAgent,
                 input: %Spectre.Input{text: "show my projects"},
                 state: %State{},
                 opts: [classify: classify]
               }
             )

    assert route.label == :LIST_PROJECTS
    assert route.strategy == :bag
  end

  test "default arbitrator accepts confident classifier when soft regex disagrees" do
    classify = fn
      "projects", _opts ->
        {:ok,
         %{
           label: "LIST_PROJECTS",
           accepted?: true,
           confidence: 0.96,
           margin: 0.2,
           strategy: :local_classifier
         }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "projects"},
               %Spectre.Context{
                 agent: SpectreTest.ArbitratedAgent,
                 input: %Spectre.Input{text: "projects"},
                 state: %State{},
                 opts: [classify: classify]
               }
             )

    assert route.label == :LIST_PROJECTS
    assert route.strategy == :local_classifier
  end

  test "reply handler returns a no-LLM response through a renderer" do
    classify = fn _text, _opts ->
      {:ok,
       %{
         label: "CLASSIFIER_ONLY",
         accepted?: true,
         confidence: 0.94,
         margin: 0.2,
         strategy: :local_classifier
       }}
    end

    assert {:ok, result} =
             Spectre.ask(SpectreTest.RoutedAgent, "classifier only",
               classify: classify,
               via: [:classifier]
             )

    assert result.reply_text == "reply:classifier_only:classifier only"
  end

  test "action handler starts protected action policy without calling the LLM" do
    assert {:ok, result} = Spectre.ask(SpectreTest.ActionAgent, "delete")

    assert result.reply_text == "reply:delete_confirmation_request:delete"

    assert [%PendingAction{name: :delete_my_account, status: :waiting_policy, source: :dsl}] =
             result.actions

    assert result.state.awaiting.policy == :delete_account
    assert result.state.pending_action.name == :delete_my_account
    assert result.state.pending_action.al == nil
    assert result.state.pending_action.source == :dsl
    assert [%{type: :policy_requested, policy: :delete_account}] = result.events
  end

  test "after_action hooks run after an executed action is delivered" do
    assert {:ok, staged} =
             Spectre.ask(SpectreTest.AfterActionAgent, "delete",
               test_pid: self(),
               assigns: %{user_id: 123}
             )

    ctx = %{
      agent: SpectreTest.AfterActionAgent,
      input: staged.input,
      state: staged.state,
      opts: [test_pid: self()],
      assigns: %{user_id: 123}
    }

    assert {:ok, executed} = Spectre.execute(staged.state, ctx)
    assert :ok = Spectre.after_action(SpectreTest.AfterActionAgent, :delivered, executed, ctx)

    assert_receive {:local_after_action, %{action: "delete_my_account"}, %{user_id: 123}}

    assert_receive {:agent_after_action, %{action: "delete_my_account"},
                    %{action: :delete_my_account, on: :delivered}, %{user_id: 123}}
  end

  test "custom plug enriches input and rule checks filter routes" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.LanguageAgent, "info",
               test_input_meta: %{language: "english", language_confidence: 0.96}
             )

    assert result.route.label == :INFO_EN
    assert result.input.meta.language == "english"
    assert result.input.meta.language_confidence == 0.96
    assert result.reply_text == "reply:platform_info_en:info"
  end

  test "rule check can accept one of many enriched field values" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.LanguageAgent, "info",
               test_input_meta: %{language: "italian"}
             )

    assert result.route.label == :INFO_IT
    assert result.input.meta.language == "italian"
    assert result.reply_text == "reply:platform_info_it:info"
  end

  test "monitor renders failure replies through the agent fail prompt" do
    context = %{
      message: %{text: "hello"},
      conversation_id: 10,
      message_id: 20,
      user_id: 30
    }

    assert {:ok, result} =
             Spectre.Monitor.dispatch(SpectreTest.FailureAgent, context,
               run: fn -> {:error, :boom} end,
               fallback_exists?: fn _context -> false end,
               create_fallback: fn fallback_context, text, reason ->
                 {:ok,
                  %{
                    conversation_id: fallback_context.conversation_id,
                    message_id: fallback_context.message_id,
                    text: String.trim(text),
                    reason: reason
                  }}
               end
             )

    assert result.status == :agent_fallback
    assert result.conversation_id == 10
    assert result.message_id == 20
    assert result.text == "Failed for hello: :boom"
    assert result.reason == :boom
  end

  test "monitor uses an english default failure message when the default prompt is missing" do
    assert {:ok, text} =
             Spectre.Monitor.fallback_text(
               SpectreTest.DefaultConfigAgent,
               %{message: %{text: "hello"}},
               :boom
             )

    assert text =~ "couldn't complete that request"
  end

  @tag :tmp_dir
  test "training dataset exports rule and policy examples", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "source.json")

    File.write!(
      source_path,
      Jason.encode!([
        %{"text" => "ciao", "intent" => "GREETING"},
        %{"text" => "hello", "label" => "GREETING"},
        %{"text" => "show my projects", "label" => "ACTION"}
      ])
    )

    assert {:ok, rows} =
             Spectre.Training.Dataset.from_agent(SpectreTest.TrainingAgent,
               source: source_path
             )

    assert %{text: "ciao", label: "GREETING"} in rows
    assert %{text: "hello", label: "GREETING"} in rows
    assert %{text: "cheap crypto promo", label: "SPAM"} in rows
    assert %{text: "yes I accept", label: "ACCEPT_TERMS"} in rows
    assert %{text: "no thanks", label: "REJECT_TERMS"} in rows
    refute Enum.any?(rows, &(&1.label == "ACTION"))
  end

  test "classifier math uses vettore cosine scoring" do
    assert Math.cosine([1.0, 0.0], [1.0, 0.0]) == 1.0
    assert Math.cosine([1.0, 0.0], [-1.0, 0.0]) == -1.0
  end

  test "classifier math uses vettore normalization" do
    assert_in_delta hd(Math.normalize([3.0, 4.0])), 0.6, 0.00001
    assert Math.normalize([0.0, 0.0]) == [0.0, 0.0]
  end

  @tag :tmp_dir
  test "trained classifier defaults to compact centroid artifacts", %{tmp_dir: tmp_dir} do
    dataset_path = Path.join(tmp_dir, "dataset.json")
    artifact_dir = Path.join(tmp_dir, "artifact")

    File.write!(
      dataset_path,
      Jason.encode!([
        %{"text" => "right", "label" => "go_right"},
        %{"text" => "left", "label" => "go_left"}
      ])
    )

    opts = [
      embedding_adapter: SpectreTest.EmbeddingAdapter,
      encoder_model: "toy",
      dimensions: 2,
      classification_log?: false
    ]

    assert {:ok, %{labels: ["go_left", "go_right"]}} =
             Trainer.train(dataset_path, artifact_dir, opts)

    classifier =
      artifact_dir
      |> Path.join("classifier.etf")
      |> File.read!()
      |> :erlang.binary_to_term()

    assert classifier.kind == :centroid_head
    assert map_size(classifier.centroids) == 2
    refute Map.has_key?(classifier, :examples)

    assert {:ok, route} =
             Spectre.Classifier.classify_once(
               "right",
               Keyword.put(opts, :artifact_dir, artifact_dir)
             )

    assert route.label == "go_right"
    assert route.accepted?
    assert route.scores["go_right"] > route.scores["go_left"]
  end

  @tag :tmp_dir
  test "trained classifier can opt into vettore example index without centroids", %{
    tmp_dir: tmp_dir
  } do
    dataset_path = Path.join(tmp_dir, "dataset.json")
    artifact_dir = Path.join(tmp_dir, "artifact")

    File.write!(
      dataset_path,
      Jason.encode!([
        %{"text" => "right", "label" => "go_right"},
        %{"text" => "left", "label" => "go_left"}
      ])
    )

    opts = [
      embedding_adapter: SpectreTest.EmbeddingAdapter,
      encoder_model: "toy",
      dimensions: 2,
      local_classifier_mode: :examples,
      classification_log?: false
    ]

    assert {:ok, %{labels: ["go_left", "go_right"]}} =
             Trainer.train(dataset_path, artifact_dir, opts)

    classifier =
      artifact_dir
      |> Path.join("classifier.etf")
      |> File.read!()
      |> :erlang.binary_to_term()

    assert classifier.kind == :example_index
    assert map_size(classifier.centroids) == 0
    assert [%{label: "go_right"}, %{label: "go_left"}] = classifier.examples

    assert {:ok, route} =
             Spectre.Classifier.classify_once(
               "right",
               Keyword.put(opts, :artifact_dir, artifact_dir)
             )

    assert route.label == "go_right"
    assert route.accepted?
    assert route.scores["go_right"] > route.scores["go_left"]
  end

  test "classifier encoder accepts a custom embedding adapter" do
    opts = [embedding_adapter: SpectreTest.EmbeddingAdapter, dimensions: 2]

    assert {:ok, 2} = Encoder.load("toy", opts)
    assert {:ok, [right, zero]} = Encoder.embed("right", opts)
    assert right == 1.0
    assert zero == 0.0
  end
end
