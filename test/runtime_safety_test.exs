defmodule SpectreRuntimeSafetyTest do
  use ExUnit.Case, async: false

  alias Spectre.Effect
  alias Spectre.State

  defmodule Actions do
    def succeed(args), do: {:ok, args}
    def return_error(_args), do: {:error, :denied}
    def explode(_args), do: raise("boom")

    def capture(_args, ctx) do
      send(
        Keyword.fetch!(ctx.opts, :test_pid),
        {:action_context, ctx.opts[:effect_id], ctx.opts[:idempotency_key]}
      )

      :captured
    end
  end

  defmodule OtherActions do
    def dangerous(_args), do: :dangerous
  end

  defmodule ActionAgent do
    use Spectre.Agent
    actions(SpectreRuntimeSafetyTest.Actions)
  end

  defmodule FailingStateStore do
    def load(_input, _agent, _opts), do: {:error, :store_unavailable}
  end

  defmodule RestoreAgent do
    use Spectre.Agent
    state(SpectreRuntimeSafetyTest.FailingStateStore)
  end

  defmodule IdleAgent do
    use Spectre.Agent
    idle(5)
  end

  defmodule RecordingStateStore do
    def load(_input, _agent, _opts), do: {:ok, %Spectre.State{}}

    def persist(state, _input, _agent, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:state_persisted, state})
      :ok
    end
  end

  defmodule FailingMemoryStore do
    def remember(_payload, _opts), do: {:error, :memory_unavailable}
  end

  defmodule PersistenceAgent do
    use Spectre.Agent
    state(SpectreRuntimeSafetyTest.RecordingStateStore)
    memory(SpectreRuntimeSafetyTest.FailingMemoryStore)
  end

  test "effects and awaitables use durable UUIDv7 identities" do
    effect = Effect.stage(%{name: :succeed})
    awaitable = Spectre.Awaitable.open_policy(:confirm, effect)

    assert effect.id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert awaitable.id =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert effect.idempotency_key == "effect:" <> effect.id
  end

  test "a protected effect cannot execute before approval" do
    state =
      %State{}
      |> State.put_pending_effect(Effect.stage(%{name: :succeed}), :confirmation)

    effect = State.pending_effect(state)
    effect_id = effect.id

    assert {:error, {:effect_not_approved, ^effect_id}} =
             Spectre.execute(state, %{agent: ActionAgent})
  end

  test "an action error becomes a failed effect" do
    state =
      %State{}
      |> State.put_pending_effect(Effect.stage(%{name: :return_error}), nil)

    assert {:ok, result} = Spectre.execute(state, %{agent: ActionAgent})

    assert [%Effect{status: :failed, error: :denied}] = result.effects
    assert result.state.pending_effects == []
    assert [%{type: :effect_failed, error: :denied}] = result.events
  end

  test "an action exception becomes a failed effect without crashing the caller" do
    state =
      %State{}
      |> State.put_pending_effect(Effect.stage(%{name: :explode}), nil)

    assert {:ok, result} = Spectre.execute(state, %{agent: ActionAgent})

    assert [
             %Effect{
               status: :failed,
               error: {:action_exception, Actions, :explode, %RuntimeError{message: "boom"}}
             }
           ] = result.effects
  end

  test "a selected tool cannot escape the configured action module" do
    effect =
      Effect.stage(%{
        name: :dangerous,
        payload: %{
          selected_tool: "Elixir.SpectreRuntimeSafetyTest.OtherActions.dangerous/1"
        }
      })

    state = State.put_pending_effect(%State{}, effect, nil)

    assert {:ok, result} = Spectre.execute(state, %{agent: ActionAgent})

    assert [
             %Effect{
               status: :failed,
               error:
                 {:unauthorized_action_module, OtherActions,
                  Actions}
             }
           ] = result.effects
  end

  test "effect identity is injected into the action context" do
    effect = Effect.stage(%{name: :capture})
    state = State.put_pending_effect(%State{}, effect, nil)

    assert {:ok, result} =
             Spectre.execute(state, %{agent: ActionAgent, opts: [test_pid: self()]})

    assert [%Effect{status: :completed}] = result.effects

    effect_id = effect.id
    idempotency_key = effect.idempotency_key
    assert_receive {:action_context, ^effect_id, ^idempotency_key}
  end

  test "memory failure does not roll back already persisted machine state" do
    assert {:ok, result} =
             Spectre.ask(PersistenceAgent, "hello", test_pid: self())

    assert_receive {:state_persisted, persisted}
    assert persisted == result.state

    assert %{type: :memory_persist_failed, error: :memory_unavailable} in result.events

    assert [
             %{type: :memory_persist_failed, error: :memory_unavailable}
           ] = result.metadata.persistence_warnings
  end

  test "strict memory persistence returns and retains the already committed state" do
    assert {:error, {:memory_persist_failed, :memory_unavailable, result}} =
             Spectre.ask(PersistenceAgent, "hello",
               test_pid: self(),
               memory_persist_failure: :error
             )

    assert_receive {:state_persisted, persisted}
    assert persisted == result.state

    session =
      start_supervised!(
        {Spectre.Session,
         agent: PersistenceAgent,
         id: :strict_memory_session,
         opts: [test_pid: self(), memory_persist_failure: :error]}
      )

    assert {:error, {:memory_persist_failed, :memory_unavailable, session_result}} =
             Spectre.ask(session, "hello")

    assert_receive {:state_persisted, session_persisted}
    assert session_persisted == session_result.state
    assert Spectre.state(session) == session_result.state
  end

  test "session startup fails when durable state cannot be restored" do
    assert {:error, :store_unavailable} =
             Spectre.Runtime.restore_state(RestoreAgent, [])

    Process.flag(:trap_exit, true)

    assert {:error, {:state_restore_failed, :store_unavailable}} =
             Spectre.summon(agent: RestoreAgent)
  end

  test "explicit idle false overrides the agent timeout" do
    pid = start_supervised!({Spectre.Session, agent: IdleAgent, idle: false})
    assert :sys.get_state(pid).idle_timeout == false
  end

  test "semantic cache tables belong to the supervised owner" do
    owner = Process.whereis(Spectre.Router.SemanticCache.Owner)

    assert is_pid(owner)
    assert :ets.info(Spectre.Router.SemanticCache.Learned, :owner) == owner
  end

  test "semantic vector collections survive the lookup process and discard duplicate builds" do
    owner = Process.whereis(Spectre.Router.SemanticCache.Owner)

    assert {:ok, first} =
             Spectre.Router.SemanticCache.Owner.new_collection(
               dimensions: 2,
               metric: :cosine,
               index: :flat
             )

    assert {:ok, duplicate} =
             Spectre.Router.SemanticCache.Owner.new_collection(
               dimensions: 2,
               metric: :cosine,
               index: :flat
             )

    first_table = first.store_state.table
    duplicate_table = duplicate.store_state.table
    assert :ets.info(first_table, :owner) == owner
    assert :ets.info(duplicate_table, :owner) == owner

    key = {{:agent, __MODULE__}, :duplicate_build}
    first_index = %{collection: first, inserted_at: 1}
    duplicate_index = %{collection: duplicate, inserted_at: 2}

    assert {:ok, ^first_index} =
             Spectre.Router.SemanticCache.Owner.cache_index(
               Spectre.Router.SemanticCache.Learned,
               key,
               first_index,
               4
             )

    assert {:ok, ^first_index} =
             Spectre.Router.SemanticCache.Owner.cache_index(
               Spectre.Router.SemanticCache.Learned,
               key,
               duplicate_index,
               4
             )

    assert :undefined == :ets.info(duplicate_table)
    assert :ok = Spectre.Router.SemanticCache.Owner.clear_indexes(__MODULE__)
    assert :undefined == :ets.info(first_table)
  end
end
