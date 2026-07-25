defmodule SpectreSystemLifecycleContractTest.Ledger do
  @moduledoc false

  alias Spectre.State

  def start_link do
    Elixir.Agent.start_link(fn ->
      %{
        actions: %{},
        action_attempts: %{},
        events: [],
        faults: %{},
        side_effect_count: 0,
        states: %{}
      }
    end)
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

      event = {:state_persist, expected, state.revision}
      data = update_in(data.events, &(&1 ++ [event]))

      if current.revision == expected do
        {{:ok, state}, put_in(data, [:states, state.conversation_id], state)}
      else
        {{:error, {:stale_state, current.revision}}, data}
      end
    end)
  end

  def perform_once(ledger, key, args) do
    Elixir.Agent.get_and_update(ledger, fn data ->
      attempts = Map.update(data.action_attempts, key, 1, &(&1 + 1))

      case Map.fetch(data.actions, key) do
        {:ok, result} ->
          event = {:action_attempt, key, :duplicate}

          {{result, false}, %{data | action_attempts: attempts, events: data.events ++ [event]}}

        :error ->
          result = %{args: args, idempotency_key: key}
          event = {:action_attempt, key, :committed}

          {{result, true},
           %{
             data
             | actions: Map.put(data.actions, key, result),
               action_attempts: attempts,
               events: data.events ++ [event],
               side_effect_count: data.side_effect_count + 1
           }}
      end
    end)
  end

  def action_attempts(ledger, key),
    do: Elixir.Agent.get(ledger, &Map.get(&1.action_attempts, key, 0))

  def side_effect_count(ledger), do: Elixir.Agent.get(ledger, & &1.side_effect_count)
end

defmodule SpectreSystemLifecycleContractTest.Fault do
  @moduledoc false

  alias SpectreSystemLifecycleContractTest.Ledger

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

defmodule SpectreSystemLifecycleContractTest.Store do
  @moduledoc false
  @behaviour Spectre.State.Store

  alias SpectreSystemLifecycleContractTest.Fault
  alias SpectreSystemLifecycleContractTest.Ledger

  @impl Spectre.State.Store
  def load(_input, _agent, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    Ledger.record(ledger, {:state_load, conversation_id})

    Fault.run(ledger, :state_load, fn ->
      {:ok, Ledger.load_state(ledger, conversation_id)}
    end)
  end

  @impl Spectre.State.Store
  def compare_and_swap(state, expected, _input, _agent, opts) do
    ledger = Keyword.fetch!(opts, :ledger)

    case Ledger.fault(ledger, :state_persist) do
      :after_commit_kill ->
        {:ok, _state} = Ledger.compare_and_swap(ledger, state, expected)
        Process.exit(self(), :kill)

      _other ->
        Fault.run(ledger, :state_persist, fn ->
          Ledger.compare_and_swap(ledger, state, expected)
        end)
    end
  end
end

defmodule SpectreSystemLifecycleContractTest.Actions do
  @moduledoc false

  alias SpectreSystemLifecycleContractTest.Ledger

  def perform(args, ctx) do
    ledger = Keyword.fetch!(ctx.opts, :ledger)
    key = Keyword.fetch!(ctx.opts, :idempotency_key)
    {result, first?} = Ledger.perform_once(ledger, key, args)

    if test_pid = Keyword.get(ctx.opts, :test_pid) do
      send(test_pid, {:action_boundary, key, first?, self()})
    end

    if first? and Ledger.fault(ledger, :action) == :block_after_commit do
      receive do
        :release -> :ok
      end
    end

    {:ok, result}
  end
end

defmodule SpectreSystemLifecycleContractTest.Journal do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  alias SpectreSystemLifecycleContractTest.Ledger

  @impl Spectre.Journal.Store
  def append(record, opts) do
    ledger = Keyword.fetch!(opts, :ledger)
    Ledger.record(ledger, {:journal_append, record.phase, record.state_revision})

    if record.phase == :persistence and Ledger.fault(ledger, :persistence_journal) do
      {:error, :audit_down}
    else
      :ok
    end
  end
end

defmodule SpectreSystemLifecycleContractTest.Renderer do
  @moduledoc false

  alias SpectreSystemLifecycleContractTest.Ledger

  def render(prompt, input, ctx) do
    Ledger.record(
      Keyword.fetch!(ctx.opts, :ledger),
      {:renderer, prompt, input.text, ctx.state.revision}
    )

    "reply:#{input.text}"
  end
end

defmodule SpectreSystemLifecycleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  state(SpectreSystemLifecycleContractTest.Store)
  actions(SpectreSystemLifecycleContractTest.Actions)
  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :lifecycle do
    on :HELLO, regex: ~r/^hello$/ do
      reply(
        :hello,
        renderer: {SpectreSystemLifecycleContractTest.Renderer, :render}
      )
    end

    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{source: :lifecycle_contract})
    end
  end
end

defmodule SpectreSystemLifecycleContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Journal.Buffer
  alias Spectre.Provider.Failure
  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner
  alias Spectre.State
  alias SpectreSystemLifecycleContractTest.Agent, as: LifecycleAgent
  alias SpectreSystemLifecycleContractTest.Ledger

  @application_children [
    Spectre.Router.SemanticCache.Owner,
    Spectre.Journal.TaskSupervisor,
    Buffer
  ]

  test "an action committed before a definite state-write failure retries idempotently" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})
    conversation_id = unique_conversation("execute-persist-retry")

    assert {:ok, session} = summon(supervisor, ledger, conversation_id)
    assert {:ok, staged} = Spectre.ask(session, "perform")
    staged_state = staged.state

    Ledger.put_fault(ledger, :state_persist, {:error, :store_down})

    assert {:error, :store_down} = Spectre.execute(session, staged)
    assert_receive {:action_boundary, key, true, _worker}

    assert Process.alive?(session)
    assert Spectre.state(session) == staged_state
    assert Ledger.load_state(ledger, conversation_id) == staged_state
    assert Ledger.side_effect_count(ledger) == 1
    assert Ledger.action_attempts(ledger, key) == 1

    Ledger.clear_fault(ledger, :state_persist)

    assert {:ok, completed} = Spectre.execute(session, staged)
    assert_receive {:action_boundary, ^key, false, _worker}

    assert [%Spectre.Effect{status: :completed}] = completed.effects
    assert completed.state.revision == staged_state.revision + 1
    assert Spectre.state(session) == completed.state
    assert Ledger.load_state(ledger, conversation_id) == completed.state
    assert Ledger.side_effect_count(ledger) == 1
    assert Ledger.action_attempts(ledger, key) == 2
  end

  test "the application starts every runtime owner and restarts crashed children without leaks" do
    supervisor = Process.whereis(Spectre.ApplicationSupervisor)
    assert is_pid(supervisor)
    assert Process.alive?(supervisor)

    for child <- @application_children do
      pid = Process.whereis(child)
      assert is_pid(pid), "#{inspect(child)} was not started"
      assert Process.alive?(pid)
    end

    assert {:ok, collection} =
             Owner.new_collection(dimensions: 2, metric: :cosine, index: :flat)

    collection_owner = collection.store_state.owner
    collection_monitor = Process.monitor(collection_owner)

    key = {{:agent, __MODULE__}, :owner_crash_contract}
    index = %{collection: collection, inserted_at: 1}
    assert {:ok, ^index} = Owner.cache_index(Learned, key, index, 4)

    Process.exit(collection_owner, :kill)
    assert_receive {:DOWN, ^collection_monitor, :process, ^collection_owner, :killed}

    assert :removed =
             eventually(fn ->
               if :ets.lookup(Learned, key) == [], do: :removed
             end)

    assert_application_supervisor(supervisor)

    assert {:ok, replacement_collection} =
             Owner.new_collection(dimensions: 2, metric: :cosine, index: :flat)

    replacement_collection_owner = replacement_collection.store_state.owner
    replacement_collection_monitor = Process.monitor(replacement_collection_owner)
    replacement_index = %{collection: replacement_collection, inserted_at: 2}
    assert {:ok, ^replacement_index} = Owner.cache_index(Learned, key, replacement_index, 4)

    old_owner = Process.whereis(Owner)
    owner_monitor = Process.monitor(old_owner)
    Process.exit(old_owner, :kill)

    assert_receive {:DOWN, ^owner_monitor, :process, ^old_owner, :killed}

    assert_receive {:DOWN, ^replacement_collection_monitor, :process,
                    ^replacement_collection_owner, _reason}

    new_owner = eventually(fn -> replacement_pid(Owner, old_owner) end)
    assert :ets.info(Learned, :owner) == new_owner
    assert_application_supervisor(supervisor)

    old_task_supervisor = Process.whereis(Spectre.Journal.TaskSupervisor)
    task_monitor = Process.monitor(old_task_supervisor)
    Process.exit(old_task_supervisor, :kill)
    assert_receive {:DOWN, ^task_monitor, :process, ^old_task_supervisor, :killed}

    assert is_pid(
             eventually(fn ->
               replacement_pid(Spectre.Journal.TaskSupervisor, old_task_supervisor)
             end)
           )

    assert_application_supervisor(supervisor)

    old_buffer = Process.whereis(Buffer)
    buffer_monitor = Process.monitor(old_buffer)
    Process.exit(old_buffer, :kill)
    assert_receive {:DOWN, ^buffer_monitor, :process, ^old_buffer, :killed}

    new_buffer =
      eventually(fn -> replacement_pid(Buffer, old_buffer) end)

    assert %{queue_depth: 0, running_count: 0, running?: false} =
             Buffer.stats(new_buffer)

    assert_application_supervisor(supervisor)
  end

  test "an abnormally terminated Session restores staged and terminal state and stays idempotent" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})
    conversation_id = unique_conversation("abnormal-restart")

    assert {:ok, session} =
             summon(supervisor, ledger, conversation_id)

    assert {:ok, staged} = Spectre.ask(session, "perform")
    assert staged.state.revision == 1
    assert %Spectre.Effect{status: :pending} = State.pending_effect(staged.state)
    assert Ledger.side_effect_count(ledger) == 0

    restarted = crash_and_wait_for_replacement(supervisor, session)
    assert Spectre.state(restarted) == staged.state

    assert {:ok, completed} = Spectre.execute(restarted, staged)
    assert completed.state.revision == 2
    assert completed.state.pending_effects == []

    assert_receive {:action_boundary, key, true, _worker}
    assert Ledger.side_effect_count(ledger) == 1
    assert Ledger.action_attempts(ledger, key) == 1

    restarted_again = crash_and_wait_for_replacement(supervisor, restarted)
    assert Spectre.state(restarted_again) == completed.state

    assert {:ok, replayed} = Spectre.execute(restarted_again, staged)
    assert [%Spectre.Effect{status: :completed}] = replayed.effects
    assert replayed.state == completed.state
    assert Ledger.side_effect_count(ledger) == 1
    assert Ledger.action_attempts(ledger, key) == 1
    refute_receive {:action_boundary, ^key, _first?, _worker}

    assert {:ok, healthy} = Spectre.ask(restarted_again, "hello")
    assert healthy.reply_text == "reply:hello"
    assert healthy.state.revision == 3
  end

  test "a Session crash after the external action commit retries one idempotency key only" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})
    conversation_id = unique_conversation("action-crash")

    assert {:ok, session} = summon(supervisor, ledger, conversation_id)
    assert {:ok, staged} = Spectre.ask(session, "perform")

    Ledger.put_fault(ledger, :action, :block_after_commit)
    parent = self()

    caller =
      spawn(fn ->
        outcome =
          try do
            Spectre.execute(session, staged)
          catch
            :exit, reason -> {:caller_exit, reason}
          end

        send(parent, {:execution_caller_finished, outcome})
      end)

    caller_monitor = Process.monitor(caller)

    assert_receive {:action_boundary, key, true, action_worker}
    action_monitor = Process.monitor(action_worker)
    assert Ledger.side_effect_count(ledger) == 1

    restarted = crash_and_wait_for_replacement(supervisor, session)

    assert_receive {:DOWN, ^action_monitor, :process, ^action_worker, _reason}
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}
    assert_receive {:execution_caller_finished, {:caller_exit, _reason}}

    Ledger.clear_fault(ledger, :action)

    assert %Spectre.Effect{idempotency_key: ^key, status: :pending} =
             State.pending_effect(Spectre.state(restarted))

    assert {:ok, completed} = Spectre.execute(restarted, staged)
    assert [%Spectre.Effect{status: :completed}] = completed.effects
    assert_receive {:action_boundary, ^key, false, _second_worker}

    assert Ledger.side_effect_count(ledger) == 1
    assert Ledger.action_attempts(ledger, key) == 2
  end

  test "state persistence failures are definite only when the adapter explicitly says so" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})

    cases = [
      {{:error, :store_down}, {:definite, :store_down}},
      {:raise, {:ambiguous, %Failure{provider: :state, kind: :exception}}},
      {:exit, {:ambiguous, %Failure{provider: :state, kind: :exit}}},
      {:throw, {:ambiguous, %Failure{provider: :state, kind: :throw}}},
      {:kill, {:ambiguous, %Failure{provider: :state, kind: :crash}}},
      {:timeout, {:ambiguous, %Failure{provider: :state, kind: :timeout}}},
      {:invalid, {:ambiguous, {:invalid_persist_reply, :atom}}}
    ]

    Enum.each(cases, fn {fault, expectation} ->
      conversation_id = unique_conversation("persist-boundary")
      assert {:ok, session} = summon(supervisor, ledger, conversation_id, state_timeout: 10)
      Ledger.put_fault(ledger, :state_persist, fault)

      case expectation do
        {:definite, reason} ->
          assert {:error, ^reason} = Spectre.ask(session, "hello")
          assert Spectre.state(session).revision == 0
          assert Ledger.load_state(ledger, conversation_id).revision == 0

        {:ambiguous, expected_reason} ->
          assert {:error, {:persistence_ambiguous, reason, ambiguous}} =
                   Spectre.ask(session, "hello")

          assert_reason(reason, expected_reason)
          assert ambiguous.state.revision == 1
          assert ambiguous.metadata.state_persistence.status == :ambiguous
          assert Spectre.state(session) == ambiguous.state
          assert Ledger.load_state(ledger, conversation_id).revision == 0
      end

      Ledger.clear_fault(ledger, :state_persist)
      assert :ok = Spectre.dismiss(supervisor, session)
    end)
  end

  test "a store crash after commit is reconciled by restart and the next turn continues" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})
    conversation_id = unique_conversation("after-state-commit")

    assert {:ok, session} =
             summon(supervisor, ledger, conversation_id, state_timeout: 50)

    Ledger.put_fault(ledger, :state_persist, :after_commit_kill)

    assert {:error, {:persistence_ambiguous, %Failure{provider: :state, kind: :crash}, ambiguous}} =
             Spectre.ask(session, "hello")

    assert ambiguous.state.revision == 1
    assert Spectre.state(session) == ambiguous.state
    assert Ledger.load_state(ledger, conversation_id) == ambiguous.state

    Ledger.clear_fault(ledger, :state_persist)
    restarted = crash_and_wait_for_replacement(supervisor, session)
    assert Spectre.state(restarted) == ambiguous.state

    assert {:ok, continued} = Spectre.ask(restarted, "hello")
    assert continued.state.revision == 2
    assert Ledger.load_state(ledger, conversation_id) == continued.state
  end

  test "a strict persistence-journal failure reports the committed state and keeps the Session live" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})
    conversation_id = unique_conversation("journal-after-commit")

    journal =
      {SpectreSystemLifecycleContractTest.Journal,
       [
         events: [:routing, :persistence],
         mode: :sync,
         on_error: :error,
         store_opts: [ledger: ledger]
       ]}

    assert {:ok, session} = summon(supervisor, ledger, conversation_id)
    Ledger.put_fault(ledger, :persistence_journal, true)

    assert {:error,
            {:persistence_journal_failed, {:journal_append_failed, :audit_down}, committed}} =
             Spectre.ask(session, "hello", journal: journal)

    assert committed.state.revision == 1
    assert committed.metadata.state_persistence.status == :committed
    assert Spectre.state(session) == committed.state
    assert Ledger.load_state(ledger, conversation_id) == committed.state

    assert Enum.any?(
             Ledger.events(ledger),
             &match?({:journal_append, :persistence, 1}, &1)
           )

    Ledger.clear_fault(ledger, :persistence_journal)

    assert {:ok, continued} = Spectre.ask(session, "hello", journal: journal)
    assert continued.state.revision == 2
    assert Spectre.state(session) == continued.state
  end

  test "normal dismissal and idle shutdown end Sessions without restarting them" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})

    assert {:ok, dismissed} =
             summon(supervisor, ledger, unique_conversation("dismiss"))

    dismissed_monitor = Process.monitor(dismissed)
    assert :ok = Spectre.dismiss(supervisor, dismissed)
    assert_receive {:DOWN, ^dismissed_monitor, :process, ^dismissed, :shutdown}
    assert eventually(fn -> session_pids(supervisor) end) == []

    assert {:ok, idle} =
             summon(supervisor, ledger, unique_conversation("idle"), idle: 20)

    idle_monitor = Process.monitor(idle)
    assert_receive {:DOWN, ^idle_monitor, :process, ^idle, :normal}, 500
    assert eventually(fn -> session_pids(supervisor) end) == []
  end

  test "every state-restore failure leaves no zombie child and a later healthy start succeeds" do
    ledger = start_supervised!({Elixir.Agent, fn -> ledger_state() end})
    supervisor = start_supervised!({Spectre.Supervisor, []})

    failures = [
      {{:error, :store_down}, :store_down},
      {:raise, %Failure{provider: :state, kind: :exception}},
      {:exit, %Failure{provider: :state, kind: :exit}},
      {:throw, %Failure{provider: :state, kind: :throw}},
      {:kill, %Failure{provider: :state, kind: :crash}},
      {:timeout, %Failure{provider: :state, kind: :timeout}},
      {:invalid, {:invalid_state_reply, :atom}}
    ]

    Enum.each(failures, fn {mode, expected} ->
      Ledger.put_fault(ledger, :state_load, mode)

      assert {:error, {:state_restore_failed, reason}} =
               summon(
                 supervisor,
                 ledger,
                 unique_conversation("restore-failure"),
                 state_timeout: 10
               )

      assert_reason(reason, expected)
      assert session_pids(supervisor) == []
      assert Process.alive?(supervisor)
      Ledger.clear_fault(ledger, :state_load)
    end)

    assert {:ok, session} =
             summon(supervisor, ledger, unique_conversation("restored"))

    assert {:ok, result} = Spectre.ask(session, "hello")
    assert result.reply_text == "reply:hello"
    assert Process.alive?(session)
  end

  defp summon(supervisor, ledger, conversation_id, extra_opts \\ []) do
    {session_opts, runtime_opts} = Keyword.split(extra_opts, [:idle])

    Spectre.summon(
      supervisor,
      LifecycleAgent,
      Keyword.merge(
        [
          conversation_id: conversation_id,
          idle: false,
          opts:
            Keyword.merge(
              [ledger: ledger, test_pid: self()],
              runtime_opts
            )
        ],
        session_opts
      )
    )
  end

  defp crash_and_wait_for_replacement(supervisor, session) do
    monitor = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}

    eventually(fn ->
      case session_pids(supervisor) do
        [replacement] when replacement != session -> replacement
        _other -> nil
      end
    end)
  end

  defp session_pids(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
      _child -> []
    end)
  end

  defp replacement_pid(name, old_pid) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _other -> nil
    end
  end

  defp assert_application_supervisor(supervisor) do
    assert Process.whereis(Spectre.ApplicationSupervisor) == supervisor
    assert Process.alive?(supervisor)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      [] when attempts > 1 ->
        []

      value ->
        value
    end
  end

  defp eventually(fun, 0), do: flunk("condition did not become true: #{inspect(fun)}")

  defp assert_reason(reason, %Failure{provider: provider, kind: kind}) do
    assert %Failure{provider: ^provider, kind: ^kind} = reason
  end

  defp assert_reason(reason, expected), do: assert(reason == expected)

  defp unique_conversation(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp ledger_state do
    %{
      actions: %{},
      action_attempts: %{},
      events: [],
      faults: %{},
      side_effect_count: 0,
      states: %{}
    }
  end
end
