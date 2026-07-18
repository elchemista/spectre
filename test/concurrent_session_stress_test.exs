defmodule SpectreConcurrentSessionStressTest.AtomicStore do
  @moduledoc false
  @behaviour Spectre.State.Store

  alias Spectre.State

  @impl Spectre.State.Store
  @spec load(Spectre.Input.t(), module(), keyword()) :: {:ok, State.t()}
  def load(_input, _agent, opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    store = Keyword.fetch!(opts, :store)

    state =
      Elixir.Agent.get(store, fn states ->
        Map.get(states, conversation_id, %State{conversation_id: conversation_id})
      end)

    {:ok, state}
  end

  @impl Spectre.State.Store
  @spec compare_and_swap(State.t(), non_neg_integer(), Spectre.Input.t(), module(), keyword()) ::
          {:ok, State.t()} | {:error, {:stale_state, non_neg_integer()}}
  def compare_and_swap(%State{} = state, expected, _input, _agent, opts) do
    store = Keyword.fetch!(opts, :store)

    Elixir.Agent.get_and_update(store, fn states ->
      current = Map.get(states, state.conversation_id, %State{})

      if current.revision == expected do
        {{:ok, state}, Map.put(states, state.conversation_id, state)}
      else
        {{:error, {:stale_state, current.revision}}, states}
      end
    end)
  end
end

defmodule SpectreConcurrentSessionStressTest.Actions do
  @moduledoc false

  @spec perform(map(), Spectre.Context.t()) :: {:ok, map()}
  def perform(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:performed, args})
    {:ok, args}
  end
end

defmodule SpectreConcurrentSessionStressTest.SlowActions do
  @moduledoc false

  @spec perform(map(), Spectre.Context.t()) :: {:ok, map()}
  def perform(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:slow_action_started, self()})

    receive do
      :finish -> {:ok, args}
    end
  end
end

defmodule SpectreConcurrentSessionStressTest.CASAgent do
  @moduledoc false

  use Spectre.Agent

  state(SpectreConcurrentSessionStressTest.AtomicStore)
  actions(SpectreConcurrentSessionStressTest.Actions)

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{source: :cas})
    end
  end
end

defmodule SpectreConcurrentSessionStressTest.PolicyAgent do
  @moduledoc false

  use Spectre.Agent

  actions SpectreConcurrentSessionStressTest.Actions do
    protect(:perform, with: :confirmation)
  end

  policy :confirmation do
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{source: :policy})
    end
  end
end

defmodule SpectreConcurrentSessionStressTest.SlowActionAgent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreConcurrentSessionStressTest.SlowActions)

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{source: :timeout})
    end
  end
end

defmodule SpectreConcurrentSessionStressTest do
  use ExUnit.Case, async: false

  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.State

  @session_count 6

  test "concurrent Sessions isolate provider timeouts and remain available" do
    test_pid = self()
    sessions = start_sessions(SpectreConcurrentSessionStressTest.SlowActionAgent)

    staged =
      concurrently(sessions, fn session ->
        {session, Spectre.ask(session, "perform")}
      end)
      |> Enum.map(fn {session, {:ok, %Result{} = result}} -> {session, result} end)

    outcomes =
      concurrently(staged, fn {session, result} ->
        Spectre.execute(session, result, action_timeout: 10, test_pid: test_pid)
      end)

    assert Enum.all?(outcomes, fn
             {:ok,
              %Result{
                effects: [
                  %Effect{
                    status: :failed,
                    error:
                      {:action_outcome_ambiguous, %Failure{provider: :action, kind: :timeout}}
                  }
                ]
              }} ->
               true

             _other ->
               false
           end)

    workers =
      Enum.map(sessions, fn _session ->
        assert_receive {:slow_action_started, worker}
        worker
      end)

    assert Enum.all?(workers, &(not Process.alive?(&1)))
    assert Enum.all?(sessions, &Process.alive?/1)
    assert Enum.all?(sessions, &match?(%State{pending_effects: []}, Spectre.state(&1)))
  end

  test "one concurrent policy resolution and action completion wins per Session" do
    test_pid = self()

    state =
      %State{}
      |> State.put_pending_effect(
        Effect.stage_action(
          %{name: :perform, args: %{source: :policy}},
          SpectreConcurrentSessionStressTest.PolicyAgent,
          :agent
        ),
        :confirmation
      )

    staged = %Result{
      input: Input.new("perform"),
      state: state,
      effects: [State.pending_effect(state)],
      awaitables: [State.open_policy_awaitable(state)]
    }

    session =
      start_session(SpectreConcurrentSessionStressTest.PolicyAgent,
        state: state,
        opts: [test_pid: test_pid]
      )

    resolutions =
      concurrently(1..@session_count, fn _index ->
        Spectre.resolve_policy(session, staged, {:accept, :accepted})
      end)

    approved = for {:ok, %Result{} = result} <- resolutions, do: result
    rejected = for {:error, reason} <- resolutions, do: reason

    assert [%Result{} = approved_result] = approved
    assert length(rejected) == @session_count - 1
    assert Enum.all?(rejected, &(&1 == :no_open_policy))

    completions =
      concurrently(1..@session_count, fn _index ->
        Spectre.execute(session, approved_result, test_pid: test_pid)
      end)

    assert Enum.all?(completions, fn
             {:ok, %Result{effects: [%Effect{status: :completed, result: %{source: :policy}}]}} ->
               true

             _other ->
               false
           end)

    assert_receive {:performed, %{source: :policy}}
    refute_receive {:performed, %{source: :policy}}
    assert %State{pending_effects: []} = Spectre.state(session)
  end

  test "state CAS admits one of several concurrent Sessions at the same revision" do
    conversation_id = "concurrent-cas-#{System.unique_integer([:positive])}"
    store = start_supervised!({Elixir.Agent, fn -> %{} end})

    sessions =
      start_sessions(SpectreConcurrentSessionStressTest.CASAgent,
        conversation_id: conversation_id,
        opts: [store: store]
      )

    outcomes = concurrently(sessions, &Spectre.ask(&1, "perform"))
    committed = for {:ok, %Result{} = result} <- outcomes, do: result
    stale = for {:error, reason} <- outcomes, do: reason

    assert [%Result{state: %State{revision: 1}}] = committed
    assert length(stale) == @session_count - 1
    assert Enum.all?(stale, &(&1 == {:stale_state, 0, 1}))

    persisted = Elixir.Agent.get(store, &Map.fetch!(&1, conversation_id))
    assert persisted.revision == 1
  end

  @spec start_sessions(module(), keyword()) :: [pid()]
  defp start_sessions(agent, opts \\ []) do
    Enum.map(1..@session_count, fn _index -> start_session(agent, opts) end)
  end

  @spec start_session(module(), keyword()) :: pid()
  defp start_session(agent, opts) do
    id = {:concurrent_session_stress, System.unique_integer([:positive])}
    session_opts = Keyword.merge([agent: agent, id: id, idle: false], opts)
    start_supervised!({Spectre.Session, session_opts})
  end

  @spec concurrently(Enumerable.t(), (term() -> term())) :: [term()]
  defp concurrently(enumerable, fun) do
    items = Enum.to_list(enumerable)

    items
    |> Task.async_stream(fun,
      max_concurrency: length(items),
      ordered: false,
      timeout: 5_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end
end
