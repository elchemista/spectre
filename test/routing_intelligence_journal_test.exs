defmodule SpectreRoutingIntelligenceTest.LocalClassifier do
  @moduledoc false

  def classify(text, opts) do
    notify(opts, {:routing_intelligence_local, text})

    case text do
      "local request" ->
        {:ok,
         %{
           label: :LOCAL,
           accepted?: true,
           confidence: 0.99,
           margin: 0.4,
           strategy: :local_classifier
         }}

      "uncertain request" ->
        {:ok,
         %{
           label: :LOCAL,
           accepted?: false,
           confidence: 0.55,
           margin: 0.01,
           strategy: :local_classifier
         }}

      _text ->
        {:error, :no_local_match}
    end
  end

  defp notify(opts, message) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, message)
    :ok
  end
end

defmodule SpectreRoutingIntelligenceTest.ClassifierLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:routing_intelligence_llm, prompt, opts})
    end

    cond do
      prompt =~ "malformed response" -> {:ok, "LOCAL and LLM_ROUTE"}
      prompt =~ "fenced response" -> {:ok, "```text\nLLM_ROUTE\n```"}
      true -> {:ok, "LLM_ROUTE"}
    end
  end
end

defmodule SpectreRoutingIntelligenceTest.Renderer do
  @moduledoc false

  def render(prompt, input, _ctx), do: "#{prompt}:#{input.text}"
end

defmodule SpectreRoutingIntelligenceTest.Agent do
  @moduledoc false

  use Spectre.Agent

  classifier(SpectreRoutingIntelligenceTest.ClassifierLLM,
    local: SpectreRoutingIntelligenceTest.LocalClassifier,
    llm_opts: [max_tokens: 6]
  )

  router(via: [:regex, :classifier, :llm_classifier], classification_log?: false)

  interrupt :HELP, regex: ~r/^help$/i do
    reply(:help, renderer: {SpectreRoutingIntelligenceTest.Renderer, :render})
  end

  flow :conversation do
    on :LOCAL, via: [:classifier, :llm_classifier] do
      reply(:local, renderer: {SpectreRoutingIntelligenceTest.Renderer, :render})
    end

    on :LLM_ROUTE, via: [:llm_classifier] do
      reply(:llm, renderer: {SpectreRoutingIntelligenceTest.Renderer, :render})
    end
  end
end

defmodule SpectreRoutingIntelligenceTest.RestrictedAgent do
  @moduledoc false

  use Spectre.Agent

  classifier(SpectreRoutingIntelligenceTest.ClassifierLLM,
    local: SpectreRoutingIntelligenceTest.LocalClassifier
  )

  router(via: [:classifier, :llm_classifier], classification_log?: false)

  flow :conversation do
    on :CLASSIFIER_ONLY, via: [:classifier] do
      reply(:classifier_only, renderer: {SpectreRoutingIntelligenceTest.Renderer, :render})
    end
  end
end

defmodule SpectreRoutingIntelligenceTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:routing_journal, record, opts})
    Keyword.get(opts, :reply, :ok)
  end
end

defmodule SpectreRoutingIntelligenceTest.JournalAgent do
  @moduledoc false

  use Spectre.Agent

  journal(SpectreRoutingIntelligenceTest.JournalStore,
    events: [:routing],
    mode: :sync,
    include_input: false
  )

  router(via: [:regex], classification_log?: false)

  flow :conversation do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreRoutingIntelligenceTest.Renderer, :render})
    end
  end
end

defmodule SpectreRoutingIntelligenceTest.JournalDisabledAgent do
  @moduledoc false

  use Spectre.Agent
  journal(false)
end

defmodule SpectreRoutingIntelligenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Spectre.Journal.Record
  alias Spectre.Router.LLMClassifier

  describe "classifier and LLM routing" do
    test "hard deterministic evidence skips local and LLM classifiers" do
      assert {:ok, turn} = route("help")
      assert {:reply, result} = turn.decision
      assert result.route.label == :HELP
      assert result.route.strategy == :regex

      refute_received {:routing_intelligence_local, _text}
      refute_received {:routing_intelligence_llm, _prompt, _opts}
    end

    test "a confident local classifier wins without spending an LLM call" do
      assert {:ok, turn} = route("local request")
      assert {:reply, result} = turn.decision
      assert result.route.label == :LOCAL
      assert result.route.strategy == :local_classifier

      assert_receive {:routing_intelligence_local, "local request"}
      refute_received {:routing_intelligence_llm, _prompt, _opts}
    end

    test "the default arbitrator asks the LLM after a local miss" do
      assert {:ok, turn} = route("needs semantic routing")
      assert {:reply, result} = turn.decision
      assert result.route.label == :LLM_ROUTE
      assert result.route.strategy == :llm_classifier

      assert_receive {:routing_intelligence_local, "needs semantic routing"}
      assert_receive {:routing_intelligence_llm, prompt, opts}
      assert prompt =~ "Latest message:\nneeds semantic routing"
      assert prompt =~ "Available labels, grouped by conversation flow"
      assert prompt =~ "conversation/\n  LOCAL\n  LLM_ROUTE"
      assert Keyword.fetch!(opts, :purpose) == :classifier
      assert Keyword.fetch!(opts, :max_tokens) == 6
    end

    test "uncertain local evidence falls through to the LLM" do
      assert {:ok, turn} = route("uncertain request")
      assert {:reply, result} = turn.decision
      assert result.route.label == :LLM_ROUTE
      assert result.route.strategy == :llm_classifier

      assert_receive {:routing_intelligence_local, "uncertain request"}
      assert_receive {:routing_intelligence_llm, prompt, _opts}
      assert prompt =~ "local_classifier: label=LOCAL"
      assert prompt =~ "accepted=false"
    end

    test "recent chat is passed to the default classifier prompt" do
      state = %Spectre.State{
        data: %{
          chat_history: [
            %{user: "previous question", assistant: "previous answer"}
          ]
        }
      }

      assert {:ok, _turn} = route("needs context", state: state)

      assert_receive {:routing_intelligence_llm, prompt, _opts}
      assert prompt =~ "User: previous question"
      assert prompt =~ "Assistant: previous answer"
    end

    test "route-level via restrictions keep classifier-only labels away from the LLM" do
      assert {:ok, turn} =
               Spectre.turn(
                 SpectreRoutingIntelligenceTest.RestrictedAgent,
                 "not locally routeable",
                 test_pid: self()
               )

      assert {:no_response, result} = turn.decision
      assert result.route.strategy == :clarify
      assert_receive {:routing_intelligence_local, "not locally routeable"}
      refute_received {:routing_intelligence_llm, _prompt, _opts}
    end

    test "unknown or multi-label model output degrades to an unknown route" do
      assert {:ok, turn} = route("malformed response")
      assert {:no_response, result} = turn.decision
      assert result.route.label == :unknown
      assert result.route.strategy == :unknown

      assert {:unknown_llm_classifier_label, "LOCAL and LLM_ROUTE"} =
               result.route.fallback_error
    end

    test "a fenced exact label is normalized without accepting an explanation" do
      assert {:ok, turn} = route("fenced response")
      assert {:reply, result} = turn.decision
      assert result.route.label == :LLM_ROUTE
      assert result.route.strategy == :llm_classifier
    end

    test "an empty label set never invokes the model" do
      assert {:error, :no_llm_classifier_labels} =
               LLMClassifier.classify("anything", [],
                 model: SpectreRoutingIntelligenceTest.ClassifierLLM,
                 test_pid: self()
               )

      refute_received {:routing_intelligence_llm, _prompt, _opts}
    end
  end

  describe "routing journal" do
    test "the DSL stores an opt-in journal configuration" do
      assert Keyword.fetch!(
               SpectreRoutingIntelligenceTest.JournalAgent.__spectre_config__(),
               :journal
             ) ==
               {SpectreRoutingIntelligenceTest.JournalStore,
                [events: [:routing], mode: :sync, include_input: false]}
    end

    test "the DSL can disable an application-level journal default" do
      assert Keyword.fetch!(
               SpectreRoutingIntelligenceTest.JournalDisabledAgent.__spectre_config__(),
               :journal
             ) == false
    end

    test "records a privacy-safe, correlated arbitration decision" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore,
         [mode: :sync, store_opts: [pid: self(), source: :test]]}

      assert {:ok, turn} =
               route("local request",
                 turn_id: "turn-routing-1",
                 trace_id: "trace-routing-1",
                 conversation_id: "conversation-1",
                 journal: journal
               )

      assert {:reply, _result} = turn.decision

      assert_receive {:routing_journal, %Record{} = record, store_opts}
      assert record.schema_version == 1
      assert record.id =~ "journal:"
      assert record.agent == SpectreRoutingIntelligenceTest.Agent
      assert record.conversation_id == "conversation-1"
      assert record.turn_id == "turn-routing-1"
      assert record.trace_id == "trace-routing-1"
      assert record.phase == :arbitration
      assert record.input == nil
      assert record.reply == nil
      assert record.decision.label == :LOCAL
      assert record.decision.strategy == :local_classifier
      assert record.reason.code == :candidate_selected
      assert [%{provider: :local_classifier, label: :LOCAL}] = record.evidence
      assert store_opts[:source] == :test
    end

    test "record IDs are stable for a retried turn identity" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore, [mode: :sync, store_opts: [pid: self()]]}

      for _attempt <- 1..2 do
        assert {:ok, _turn} =
                 route("local request", turn_id: "same-turn", journal: journal)
      end

      assert_receive {:routing_journal, first, _opts}
      assert_receive {:routing_journal, second, _opts}
      assert first.id == second.id
    end

    test "input content requires an explicit opt-in" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore,
         [events: [:arbitration], mode: :sync, include_input: true, store_opts: [pid: self()]]}

      assert {:ok, _turn} = route("local request", journal: journal)
      assert_receive {:routing_journal, record, _opts}
      assert record.input == %{text: "local request", meta: %{}}
    end

    test "model output and input stay out of failure records by default" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore, [mode: :sync, store_opts: [pid: self()]]}

      assert {:ok, _turn} = route("malformed response", journal: journal)
      assert_receive {:routing_journal, record, _opts}

      serialized = inspect(record)
      refute serialized =~ "malformed response"
      refute serialized =~ "LOCAL and LLM_ROUTE"
      assert record.reason == %{code: :llm_failed, error: :unknown_llm_classifier_label}
    end

    test "sampling can suppress routing records" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore,
         [mode: :sync, sample_rate: 0.0, store_opts: [pid: self()]]}

      assert {:ok, _turn} = route("local request", journal: journal)
      refute_received {:routing_journal, _record, _opts}
    end

    test "warning-mode store failure does not change the route" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore,
         [mode: :sync, on_error: :warn, store_opts: [reply: {:error, :store_down}]]}

      log =
        capture_log(fn ->
          assert {:ok, turn} = route("local request", journal: journal)
          assert {:reply, result} = turn.decision
          assert result.route.label == :LOCAL
        end)

      assert log =~ "spectre_journal append_failed"
      assert log =~ "store_down"
    end

    test "strict synchronous store failure is returned to the host" do
      journal =
        {SpectreRoutingIntelligenceTest.JournalStore,
         [mode: :sync, on_error: :error, store_opts: [reply: {:error, :audit_down}]]}

      assert {:error, {:journal_append_failed, :audit_down}} =
               route("local request", journal: journal)
    end
  end

  defp route(text, opts \\ []) do
    Spectre.turn(
      SpectreRoutingIntelligenceTest.Agent,
      text,
      Keyword.put(opts, :test_pid, self())
    )
  end
end
