defmodule Spectre.Agents.HandlerAlternativesTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.{Candidate, Instance, Mind}
  alias Spectre.Agent.Runtime
  alias Spectre.V04Test.Fixture

  defmodule Assistant do
    use Spectre.Agent, namespace: "alternatives", name: "assistant"

    @impl true
    def init(:invalid), do: :invalid
    def init(:declined), do: {:error, :initialization_declined}
    def init(:crash), do: raise(ArgumentError, "private initialization detail")
    def init(state), do: {:ok, state}

    @impl true
    def handle_turn(%{payload: %{"text" => mode}}, turn, state) do
      count = if mode == "too many", do: 33, else: 2

      candidates =
        for n <- 1..count do
          attrs = %{state.attrs | identity_key: "alternative:#{turn.ref}:#{n}"}

          attrs =
            put_in(attrs.disclosure.source_evidence_refs, Mind.Turn.evidence_refs(turn.mind_turn))

          attrs = %{attrs | evidence_refs: Mind.Turn.evidence_refs(turn.mind_turn)}
          {:ok, candidate} = Mind.candidate(turn.mind_turn, attrs)
          candidate
        end

      candidates = if mode == "malformed", do: candidates ++ [%{}], else: candidates
      {:request, candidates, %{state | count: state.count + 1}}
    end

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  @moduletag handler: Assistant

  test "an explicit set of alternatives is not a batch of authorized effects", c do
    instance = configured(c)
    assert {:ok, turn} = run_turn(c, instance, "two choices")
    assert [first, selected] = turn.requests
    assert first.candidate.ref != selected.candidate.ref
    refute_received {:handler_execution, _, _, _}
    assert {:ok, completed} = Instance.advance(instance, selected)
    assert completed.result.status == :done
    assert_receive {:handler_execution, _, act, _}
    assert act.candidate_identity_key == selected.candidate.identity_key
    assert {:error, :invalid_or_superseded_instance_request} = Instance.advance(instance, first)
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "overflow or one invalid alternative publishes no partial ticket list", c do
    instance = configured(c)
    before = Instance.state(instance).value
    assert {:error, :too_many_request_alternatives} = run_turn(c, instance, "too many")
    assert Instance.state(instance).value == before
    assert Instance.current_turn(instance).requests == []
    assert {:error, _} = run_turn(c, instance, "malformed")
    assert Instance.state(instance).value == before
    assert Instance.current_turn(instance).requests == []
    refute_received {:handler_execution, _, _, _}
  end

  test "runtime initialization validates callbacks and restored component keys", c do
    for {value, reason} <- [
          invalid: :invalid_agent_init_reply,
          declined: :initialization_declined
        ] do
      assert {:error, ^reason} = Runtime.new(Assistant, c.definition, [], %{}, value)
    end

    assert {:error, {:adapter_callback_exception, Assistant, :init, ArgumentError}} =
             Runtime.new(Assistant, c.definition, [], %{}, :crash)

    assert {:error, :invalid_request_bindings} = Runtime.new(Assistant, c.definition, [], [], nil)

    assert {:error, :invalid_component_states} =
             Runtime.new(Assistant, c.definition, [], %{}, nil, [])

    for states <- [%{42 => :unknown}, %{"support" => 1, "support/" => 2}, %{"broken//key" => 1}] do
      assert {:error, :invalid_component_state_name} =
               Runtime.new(Assistant, c.definition, [], %{}, nil, states)
    end

    # A restored value must not rerun an init that would fail or perform host work.
    assert {:ok, _, :crash} = Runtime.new(Assistant, c.definition, [], %{}, :crash, %{}, true)
  end

  test "invalid flow choices are rejected before observing input", c do
    before = Spectre.Domain.Sequencer.head(c.fixture.server)

    assert {:error, {:unknown_agent_flow, :missing}} =
             Instance.turn(c.instance, input(c, "hello"), flow: :missing)

    assert {:error, :invalid_agent_flow} = Instance.turn(c.instance, input(c, "hello"), flow: 42)
    assert Spectre.Domain.Sequencer.head(c.fixture.server) == before
  end

  defp configured(c) do
    attrs = c.fixture |> Fixture.refund_candidate(25) |> Map.take(Candidate.request_fields())
    state = Map.put(c.state, :attrs, attrs)
    opts = Keyword.put(c.instance_options, :state, state)
    start_supervised!({Instance, opts}, id: :alternatives)
  end

  defp run_turn(c, instance, text),
    do:
      Instance.turn(instance, input(c, text),
        context_evidence_refs: [c.fixture.refs.payment_evidence]
      )
end
