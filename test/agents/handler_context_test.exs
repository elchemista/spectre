defmodule Spectre.Agents.HandlerContextTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Domain.Sequencer
  alias Spectre.Instance
  alias Spectre.Mind.Turn

  defmodule Chat do
    @behaviour Spectre.History
    @impl true
    def load(binding, window, opts) do
      send(opts[:test_pid], {:loaded_chat, self(), binding, window})
      {:ok, %{binding: binding, messages: [opts[:message]], cursor: nil, truncated?: false}}
    end

    @impl true
    def append(_binding, _message, _opts), do: raise("no implicit chat persistence")
    @impl true
    def record_delivery(_binding, _receipt, _opts), do: raise("no implicit delivery")
  end

  defmodule Policy do
    @behaviour Spectre.Memory
    @impl true
    def retrieve(binding, query, opts) do
      send(opts[:test_pid], {:loaded_policy, self(), binding, query})
      {:ok, %{binding: binding, items: [opts[:item]]}}
    end
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "handler-context", name: "assistant"
    history(:chat, keep: 2, max_bytes: 4096)
    memory(:policy, limit: 2, max_bytes: 4096)
    request(:refund, class: "refund.issue")

    @impl true
    def handle_turn(_input, _turn, state), do: {:request, :refund, state.consequence, state}
    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  @moduletag handler: Assistant, configure_adapters: &__MODULE__.adapters/1

  def adapters(c) do
    old_input = input(c, "The parcel arrived damaged; I would prefer a refund.")
    assert {:ok, prior} = Spectre.open_turn(c.scope, old_input)
    [evidence] = prior.evidence

    message = %{
      ref: "chat:prior",
      revision: 0,
      role: :user,
      status: :received,
      content: old_input.payload["text"],
      evidence_refs: [evidence.ref]
    }

    item = %{
      ref: "memory:payment",
      source_ref: c.fixture.refs.order,
      content: "This order has a confirmed payment in EUR.",
      evidence_refs: [c.fixture.refs.payment_evidence]
    }

    %{
      history: %{
        chat:
          {Chat,
           tenant_id: c.fixture.refs.domain,
           conversation_id: "conversation:returns",
           message: message,
           test_pid: self()}
      },
      memory: %{policy: {Policy, tenant_id: c.fixture.refs.domain, item: item, test_pid: self()}}
    }
  end

  test "host history and retrieval become bounded evidence-backed context in a complete agent",
       c do
    assert {:ok, turn} = Instance.turn(c.instance, input(c, "Please refund the order."))
    assert_receive {:loaded_chat, worker, binding, %{keep: 2, max_bytes: 4096}}
    assert_receive {:loaded_policy, ^worker, %{tenant_id: tenant}, %{limit: 2, max_bytes: 4096}}
    refute worker == c.instance
    refute worker == c.fixture.server
    assert binding.tenant_id == tenant
    assert tenant == c.fixture.refs.domain
    assert [%{status: :received}] = turn.context.history
    assert [%{source_ref: source}] = turn.context.memory
    assert source == c.fixture.refs.order
    assert [request] = turn.requests
    refs = Turn.evidence_refs(turn.mind_turn)

    assert Enum.all?(turn.context.history ++ turn.context.memory, fn item ->
             Enum.all?(item.evidence_refs, &(&1 in refs))
           end)

    assert {:ok, %{result: %{status: :done}}} = Instance.advance(c.instance, request)
    assert_receive {:handler_execution, _, _, _}
    assert_replay(c)
  end

  test "an unbacked chat window cannot reach the handler or prepare a request", c do
    opts = c.instance_options
    adapters = opts[:adapters]
    {module, history_opts} = adapters.history.chat
    history_opts = Keyword.update!(history_opts, :message, &%{&1 | evidence_refs: []})
    adapters = put_in(adapters.history.chat, {module, history_opts})

    instance =
      start_supervised!(
        Supervisor.child_spec({Instance, Keyword.put(opts, :adapters, adapters)}, id: :unbacked)
      )

    before = Sequencer.projection(c.fixture.server)
    assert {:error, :context_evidence_required} = Instance.turn(instance, input(c, "Refund me."))
    assert Instance.current_turn(instance) == nil
    assert Sequencer.projection(c.fixture.server) === before
    refute_received {:handler_execution, _, _, _}
  end

  test "referencing absent evidence cannot launder retrieved text into the sealed turn", c do
    opts = c.instance_options
    adapters = opts[:adapters]
    {module, memory_opts} = adapters.memory.policy

    memory_opts =
      Keyword.update!(memory_opts, :item, &%{&1 | evidence_refs: ["evidence:invented"]})

    adapters = put_in(adapters.memory.policy, {module, memory_opts})

    instance =
      start_supervised!(
        Supervisor.child_spec({Instance, Keyword.put(opts, :adapters, adapters)}, id: :foreign)
      )

    before = Sequencer.projection(c.fixture.server).decisions
    assert {:error, _} = Instance.turn(instance, input(c, "Refund me."))
    assert Instance.current_turn(instance) == nil
    assert Sequencer.projection(c.fixture.server).decisions === before
    refute_received {:handler_execution, _, _, _}
  end
end
