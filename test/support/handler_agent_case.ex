defmodule Spectre.Test.HandlerAgentCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.{Audit, Instance, Ledger}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.SemanticCache.Exact
  alias Spectre.V04Test.{Fixture, Runtime}

  using do
    quote do
      import Spectre.Test.HandlerAgentCase, only: [input: 2, prepare: 2, assert_replay: 1]
    end
  end

  defmodule Text do
    @moduledoc false
    @behaviour Spectre.Input.Plug
    @impl true
    def call(%{payload: %{"text" => text}}, _opts), do: {:cont, text}
  end

  defmodule Routes do
    @moduledoc false
    use Spectre.Router

    flow :support do
      pipe_through(:text)
      router(via: [:regex, :string_bag, :semantic_cache], cache: :routing, accept: 0.9)

      route(:refund,
        match: [regex: ~r/^refund (?<amount>[0-9]+)$/, string_bag: ["refund my order"]],
        cache: true
      )
    end

    flow :uncertain do
      pipe_through(:text)
      router(via: [:regex])
      route(:first, match: [regex: ~r/^both$/])
      route(:second, match: [regex: ~r/^both$/])
    end
  end

  defmodule Defaults do
    @moduledoc false
    use Spectre.Stack
    semantic_cache(:routing, learn: :review)
    adapter(:observer, :events, Spectre.Agent.Observer)
  end

  defmodule Billing do
    @moduledoc false
    use Spectre.Skill, namespace: "handler-tests", name: "billing"
    request(:refund, class: "refund.issue")

    flow :support do
      pipe_through(:text)
      router(via: [:regex])
      route(:refund, match: [regex: ~r/^refund$/])
    end

    @impl true
    def handle_turn({:support, :refund, _captures}, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  defmodule Assistant do
    @moduledoc false
    use Spectre.Agent, namespace: "handler-tests", name: "assistant", stack: Defaults
    router(Routes)
    request(:refund, class: "refund.issue")
    skill(Billing, as: :billing)
    skill(Billing, as: :returns)

    @impl true
    def handle_turn({:support, :refund, captures}, _turn, state) do
      amount = if captures["amount"], do: String.to_integer(captures["amount"]), else: 100
      [meter] = Map.keys(state.consequence["meter_requests"])

      consequence =
        Map.merge(state.consequence, %{
          "amount_cents" => amount,
          "meter_requests" => %{meter => amount}
        })

      {:request, :refund, consequence, %{state | count: state.count + 1}}
    end

    def handle_turn({_flow, status, _details}, _turn, state),
      do: {:ok, Map.put(state, :last_route, status)}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  defmodule Executor do
    @moduledoc false
    @behaviour Spectre.Attempt.Executor
    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor

    @impl true
    def execute(act, attempt, _capability, opts) do
      send(opts[:observer], {:handler_execution, self(), act, attempt})
      if opts[:gated], do: wait_for_release(Keyword.get(opts, :timeout, :infinity))
      status = Keyword.get(opts, :status, :succeeded)

      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(), payload: "receipt")

      metadata = %{evidence: [evidence], details_ref: "receipt:handler-test"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end

    # Model a host adapter's bounded provider call. The execution boundary must
    # turn a timeout exit into uncertainty, not a claim that no effect occurred.
    defp wait_for_release(timeout) do
      receive do
        :release -> :ok
      after
        timeout -> exit(:provider_timeout)
      end
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    module = Map.get(tags, :handler, Assistant)

    components =
      Map.new(module.__spectre_plan__().components, fn {name, entry} ->
        {name, entry.module.definition(revision: 1, declared_at: Runtime.now())}
      end)

    definition =
      module.definition(revision: 1, declared_at: Runtime.now(), components: components)

    namespace = "handler-#{System.unique_integer([:positive])}"
    name = {:via, Registry, {Spectre.Domain.Registry, "v0.4:#{namespace}:domain"}}

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: name,
        mind: Spectre.Agent,
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref],
        executors: [
          {Executor,
           observer: self(),
           status: Map.get(tags, :status, :succeeded),
           gated: tags[:gated],
           timeout: Map.get(tags, :executor_timeout, :infinity)}
        ]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))
    assert {:ok, _payment} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))

    {:ok, admin} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture,
          authenticated_principal_ref: fixture.refs.grantor
        )
      )

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(admin, definition,
               identity_key: "publish-handler",
               requested_mandate_ref: fixture.governance_mandate.ref,
               accountable_ref: fixture.refs.accountable,
               purpose_ref: fixture.refs.purpose,
               purpose_params: %{"currency" => "EUR"}
             )

    {:ok, pipeline} =
      Pipeline.new(Map.get(tags, :input_plugs, [Text, {NormalizeText, case: :downcase}]))

    backend = Map.get(tags, :cache_backend, Exact)

    binding = %{
      namespace: namespace,
      definition_ref: definition.ref,
      flow: "support",
      profile_ref: Map.get(tags, :cache_profile)
    }

    cache_options =
      Map.to_list(binding) ++
        [labels: ["support/refund"], max_entries: 20] ++
        Map.get(tags, :cache_options, [])

    cache_server = start_supervised!({backend, cache_options})
    {:ok, cache} = SemanticCache.bind({backend, server: cache_server}, binding)
    attrs = Fixture.refund_candidate(fixture, 100)

    class_binding =
      Map.take(attrs, [
        :requested_mandate_ref,
        :executor_ref,
        :executor_contract_ref,
        :accountable_ref,
        :purpose_ref,
        :purpose_params,
        :observation_window_ms
      ])

    state = %{count: 0, consequence: attrs.consequence}

    adapters = %{
      pipelines:
        Map.new(["text" | Enum.map(Map.keys(components), &(&1 <> "/text"))], &{&1, pipeline}),
      semantic_cache: %{
        routing:
          {backend,
           Map.to_list(binding |> Map.take([:namespace, :profile_ref])) ++ [server: cache_server]}
      },
      observer: %{events: [to: self()]}
    }

    adapters = if module == Assistant or tags[:standard_wiring], do: adapters, else: %{}

    adapters =
      case tags[:configure_adapters] do
        nil -> adapters
        configure -> configure.(%{scope: scope, fixture: fixture, adapters: adapters})
      end

    instance_options = [
      scope: scope,
      agent: module,
      definition: definition,
      state: state,
      adapters: adapters,
      bindings: %{"refund.issue" => class_binding},
      component_states: Map.new(components, fn {name, _} -> {name, state} end),
      max_pending_operations: Map.get(tags, :max_pending_operations, 32)
    ]

    instance = start_supervised!({Instance, instance_options})

    %{
      fixture: fixture,
      scope: scope,
      instance: instance,
      definition: definition,
      cache: cache,
      instance_options: instance_options,
      state: state
    }
  end

  def input(c, text) do
    c.fixture
    |> Fixture.paid_evidence(
      proposition: "chat.message",
      issuer_ref: c.fixture.refs.proposer,
      payload: %{"text" => text}
    )
    |> Map.from_struct()
    |> Map.delete(:ref)
  end

  def prepare(c, text) do
    assert {:ok, turn} =
             Instance.turn(c.instance, input(c, text),
               flow: :support,
               context_evidence_refs: [c.fixture.refs.payment_evidence]
             )

    assert [request] = turn.requests
    {turn, request}
  end

  def assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, recovered} = Projection.replay(snapshot, c.fixture.constitution)
    assert recovered === Sequencer.projection(c.fixture.server)
    {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
