defmodule SpectreTurnCoreErgonomicsTest.Actions do
  @moduledoc false

  def ping(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:ping_ran, args})
    {:ok, %{pong: true}}
  end

  def blocked(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:blocked_ran, args})
    {:ok, %{}}
  end

  def weird(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:weird_ran, args})
    {:ok, %{}}
  end
end

defmodule SpectreTurnCoreErgonomicsTest.Guards do
  @moduledoc false

  def veto(_action, _ctx), do: {:suppress, "not now"}
  def invalid(_action, _ctx), do: :nonsense
end

defmodule SpectreTurnCoreErgonomicsTest.Summarizer do
  @moduledoc false

  def fold(current, evicted) do
    evicted
    |> Enum.map(& &1.user)
    |> then(&Enum.join(List.wrap(current) ++ &1, "|"))
  end

  def boom(_current, _evicted), do: raise("summarizer exploded")
end

defmodule SpectreTurnCoreErgonomicsTest.Renderer do
  @moduledoc false

  def render(prompt, input, _ctx), do: "#{prompt}:#{input.text}"
end

defmodule SpectreTurnCoreErgonomicsTest.Agent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreTurnCoreErgonomicsTest.Guards
  alias SpectreTurnCoreErgonomicsTest.Renderer
  alias SpectreTurnCoreErgonomicsTest.Summarizer

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  history(2, summary: {Summarizer, :fold})
  actions(SpectreTurnCoreErgonomicsTest.Actions)

  before_action(:blocked, run: {Guards, :veto})
  before_action(:weird, run: {Guards, :invalid})

  flow :ops do
    on :PING, regex: ~r/^ping$/i, cache: false do
      action(:ping, args: %{probe: true})
    end

    on :BLOCK, regex: ~r/^block$/i, cache: false do
      action(:blocked)
    end

    on :WEIRD, regex: ~r/^weird$/i, cache: false do
      action(:weird)
    end

    on :HELLO, regex: ~r/^hello$/i, cache: false do
      reply(:hello, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreTurnCoreErgonomicsTest.BoomAgent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreTurnCoreErgonomicsTest.Renderer
  alias SpectreTurnCoreErgonomicsTest.Summarizer

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  history(1, summary: {Summarizer, :boom})

  flow :ops do
    on :HELLO, regex: ~r/^hello$/i, cache: false do
      reply(:hello, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreTurnCoreErgonomicsTest.PolicyAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  actions(SpectreTurnCoreErgonomicsTest.Actions)

  protect(:ping, with: :terms)

  policy :terms do
    accept(:ok_terms, regex: ~r/^yes$/i)
    reject(:no_terms, regex: ~r/^no$/i)
    attempts(2, then: :cancel_pending)
  end

  flow :ops do
    on :GUARDED, regex: ~r/^guarded$/i, cache: false do
      action :ping, args: %{probe: :guarded} do
        reply(:confirm_ping, renderer: {SpectreTurnCoreErgonomicsTest.Renderer, :render})
      end
    end
  end
end

defmodule SpectreTurnCoreErgonomicsTest.CaptureDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end
end

defmodule SpectreTurnCoreErgonomicsTest.FallbackDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end

  @impl true
  def fallback_reply(_result, _opts), do: "sorry, that did not work"
end

defmodule SpectreTurnCoreErgonomicsTest.VetoDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end

  @impl true
  def execute?(_effect, _result, _opts), do: false

  @impl true
  def suppressed(effect, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:suppressed, effect.name})
    {:ok, :suppressed}
  end
end

defmodule SpectreTurnCoreErgonomicsTest.PolicyDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end

  @impl true
  def policy_request(awaitable, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:policy_requested, awaitable.name})
    {:ok, :policy_requested}
  end
end

defmodule SpectreTurnCoreErgonomicsTest.AutoResolveDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end

  @impl true
  def satisfied_resolution(_awaitable, _opts), do: {:ok, {:accept, :ok_terms}}
end

defmodule SpectreTurnCoreErgonomicsTest do
  use ExUnit.Case

  alias Spectre.Effect
  alias Spectre.Result
  alias Spectre.Router.LLMClassifier
  alias Spectre.Rule
  alias Spectre.State
  alias Spectre.Turn
  alias Spectre.Turn.Dispatcher
  alias SpectreTurnCoreErgonomicsTest.Agent
  alias SpectreTurnCoreErgonomicsTest.AutoResolveDelivery
  alias SpectreTurnCoreErgonomicsTest.BoomAgent
  alias SpectreTurnCoreErgonomicsTest.CaptureDelivery
  alias SpectreTurnCoreErgonomicsTest.FallbackDelivery
  alias SpectreTurnCoreErgonomicsTest.PolicyAgent
  alias SpectreTurnCoreErgonomicsTest.PolicyDelivery
  alias SpectreTurnCoreErgonomicsTest.VetoDelivery

  defp turn(agent \\ Agent, text, opts \\ []) do
    Spectre.turn(agent, text, Keyword.put_new(opts, :test_pid, self()))
  end

  defp execute(agent \\ Agent, %Result{} = result) do
    Spectre.execute(result.state, %{
      agent: agent,
      input: result.input,
      state: result.state,
      opts: [test_pid: self()]
    })
  end

  describe "before_action guards" do
    test "guards are compiled into the definition" do
      guards = Agent.__spectre_definition__().before_actions

      assert [%{action: :blocked}, %{action: :weird}] = guards
    end

    test "a guard without run: fails at compile time" do
      assert_raise KeyError, fn ->
        defmodule BadGuardAgent do
          use Spectre.Agent
          before_action(:anything, [])
        end
      end
    end

    test "skills cannot declare before_action guards" do
      assert_raise ArgumentError, ~r/skill_before_action_not_supported/, fn ->
        defmodule BadGuardSkill do
          use Spectre.Skill
          requires_action(:anything, mode: :read)
          before_action(:anything, run: {SpectreTurnCoreErgonomicsTest.Guards, :veto})
        end
      end
    end

    test "an allowed action executes normally" do
      assert {:ok, %Turn{decision: {:needs, %Effect{name: :ping}, result}}} = turn("ping")
      assert {:ok, executed} = execute(result)

      assert [%Effect{name: :ping, status: :completed}] = executed.effects
      assert_receive {:ping_ran, %{probe: true}}
    end

    test "a suppressing guard cancels the effect and replies without executing" do
      assert {:ok, %Turn{decision: {:needs, %Effect{name: :blocked}, result}}} = turn("block")
      assert {:ok, executed} = execute(result)

      assert executed.reply_text == "not now"
      assert [%Effect{name: :blocked, status: :cancelled}] = executed.effects
      assert Enum.any?(executed.events, &(&1.type == :effect_suppressed))
      refute_receive {:blocked_ran, _args}
    end

    test "an invalid guard reply fails the effect closed" do
      assert {:ok, %Turn{decision: {:needs, %Effect{name: :weird}, result}}} = turn("weird")
      assert {:ok, executed} = execute(result)

      assert [%Effect{name: :weird, status: :failed}] = executed.effects
      refute_receive {:weird_ran, _args}
    end
  end

  describe "history summary" do
    test "evicted turns fold into state.data.chat_summary" do
      assert {:ok, first} = Spectre.ask(Agent, "hello", test_pid: self())
      assert {:ok, second} = Spectre.ask(Agent, "hello", state: first.state, test_pid: self())
      assert {:ok, third} = Spectre.ask(Agent, "hello", state: second.state, test_pid: self())

      history = third.state.data.chat_history
      assert length(history) == 2
      assert third.state.data.chat_summary == "hello"

      assert {:ok, fourth} = Spectre.ask(Agent, "hello", state: third.state, test_pid: self())
      assert fourth.state.data.chat_summary == "hello|hello"
    end

    test "a crashing summarizer keeps the previous summary and the turn succeeds" do
      assert {:ok, first} = Spectre.ask(BoomAgent, "hello", test_pid: self())
      assert {:ok, second} = Spectre.ask(BoomAgent, "hello", state: first.state, test_pid: self())

      assert length(second.state.data.chat_history) == 1
      refute Map.has_key?(second.state.data, :chat_summary)
    end

    test "the classifier prompt includes the rolling summary" do
      test_pid = self()

      model = fn prompt, _opts ->
        send(test_pid, {:classifier_prompt, prompt})
        {:ok, "HELP"}
      end

      rules = [Rule.new(%{label: :HELP, regex: ~r/help/})]

      assert {:ok, _route} =
               LLMClassifier.classify("help", [:HELP],
                 model: model,
                 spectre_rules: rules,
                 classifier_assigns: %{
                   state: %State{data: %{chat_summary: "user wants a website"}}
                 }
               )

      assert_received {:classifier_prompt, prompt}
      assert prompt =~ "Conversation summary (older turns):\nuser wants a website"
    end
  end

  describe "Turn.Dispatcher" do
    test "a reply decision delivers the reply text" do
      assert {:ok, %Turn{decision: {:reply, _result}} = reply_turn} = turn("hello")

      assert {:ok, {:sent, "hello:hello"}} =
               Dispatcher.dispatch(reply_turn, CaptureDelivery, test_pid: self())

      assert_received {:delivered, "hello:hello"}
    end

    test "a needs decision executes the action and delivers the outcome" do
      assert {:ok, %Turn{decision: {:needs, _effect, _result}} = needs_turn} = turn("ping")

      assert {:ok, {:sent, text}} =
               Dispatcher.dispatch(needs_turn, CaptureDelivery, test_pid: self())

      assert text =~ "pong"
      assert_receive {:ping_ran, %{probe: true}}
      assert_received {:delivered, ^text}
    end

    test "an execute? veto goes through the suppressed callback" do
      assert {:ok, needs_turn} = turn("ping")

      assert {:ok, :suppressed} =
               Dispatcher.dispatch(needs_turn, VetoDelivery, test_pid: self())

      assert_received {:suppressed, :ping}
      refute_receive {:ping_ran, _args}
    end

    test "a core guard suppression flows through as a normal reply" do
      assert {:ok, needs_turn} = turn("block")

      assert {:ok, {:sent, "not now"}} =
               Dispatcher.dispatch(needs_turn, CaptureDelivery, test_pid: self())

      refute_receive {:blocked_ran, _args}
    end

    test "an empty outcome uses fallback_reply" do
      assert {:ok, weird_turn} = turn("weird")

      assert {:ok, {:sent, "sorry, that did not work"}} =
               Dispatcher.dispatch(weird_turn, FallbackDelivery, test_pid: self())

      assert_received {:delivered, "sorry, that did not work"}
    end

    test "an empty outcome without fallback becomes no_response" do
      assert {:ok, weird_turn} = turn("weird")

      assert {:ok, :no_response} =
               Dispatcher.dispatch(weird_turn, CaptureDelivery, test_pid: self())

      refute_received {:delivered, _text}
    end

    test "an open policy is delivered through policy_request" do
      assert {:ok, %Turn{decision: {:awaiting, _awaitable, _result}} = awaiting_turn} =
               turn(PolicyAgent, "guarded")

      assert {:ok, :policy_requested} =
               Dispatcher.dispatch(awaiting_turn, PolicyDelivery, test_pid: self())

      assert_received {:policy_requested, :terms}
      refute_receive {:ping_ran, _args}
    end

    test "a satisfied policy auto-resolves, executes, and delivers" do
      assert {:ok, awaiting_turn} = turn(PolicyAgent, "guarded")

      assert {:ok, {:sent, text}} =
               Dispatcher.dispatch(
                 awaiting_turn,
                 AutoResolveDelivery,
                 test_pid: self()
               )

      assert text =~ "pong"
      assert_receive {:ping_ran, %{probe: :guarded}}
    end
  end
end
