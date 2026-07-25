defmodule SpectreRouterReceiptFailureContractTest.ErrorPipeline do
  @moduledoc false

  def call(_context), do: {:error, :router_dependency_down}
end

defmodule SpectreRouterReceiptFailureContractTest.InvalidPipeline do
  @moduledoc false

  def call(_context), do: {:unexpected, %{private: "must not leak"}}
end

defmodule SpectreRouterReceiptFailureContractTest.Agent do
  @moduledoc false
  use Spectre.Agent

  router(
    via: [:arbitrate, :terminalize],
    semantic_cache?: false,
    classification_log?: false
  )

  flow :main do
    on :SAFE, regex: ~r/^safe$/ do
      reply("safe")
    end
  end
end

defmodule SpectreRouterReceiptFailureContractTest.RaisingAgent do
  @moduledoc false

  def __spectre_config__, do: raise("private configuration failure")
  def __spectre_router__, do: []
  def __spectre_rules__, do: []
end

defmodule SpectreRouterReceiptFailureContractTest.ThrowingAgent do
  @moduledoc false

  def __spectre_config__, do: throw(:private_configuration_throw)
  def __spectre_router__, do: []
  def __spectre_rules__, do: []
end

defmodule SpectreRouterReceiptFailureContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Input
  alias Spectre.Route
  alias Spectre.Router
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context, as: RouterContext
  alias Spectre.Router.Receipt
  alias Spectre.State

  @agent SpectreRouterReceiptFailureContractTest.Agent

  test "receipt sanitization strips malformed labels, traces, explanations, errors, and calls" do
    route =
      Route.new(%{
        label: "private-label",
        scope: {:skill, self()},
        strategy: "private-strategy",
        accepted?: true
      })

    candidate =
      Candidate.new(%{
        label: "private-candidate",
        scope: {:skill, self()},
        provider: "private-provider",
        score: "private-score",
        margin: %{private: true},
        strength: "private-strength",
        accepted?: true
      })

    context = %RouterContext{
      input: Input.new("private raw input"),
      labels: [:SAFE],
      route: route,
      candidates: [candidate],
      traces: [
        {:local_uncertain, %{label: :SAFE, raw: "private"}},
        {:local_label_not_routeable, route},
        {:llm_arbitration_skipped, {:secret_reason, "private"}},
        {:unknown_trace, "private"}
      ],
      arbitration: %{
        outcome: :unknown,
        reason: :no_decision,
        thresholds: "private-thresholds",
        candidates: [123]
      },
      errors: [%{private: "error"}]
    }

    receipt = Receipt.from_context(context, -10, [123])

    assert receipt.label == nil
    assert receipt.scope == nil
    assert receipt.strategy == nil
    assert receipt.duration_us == 0
    assert receipt.error == :unknown_error

    assert receipt.provider_calls == [
             %{provider: :unknown, outcome: :unknown, duration_us: 0, invoked?: false}
           ]

    assert receipt.arbitration.thresholds == %{}
    assert receipt.arbitration.candidates == [%{}]

    assert Enum.any?(
             receipt.attempts,
             &match?(%{provider: :local_classifier, result: :uncertain}, &1)
           )

    assert Enum.any?(
             receipt.attempts,
             &match?(%{provider: :local_classifier, result: :unrouteable}, &1)
           )

    assert Enum.any?(
             receipt.attempts,
             &match?(%{provider: :llm_classifier, result: :skipped}, &1)
           )

    refute inspect(receipt) =~ "private raw input"
    refute inspect(receipt) =~ "private-label"
  end

  test "error receipts and invalid provider-call containers stay privacy safe" do
    assert %Receipt{
             outcome: :error,
             error: :timeout,
             duration_us: 0,
             provider_calls: []
           } = Receipt.from_error({:timeout, "private details"}, -1)

    context = %RouterContext{
      input: Input.new("secret"),
      labels: [],
      traces: [],
      candidates: [],
      errors: []
    }

    assert Receipt.from_context(context, 1, %{private: "not a call list"}).provider_calls == []
  end

  test "custom pipeline errors and malformed replies become typed provider failures" do
    input = Input.new("safe")
    ctx = %Context{agent: @agent, input: input, state: %State{}, opts: []}

    assert {:error, :router_dependency_down} =
             Router.route_context(input, %{
               ctx
               | opts: [pipeline: SpectreRouterReceiptFailureContractTest.ErrorPipeline]
             })

    assert {:error, %Spectre.Provider.Failure{provider: :router, kind: :invalid_reply}} =
             Router.route_context(input, %{
               ctx
               | opts: [pipeline: SpectreRouterReceiptFailureContractTest.InvalidPipeline]
             })
  end

  test "explicit arbitration and terminalization stages are not duplicated" do
    input = Input.new("safe")

    ctx = %Context{
      agent: @agent,
      input: input,
      state: %State{},
      opts: [via: [:arbitrate, :terminalize, :unknown_strategy]]
    }

    assert {:ok, %RouterContext{} = routed} = Router.route_context(input, ctx)
    assert Enum.count(routed.traces, &match?({:arbitrated, _route}, &1)) <= 1

    assert {:ok, %Route{label: :unknown, accepted?: false}} =
             Router.route_from_context(%RouterContext{
               input: Input.new("no matching fallback"),
               labels: [:SAFE],
               rules: []
             })
  end

  test "router evaluation contains agent exceptions, throws, and malformed recovery state" do
    assert {:ok, %Receipt{outcome: :error, error: :routing_evaluation_exception}} =
             Router.evaluate(SpectreRouterReceiptFailureContractTest.RaisingAgent, "safe")

    assert {:ok, %Receipt{outcome: :error, error: :routing_evaluation_failure}} =
             Router.evaluate(SpectreRouterReceiptFailureContractTest.ThrowingAgent, "safe")

    assert {:ok, %Receipt{outcome: :clarify}} =
             Router.evaluate(@agent, "safe", state: %State{data: %{checkpoint: :restored}})

    assert {:ok, %Receipt{outcome: :error, error: :invalid_evaluation_state}} =
             Router.evaluate(@agent, "safe", state: [:not_a_key_value_pair])

    assert {:ok, %Receipt{outcome: :clarify}} =
             Router.evaluate(@agent, "safe", state: %{"data" => %{"checkpoint" => "restored"}})
  end
end
