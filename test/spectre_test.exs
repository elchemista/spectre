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

defmodule SpectreTest.MainBrainLLM do
  @behaviour Spectre.LLM

  def complete("PROJECT CREATE" <> _prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:main_brain_llm, opts})
    {:ok, "main brain reply"}
  end

  def complete(_prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:main_brain_llm, opts})
    {:ok, "INFO"}
  end
end

defmodule SpectreTest.SmallClassifierLLM do
  @behaviour Spectre.LLM

  def complete(prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:small_classifier_llm, prompt, opts})
    {:ok, "INFO"}
  end
end

defmodule SpectreTest.FailingClassifierLLM do
  @behaviour Spectre.LLM

  def complete(_prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:failing_classifier_llm, opts})
    {:error, :classifier_down}
  end
end

defmodule SpectreTest.FallbackClassifierLLM do
  @behaviour Spectre.LLM

  def complete(prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:fallback_classifier_llm, prompt, opts})
    {:ok, "INFO"}
  end
end

defmodule SpectreTest.RouteTrainingClassifierLLM do
  @behaviour Spectre.LLM

  def complete(prompt, _opts) do
    cond do
      prompt =~ "delete" -> {:ok, "DELETE_ACCOUNT"}
      prompt =~ "billing" -> {:ok, "BILLING"}
      true -> {:ok, "PRICING"}
    end
  end
end

defmodule SpectreTest.ForceLLMArbitrator do
  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Arbitrators.Default

  def decide(arbitration, opts) do
    if Enum.any?(arbitration.candidates, &(&1.provider == :llm_classifier)) do
      Default.decide(arbitration, Keyword.put(opts, :conflict, :best))
    else
      {:llm, arbitration}
    end
  end
end

defmodule SpectreTest.ClassifierPrompt do
  def build(assigns), do: "classify: #{assigns.text} -> #{Enum.join(assigns.labels, ",")}"
end

defmodule SpectreTest.DslLocalClassifier do
  def classify(text, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:dsl_local_classifier, text, opts})

    {:ok,
     %{
       label: "INFO",
       accepted?: true,
       confidence: 0.96,
       margin: 0.2,
       strategy: :local_classifier
     }}
  end
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

defmodule SpectreTest.MockExFastembed do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  def load(_model, _opts), do: {:ok, 4}
  def download(model, opts), do: load(model, opts)

  def embed(text, _opts) do
    text = String.downcase(to_string(text))

    {:ok, vector_for(text)}
  end

  # This deterministic adapter mirrors the ExFastembed boundary while keeping
  # the test offline. Each intent owns one vector axis, so routing depends on
  # semantic examples and cosine similarity without hidden model state.
  defp vector_for(text) do
    cond do
      text =~ ~r/\b(scope|estimate|quote|proposal|budget|mvp|marketplace|build)\b/ ->
        [1.0, 0.0, 0.0, 0.0]

      text =~ ~r/\b(available|availability|calendar|meeting|schedule|call|next week)\b/ ->
        [0.0, 1.0, 0.0, 0.0]

      text =~ ~r/\b(portfolio|case studies|examples|previous|work|shipped|clients)\b/ ->
        [0.0, 0.0, 1.0, 0.0]

      text =~ ~r/\b(start|kick off|brief|project|engagement)\b/ ->
        [0.0, 0.0, 0.0, 1.0]

      true ->
        [0.1, 0.1, 0.1, 0.1]
    end
  end
end

defmodule SpectreTest.DeterministicFreelanceModel do
  @moduledoc false
  @behaviour Spectre.LLM

  def complete("FREELANCE_PROPOSAL" <> _prompt, _opts) do
    {:ok, "I can scope the build, split milestones, and return a fixed proposal."}
  end

  def complete("FREELANCE_AVAILABILITY" <> _prompt, _opts) do
    {:ok, "I have deterministic availability for a discovery call on Tuesday or Thursday."}
  end

  def complete("FREELANCE_PORTFOLIO" <> _prompt, _opts) do
    {:ok, "Relevant examples: SaaS intake, marketplace launch, and internal ops tooling."}
  end

  def complete("FREELANCE_TERMS" <> _prompt, _opts) do
    {:ok, "Please accept the collaboration terms before I create the project brief."}
  end

  def complete(_prompt, _opts), do: {:ok, "Deterministic freelance fallback."}
end

defmodule SpectreTest.FreelanceActions do
  def create_project(args, _ctx), do: {:ok, %{created_project: args}}
end

defmodule SpectreTest.ProjectAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  actions SpectreTest.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)

    accept(:accepted_terms,
      regex: ~r/^\s*accetto\s*$/i
    )

    reject(:rejected_terms,
      regex: ~r/^\s*(non accetto|rifiuto|no)\b/i
    )

    otherwise(ask: :accept_terms_retry)
    attempts(3, then: :cancel_pending)
  end

  flow :project_create do
    on :wants_project_create,
      regex: ~r/\b(crea|creare|nuovo)\b.*\b(progetto|project)\b/i do
      ask(:project_create)
    end
  end

  interrupt :cancel,
    regex: ~r/\b(annulla|ferma|stop)\b/i do
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

defmodule SpectreTest.ClassifierDslAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  model(SpectreTest.MainBrainLLM, model: "main")

  classifier(SpectreTest.SmallClassifierLLM,
    model: "small",
    fallback: SpectreTest.FallbackLLM,
    prompt: &SpectreTest.ClassifierPrompt.build/1,
    llm_opts: [max_tokens: 4],
    local: SpectreTest.DslLocalClassifier,
    artifact_dir: "dsl-artifact",
    local_accept_threshold: 0.9,
    local_margin_threshold: 0.08
  )

  router(via: [:classifier, :llm_classifier])

  flow :conversation do
    on :INFO, via: [:classifier, :llm_classifier] do
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
      regex: ~r/^classifier only$/i do
      reply(:classifier_only, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :FALLBACK, regex: ~r/\S/u do
      reply(:fallback, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.LearnedSemanticCacheAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  embedding(SpectreTest.EmbeddingAdapter, model: "toy")

  flow :conversation do
    on :GO_RIGHT, learn: true do
      reply(:go_right, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :GO_LEFT, learn: true, via: [:classifier] do
      reply(:go_left, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.SemanticCacheRedesignAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  embedding(SpectreTest.EmbeddingAdapter, model: "toy")

  flow :conversation do
    on :PRICING, cache: true do
      reply(:pricing, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :TECHNICAL_SUPPORT, cache: false do
      reply(:technical_support, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :SALES do
      reply(:sales, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.OnlineLearningAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  classifier(SpectreTest.RouteTrainingClassifierLLM)
  arbitrator(SpectreTest.ForceLLMArbitrator)
  actions(SpectreTest.HookActions)
  protect(:delete_my_account, with: :delete_account)

  policy :delete_account do
    request(:confirm_delete_account)
    accept(:confirm_delete, regex: ~r/^yes$/i)
    reject(:cancel_delete, regex: ~r/^no$/i)
  end

  router(via: [:llm_classifier])

  flow :conversation do
    on :PRICING, learn: true do
      reply(:pricing, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :BILLING, learn: false do
      reply(:billing, renderer: {SpectreTest.ReplyRenderer, :render})
    end

    on :DELETE_ACCOUNT, learn: true do
      action(:delete_my_account)
    end
  end
end

defmodule SpectreTest.OtherLearnedSemanticCacheAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  embedding(SpectreTest.EmbeddingAdapter, model: "toy")

  flow :conversation do
    on :OTHER_RIGHT, learn: true do
      reply(:other_right, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest.SemanticCacheOverride do
  def lookup("right", _opts) do
    {:ok,
     %{
       label: :GO_RIGHT,
       accepted?: true,
       confidence: 0.99,
       strategy: :semantic_cache_exact
     }}
  end
end

defmodule SpectreTest.ClearableSemanticCache do
  @behaviour Spectre.Router.SemanticCache

  def lookup(_text, _opts), do: {:error, :miss}

  def clear(agent, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:semantic_cache_clear, agent, opts})
    :ok
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
    accept(:ACCEPT_TERMS, [])
    reject(:REJECT_TERMS, [])
  end

  flow :conversation do
    on :GREETING do
      reply(:greeting)
    end

    on :SPAM do
      reply(:spam)
    end
  end
end

defmodule SpectreTest.NormalizingAgent do
  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText, case: :downcase)
  end

  actions SpectreTest.ProjectActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:accept_terms)
    accept(:confirmed_terms, regex: ~r/^confermo$/)
  end
end

defmodule SpectreTest.DeterministicFreelanceAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "tmp/spectre_test/prompts"

  model(SpectreTest.DeterministicFreelanceModel)
  embedding(SpectreTest.MockExFastembed, model: "mock-ex-fastembed")

  router(via: [:regex, :embedding])

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText, case: :downcase)
  end

  actions SpectreTest.FreelanceActions do
    protect(:create_project, with: :terms)
  end

  policy :terms do
    request(:freelance_terms)
    accept(:accepted_terms, regex: ~r/^\s*(yes|accept|i agree|confirmed)\s*$/i)
    reject(:rejected_terms, regex: ~r/^\s*(no|reject|cancel)\s*$/i)
    otherwise(ask: :freelance_terms)
    attempts(2, then: :cancel_pending)
  end

  interrupt :FREELANCE_HELP,
    regex: ~r/\b(help|menu|what can you do)\b/i,
    via: [:regex] do
    reply(:freelance_help, renderer: {SpectreTest.ReplyRenderer, :render})
  end

  flow :freelance_intake do
    on :PROJECT_PROPOSAL,
      regex: ~r/\b(proposal|quote|estimate|budget)\b/i,
      embedding: ["scope an MVP build"],
      via: [:regex, :embedding] do
      ask(:freelance_proposal)
    end

    on :AVAILABILITY,
      regex: ~r/\b(available|availability|meeting|schedule|calendar|call)\b/i,
      embedding: ["schedule a discovery call"],
      via: [:regex, :embedding] do
      ask(:freelance_availability)
    end

    on :PORTFOLIO,
      regex: ~r/\b(portfolio|case studies|examples|previous work)\b/i,
      embedding: ["portfolio examples for shipped products"],
      via: [:regex, :embedding] do
      ask(:freelance_portfolio)
    end

    on :START_PROJECT,
      regex: ~r/\b(start|kick off|create).*\b(project|brief|engagement)\b/i,
      embedding: ["start a new project brief"],
      via: [:regex, :embedding] do
      action :create_project, args: %{kind: "freelance_brief"} do
        reply(:freelance_terms_request, renderer: {SpectreTest.ReplyRenderer, :render})
      end
    end

    on :FALLBACK, regex: ~r/\b(other|fallback)\b/i, via: [:regex] do
      reply(:freelance_fallback, renderer: {SpectreTest.ReplyRenderer, :render})
    end
  end
end

defmodule SpectreTest do
  use ExUnit.Case

  alias Spectre.Awaitable
  alias Spectre.Classifier.Encoder
  alias Spectre.Classifier.Math
  alias Spectre.Classifier.Trainer
  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.Router.LLMClassifier
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.State
  alias Spectre.Training.Dataset
  alias Spectre.Turn.Decision

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

    File.write!(
      Path.join(@prompt_root, "freelance_proposal.text.heex"),
      """
      FREELANCE_PROPOSAL
      Client message: <%= @input.text %>
      """
    )

    File.write!(
      Path.join(@prompt_root, "freelance_availability.text.heex"),
      """
      FREELANCE_AVAILABILITY
      Client message: <%= @input.text %>
      """
    )

    File.write!(
      Path.join(@prompt_root, "freelance_portfolio.text.heex"),
      """
      FREELANCE_PORTFOLIO
      Client message: <%= @input.text %>
      """
    )

    File.write!(
      Path.join(@prompt_root, "freelance_terms.text.heex"),
      """
      FREELANCE_TERMS
      Client message: <%= @input.text %>
      """
    )

    :ok
  end

  defp learned_cache_opts(agent) do
    [
      spectre_agent: agent,
      spectre_rules: Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1),
      semantic_cache_source: learned_cache_source(agent),
      embedding: {SpectreTest.EmbeddingAdapter, [model: "toy"]},
      semantic_search?: true,
      semantic_cache_threshold: 0.0
    ]
  end

  defp learned_cache_source(SpectreTest.OtherLearnedSemanticCacheAgent),
    do: "test/fixtures/other_learned_semantic_cache.json"

  defp learned_cache_source(_agent), do: "test/fixtures/learned_semantic_cache.json"

  defp semantic_redesign_source, do: "test/fixtures/semantic_cache_redesign.json"

  defp learned_cache_entries(agent) do
    case :ets.whereis(Learned) do
      :undefined ->
        []

      _tid ->
        Learned
        |> :ets.tab2list()
        |> Enum.filter(fn
          {{{:agent, ^agent}, _hash}, _index} -> true
          _other -> false
        end)
    end
  end

  defp learned_cache_collection(agent) do
    case learned_cache_entries(agent) do
      [{_key, %{collection: collection}}] -> collection
      entries -> flunk("expected one learned cache collection, got: #{inspect(entries)}")
    end
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

    assert [%Effect{name: :create_project, status: :waiting_policy, policy: :terms} = effect] =
             result.effects

    assert Effect.source(effect) == :al
    effect_id = effect.id

    assert [
             %Spectre.Awaitable{
               kind: :policy,
               name: :terms,
               status: :open,
               subject_id: ^effect_id
             }
           ] =
             result.awaitables

    assert [%Effect{status: :waiting_policy, policy: :terms}] = result.state.pending_effects
    assert [%Spectre.Awaitable{name: :terms, status: :open}] = result.state.awaitables
  end

  test "active policy bypasses the normal router and executes pending action on accept" do
    state =
      %State{}
      |> State.put_pending_effect(
        Effect.stage(%{name: :create_project, args: %{"title" => "ciao"}}),
        :terms
      )

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "accetto",
               state: state,
               model: fn _prompt, _opts -> {:ok, "unused"} end
             )

    assert result.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
    assert result.state.pending_effects == []
    assert [%Spectre.Awaitable{status: :accepted, label: :accepted_terms}] = result.awaitables
    assert [%Effect{name: :create_project, status: :completed}] = result.effects
    assert [%{type: :awaitable_accepted, label: :accepted_terms} | _] = result.events
  end

  test "input pipeline normalizes text before policy matching" do
    state =
      %State{}
      |> State.put_pending_effect(
        Effect.stage(%{name: :create_project, args: %{"title" => "ciao"}}),
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
    assert [%{type: :awaitable_accepted, label: :confirmed_terms} | _] = result.events
  end

  test "interrupt handlers can cancel pending state" do
    state =
      %State{}
      |> State.put_pending_effect(Effect.stage(%{name: :create_project}), :terms)
      |> State.clear_open_awaitables()

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "stop", state: state)

    assert result.state.pending_effects == []
    assert result.state.awaitables == []
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
    assert [%Spectre.Awaitable{name: :terms, status: :open}] = first.state.awaitables

    assert {:ok, second} = Spectre.ask(SpectreTest.ProjectSession, "accetto")
    assert second.state.pending_effects == []
    assert second.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
  end

  test "turn returns lifecycle decision for an open policy awaitable" do
    model = fn
      "PROJECT CREATE" <> _prompt, _opts ->
        {:ok, "Ok.\n<al>\nCREATE PROJECT title=\"ciao\"\n</al>"}

      "ACCEPT TERMS" <> _prompt, _opts ->
        {:ok, "Accetti i termini?"}
    end

    assert {:ok, turn} =
             Spectre.turn(SpectreTest.ProjectAgent, "crea nuovo progetto", model: model)

    assert {:awaiting, %Spectre.Awaitable{name: :terms, status: :open}, result} = turn.decision
    assert result == turn.result
  end

  test "turn decision prefers open awaitable over pending effect" do
    effect = Effect.stage(%{kind: :action, name: :create_project})
    awaitable = Awaitable.open_policy(:terms, effect)
    result = %Result{effects: [effect], awaitables: [awaitable], reply_text: "visible"}

    assert {:awaiting, ^awaitable, ^result} = Decision.decide(result)
  end

  test "turn decision returns needs for a pending effect" do
    effect = Effect.stage(%{kind: :retrieve, name: :project_context})
    result = %Result{effects: [effect], reply_text: "visible"}

    assert {:needs, ^effect, ^result} = Decision.decide(result)
  end

  test "turn decision surfaces completion before reply" do
    effect =
      %{kind: :action, name: :create_project}
      |> Effect.stage()
      |> Effect.complete(%{id: 123})

    result = %Result{effects: [effect], reply_text: "visible"}

    assert {:completed, ^effect, ^result} = Decision.decide(result)
  end

  test "turn decision falls back to reply and no response" do
    reply = %Result{reply_text: "hello"}
    blank = %Result{reply_text: "   "}

    assert {:reply, ^reply} = Decision.decide(reply)
    assert {:no_response, ^blank} = Decision.decide(blank)
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

  test "classifier DSL stores LLM and local classifier configuration" do
    config = SpectreTest.ClassifierDslAgent.__spectre_config__()
    classifier = Keyword.fetch!(config, :classifier)

    assert Keyword.fetch!(classifier, :adapter) ==
             {SpectreTest.SmallClassifierLLM, :complete,
              [model: "small", fallback: SpectreTest.FallbackLLM]}

    assert classifier |> Keyword.fetch!(:prompt) |> is_function(1)
    assert Keyword.fetch!(classifier, :llm_opts) == [max_tokens: 4]
    assert Keyword.fetch!(classifier, :local) == SpectreTest.DslLocalClassifier

    assert Keyword.fetch!(classifier, :local_opts) == [
             artifact_dir: "dsl-artifact",
             local_accept_threshold: 0.9,
             local_margin_threshold: 0.08
           ]
  end

  test "LLM classifier uses classifier DSL model and normal ask uses main model" do
    config = SpectreTest.ClassifierDslAgent.__spectre_config__()

    assert {:ok, route} =
             LLMClassifier.classify(
               "ambiguous",
               [:INFO],
               test_pid: self(),
               model: Keyword.fetch!(config, :model),
               classifier: Keyword.fetch!(config, :classifier)
             )

    assert route.label == :INFO

    assert_receive {:small_classifier_llm, "classify: ambiguous -> INFO", classifier_opts}
    assert Keyword.fetch!(classifier_opts, :model) == "small"
    assert Keyword.fetch!(classifier_opts, :purpose) == :classifier
    assert Keyword.fetch!(classifier_opts, :temperature) == 0.0
    assert Keyword.fetch!(classifier_opts, :max_tokens) == 4

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ClassifierDslAgent, "anything",
               test_pid: self(),
               classify: fn _text, _opts ->
                 {:ok,
                  %{
                    label: "INFO",
                    accepted?: true,
                    confidence: 0.96,
                    margin: 0.2,
                    strategy: :local_classifier
                  }}
               end
             )

    assert result.reply_text == "main brain reply"
    assert_receive {:main_brain_llm, main_opts}
    assert Keyword.fetch!(main_opts, :model) == "main"
  end

  test "LLM classifier falls back to main model when classifier DSL is not set" do
    assert {:ok, route} =
             LLMClassifier.classify("anything", [:INFO],
               test_pid: self(),
               model: {SpectreTest.MainBrainLLM, :complete, model: "main"}
             )

    assert route.label == :INFO
    assert_receive {:main_brain_llm, _opts}
  end

  test "LLM classifier uses classifier fallback when classifier model fails" do
    assert {:ok, route} =
             LLMClassifier.classify("anything", [:INFO],
               test_pid: self(),
               model: {SpectreTest.MainBrainLLM, :complete, model: "main"},
               classifier: [
                 adapter:
                   {SpectreTest.FailingClassifierLLM, :complete,
                    fallback: SpectreTest.FallbackClassifierLLM}
               ]
             )

    assert route.label == :INFO

    assert_receive {:failing_classifier_llm, failing_opts}
    refute Keyword.has_key?(failing_opts, :primary_error)

    assert_receive {:fallback_classifier_llm, _prompt, fallback_opts}
    assert Keyword.fetch!(fallback_opts, :primary_error) == :classifier_down
    refute_received {:main_brain_llm, _opts}
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
        if Keyword.get(opts, :semantic_search?) do
          {:error, :miss}
        else
          {:ok,
           %{
             label: :wants_project_create,
             accepted?: true,
             confidence: 0.98,
             strategy: :semantic_cache_exact
           }}
        end
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

  test "router uses learned semantic cache by default for cacheable routes" do
    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "right"},
               %Spectre.Context{
                 agent: SpectreTest.LearnedSemanticCacheAgent,
                 input: %Spectre.Input{text: "right"},
                 state: %State{},
                 opts: [
                   classification_log?: false,
                   semantic_cache_source:
                     learned_cache_source(SpectreTest.LearnedSemanticCacheAgent)
                 ]
               }
             )

    assert route.label == :GO_RIGHT
    assert route.strategy == :semantic_cache_exact
    assert route.accepted?
  end

  test "learned semantic cache uses vettore search without a custom adapter" do
    rules =
      SpectreTest.LearnedSemanticCacheAgent.__spectre_rules__()
      |> Enum.map(&Spectre.Rule.new/1)

    assert {:ok, result} =
             Learned.lookup("right",
               spectre_rules: rules,
               semantic_cache_source: learned_cache_source(SpectreTest.LearnedSemanticCacheAgent),
               embedding: {SpectreTest.EmbeddingAdapter, [model: "toy"]},
               semantic_search?: true,
               semantic_cache_threshold: 0.0
             )

    assert result.label == :GO_RIGHT
    assert result.strategy == :semantic_cache_search
    assert result.accepted?
    assert result.confidence >= 0.0
  end

  test "learned semantic cache stores examples in a compressed vettore collection" do
    agent = SpectreTest.LearnedSemanticCacheAgent

    assert :ok = SemanticCache.clear(agent)

    assert {:ok, result} =
             Learned.lookup("right", learned_cache_opts(agent))

    assert result.label == :GO_RIGHT

    collection = learned_cache_collection(agent)
    assert :ets.info(Learned, :compressed)
    assert collection.store_state.__struct__ == Vettore.Store.ETS
    assert :ets.info(collection.store_state.table, :compressed)

    assert {:ok, embeddings} = Vettore.all(collection)
    assert length(embeddings) == 1

    right = Enum.find(embeddings, &(&1.metadata["text"] == "right"))

    assert right.metadata["label"] == :GO_RIGHT
    refute Enum.find(embeddings, &(&1.metadata["label"] == :GO_LEFT))

    assert {:ok, fetched} = Vettore.get(collection, right.id)
    assert fetched.metadata["text"] == "right"
    assert fetched.vector == [1.0, 0.0]

    assert {:ok, [nearest | _]} = Vettore.search(collection, [1.0, 0.0], limit: 1)
    assert nearest.metadata["text"] == "right"
    assert nearest.metadata["label"] == :GO_RIGHT
  end

  test "semantic cache adapter overrides learned cache" do
    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "right"},
               %Spectre.Context{
                 agent: SpectreTest.LearnedSemanticCacheAgent,
                 input: %Spectre.Input{text: "right"},
                 state: %State{},
                 opts: [
                   semantic_cache: SpectreTest.SemanticCacheOverride,
                   classification_log?: false
                 ]
               }
             )

    assert route.label == :GO_RIGHT
    assert route.strategy == :semantic_cache_exact
  end

  test "learn true does not add semantic cache visibility to explicit route via" do
    rules =
      SpectreTest.LearnedSemanticCacheAgent.__spectre_rules__()
      |> Enum.map(&Spectre.Rule.new/1)

    assert %{via: via} = Enum.find(rules, &(&1.label == :GO_LEFT))
    assert :classifier in via
    refute :semantic_cache in via
  end

  test "offline dataset rows mirror into semantic cache by default" do
    agent = SpectreTest.SemanticCacheRedesignAgent
    rules = Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1)

    opts = [
      spectre_agent: agent,
      spectre_rules: rules,
      semantic_cache_source: semantic_redesign_source()
    ]

    assert {:ok, %{label: :PRICING, semantic_cache_source: :offline_dataset}} =
             Learned.lookup("pricing quote", opts)

    assert {:error, :miss} = Learned.lookup("api key fails", opts)

    assert {:ok, offline_rows} =
             SemanticCache.examples(agent,
               source: :offline_dataset,
               semantic_cache_source: semantic_redesign_source()
             )

    assert Enum.any?(offline_rows, &(&1.label == :PRICING and &1.editable? == false))
    refute Enum.any?(offline_rows, &(&1.label == :TECHNICAL_SUPPORT))
  end

  test "cache false excludes semantic cache but keeps local classifier routing" do
    classify = fn _text, _opts ->
      {:ok,
       %{
         label: "TECHNICAL_SUPPORT",
         accepted?: true,
         confidence: 0.96,
         margin: 0.2,
         strategy: :local_classifier
       }}
    end

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "api key fails"},
               %Spectre.Context{
                 agent: SpectreTest.SemanticCacheRedesignAgent,
                 input: %Spectre.Input{text: "api key fails"},
                 state: %State{},
                 opts: [
                   classify: classify,
                   via: [:semantic_cache, :classifier],
                   semantic_cache_source: semantic_redesign_source(),
                   classification_log?: false
                 ]
               }
             )

    assert route.label == :TECHNICAL_SUPPORT
    assert route.strategy == :local_classifier
  end

  test "learn true stores online examples after accepted LLM arbitration" do
    agent = SpectreTest.OnlineLearningAgent
    assert :ok = SemanticCache.clear(agent)

    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "what do you charge for support"},
               %Spectre.Context{
                 agent: agent,
                 input: %Spectre.Input{text: "what do you charge for support"},
                 state: %State{},
                 opts: Keyword.merge(agent.__spectre_config__(), classification_log?: false)
               }
             )

    assert route.label == :PRICING
    assert route.strategy == :llm_classifier

    assert {:ok, [row]} = SemanticCache.examples(agent)
    assert row.text == "what do you charge for support"
    assert row.label == :PRICING
    assert row.source == :online_learned
    refute row.verified?

    assert {:ok, cached} =
             Learned.lookup("what do you charge for support",
               spectre_agent: agent,
               spectre_rules: Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1)
             )

    assert cached.label == :PRICING
  end

  test "learn false and guarded inputs skip online learning" do
    agent = SpectreTest.OnlineLearningAgent
    assert :ok = SemanticCache.clear(agent)

    for text <- [
          "billing question please",
          "price",
          "delete my account",
          "password: secret12345"
        ] do
      assert {:ok, _route} =
               Spectre.Router.route(
                 %Spectre.Input{text: text},
                 %Spectre.Context{
                   agent: agent,
                   input: %Spectre.Input{text: text},
                   state: %State{},
                   opts: Keyword.merge(agent.__spectre_config__(), classification_log?: false)
                 }
               )
    end

    assert {:ok, []} = SemanticCache.examples(agent)
  end

  @tag :tmp_dir
  test "examples API supports review mutations and read-only dataset rows", %{tmp_dir: tmp_dir} do
    agent = SpectreTest.SemanticCacheRedesignAgent
    assert :ok = SemanticCache.clear(agent)

    opts = [semantic_cache_source: semantic_redesign_source()]

    assert {:ok, row} =
             SemanticCache.put(
               "custom quote help",
               %{label: :PRICING, accepted?: true, strategy: :llm_classifier},
               Keyword.merge(opts,
                 spectre_agent: agent,
                 spectre_rules: Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1)
               )
             )

    assert {:ok, [listed]} = SemanticCache.examples(agent, opts)
    assert listed.id == row.id

    assert {:ok, verified} = SemanticCache.verify(agent, row.id, opts)
    assert verified.verified?

    assert {:ok, relabeled} = SemanticCache.relabel(agent, row.id, :SALES, opts)
    assert relabeled.label == :SALES
    assert relabeled.verified?

    assert {:ok, offline_rows} =
             SemanticCache.examples(agent, Keyword.put(opts, :source, :offline_dataset))

    offline = Enum.find(offline_rows, &(&1.label == :PRICING))
    assert {:error, :read_only_example} = SemanticCache.delete(agent, offline.id, opts)
    assert {:error, :read_only_example} = SemanticCache.verify(agent, offline.id, opts)
    assert {:error, :read_only_example} = SemanticCache.relabel(agent, offline.id, :SALES, opts)

    path = Path.join(tmp_dir, "semantic_cache.online.jsonl")
    assert {:ok, ^path} = SemanticCache.snapshot(agent, Keyword.merge(opts, path: path))

    assert :ok = SemanticCache.clear(agent)
    assert {:ok, []} = SemanticCache.examples(agent, opts)

    assert {:ok, %{loaded: 1, skipped: 0}} = SemanticCache.load_snapshot(agent, path: path)
    assert {:ok, [loaded]} = SemanticCache.examples(agent, opts)
    assert loaded.label == :SALES

    assert :ok = SemanticCache.delete(agent, loaded.id, opts)
    assert {:ok, []} = SemanticCache.examples(agent, opts)
  end

  test "online mutations bump revision and rebuild semantic search index" do
    agent = SpectreTest.SemanticCacheRedesignAgent
    assert :ok = SemanticCache.clear(agent)

    opts = [
      spectre_agent: agent,
      spectre_rules: Enum.map(agent.__spectre_rules__(), &Spectre.Rule.new/1),
      semantic_cache_source: semantic_redesign_source(),
      embedding: {SpectreTest.EmbeddingAdapter, [model: "toy"]},
      semantic_search?: true,
      semantic_cache_threshold: 0.0
    ]

    assert {:ok, _result} = Learned.lookup("pricing quote", opts)
    revision = Learned.online_revision(agent)

    assert {:ok, _row} =
             SemanticCache.put(
               "available schedule now",
               %{label: :SALES, accepted?: true, strategy: :llm_classifier},
               opts
             )

    assert Learned.online_revision(agent) > revision
    assert {:ok, %{label: :SALES}} = Learned.lookup("available schedule now", opts)
  end

  test "semantic cache clear removes built-in learned cache for an agent" do
    agent = SpectreTest.LearnedSemanticCacheAgent

    assert :ok = SemanticCache.clear(agent)
    assert [] = learned_cache_entries(agent)

    assert {:ok, result} =
             Learned.lookup(
               "right",
               learned_cache_opts(agent)
             )

    assert result.label == :GO_RIGHT
    assert [_entry] = learned_cache_entries(agent)

    assert :ok = SemanticCache.clear(agent)
    assert [] = learned_cache_entries(agent)

    assert {:ok, rebuilt} =
             Learned.lookup(
               "right",
               learned_cache_opts(agent)
             )

    assert rebuilt.label == :GO_RIGHT
    assert [_entry] = learned_cache_entries(agent)
  end

  test "semantic cache clear is scoped by agent" do
    first = SpectreTest.LearnedSemanticCacheAgent
    second = SpectreTest.OtherLearnedSemanticCacheAgent

    assert :ok = SemanticCache.clear(first)
    assert :ok = SemanticCache.clear(second)

    assert {:ok, %{label: :GO_RIGHT}} =
             Learned.lookup("right", learned_cache_opts(first))

    assert {:ok, %{label: :OTHER_RIGHT}} =
             Learned.lookup("right", learned_cache_opts(second))

    assert [_first_entry] = learned_cache_entries(first)
    assert [_second_entry] = learned_cache_entries(second)

    assert :ok = SemanticCache.clear(first)
    assert [] = learned_cache_entries(first)
    assert [_second_entry] = learned_cache_entries(second)
  end

  test "learned semantic cache capacity evicts the oldest index" do
    first = SpectreTest.LearnedSemanticCacheAgent
    second = SpectreTest.OtherLearnedSemanticCacheAgent

    assert :ok = SemanticCache.clear(first)
    assert :ok = SemanticCache.clear(second)

    assert {:ok, %{label: :GO_RIGHT}} =
             Learned.lookup(
               "right",
               Keyword.put(learned_cache_opts(first), :semantic_cache_capacity, 1)
             )

    assert [_first_entry] = learned_cache_entries(first)

    assert {:ok, %{label: :OTHER_RIGHT}} =
             Learned.lookup(
               "right",
               Keyword.put(learned_cache_opts(second), :semantic_cache_capacity, 1)
             )

    assert [] = learned_cache_entries(first)
    assert [_second_entry] = learned_cache_entries(second)
  end

  test "semantic cache clear delegates to custom adapter clear callback" do
    assert :ok =
             SemanticCache.clear(
               SpectreTest.LearnedSemanticCacheAgent,
               semantic_cache: SpectreTest.ClearableSemanticCache,
               test_pid: self()
             )

    assert_receive {:semantic_cache_clear, SpectreTest.LearnedSemanticCacheAgent, opts}
    assert opts[:test_pid] == self()
    assert opts[:spectre_agent] == SpectreTest.LearnedSemanticCacheAgent
  end

  test "semantic cache clear requires custom adapter clear callback" do
    assert {:error, {:missing_semantic_cache_callback, SpectreTest.SemanticCacheOverride, :clear}} =
             SemanticCache.clear(
               SpectreTest.LearnedSemanticCacheAgent,
               semantic_cache: SpectreTest.SemanticCacheOverride
             )
  end

  test "semantic cache clear cannot clear bare semantic lookup function" do
    assert {:error, :unclearable_semantic_lookup} =
             SemanticCache.clear(
               SpectreTest.LearnedSemanticCacheAgent,
               semantic_lookup: fn _text, _opts -> {:error, :miss} end
             )
  end

  test "semantic cache clear rejects invalid agents" do
    assert {:error, {:invalid_agent, NotAnAgent}} =
             SemanticCache.clear(NotAnAgent)
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

  test "router accepts classifier_local as the local classifier adapter option" do
    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "classifier local"},
               %Spectre.Context{
                 agent: SpectreTest.ArbitratedAgent,
                 input: %Spectre.Input{text: "classifier local"},
                 state: %State{},
                 opts: [
                   classifier_local: SpectreTest.DslLocalClassifier,
                   test_pid: self(),
                   via: [:classifier]
                 ]
               }
             )

    assert route.label == :INFO
    assert route.strategy == :local_classifier
    assert_receive {:dsl_local_classifier, "classifier local", _opts}
  end

  test "classifier DSL local option drives the local classifier adapter" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.ClassifierDslAgent, "anything", test_pid: self())

    assert result.route.label == :INFO
    assert result.reply_text == "main brain reply"

    assert_receive {:dsl_local_classifier, "anything", opts}
    assert Keyword.fetch!(opts, :artifact_dir) == "dsl-artifact"
    assert Keyword.fetch!(opts, :local_accept_threshold) == 0.9
    assert_receive {:main_brain_llm, _opts}
  end

  test "old classifier option is no longer treated as a local classifier adapter" do
    assert {:ok, route} =
             Spectre.Router.route(
               %Spectre.Input{text: "legacy classifier option"},
               %Spectre.Context{
                 agent: SpectreTest.ArbitratedAgent,
                 input: %Spectre.Input{text: "legacy classifier option"},
                 state: %State{},
                 opts: [
                   classifier: SpectreTest.DslLocalClassifier,
                   test_pid: self(),
                   via: [:classifier]
                 ]
               }
             )

    refute route.label == :INFO
    refute_received {:dsl_local_classifier, _text, _opts}
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

  test "deterministic freelance agent routes proposal intent by embedding" do
    assert {:ok, result} =
             Spectre.ask(
               SpectreTest.DeterministicFreelanceAgent,
               "Can you scope an MVP for my marketplace?"
             )

    assert result.input.text == "can you scope an mvp for my marketplace?"
    assert result.route.label == :PROJECT_PROPOSAL
    assert result.route.strategy == :embedding
    assert result.reply_text =~ "fixed proposal"
  end

  test "deterministic freelance agent routes availability by regex and mock model" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.DeterministicFreelanceAgent, "Are you available next week?")

    assert result.route.label == :AVAILABILITY
    assert result.route.strategy in [:regex, :embedding]
    assert result.reply_text =~ "discovery call"
  end

  test "deterministic freelance agent handles help interrupt without model work" do
    assert {:ok, result} = Spectre.ask(SpectreTest.DeterministicFreelanceAgent, "HELP")

    assert result.route.label == :FREELANCE_HELP
    assert result.route.flow == nil
    assert result.reply_text == "reply:freelance_help:help"
  end

  test "deterministic freelance agent stages protected project action" do
    assert {:ok, staged} =
             Spectre.ask(SpectreTest.DeterministicFreelanceAgent, "Kick off a project brief")

    assert staged.route.label == :START_PROJECT
    assert staged.reply_text == "reply:freelance_terms_request:kick off a project brief"

    assert [%Effect{name: :create_project, args: %{kind: "freelance_brief"}}] = staged.effects

    assert [%Spectre.Awaitable{name: :terms, status: :open}] = staged.state.awaitables
    assert [%Effect{policy: :terms}] = staged.state.pending_effects

    assert {:ok, executed} =
             Spectre.ask(SpectreTest.DeterministicFreelanceAgent, "I agree", state: staged.state)

    assert executed.reply_text == "%{created_project: %{kind: \"freelance_brief\"}}"
    assert executed.state.pending_effects == []
  end

  test "action handler starts protected action policy without calling the LLM" do
    assert {:ok, result} = Spectre.ask(SpectreTest.ActionAgent, "delete")

    assert result.reply_text == "reply:delete_confirmation_request:delete"

    assert [%Effect{name: :delete_my_account, status: :waiting_policy} = effect] =
             result.effects

    assert Effect.source(effect) == :dsl
    assert Effect.al(effect) == nil
    assert [%Spectre.Awaitable{name: :delete_account, status: :open}] = result.state.awaitables

    assert [%Effect{name: :delete_my_account, policy: :delete_account}] =
             result.state.pending_effects

    assert [%{type: :awaitable_opened, name: :delete_account}, %{type: :effect_staged}] =
             result.events
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
        %{"text" => "cheap crypto promo", "label" => "SPAM"},
        %{"text" => "yes I accept", "label" => "ACCEPT_TERMS"},
        %{"text" => "no thanks", "label" => "REJECT_TERMS"},
        %{"text" => "show my projects", "label" => "ACTION"}
      ])
    )

    assert {:ok, rows} = Dataset.from_agent(SpectreTest.TrainingAgent, source: source_path)

    assert %{text: "ciao", label: "GREETING"} in rows
    assert %{text: "hello", label: "GREETING"} in rows
    assert %{text: "cheap crypto promo", label: "SPAM"} in rows
    assert %{text: "yes I accept", label: "ACCEPT_TERMS"} in rows
    assert %{text: "no thanks", label: "REJECT_TERMS"} in rows
    refute Enum.any?(rows, &(&1.label == "ACTION"))
  end

  @tag :tmp_dir
  test "training dataset reads configured classifier source for known labels", %{
    tmp_dir: tmp_dir
  } do
    source_path = Path.join(tmp_dir, "configured_source.json")

    File.write!(
      source_path,
      Jason.encode!([
        %{"text" => "ciao configurato", "intent" => "GREETING"},
        %{"text" => "ignored action", "label" => "ACTION"}
      ])
    )

    previous = Application.get_env(:spectre, :classifier, [])
    Application.put_env(:spectre, :classifier, Keyword.put(previous, :dataset_path, source_path))

    on_exit(fn ->
      Application.put_env(:spectre, :classifier, previous)
    end)

    assert {:ok, rows} = Dataset.from_agent(SpectreTest.TrainingAgent)
    assert %{text: "ciao configurato", label: "GREETING"} in rows
    refute Enum.any?(rows, &(&1.text == "ignored action"))
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
