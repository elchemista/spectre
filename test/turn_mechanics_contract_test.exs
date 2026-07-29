defmodule SpectreTurnMechanicsContractTest.Ledger do
  @moduledoc false

  alias Spectre.State

  def initial do
    %{events: [], faults: %{}, handler_mode: :cont, states: %{}}
  end

  def record(ledger, event) do
    Elixir.Agent.update(ledger, &update_in(&1.events, fn events -> events ++ [event] end))
  end

  def events(ledger), do: Elixir.Agent.get(ledger, & &1.events)

  def clear_events(ledger) do
    Elixir.Agent.update(ledger, &%{&1 | events: []})
  end

  def put_fault(ledger, boundary, mode) do
    Elixir.Agent.update(ledger, &put_in(&1, [:faults, boundary], mode))
  end

  def clear_fault(ledger, boundary) do
    Elixir.Agent.update(
      ledger,
      &update_in(&1.faults, fn faults -> Map.delete(faults, boundary) end)
    )
  end

  def fault(ledger, boundary), do: Elixir.Agent.get(ledger, &get_in(&1, [:faults, boundary]))

  def put_handler_mode(ledger, mode) do
    Elixir.Agent.update(ledger, &%{&1 | handler_mode: mode})
  end

  def handler_mode(ledger), do: Elixir.Agent.get(ledger, & &1.handler_mode)

  def load_state(ledger, conversation_id) do
    Elixir.Agent.get(
      ledger,
      &Map.get(&1.states, conversation_id, %State{conversation_id: conversation_id})
    )
  end

  def compare_and_swap(ledger, %State{} = state, expected) do
    Elixir.Agent.get_and_update(ledger, fn data ->
      current =
        Map.get(
          data.states,
          state.conversation_id,
          %State{conversation_id: state.conversation_id}
        )

      if current.revision == expected do
        {{:ok, state}, put_in(data, [:states, state.conversation_id], state)}
      else
        {{:error, {:stale_state, current.revision}}, data}
      end
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Fault do
  @moduledoc false

  alias SpectreTurnMechanicsContractTest.Ledger

  def run(ledger, boundary, success) when is_function(success, 0) do
    case Ledger.fault(ledger, boundary) do
      nil -> success.()
      {:error, reason} -> {:error, reason}
      :raise -> raise "private #{boundary} failure"
      :exit -> exit({boundary, "private failure"})
      :throw -> throw({boundary, "private failure"})
      :kill -> Process.exit(self(), :kill)
      :timeout -> Process.sleep(250)
      :invalid -> :invalid_boundary_reply
    end
  end
end

defmodule SpectreTurnMechanicsContractTest.InputPlug do
  @moduledoc false
  @behaviour Spectre.Input.Plug

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  @impl Spectre.Input.Plug
  def init(opts), do: opts

  @impl Spectre.Input.Plug
  def call(input, context, _opts) do
    ledger = Keyword.fetch!(context.opts, :ledger)
    Ledger.record(ledger, {:input, input.text})

    Fault.run(ledger, :input, fn ->
      normalized = input.text |> String.trim() |> String.downcase()
      {:cont, %{input | text: normalized}}
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Store do
  @moduledoc false
  @behaviour Spectre.State.Store

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  @impl Spectre.State.Store
  def load(input, _agent, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Ledger.record(ledger, {:state_load, input.text})

    Fault.run(ledger, :state_load, fn ->
      {:ok, Ledger.load_state(ledger, conversation_id)}
    end)
  end

  @impl Spectre.State.Store
  def compare_and_swap(state, expected, input, _agent, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    Ledger.record(ledger, {:state_persist, expected, state.revision, input.text})

    Fault.run(ledger, :state_persist, fn ->
      Ledger.compare_and_swap(ledger, state, expected)
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Memory do
  @moduledoc false

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  def recall(text, opts) do
    input = Keyword.fetch!(opts, :input)
    state = Keyword.fetch!(opts, :state)
    ledger = input.meta.ledger
    Ledger.record(ledger, {:memory_recall, text, state.revision})

    Fault.run(ledger, :memory_recall, fn ->
      {:ok, %{recalled_for: text, revision: state.revision}}
    end)
  end

  def remember(input, result, _agent, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    Ledger.record(ledger, {:memory_persist, input.text, result.state.revision})
    Fault.run(ledger, :memory_persist, fn -> :ok end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Handler do
  @moduledoc false
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply
  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  @impl Spectre.Turn.Handler
  def handle_turn(request, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    Ledger.record(ledger, {:turn_handler, request.input.text, request.state.revision})

    Fault.run(ledger, :turn_handler, fn ->
      case Ledger.handler_mode(ledger) do
        :cont -> :cont
        :reply -> {:reply, Reply.new("owned:#{request.input.text}")}
      end
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Journal do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  @impl Spectre.Journal.Store
  def append(record, opts) do
    ledger = Keyword.fetch!(opts, :ledger)

    Ledger.record(
      ledger,
      {:journal, record.phase, record.state_revision, record.turn_id, record.trace_id}
    )

    boundary =
      case record.phase do
        :arbitration -> :journal_arbitration
        :persistence -> :journal_persistence
        _other -> :journal_runtime
      end

    Fault.run(ledger, boundary, fn -> :ok end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Renderer do
  @moduledoc false

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  def render(prompt, input, ctx) do
    ledger = Keyword.fetch!(ctx.opts, :ledger)
    Ledger.record(ledger, {:renderer, prompt, input.text, ctx.state.revision})

    Fault.run(ledger, :renderer, fn ->
      "reply:#{prompt}:#{input.text}"
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Actions do
  @moduledoc false

  alias SpectreTurnMechanicsContractTest.Fault
  alias SpectreTurnMechanicsContractTest.Ledger

  def perform(args, ctx) do
    ledger = Keyword.fetch!(ctx.opts, :ledger)
    key = Keyword.fetch!(ctx.opts, :idempotency_key)
    Ledger.record(ledger, {:action, key, args, ctx.state.revision})

    Fault.run(ledger, :action, fn ->
      {:ok, %{idempotency_key: key, args: args}}
    end)
  end
end

defmodule SpectreTurnMechanicsContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  input_pipeline([{SpectreTurnMechanicsContractTest.InputPlug, []}])
  state(SpectreTurnMechanicsContractTest.Store)
  memory(SpectreTurnMechanicsContractTest.Memory)
  turn_handler(SpectreTurnMechanicsContractTest.Handler)

  actions SpectreTurnMechanicsContractTest.Actions do
    protect(:perform, with: :terms)
  end

  policy :terms do
    accept(:accepted, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :contract do
    on :HELLO, regex: ~r/^hello$/ do
      reply(:hello, renderer: {SpectreTurnMechanicsContractTest.Renderer, :render})
    end

    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform,
        args: %{source: :turn_contract},
        reply: :approval,
        renderer: {SpectreTurnMechanicsContractTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreTurnMechanicsContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Provider.Failure
  alias Spectre.State
  alias SpectreTurnMechanicsContractTest.Agent, as: ContractAgent
  alias SpectreTurnMechanicsContractTest.InputPlug
  alias SpectreTurnMechanicsContractTest.Ledger

  @full_boundary_order [
    :input,
    :state_load,
    :memory_recall,
    :turn_handler,
    :journal_arbitration,
    :renderer,
    :state_persist,
    :journal_persistence,
    :memory_persist
  ]

  @run_boundary_order [
    :input,
    :state_load,
    :run_started,
    :memory_recall,
    :turn_handler,
    :journal_arbitration,
    :renderer,
    :state_persist,
    :journal_persistence,
    :memory_persist,
    :run_boundary
  ]

  test "a routed turn crosses every boundary once, in order, and persists the final state" do
    ledger = start_ledger()
    conversation_id = unique_conversation("ordered")
    opts = runtime_opts(ledger, conversation_id, "ordered-turn")

    assert {:ok, turn} = Spectre.turn(ContractAgent, input(ledger, "  HELLO  "), opts)
    assert {:reply, result} = turn.decision
    assert result.input.text == "hello"
    assert result.reply_text == "reply:hello:hello"
    assert result.route.label == :HELLO
    assert result.state.revision == 1
    assert Ledger.load_state(ledger, conversation_id) == result.state

    assert [%{user: "hello", assistant: "reply:hello:hello", route: :HELLO}] =
             Enum.map(result.state.data.chat_history, &Map.drop(&1, [:at, :events]))

    events = Ledger.events(ledger)
    assert event_tags(events) == @run_boundary_order

    assert [
             {:input, "  HELLO  "},
             {:state_load, "hello"},
             {:journal, :run_started, nil, run_started_id, "ordered-trace"},
             {:memory_recall, "hello", 0},
             {:turn_handler, "hello", 0},
             {:journal, :arbitration, 0, "ordered-turn", "ordered-trace"},
             {:renderer, :hello, "hello", 0},
             {:state_persist, 0, 1, "hello"},
             {:journal, :persistence, 1, "ordered-turn", "ordered-trace"},
             {:memory_persist, "hello", 1},
             {:journal, :run_boundary, nil, run_boundary_id, "ordered-trace"}
           ] = events

    assert "run-event:" <> _digest = run_started_id
    assert "run-event:" <> _digest = run_boundary_id
    refute run_started_id == run_boundary_id
  end

  test "a handler-owned turn skips routing and rendering but still commits history and memory" do
    ledger = start_ledger()
    conversation_id = unique_conversation("handler")
    Ledger.put_handler_mode(ledger, :reply)

    assert {:ok, turn} =
             Spectre.turn(
               ContractAgent,
               input(ledger, "  HELLO  "),
               runtime_opts(ledger, conversation_id, "handler-turn")
             )

    assert {:reply, result} = turn.decision
    assert result.route == nil
    assert result.reply_text == "owned:hello"
    assert result.state.revision == 1
    assert Ledger.load_state(ledger, conversation_id) == result.state

    tags = event_tags(Ledger.events(ledger))

    assert tags == [
             :input,
             :state_load,
             :run_started,
             :memory_recall,
             :turn_handler,
             :journal_runtime,
             :state_persist,
             :journal_persistence,
             :memory_persist,
             :run_boundary
           ]

    refute :journal_arbitration in tags
    refute :renderer in tags
  end

  test "a memory recall error stops the turn before handlers, routing, writes, and memory persist" do
    ledger = start_ledger()
    conversation_id = unique_conversation("recall-error")
    Ledger.put_fault(ledger, :memory_recall, {:error, :memory_down})

    assert {:error, :memory_down} =
             Spectre.turn(
               ContractAgent,
               input(ledger, "hello"),
               runtime_opts(ledger, conversation_id, "recall-error-turn")
             )

    assert event_tags(Ledger.events(ledger)) == [
             :input,
             :state_load,
             :run_started,
             :memory_recall,
             :run_advance_failed
           ]

    assert Ledger.load_state(ledger, conversation_id).revision == 0
  end

  test "a hard crash at every turn boundary stops later work and the next complete turn recovers" do
    Enum.each(@full_boundary_order, fn boundary ->
      ledger = start_ledger()
      conversation_id = unique_conversation("crash-#{boundary}")
      opts = runtime_opts(ledger, conversation_id, "crash-#{boundary}")
      Ledger.put_fault(ledger, boundary, :kill)

      assert {:error, reason} =
               Spectre.turn(ContractAgent, input(ledger, "hello"), opts)

      assert_boundary_failure(boundary, reason)

      expected_prefix =
        @full_boundary_order
        |> Enum.take_while(&(&1 != boundary))
        |> Kernel.++([boundary])
        |> maybe_append_ambiguous_persistence_record(boundary)
        |> include_run_failure_events(boundary)

      assert event_tags(Ledger.events(ledger)) == expected_prefix

      committed? = boundary in [:journal_persistence, :memory_persist]
      assert Ledger.load_state(ledger, conversation_id).revision == if(committed?, do: 1, else: 0)

      Ledger.clear_fault(ledger, boundary)
      Ledger.clear_events(ledger)

      assert {:ok, recovered} =
               Spectre.turn(ContractAgent, input(ledger, "hello"), opts)

      assert {:reply, recovered_result} = recovered.decision
      assert recovered_result.state.revision == if(committed?, do: 2, else: 1)
      assert event_tags(Ledger.events(ledger)) == @run_boundary_order
    end)
  end

  test "host policy resolution and action execution skip user-turn mechanics and replay terminal results" do
    ledger = start_ledger()
    conversation_id = unique_conversation("continuations")
    opts = runtime_opts(ledger, conversation_id, "stage-turn")

    assert {:ok, staged_turn} =
             Spectre.turn(ContractAgent, input(ledger, "perform"), opts)

    assert {:awaiting, _awaitable, staged} = staged_turn.decision
    assert %Spectre.Effect{status: :waiting_policy} = State.pending_effect(staged.state)
    assert staged.state.revision == 1
    assert length(staged.state.data.chat_history) == 1

    Ledger.clear_events(ledger)

    assert {:ok, approved} =
             Spectre.resolve_policy(
               ContractAgent,
               staged,
               {:accept, :accepted},
               continuation_opts(opts, "approve-turn")
             )

    assert %Spectre.Effect{status: :approved} = State.pending_effect(approved.state)
    assert approved.state.revision == 2
    assert length(approved.state.data.chat_history) == 1

    approval_tags = event_tags(Ledger.events(ledger))
    assert :journal_runtime in approval_tags
    assert Enum.take(approval_tags, -2) == [:state_persist, :journal_persistence]
    assert_no_user_turn_boundaries(approval_tags)

    Ledger.clear_events(ledger)

    assert {:ok, completed} =
             Spectre.execute(
               ContractAgent,
               approved,
               continuation_opts(opts, "execute-turn")
             )

    assert [%Spectre.Effect{status: :completed}] = completed.effects
    assert completed.state.revision == 3
    assert length(completed.state.data.chat_history) == 1

    execution_tags = event_tags(Ledger.events(ledger))
    assert Enum.count(execution_tags, &(&1 == :action)) == 1
    assert :journal_runtime in execution_tags
    assert Enum.take(execution_tags, -2) == [:state_persist, :journal_persistence]
    assert_no_user_turn_boundaries(execution_tags)

    Ledger.clear_events(ledger)
    assert {:ok, replayed} = Spectre.execute(ContractAgent, completed, opts)
    assert replayed == completed
    assert Ledger.events(ledger) == []
  end

  defp runtime_opts(ledger, conversation_id, turn_id) do
    [
      conversation_id: conversation_id,
      ledger: ledger,
      turn_id: turn_id,
      trace_id: String.replace(turn_id, "turn", "trace"),
      memory_persist_failure: :error,
      journal:
        {SpectreTurnMechanicsContractTest.Journal,
         [
           events: :all,
           mode: :sync,
           on_error: :error,
           store_opts: [ledger: ledger]
         ]}
    ]
  end

  defp continuation_opts(opts, turn_id) do
    opts
    |> Keyword.put(:turn_id, turn_id)
    |> Keyword.put(:trace_id, String.replace(turn_id, "turn", "trace"))
  end

  defp input(ledger, text), do: %{text: text, meta: %{ledger: ledger}}

  defp event_tags(events), do: Enum.map(events, &event_tag/1)

  defp event_tag({:input, _text}), do: :input
  defp event_tag({:state_load, _text}), do: :state_load
  defp event_tag({:memory_recall, _text, _revision}), do: :memory_recall
  defp event_tag({:turn_handler, _text, _revision}), do: :turn_handler
  defp event_tag({:renderer, _prompt, _text, _revision}), do: :renderer
  defp event_tag({:state_persist, _expected, _revision, _text}), do: :state_persist
  defp event_tag({:memory_persist, _text, _revision}), do: :memory_persist
  defp event_tag({:action, _key, _args, _revision}), do: :action

  defp event_tag({:journal, :arbitration, _revision, _turn_id, _trace_id}),
    do: :journal_arbitration

  defp event_tag({:journal, :persistence, _revision, _turn_id, _trace_id}),
    do: :journal_persistence

  defp event_tag({:journal, phase, _revision, _turn_id, _trace_id})
       when phase in [
              :run_started,
              :run_boundary,
              :run_start_failed,
              :run_advance_failed,
              :run_resume_failed
            ],
       do: phase

  defp event_tag({:journal, _phase, _revision, _turn_id, _trace_id}), do: :journal_runtime

  defp include_run_failure_events(tags, boundary) when boundary in [:input, :state_load],
    do: tags ++ [:run_start_failed]

  defp include_run_failure_events(tags, _boundary) do
    {before_memory, from_memory} = Enum.split_while(tags, &(&1 != :memory_recall))
    before_memory ++ [:run_started] ++ from_memory ++ [:run_advance_failed]
  end

  defp assert_boundary_failure(:input, {InputPlug, %Failure{provider: :input, kind: :crash}}),
    do: :ok

  defp assert_boundary_failure(
         :state_load,
         %Failure{provider: :state, kind: :crash}
       ),
       do: :ok

  defp assert_boundary_failure(
         :memory_recall,
         %Failure{provider: :memory, kind: :crash}
       ),
       do: :ok

  defp assert_boundary_failure(
         :turn_handler,
         %Failure{provider: :turn_handler, kind: :crash}
       ),
       do: :ok

  defp assert_boundary_failure(
         :journal_arbitration,
         {:journal_append_failed, %Failure{provider: :journal, kind: :crash}}
       ),
       do: :ok

  defp assert_boundary_failure(
         :renderer,
         %Failure{provider: :renderer, kind: :crash}
       ),
       do: :ok

  defp assert_boundary_failure(
         :state_persist,
         {:persistence_ambiguous, %Failure{provider: :state, kind: :crash}, result}
       ) do
    assert result.state.revision == 1
    assert result.metadata.state_persistence.status == :ambiguous
  end

  defp assert_boundary_failure(
         :journal_persistence,
         {:persistence_journal_failed,
          {:journal_append_failed, %Failure{provider: :journal, kind: :crash}}, result}
       ) do
    assert result.state.revision == 1
    assert result.metadata.state_persistence.status == :committed
  end

  defp assert_boundary_failure(
         :memory_persist,
         {:memory_persist_failed, %Failure{provider: :memory, kind: :crash}, result}
       ) do
    assert result.state.revision == 1
    assert result.metadata.state_persistence.status == :committed
  end

  defp assert_no_user_turn_boundaries(tags) do
    for forbidden <- [
          :input,
          :state_load,
          :memory_recall,
          :turn_handler,
          :journal_arbitration,
          :renderer,
          :memory_persist
        ] do
      refute forbidden in tags
    end
  end

  defp maybe_append_ambiguous_persistence_record(tags, :state_persist),
    do: tags ++ [:journal_persistence]

  defp maybe_append_ambiguous_persistence_record(tags, _boundary), do: tags

  defp start_ledger do
    start_supervised!(%{
      id: make_ref(),
      start: {Elixir.Agent, :start_link, [fn -> Ledger.initial() end]}
    })
  end

  defp unique_conversation(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
