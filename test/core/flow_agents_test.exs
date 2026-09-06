defmodule Spectre.CoreTest.FlowAgentsTest do
  use ExUnit.Case, async: false

  alias Spectre.Agent.Flow
  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.{Audit, Instance, Ledger, Prompt}
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText
  alias Spectre.Mind.Turn
  alias Spectre.Proposal.Result
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Refunds do
    use Spectre.Skill, namespace: "flow-agent", name: "refunds", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule BinaryMatcher do
    use Spectre.Router.Adapter
    @impl true
    def evaluate(request, _opts) do
      {:ok, for(rule <- request.rules, rule.data == request.input, do: result(rule, 1.0))}
    end
  end

  # A small agent needs no separate Controller behaviour. This same module
  # declares reusable data and implements ordinary, capability-free handlers.
  defmodule Assistant do
    use Spectre.Agent, namespace: "flow-agent", name: "assistant", revision: 1, declared_at: 0
    use Spectre.Mind, ref: "mind:flow-agent", stateful: true
    install(Refunds, as: "billing")
    asset("instructions", "Refunds are proposals, not promises of successful payment.")

    flow "support" do
      pipe_through("text")
      router(via: [:regex, :string_bag])

      route("refund",
        to: "billing/refund",
        match: %{regex: ~r/^refund (?<amount>[0-9]+)$/, string_bag: ["money back"]}
      )
    end

    flow "device" do
      router(via: [:binary])
      route("refund", to: "billing/refund", match: %{binary: "REFUND"})
    end

    flow "uncertain" do
      router(via: [:regex])
      route("first", to: "billing/refund", match: %{regex: ".*"})
      route("second", to: "billing/refund", match: %{regex: ".*"})
    end

    @impl true
    def deliberate(turn, state, opts) do
      input = Enum.find(turn.evidence, &(&1.proposition == opts[:proposition]))

      with {:ok, candidates} <-
             handle_route(Flow.route(opts[:flow], input.payload), turn, input, opts) do
        {:ok, candidates, (state || 0) + 1}
      end
    end

    # No-match and ambiguity deliberately have different application policies.
    defp handle_route(:no_match, _turn, _input, _opts), do: {:ok, []}

    defp handle_route({:ambiguous, rules}, _turn, _input, _opts),
      do: {:error, {:clarification_required, rules}}

    defp handle_route({:error, _} = error, _turn, _input, _opts), do: error

    defp handle_route({:ok, selection}, turn, input, opts) do
      amount =
        if selection.via == "regex", do: String.to_integer(selection.matched["amount"]), else: 7

      with {:ok, prompt} <-
             Prompt.compose(turn, [{:asset, definition(), "instructions"}, {:evidence, input.ref}]),
           attrs = opts[:build].(amount, Turn.evidence_refs(turn)),
           {:ok, proposal} <- candidate(selection.candidate, turn, attrs) do
        send(opts[:observer], {:planned, self(), selection, prompt})
        {:ok, [proposal]}
      end
    end
  end

  defmodule Executor do
    use Spectre.Attempt.Executor,
      executor_ref: Spectre.V04Test.Executor.executor_ref(),
      contract_ref: Spectre.V04Test.Executor.contract_ref()

    @impl true
    def execute(act, attempt, _capability, opts) do
      {:ok, domain} = Spectre.lookup_domain(opts[:domain_ref])
      {:ok, head} = Spectre.head(domain)
      send(opts[:observer], {:executed, act, attempt, head.revision})
      status = Keyword.get(opts, :status, :succeeded)

      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(), payload: "receipt")

      metadata = %{evidence: [evidence], details_ref: "receipt:flow-agent"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end

  setup context do
    Runtime.reset(Fixture.default_now())
    definition = Assistant.definition()
    domain_ref = "v0.4:flow-agent:domain"

    fixture =
      Fixture.start_domain(
        namespace: "flow-agent",
        mind: Assistant,
        executors: [
          {Executor,
           observer: self(),
           domain_ref: domain_ref,
           status: Map.get(context, :outcome, :succeeded)}
        ],
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(domain_ref)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))
    payment = fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)
    assert {:ok, [payment]} = Spectre.observe(scope, payment)

    {:ok, governance} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    {:ok, registered} =
      Spectre.revise_definition(governance, definition,
        identity_key: "register",
        requested_mandate_ref: fixture.governance_mandate.ref,
        accountable_ref: fixture.refs.accountable,
        purpose_ref: fixture.refs.purpose,
        purpose_params: %{"currency" => "EUR"}
      )

    assert Result.status(registered).primary == %{
             admission: :admitted,
             act_committed?: true,
             attempted?: false,
             outcome: nil
           }

    instance =
      start_supervised!({Instance, scope: scope, definition_ref: definition.ref, state: 0})

    {:ok, text} = Pipeline.new([{NormalizeText, case: :downcase}])
    {:ok, support} = Assistant.flow("support", pipelines: %{"text" => text})
    {:ok, device} = Assistant.flow("device", adapters: [binary: BinaryMatcher])
    {:ok, uncertain} = Assistant.flow("uncertain")

    %{
      fixture: fixture,
      payment: payment,
      scope: scope,
      instance: instance,
      flows: %{support: support, device: device, uncertain: uncertain}
    }
  end

  test "one Instance uses different flow policies, with planning before durable execution", c do
    scenarios = [
      {:support, "  REFUND 13  ", "regex"},
      {:support, "money back", "string_bag"},
      {:device, "REFUND", "binary"}
    ]

    for {{flow, input, method}, i} <- Enum.with_index(scenarios, 1) do
      assert {:ok, %{candidates: [candidate]}} = turn(c, flow, input, i)
      assert_receive {:planned, worker, selection, prompt}
      refute worker == c.instance
      refute worker == c.fixture.server
      assert selection.via == method
      assert selection.candidate == "billing/refund"
      assert Prompt.text(prompt) =~ input
      refute_receive {:executed, _, _, _}, 0

      assert {:ok, result} = Instance.propose(c.instance, candidate)

      assert result.primary.decision.outcome == :admitted,
             inspect(result.primary.decision.reasons)

      assert_receive {:executed, act, attempt, revision}
      assert act.ref == result.primary.act.ref
      assert attempt.ref == result.primary.attempt.ref
      assert revision > 0

      assert Result.status(result) == %{
               primary: %{
                 admission: :admitted,
                 act_committed?: true,
                 attempted?: true,
                 outcome: :succeeded
               },
               fallback: :not_applicable
             }

      assert Instance.state(c.instance) == %{revision: i, value: i}
    end

    assert {:ok, acts} = Spectre.acts(c.scope)
    assert length(acts) == 3
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _report} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())
  end

  test "uncertainty and no-match follow explicit handler policies without execution", c do
    assert {:error, {:clarification_required, ["first", "second"]}} =
             turn(c, :uncertain, "refund 9", 1)

    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert {:ok, %{candidates: []}} = turn(c, :support, "unknown", 2)
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert {:ok, []} = Spectre.acts(c.scope)
    refute_receive {:executed, _, _, _}, 0
  end

  test "a routed request above the Mandate budget is refused, not promoted by its prompt", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, :support, "refund 999999999", 1)

    assert {:ok, result} = Instance.propose(c.instance, candidate)

    assert Result.status(result).primary == %{
             admission: :refused,
             act_committed?: false,
             attempted?: false,
             outcome: nil
           }

    refute_receive {:executed, _, _, _}, 0
  end

  @tag outcome: :ambiguous
  test "an ambiguous executor outcome remains ambiguous after successful admission", c do
    assert {:ok, %{candidates: [candidate]}} = turn(c, :support, "refund 11", 1)

    assert {:ok, result} = Instance.propose(c.instance, candidate)

    assert Result.status(result).primary == %{
             admission: :admitted,
             act_committed?: true,
             attempted?: true,
             outcome: :ambiguous
           }

    assert {:ok, duties} = Spectre.duties(c.scope, status: :open)
    assert Enum.any?(duties, &(&1.class == :ambiguous_outcome))
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())
  end

  defp turn(c, flow, text, occurrence) do
    proposition = "message:#{occurrence}"

    input =
      c.fixture
      |> Fixture.paid_evidence()
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(%{proposition: proposition, payload: text})

    build = fn amount, refs ->
      c.fixture
      |> Fixture.refund_candidate(amount,
        identity_key: "refund:#{occurrence}",
        evidence_refs: refs
      )
      |> Map.drop([:class, :row, :proposer_ref, :scope_ref])
    end

    Instance.turn(c.instance, input,
      context_evidence_refs: [c.payment.ref],
      mind_opts: [flow: c.flows[flow], proposition: proposition, build: build, observer: self()]
    )
  end
end
