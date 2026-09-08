defmodule Spectre.SemanticCache.RealAgentTest do
  @moduledoc false
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Instance
  alias Spectre.Router.SemanticCache
  alias Spectre.SemanticCache.Test.CustomerSupport
  alias Spectre.SemanticCache.Vettore, as: Cache
  alias Spectre.Test.HandlerAgentCase.{Billing, Defaults}

  defmodule Message do
    @behaviour Spectre.Input.Plug
    @impl true
    def call(%{payload: %{"text" => envelope}}, _options), do: {:cont, envelope}
  end

  defmodule Support do
    use Spectre.Agent, namespace: "retailer", name: "support", stack: Defaults
    request(:refund, class: "refund.issue")
    skill(Billing, as: :billing)
    skill(Billing, as: :returns)

    flow :support do
      pipe_through(:text)
      router(via: [:semantic_cache], cache: :routing, accept: 0.70, margin: 0.03)
      route(:refund, cache: true)
    end

    @impl true
    def handle_turn({:support, :refund, _source}, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    def handle_turn({:support, :no_match, _input}, _turn, state), do: {:ok, state}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  @moduletag handler: Support,
             standard_wiring: true,
             cache_backend: Cache,
             cache_options: [dimensions: 384],
             cache_profile: CustomerSupport.profile(),
             input_plugs: [Message],
             timeout: 180_000

  setup_all do
    %{vectors: CustomerSupport.embed!()}
  end

  setup c do
    for {"refund", text} <- CustomerSupport.examples() do
      {:ok, example} =
        SemanticCache.put(c.cache, %{
          text: text,
          label: "support/refund",
          embedding: c.vectors[text],
          profile_ref: CustomerSupport.profile()
        })

      {:ok, _approved} = SemanticCache.verify(c.cache, example.id, example.revision)
    end

    :ok
  end

  test "real customer paraphrase traverses embedding, Vettore, handler, GAM, executor and audit",
       c do
    {"refund", text} = hd(CustomerSupport.queries())

    envelope = %{
      "text" => text,
      "embedding" => c.vectors[text],
      "profile_ref" => CustomerSupport.profile()
    }

    {turn, request} = prepare(c, envelope)
    assert turn.selection.via == "semantic_cache"
    assert turn.selection.score > 0.70
    refute_received {:handler_execution, _, _, _}
    assert {:ok, completed} = Instance.advance(c.instance, request)
    assert completed.result.status == :done
    assert completed.result.learning == :not_requested
    assert_receive {:handler_execution, _pid, act, attempt}
    assert act.candidate_identity_key == request.candidate.identity_key
    assert completed.result.details.primary.attempt == attempt
    assert Instance.state(c.instance).value.result == :done
    assert_replay(c)
  end

  test "a real embedding does not give unrelated customer input permission to execute", c do
    text = CustomerSupport.unrelated()

    envelope = %{
      "text" => text,
      "embedding" => c.vectors[text],
      "profile_ref" => CustomerSupport.profile()
    }

    assert {:ok, %{requests: []}} = Instance.turn(c.instance, input(c, envelope), flow: :support)
    assert Instance.state(c.instance).value.count == 0
    refute_received {:handler_execution, _, _, _}
    assert_replay(c)
  end
end
