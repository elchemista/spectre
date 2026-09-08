defmodule Spectre.Agents.HandlerBoundariesTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Instance
  alias Spectre.Store.Memory, as: ApplicationStore

  defmodule Assistant do
    use Spectre.Agent, namespace: "handler-boundaries", name: "assistant"
    request(:refund, class: "refund.issue")

    @impl true
    def handle_turn(%{payload: %{"text" => "slow"}}, _turn, state) do
      send(state.observer, {:handler_blocked, self()})
      receive do: (:release -> :ok)
      {:ok, Map.update!(state, :count, &(&1 + 1))}
    end

    def handle_turn(%{payload: %{"text" => "raise"}}, _turn, _state),
      do: raise("private-provider-payload")

    def handle_turn(%{payload: %{"text" => "invalid"}}, _turn, _state), do: :not_a_reply

    def handle_turn(%{payload: %{"text" => "decline"}}, _turn, state),
      do: {:error, :host_declined, %{state | count: state.count + 1}}

    def handle_turn(_input, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    @impl true
    def handle_result(_operation, result, _turn, state) do
      if state[:fail_result], do: raise("private-continuation-data")
      {:ok, Map.put(state, :result, result.status)}
    end
  end

  @moduletag handler: Assistant

  test "a small no-router agent needs no Skills, Stack, or custom request adapter", c do
    assert {:ok, turn} = turn(c, "refund")
    assert turn.flow == nil
    assert turn.selection == nil
    assert [request] = turn.requests
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert completed.result.status == :done
    assert_replay(c)
  end

  test "callback exceptions and malformed replies do not advance application state", c do
    before = Instance.state(c.instance)

    for {message, revision} <- [{"raise", 1}, {"invalid", 2}] do
      assert {:error, reason} = turn(c, message)
      refute inspect(reason) =~ "private-provider-payload"
      assert Instance.state(c.instance).value == before.value
      # The new turn still supersedes old tickets even when its handler fails.
      assert Instance.state(c.instance).revision == revision
      assert Instance.current_turn(c.instance).requests == []
    end

    refute_received {:handler_execution, _, _, _}
  end

  test "an explicit handler error may save application state without inventing a Decision", c do
    before = Sequencer.projection(c.fixture.server).decisions
    assert {:error, :host_declined} = turn(c, "decline")
    assert Instance.state(c.instance).value.count == 1
    assert Sequencer.projection(c.fixture.server).decisions === before
    refute_received {:handler_execution, _, _, _}
  end

  test "an already queued turn fences a ticket reserved from the last completed state", c do
    instance = start_instance(c, state: Map.put(c.state, :observer, self()))
    c = %{c | instance: instance}
    assert {:ok, %{requests: [old]}} = turn(c, "refund")
    pending_turn = Task.async(fn -> turn(c, "slow") end)
    assert_receive {:handler_blocked, worker}
    assert Instance.state(instance, 200).value.count == 1
    assert {:pending, ref} = Instance.advance(instance, old, wait: 0)
    send(worker, :release)
    assert {:ok, _} = Task.await(pending_turn)
    # A queued mutation is a barrier for the preceding rejected advance.
    assert {:ok, _} = turn(c, "refund")
    assert {:error, :stale_instance_request} = Instance.operation(instance, ref)
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "the same published code on another Instance cannot consume the original ticket", c do
    assert {:ok, %{requests: [request]}} = turn(c, "refund")
    other = start_instance(c)
    assert {:error, :invalid_or_superseded_instance_request} = Instance.advance(other, request)
    assert {:ok, %{result: %{status: :done}}} = Instance.advance(c.instance, request)
    assert_receive {:handler_execution, _, _, _}
    refute_received {:handler_execution, _, _, _}
  end

  test "a failed continuation cannot erase or automatically replay the completed external effect",
       c do
    instance = start_instance(c, state: Map.put(c.state, :fail_result, true))
    assert {:ok, %{requests: [request]}} = turn(%{c | instance: instance}, "refund")
    assert {:error, reason} = Instance.advance(instance, request)
    refute inspect(reason) =~ "private-continuation-data"
    assert_receive {:handler_execution, _, act, _}
    assert {:ok, view} = Spectre.view(c.scope)
    assert Enum.any?(view.outcomes, &(&1.act_ref == act.ref and &1.status == :succeeded))
    assert {:error, :invalid_or_superseded_instance_request} = Instance.advance(instance, request)
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "restored application state cannot resurrect an unsubmitted request or its authority", c do
    assert {:ok, %{requests: [request]}} = turn(c, "refund")
    server = start_supervised!(ApplicationStore)
    store = {ApplicationStore, server: server}
    assert {:ok, 1} = Instance.checkpoint(c.instance, store, "draft", 0)

    opts =
      c.instance_options
      |> Keyword.drop([:state, :component_states])
      |> Keyword.put(:checkpoint, {store, "draft"})

    restored = start_supervised!(Supervisor.child_spec({Instance, opts}, id: :restored))
    assert Instance.state(restored).value == Instance.state(c.instance).value
    assert Instance.current_turn(restored) == nil
    assert {:error, :invalid_or_superseded_instance_request} = Instance.advance(restored, request)
    refute_received {:handler_execution, _, _, _}
  end

  defp turn(c, text),
    do:
      Instance.turn(c.instance, input(c, text),
        context_evidence_refs: [c.fixture.refs.payment_evidence]
      )

  defp start_instance(c, overrides \\ []) do
    opts = Keyword.merge(c.instance_options, overrides)
    start_supervised!(Supervisor.child_spec({Instance, opts}, id: make_ref()))
  end
end
