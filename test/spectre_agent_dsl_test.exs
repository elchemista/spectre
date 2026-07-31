defmodule SpectreAgentDSLTest.Model do
  @behaviour Spectre.LLM

  def complete(_prompt, _opts), do: {:ok, "ok"}
  def chat(_prompt, _opts), do: {:ok, "chat"}
end

defmodule SpectreAgentDSLTest.StateStore do
  def load(_input, _agent, _opts), do: {:ok, %Spectre.State{}}
end

defmodule SpectreAgentDSLTest.MemoryStore do
  def recall(_text, _opts), do: {:ok, %{}}
end

defmodule SpectreAgentDSLTest.Actions do
  def create_project(args, _ctx), do: {:ok, args}
end

defmodule SpectreAgentDSLTest.Hooks do
  def record(_result, _ctx, _hook), do: :ok
end

defmodule SpectreAgentDSLTest.ReplyRenderer do
  def render(prompt, input, _ctx), do: "#{prompt}:#{input.text}"
end

defmodule SpectreAgentDSLTest.Work do
  use Spectre.Work,
    id: :dsl_example_work,
    version: 1,
    input: :map,
    state: :map

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(state, _context), do: complete(state)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(state, _context), do: complete(state)
end

defmodule SpectreAgentDSLTest.InputPlug do
  @behaviour Spectre.Input.Plug

  def init(opts), do: opts
  def call(input, _ctx, _opts), do: {:cont, Spectre.Input.merge_meta(input, %{dsl_plug?: true})}
end

defmodule SpectreAgentDSLTest.Embedding do
  @behaviour Spectre.Classifier.Embedding

  def load(_model, _opts), do: {:ok, 2}
  def embed(_text, _opts), do: {:ok, [1.0, 0.0]}
end

defmodule SpectreAgentDSLTest.Arbitrator do
  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Arbitrators.Default

  def decide(arbitration, _opts), do: Default.decide(arbitration, [])
end

defmodule SpectreAgentDSLTest do
  use ExUnit.Case

  alias Spectre.Input
  alias Spectre.Router
  alias Spectre.State

  defp compile_agent(source, opts \\ []) do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")
    use_line = use_line(opts)

    source = """
    defmodule #{inspect(module)} do
      #{use_line}

      #{source}
    end
    """

    Code.compile_string(source)
    module
  end

  defp use_line([]), do: "use Spectre.Agent"
  defp use_line(opts), do: "use Spectre.Agent, #{opts}"

  defp route(agent, text, opts \\ []) do
    input = Input.new(text)

    Router.route(input, %Spectre.Context{
      agent: agent,
      input: input,
      state: %State{},
      opts: opts
    })
  end

  test "training declarations are not supported in the DSL" do
    assert_raise ArgumentError, ~r/train: is not supported/, fn ->
      compile_agent("""
      flow :bad do
        on :BAD, train: [true, "hello"] do
          reply :bad
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/train: is not supported/, fn ->
      compile_agent("""
      flow :bad do
        on :BAD, train: "hello" do
          reply :bad
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/train: is not supported/, fn ->
      compile_agent("""
      flow :bad do
        on :BAD, train: true do
          reply :bad
        end
      end
      """)
    end

    assert_raise ArgumentError, ~r/training: is not supported/, fn ->
      compile_agent("""
      flow :bad do
        on :BAD, training: true do
          reply :bad
        end
      end
      """)
    end
  end

  test "use without prompt_root keeps safe defaults" do
    agent = compile_agent("")

    assert agent.__spectre_prompt_root__() == "priv/spectre/prompts"
    assert Keyword.fetch!(agent.__spectre_config__(), :shutdown) == :timer.minutes(10)
    assert Keyword.fetch!(agent.__spectre_config__(), :history) == 50
    assert Keyword.fetch!(agent.__spectre_config__(), :fail) == {:agent_failure_reply, []}
    assert {Spectre.Router.Arbitrators.Default, opts} = agent.__spectre_router__()[:arbitrator]
    assert Keyword.fetch!(opts, :no_decision) == :llm
    assert agent.__spectre_rules__() == []
    assert agent.__spectre_policies__() == %{}
  end

  test "top-level DSL options are compiled into runtime metadata" do
    agent =
      compile_agent(
        """
        model SpectreAgentDSLTest.Model, with: :chat, temperature: 0
        state SpectreAgentDSLTest.StateStore
        memory SpectreAgentDSLTest.MemoryStore
        actions SpectreAgentDSLTest.Actions, namespace: :dsl do
          protect :create_project, with: :terms
          after_action :create_project,
            on: :delivered,
            run: {SpectreAgentDSLTest.Hooks, :record},
            audit?: true
        end
        input_pipeline do
          plug SpectreAgentDSLTest.InputPlug, source: :dsl
        end
        shutdown 123
        idle 45
        history 7
        fail :custom_failure, locale: :en
        router via: [:regex, :embedding], terminal_labels: [:DONE]
        arbitrator SpectreAgentDSLTest.Arbitrator, mode: :strict
        embedding SpectreAgentDSLTest.Embedding, model: "mock"
        """,
        ~s(prompt_root: "tmp/custom_prompts", custom: :kept)
      )

    config = agent.__spectre_config__()

    assert agent.__spectre_prompt_root__() == "tmp/custom_prompts"
    assert Keyword.fetch!(config, :custom) == :kept
    assert Keyword.fetch!(config, :model) == {SpectreAgentDSLTest.Model, :chat, [temperature: 0]}
    assert Keyword.fetch!(config, :state) == SpectreAgentDSLTest.StateStore
    assert Keyword.fetch!(config, :memory) == SpectreAgentDSLTest.MemoryStore
    assert Keyword.fetch!(config, :actions) == {SpectreAgentDSLTest.Actions, [namespace: :dsl]}

    assert Keyword.fetch!(config, :input_pipeline) == [
             {SpectreAgentDSLTest.InputPlug, [source: :dsl]}
           ]

    assert Keyword.fetch!(config, :shutdown) == 123
    assert Keyword.fetch!(config, :idle) == 45
    assert Keyword.fetch!(config, :history) == 7
    assert Keyword.fetch!(config, :fail) == {:custom_failure, [locale: :en]}
    assert Keyword.fetch!(config, :embedding) == {SpectreAgentDSLTest.Embedding, [model: "mock"]}

    assert Keyword.fetch!(agent.__spectre_router__(), :via) == [:regex, :embedding]
    assert Keyword.fetch!(agent.__spectre_router__(), :terminal_labels) == [:DONE]

    assert Keyword.fetch!(agent.__spectre_router__(), :arbitrator) ==
             {SpectreAgentDSLTest.Arbitrator, [mode: :strict]}

    assert agent.__spectre_protections__() == [%{action: :create_project, policy: :terms}]

    assert agent.__spectre_after_actions__() == [
             %{
               action: :create_project,
               on: :delivered,
               run: {SpectreAgentDSLTest.Hooks, :record},
               opts: [audit?: true]
             }
           ]
  end

  test "input_pipeline list form and model function option are supported" do
    agent =
      compile_agent("""
      model SpectreAgentDSLTest.Model, function: :chat, top_p: 1
      input_pipeline [{Spectre.Input.Plugs.NormalizeText, [case: :downcase]}]
      """)

    assert Keyword.fetch!(agent.__spectre_config__(), :model) ==
             {SpectreAgentDSLTest.Model, :chat, [top_p: 1]}

    assert Keyword.fetch!(agent.__spectre_config__(), :input_pipeline) ==
             [{Spectre.Input.Plugs.NormalizeText, [case: :downcase]}]
  end

  test "flow DSL captures every evidence type and handler option" do
    agent =
      compile_agent("""
      flow :all_handlers do
        on :ASK,
          regex: ~r/^ask$/i,
          bag: "bag example",
          jaro: [examples: ["jaro example"]],
          embedding: [examples: ["embedding example"]],
          check: {:language, ["en", :it]},
          checks: [role: :admin],
          via: [:regex, :bag, :jaro, :embedding],
          custom: :kept do
          ask :ask_prompt, temperature: 0
        end

        on :RUN, regex: nil do
          run :run_locally, mode: :fast
        end

        on :REASON, regex: ~r/^reason$/i do
          reason :reason_prompt, temperature: 0
        end

        on :ACT, regex: ~r/^act$/i do
          act :act_prompt, temperature: 0
        end

        on :WORK, regex: ~r/^work$/i do
          work SpectreAgentDSLTest.Work, input: %{value: 1}, reply_text: "started"
        end

        on :REPLY, bag: ["one", nil, "two"] do
          reply :reply_prompt, renderer: {SpectreAgentDSLTest.ReplyRenderer, :render}
        end

        on :ACTION, regex: ~r/^action$/i do
          action :create_project, args: %{id: 1} do
            reply :action_reply, renderer: {SpectreAgentDSLTest.ReplyRenderer, :render}
            after_action on: :delivered, run: {SpectreAgentDSLTest.Hooks, :record}
            after_action :other_action, on: :queued, run: {SpectreAgentDSLTest.Hooks, :record}
          end
        end
      end
      """)

    [ask, run, reason, act, work, reply, action] = agent.__spectre_rules__()

    assert ask.label == :ASK
    assert ask.flow == :all_handlers
    assert [ask_regex] = ask.regex
    assert Regex.source(ask_regex) == "^ask$"
    assert :caseless in Regex.opts(ask_regex)
    assert Regex.match?(ask_regex, "ASK")
    assert ask.bag == ["bag example"]
    assert ask.jaro == ["jaro example"]
    assert ask.embedding == ["embedding example"]
    refute Map.has_key?(ask, :training)
    assert ask.checks == [{:language, ["en", :it]}, {:role, :admin}]
    assert ask.via == [:regex, :bag, :jaro, :embedding]
    assert ask.opts == [custom: :kept]
    assert ask.handler == {:ask, :ask_prompt, [temperature: 0]}

    assert run.regex == []
    refute Map.has_key?(run, :training)
    assert run.handler == {:run, :run_locally, [mode: :fast]}

    assert reason.handler == {:reason, :reason_prompt, [temperature: 0]}
    assert act.handler == {:act, :act_prompt, [temperature: 0]}

    assert work.handler ==
             {:work, SpectreAgentDSLTest.Work, [input: %{value: 1}, reply_text: "started"]}

    refute Map.has_key?(reply, :training)
    assert reply.bag == ["one", "two"]

    assert reply.handler ==
             {:reply, :reply_prompt, [renderer: {SpectreAgentDSLTest.ReplyRenderer, :render}]}

    assert {:action, :create_project, action_opts} = action.handler
    assert Keyword.fetch!(action_opts, :args) == %{id: 1}
    assert Keyword.fetch!(action_opts, :reply) == :action_reply
    assert Keyword.fetch!(action_opts, :renderer) == {SpectreAgentDSLTest.ReplyRenderer, :render}

    assert [
             %{action: :other_action, on: :queued},
             %{action: :create_project, on: :delivered}
           ] = Keyword.fetch!(action_opts, :hooks)
  end

  test "compact do forms work for flow rules and interrupts" do
    agent =
      compile_agent("""
      flow :compact do
        on :COMPACT, regex: ~r/^compact$/, do: reply(:compact)
      end

      interrupt :STOP, regex: ~r/^stop$/, do: run(:stop_now)
      """)

    [compact, stop] = agent.__spectre_rules__()

    assert compact.label == :COMPACT
    assert compact.flow == :compact
    assert compact.handler == {:reply, :compact, []}
    refute compact.global?

    assert stop.label == :STOP
    assert stop.flow == nil
    assert stop.handler == {:run, :stop_now, []}
    assert stop.global?
  end

  test "policy DSL captures request branches retry and terminal action" do
    agent =
      compile_agent("""
      policy :terms do
        request :accept_terms
        accept :accepted, regex: ~r/^yes$/i
        reject :rejected, regex: ~r/^no$/i
        otherwise ask: :accept_terms_retry
        attempts 3, then: :cancel_pending
      end
      """)

    assert %{
             name: :terms,
             request: :accept_terms,
             accepts: [%{label: :accepted}],
             rejects: [%{label: :rejected}],
             otherwise: {:ask, :accept_terms_retry},
             max_attempts: 3,
             then: :cancel_pending
           } = agent.__spectre_policies__().terms
  end

  test "protect supports action atom al and function forms" do
    agent =
      compile_agent("""
      protect :delete_account, with: :confirm_delete
      protect al: "DELETE ACCOUNT", with: :confirm_al
      protect function: "MyApp.delete/1", with: :confirm_function
      """)

    assert agent.__spectre_protections__() == [
             %{action: {:function, "MyApp.delete/1"}, policy: :confirm_function},
             %{action: {:al, "DELETE ACCOUNT"}, policy: :confirm_al},
             %{action: :delete_account, policy: :confirm_delete}
           ]
  end

  test "rules with missing or empty regex do not match deterministic regex routing" do
    agent =
      compile_agent("""
      flow :empty_regex do
        on :NO_REGEX do
          reply :no_regex
        end

        on :NIL_REGEX, regex: nil do
          reply :nil_regex
        end
      end
      """)

    assert [%{regex: []}, %{regex: []}] = agent.__spectre_rules__()
    assert {:ok, route} = route(agent, "anything")
    assert route.label == :unknown
    refute route.accepted?
  end

  test "malformed rule checks fail when rules are materialized" do
    agent =
      compile_agent("""
      flow :bad_checks do
        on :BAD, regex: ~r/^bad$/, check: :language do
          reply :bad
        end
      end
      """)

    assert_raise ArgumentError, ~r/invalid rule check: :language/, fn ->
      Router.candidate_rules(agent, %State{})
    end
  end

  test "invalid flow declarations fail at compile time" do
    assert_raise ArgumentError, ~r/invalid flow declaration/, fn ->
      compile_agent("""
      flow :bad do
        reply :not_a_rule
      end
      """)
    end
  end

  test "on declarations require a do block" do
    assert_raise ArgumentError, ~r/expected do block/, fn ->
      compile_agent("""
      flow :bad do
        on :MISSING_BLOCK, regex: ~r/^x$/
      end
      """)
    end
  end

  test "route handlers must be ask run reply or action" do
    assert_raise ArgumentError, ~r/expected ask\/run\/reply\/action handler/, fn ->
      compile_agent("""
      flow :bad do
        on :BAD, regex: ~r/^bad$/ do
          :not_a_handler
        end
      end
      """)
    end
  end

  test "invalid policy declarations fail at compile time" do
    assert_raise ArgumentError, ~r/invalid policy declaration/, fn ->
      compile_agent("""
      policy :bad do
        reply :not_allowed
      end
      """)
    end
  end

  test "policy otherwise requires an ask prompt" do
    assert_raise KeyError, fn ->
      compile_agent("""
      policy :bad do
        otherwise then: :cancel_pending
      end
      """)
    end
  end

  test "invalid input pipeline declarations fail at compile time" do
    assert_raise ArgumentError, ~r/invalid input pipeline declaration/, fn ->
      compile_agent("""
      input_pipeline do
        unknown SpectreAgentDSLTest.InputPlug
      end
      """)
    end
  end

  test "invalid actions blocks fail at compile time" do
    assert_raise ArgumentError, ~r/invalid actions declaration/, fn ->
      compile_agent("""
      actions SpectreAgentDSLTest.Actions do
        reply :not_allowed
      end
      """)
    end
  end

  test "invalid action handler blocks fail at compile time" do
    assert_raise ArgumentError, ~r/invalid action declaration/, fn ->
      compile_agent("""
      flow :bad_action do
        on :BAD_ACTION, regex: ~r/^bad$/ do
          action :create_project do
            ask :not_allowed
          end
        end
      end
      """)
    end
  end

  test "protect requires a policy" do
    assert_raise KeyError, fn ->
      compile_agent("protect :delete_account")
    end
  end

  test "after_action requires on and run options" do
    assert_raise KeyError, fn ->
      compile_agent("after_action :delete_account, on: :delivered")
    end
  end

  test "interrupt compact form requires a do block" do
    assert_raise ArgumentError, ~r/expected do block/, fn ->
      compile_agent("interrupt :cancel, regex: ~r/^cancel$/")
    end
  end
end
