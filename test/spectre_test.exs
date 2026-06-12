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

defmodule SpectreTest.LLM do
  def complete("PROJECT CREATE" <> _prompt, _opts), do: {:ok, "Risposta dal DSL complete."}
  def complete("ACCEPT TERMS" <> _prompt, _opts), do: {:ok, "Accetti i termini?"}
  def complete(_prompt, _opts), do: {:ok, "Risposta generica."}
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

  actions(SpectreTest.ProjectActions)

  protect(:create_project, with: :terms)

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

  complete(SpectreTest.LLM)
  state(SpectreTest.StateStore)
  memory(SpectreTest.MemoryStore)
  shutdown(50)

  flow :project_create do
    on :wants_project_create, regex: ~r/\b(crea|creare|nuovo)\b.*\b(progetto|project)\b/i do
      ask(:project_create)
    end
  end
end

defmodule SpectreTest do
  use ExUnit.Case

  alias Spectre.Classifier.{Encoder, Math}
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
    complete = fn
      "PROJECT CREATE" <> _prompt, _opts ->
        {:ok, "Perfetto, preparo il progetto.\n<al>\nCREATE PROJECT title=\"ciao\"\n</al>"}

      "ACCEPT TERMS" <> _prompt, _opts ->
        {:ok, "Prima di procedere, accetti i termini?"}
    end

    assert {:ok, result} =
             Spectre.ask(SpectreTest.ProjectAgent, "crea nuovo progetto",
               complete: complete,
               state: %State{data: %{source: :test}}
             )

    assert result.reply_text ==
             "Perfetto, preparo il progetto.\n\nPrima di procedere, accetti i termini?"

    assert [%PendingAction{name: :create_project, status: :ok}] = result.actions
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
               complete: fn _prompt, _opts -> {:ok, "unused"} end
             )

    assert result.reply_text == "{:created_project, %{\"title\" => \"ciao\"}}"
    assert result.state.awaiting == nil
    assert result.state.pending_action == nil
    assert [%{type: :policy_accepted, label: :accepted_terms} | _] = result.events
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
    complete = fn
      "PROJECT CREATE" <> _prompt, _opts ->
        {:ok, "Ok.\n<al>\nCREATE PROJECT title=\"ciao\"\n</al>"}

      "ACCEPT TERMS" <> _prompt, _opts ->
        {:ok, "Accetti i termini?"}
    end

    start_supervised!(
      {Spectre.Session,
       agent: SpectreTest.ProjectAgent,
       name: SpectreTest.ProjectSession,
       opts: [complete: complete]}
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
               opts: [complete: fn _prompt, _opts -> {:ok, "unused"} end]
             )

    assert %State{conversation_id: "chat-1"} = Spectre.state(pid)
  end

  test "agent DSL complete adapter is used without per-call complete option" do
    assert {:ok, result} =
             Spectre.ask(SpectreTest.DurableAgent, "crea nuovo progetto",
               conversation_id: "dsl-complete"
             )

    assert result.reply_text == "Risposta dal DSL complete."

    assert [%{user: "crea nuovo progetto", assistant: "Risposta dal DSL complete."}] =
             result.state.data.chat_history
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

    assert %{reply_text: "Risposta dal DSL complete."} =
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
           confidence: 0.92,
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

  test "classifier math uses vettore cosine scoring" do
    assert Math.cosine([1.0, 0.0], [1.0, 0.0]) == 1.0
    assert Math.cosine([1.0, 0.0], [-1.0, 0.0]) == -1.0
  end

  test "classifier encoder accepts a custom embedding adapter" do
    opts = [embedding_adapter: SpectreTest.EmbeddingAdapter, dimensions: 2]

    assert {:ok, 2} = Encoder.load("toy", opts)
    assert {:ok, [right, zero]} = Encoder.embed("right", opts)
    assert right == 1.0
    assert zero == 0.0
  end
end
