defmodule SpectreTurnHandlerTest.First do
  @moduledoc false

  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request

  @impl Spectre.Turn.Handler
  def handle_turn(%Request{} = request, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:first_handler, request, opts})
    end

    case Keyword.get(opts, :handler_mode, :cont) do
      :cont ->
        :cont

      :reply ->
        {:reply,
         Reply.new("integration reply",
           events: [%{type: :integration_waiting}],
           metadata: %{integration: :first}
         )}

      :error ->
        {:error, :integration_unavailable}

      :raise ->
        raise "private handler failure"

      :malformed ->
        {:reply, "not a typed reply"}

      :invalid_reply ->
        {:reply, %Reply{reply_text: "invalid", events: :invalid}}

      :timeout ->
        Process.sleep(250)
        :cont
    end
  end
end

defmodule SpectreTurnHandlerTest.Second do
  @moduledoc false

  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request

  @impl Spectre.Turn.Handler
  def handle_turn(%Request{} = request, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:second_handler, request.input.text})
    end

    case Keyword.get(opts, :second_mode, :cont) do
      :cont ->
        :cont

      :reply ->
        {:reply, Reply.new("second integration reply", metadata: %{integration: :second})}
    end
  end
end

defmodule SpectreTurnHandlerTest.Agent do
  @moduledoc false

  use Spectre.Agent

  turn_handler(SpectreTurnHandlerTest.First, namespace: :profile)
  turn_handler(SpectreTurnHandlerTest.Second)

  policy :terms do
    request(:accept_terms)
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
    otherwise(ask: :try_again)
  end

  flow :normal do
    on :NORMAL, regex: ~r/.*/ do
      run(:routed)
    end
  end

  def routed(input, context) do
    if test_pid = Keyword.get(context.opts, :test_pid) do
      send(test_pid, {:routed, input.text})
    end

    "normal:#{input.text}"
  end
end

defmodule SpectreTurnHandlerTest.PlainAgent do
  @moduledoc false

  use Spectre.Agent

  flow :normal do
    on :NORMAL, regex: ~r/.*/ do
      run(:routed)
    end
  end

  def routed(_input), do: "plain"
end

defmodule SpectreTurnHandlerTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Provider.Failure
  alias Spectre.State
  alias Spectre.Turn.Handler.Reply
  alias Spectre.Turn.Handler.Request
  alias SpectreTurnHandlerTest.First
  alias SpectreTurnHandlerTest.Second

  @agent SpectreTurnHandlerTest.Agent

  test "Agents without handlers keep the existing route path" do
    assert {:ok, result} = Spectre.ask(SpectreTurnHandlerTest.PlainAgent, "hello")
    assert result.reply_text == "plain"
    assert result.route.label == :NORMAL
    refute Enum.any?(result.events, &match?(%{type: :turn_handled}, &1))
  end

  test "the ordered pipeline continues into normal routing" do
    assert {:ok, result} =
             Spectre.ask(@agent, "hello",
               handler_mode: :cont,
               second_mode: :cont,
               conversation_id: "conversation-1",
               test_pid: self()
             )

    assert_receive {:first_handler, %Request{} = request, callback_opts}
    assert request.input.text == "hello"
    assert %State{conversation_id: "conversation-1"} = request.state
    assert request.agent == @agent
    assert request.conversation_id == "conversation-1"
    assert request.turn_id == callback_opts[:turn_id]
    assert request.trace_id == callback_opts[:trace_id]
    assert callback_opts[:namespace] == :profile
    assert callback_opts[:test_pid] == self()
    refute Keyword.has_key?(callback_opts, :turn_handlers)
    assert_receive {:second_handler, "hello"}
    assert_receive {:routed, "hello"}
    assert result.reply_text == "normal:hello"
    assert result.route.label == :NORMAL
  end

  test "the first replying handler owns the turn and stops the pipeline" do
    initial = %State{data: %{owned_by: :spectre}}

    assert {:ok, result} =
             Spectre.ask(@agent, "Ada",
               handler_mode: :reply,
               second_mode: :reply,
               state: initial,
               test_pid: self()
             )

    assert_receive {:first_handler, %Request{input: %{text: "Ada"}, state: ^initial}, _opts}
    refute_receive {:second_handler, _text}
    refute_receive {:routed, _text}

    assert result.route == nil
    assert result.reply_text == "integration reply"
    assert result.effects == []
    assert result.awaitables == []
    assert result.state.data.owned_by == :spectre
    assert result.metadata.integration == :first
    assert result.metadata.turn_handler == First
    assert %{type: :turn_handled, handler: First} in result.events
    assert %{type: :integration_waiting} in result.events
  end

  test "a later handler can own a turn after earlier integrations continue" do
    assert {:ok, result} =
             Spectre.ask(@agent, "answer",
               handler_mode: :cont,
               second_mode: :reply,
               test_pid: self()
             )

    assert_receive {:first_handler, %Request{input: %{text: "answer"}}, _opts}
    assert_receive {:second_handler, "answer"}
    refute_receive {:routed, _text}
    assert result.reply_text == "second integration reply"
    assert result.metadata.integration == :second
    assert result.metadata.turn_handler == Second
  end

  test "a handled request still exits through the canonical Turn decision" do
    assert {:ok, %Spectre.Turn{decision: {:reply, result}} = turn} =
             Spectre.turn(@agent, "answer", handler_mode: :reply)

    assert turn.result == result
    assert result.reply_text == "integration reply"
    assert result.metadata.turn_handler == First
  end

  test "turn_handlers false bypasses the Agent pipeline for internal calls" do
    assert {:ok, result} =
             Spectre.ask(@agent, "internal",
               turn_handlers: false,
               handler_mode: :reply,
               second_mode: :reply,
               test_pid: self()
             )

    refute_receive {:first_handler, _request, _opts}
    refute_receive {:second_handler, _text}
    assert_receive {:routed, "internal"}
    assert result.reply_text == "normal:internal"
  end

  test "declared errors and execution failures are fail-closed" do
    assert {:error, :integration_unavailable} =
             Spectre.ask(@agent, "answer",
               handler_mode: :error,
               test_pid: self()
             )

    refute_receive {:second_handler, _text}
    refute_receive {:routed, _text}

    assert {:error, %Failure{provider: :turn_handler, kind: :exception, reason: RuntimeError}} =
             Spectre.ask(@agent, "answer",
               handler_mode: :raise,
               test_pid: self()
             )

    refute_receive {:second_handler, _text}
    refute_receive {:routed, _text}
  end

  test "malformed and invalid typed replies are rejected" do
    assert {:error, %Failure{provider: :turn_handler, kind: :invalid_reply}} =
             Spectre.ask(@agent, "answer", handler_mode: :malformed)

    assert {:error, {:invalid_turn_handler_events, :atom}} =
             Spectre.ask(@agent, "answer", handler_mode: :invalid_reply)
  end

  test "typed reply construction rejects every malformed public field" do
    assert_raise ArgumentError, ~r/expects binary text/, fn -> Reply.new(:not_text) end
    assert_raise ArgumentError, ~r/expects binary text/, fn -> Reply.new("text", %{}) end

    assert_raise ArgumentError, ~r/invalid turn handler reply/, fn ->
      Reply.new("text", metadata: [])
    end

    assert {:error, {:invalid_turn_handler_reply_text, :other}} =
             Reply.validate(%Reply{reply_text: 10})

    assert {:error, {:invalid_turn_handler_metadata, :tuple}} =
             Reply.validate(%Reply{reply_text: "text", metadata: {:bad, :metadata}})
  end

  test "runtime handler configuration rejects invalid and unavailable entries" do
    assert {:error, {:invalid_turn_handlers, :other}} =
             Spectre.ask(@agent, "answer", turn_handlers: :invalid)

    assert {:error, {:invalid_turn_handler, :tuple}} =
             Spectre.ask(@agent, "answer", turn_handlers: [{First, [:not_keyword]}])

    assert {:error, {:invalid_turn_handler, :map}} =
             Spectre.ask(@agent, "answer", turn_handlers: [%{}])

    missing = Module.concat(__MODULE__, MissingHandler)

    assert {:error, {:undefined_turn_handler, ^missing}} =
             Spectre.ask(@agent, "answer", turn_handlers: [missing])
  end

  test "handlers use their own timeout and a Session remains healthy" do
    session = start_supervised!({Spectre.Session, agent: @agent})

    assert {:error,
            %Failure{provider: :turn_handler, kind: :timeout, timeout: 10, retryable?: true}} =
             Spectre.ask(session, "slow",
               handler_mode: :timeout,
               turn_handler_timeout: 10,
               test_pid: self()
             )

    assert Process.alive?(session)

    assert {:ok, result} =
             Spectre.ask(session, "next",
               handler_mode: :cont,
               second_mode: :reply,
               test_pid: self()
             )

    assert result.reply_text == "second integration reply"
  end

  test "an open Spectre policy takes precedence over every handler" do
    waiting =
      %{name: :protected_action}
      |> Effect.stage()
      |> Effect.waiting_policy(:terms)

    open = Awaitable.open_policy(:terms, waiting)

    state = %State{
      pending_effects: [waiting],
      planned_effects: [waiting],
      awaitables: [open]
    }

    assert {:ok, result} =
             Spectre.ask(@agent, "yes",
               state: state,
               handler_mode: :reply,
               second_mode: :reply,
               test_pid: self()
             )

    refute_receive {:first_handler, _request, _opts}
    refute_receive {:second_handler, _text}
    assert [%Awaitable{status: :accepted}] = result.awaitables
    assert [%Effect{status: :approved}] = result.effects
  end

  test "the DSL appends, replaces, disables, and validates handler configuration" do
    assert [{First, [namespace: :profile]}, {Second, []}] =
             Keyword.fetch!(@agent.__spectre_config__(), :turn_handlers)

    disabled = Module.concat(__MODULE__, "Disabled#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(disabled)} do
      use Spectre.Agent
      turn_handler SpectreTurnHandlerTest.First
      turn_handlers false
    end
    """)

    assert Keyword.fetch!(disabled.__spectre_config__(), :turn_handlers) == false
    assert Reply.validate(Reply.new("next")) == :ok

    invalid = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/invalid_turn_handlers/, fn ->
      Code.compile_string("""
      defmodule #{inspect(invalid)} do
        use Spectre.Agent
        turn_handlers :not_a_pipeline
      end
      """)
    end

    skill = Module.concat(__MODULE__, "Skill#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/skill_cannot_configure_agent_infrastructure/, fn ->
      Code.compile_string("""
      defmodule #{inspect(skill)} do
        use Spectre.Skill
        turn_handler SpectreTurnHandlerTest.First
      end
      """)
    end
  end
end
