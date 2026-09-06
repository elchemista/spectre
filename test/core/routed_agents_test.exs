defmodule Spectre.Core.RoutedAgentsTest do
  use ExUnit.Case, async: false

  alias Spectre.{Agent, Audit, Candidate, Evidence, Instance, Ledger, Mind, Portable}
  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.Audit.Export
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText
  alias Spectre.Ledger.Store.{Disk, ETS, Mock}
  alias Spectre.Mind.Turn
  alias Spectre.Router.{Rule, Selection}
  alias Spectre.Store.Memory, as: ApplicationStore
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule RefundSkill do
    use Spectre.Skill, namespace: "routing-tests", name: "refund", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule SupportSkill do
    use Spectre.Skill, namespace: "routing-tests", name: "support", revision: 1, declared_at: 0
    install(RefundSkill, as: "billing")
  end

  defmodule SkilledAgent do
    use Spectre.Agent, namespace: "routing-tests", name: "skilled", revision: 1, declared_at: 0
    install(SupportSkill, as: "support")
    install(RefundSkill, as: "retention")
  end

  defmodule PlainAgent do
    use Spectre.Agent, namespace: "routing-tests", name: "plain", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  # Application glue supplies observed input to the library's compiled Router
  # and binds its selection to a template. Observation remains host-supplied.
  # Selection happens before admission; neither a match nor its score is power.
  defmodule RoutingMind do
    @behaviour Spectre.Mind

    @impl true
    def ref, do: "mind:routing-tests"

    @impl true
    def deliberate(turn, opts) do
      {definition, rules} = Map.fetch!(opts[:configurations], opts[:definition_ref])
      input = Enum.find(turn.evidence, &(&1.payload["message_ref"] == opts[:message_ref]))

      with {:ok, text} <- Pipeline.run(opts[:input_pipeline], input.payload["text"]),
           {:ok, route} <- select_route(rules, text) do
        notify(opts, {:routed, self(), turn.ref, definition.ref, route})
        materialize(turn, definition, route, opts)
      else
        {:halt, _value} -> {:ok, []}
        {:error, _} = error -> error
      end
    end

    @impl true
    def deliberate(turn, state, opts) do
      with {:ok, candidates} <- deliberate(turn, opts), do: {:ok, candidates, state + 1}
    end

    defp select_route(router, text) do
      case Spectre.Router.route(router, text) do
        {:ok, %{via: "regex"} = selected} ->
          {:ok,
           %{
             strategy: selected.via,
             template: selected.candidate,
             amount: String.to_integer(selected.matched["amount"])
           }}

        {:ok, selected} ->
          {:ok,
           %{
             strategy: selected.via,
             template: selected.candidate,
             score: selected.score,
             amount: 100
           }}

        :no_match ->
          {:ok, nil}

        {:ambiguous, rules} ->
          {:error, {:ambiguous_route, rules}}

        {:error, _} = error ->
          error
      end
    end

    defp materialize(_turn, _definition, nil, _opts), do: {:ok, []}

    defp materialize(turn, definition, route, opts) do
      attrs = opts[:candidate_builder].(route.amount, Turn.evidence_refs(turn))
      Agent.candidate(definition, route.template, turn, attrs)
    end

    defp notify(opts, event) do
      case Keyword.get(opts, :observer) do
        nil -> :ok
        observer -> observer.(event)
      end
    end
  end

  defmodule TranscriptPlug do
    @behaviour Spectre.Input.Plug

    @impl true
    def call(%{"transcript" => text} = envelope, opts) do
      send(opts[:observer], {:transcript_input, envelope, self()})
      {:cont, text}
    end

    def call(_input, _opts), do: {:error, :missing_transcript}
  end

  defmodule HoldInput do
    @behaviour Spectre.Input.Plug
    @impl true
    def call(input, _opts), do: {:halt, input}
  end

  defmodule BinaryMatcher do
    use Spectre.Router.Adapter
    @impl true
    def evaluate(request, _opts) do
      {:ok, for(rule <- request.rules, rule.data === request.input, do: result(rule, 1.0))}
    end
  end

  defmodule CheckpointStore do
    @behaviour Spectre.Store

    @impl true
    def get(key, opts) do
      send(opts[:observer], {:checkpoint_read, key})
      ApplicationStore.get(key, opts)
    end

    @impl true
    def compare_and_swap(key, expected, encoded, opts) do
      result = ApplicationStore.compare_and_swap(key, expected, encoded, opts)
      send(opts[:observer], {:checkpoint_written, key, result})
      if opts[:lose_ack], do: raise("checkpoint acknowledgement lost")
      result
    end
  end

  defmodule Executor do
    @behaviour Spectre.Attempt.Executor

    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor

    @impl true
    def execute(act, attempt, capability, opts) do
      table = Keyword.fetch!(opts, :effects)
      [{:store, store, domain_ref}] = :ets.lookup(table, :store)
      {:ok, snapshot} = Ledger.load(store, domain_ref)
      count = :ets.update_counter(table, :executions, 1, {:executions, 0})
      :ets.insert(table, {act.ref, count, attempt.ref})

      send(opts[:observer], {:executed, act, attempt, capability, snapshot})

      case Keyword.fetch!(opts, :status) do
        :crash -> raise "provider failed after receiving capability"
        :paused -> await_completion(act, attempt)
        status -> outcome(act, attempt, status)
      end
    end

    defp await_completion(act, attempt) do
      receive do
        :complete_execution -> outcome(act, attempt, :succeeded)
      after
        5_000 -> {:error, :ambiguous, %{evidence: [], details_ref: "provider:timeout"}}
      end
    end

    defp outcome(act, attempt, status) do
      {:ok, receipt} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(), payload: "receipt")

      metadata = %{evidence: [receipt], details_ref: "receipt:#{attempt.ref}"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "routed-agent-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    recovered_scope_ref = "v0.4:#{namespace}:scope:recovered"
    definition = Map.get(tags, :agent, SkilledAgent).definition()
    first_template = if tags[:agent] == PlainAgent, do: "refund", else: "support/billing/refund"
    second_template = if tags[:agent] == PlainAgent, do: "refund", else: "retention/refund"
    template = Map.fetch!(definition.body["candidates"], first_template)
    body = Map.put(definition.body, "candidates", %{"revised/refund" => template})

    {:ok, successor} =
      Spectre.Morph.prepare(definition, [%{op: :put, path: [], value: body}], Runtime.now())

    effects = :ets.new(__MODULE__, [:set, :public])
    capability = {:private_payment_connection, make_ref()}

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        # Both Scopes are authorized in Genesis. Restart must not mint budget
        # or implicitly extend the Mandate when the host opens a fresh Scope.
        scope_refs: ["v0.4:#{namespace}:scope:refunds", recovered_scope_ref],
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        store: ledger_store(tags),
        mock_store: Map.get(tags, :mock_store, false),
        mind: RoutingMind,
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref, successor.ref],
        capability: capability,
        executors: [
          {Executor,
           effects: effects, observer: self(), status: Map.get(tags, :status, :succeeded)}
        ]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    :ets.insert(effects, {:store, fixture.store_config, domain_ref})
    assert {:ok, domain} = Spectre.lookup_domain(domain_ref)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    assert {:ok, admin} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    c = %{
      fixture: fixture,
      scope: scope,
      admin: admin,
      definition: definition,
      successor: successor,
      effects: effects,
      capability: capability
    }

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, definition)

    instance =
      start_supervised!({Instance, scope: scope, definition_ref: definition.ref, state: 0})

    payment =
      if Map.get(tags, :paid, true) do
        attrs =
          fixture
          |> Fixture.paid_evidence(valid_until: Runtime.now() + 1_000)
          |> Map.from_struct()
          |> Map.delete(:ref)

        assert {:ok, [payment]} = Spectre.observe(scope, attrs)
        payment
      end

    configurations = %{
      definition.ref => {definition, rules(first_template, second_template)},
      successor.ref => {successor, rules("revised/refund", "revised/refund")}
    }

    {:ok, input_pipeline} = Pipeline.new([{NormalizeText, case: :downcase}])

    Map.merge(c, %{
      instance: instance,
      input_pipeline: input_pipeline,
      configurations: configurations,
      payment: payment,
      recovered_scope_ref: recovered_scope_ref
    })
  end

  @tag agent: PlainAgent
  test "a plain agent routes text by regex and completes a real governed refund", c do
    {result, route, candidate} = prepare(c, "refund 37")
    assert route == %{strategy: "regex", template: "refund", amount: 37}
    assert candidate.consequence["amount_cents"] == 37
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 37)
  end

  test "regex routing reaches a nested installed Skill and not the sibling with the same local name",
       c do
    {result, route, candidate} = prepare(c, "refund 125")
    assert route.template == "support/billing/refund"
    assert c.definition.body["components"]["support/billing"] == RefundSkill.definition().ref
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 125)
  end

  test "normalized mixed-case and whitespace input still binds the original observed bytes", c do
    {result, _route, candidate} = prepare(c, " \tReFuNd   42\n")
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] == " \tReFuNd   42\n"
    assert message.ref in candidate.evidence_refs
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 42)
  end

  test "an application transcript plug feeds a skilled agent outside the trusted Domain", c do
    assert {:ok, pipeline} =
             Pipeline.new([{TranscriptPlug, observer: self()}, {NormalizeText, case: :downcase}])

    envelope = %{
      "transcript" => "  ReFuNd 23 ",
      "media_ref" => "audio:captured-input",
      "claimed_principal" => "admin"
    }

    {result, _route, candidate} = prepare(c, envelope, input_pipeline: pipeline)
    assert_receive {:transcript_input, ^envelope, pid}
    assert pid == c.instance and pid != c.fixture.server
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] === envelope
    assert message.issuer_ref == c.fixture.refs.proposer
    assert candidate.proposer_ref == c.fixture.refs.proposer
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 23)
  end

  test "normalization can be recorded as a derivation without replacing the raw observation", c do
    assert {:ok, pipeline} =
             Pipeline.new([{NormalizeText, unicode: :nfkc, case: :downcase}])

    original = "ＲＥＦＵＮＤ　４２"
    {result, _route, candidate} = prepare(c, original, input_pipeline: pipeline)
    message = Enum.find(result.evidence, &(&1.proposition == "chat.message"))
    assert message.payload["text"] === original
    assert {:ok, normalized} = Pipeline.run(pipeline, original)

    assert {:ok, evidence} =
             Mind.evidence(result.turn, Runtime.now(),
               proposition: "app.input.normalized",
               provenance: :derived,
               payload: normalized
             )

    assert evidence.payload == "refund 42"
    assert evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, result.turn, evidence)

    attrs =
      candidate
      |> Map.take(Candidate.request_fields())
      |> Map.update!(:evidence_refs, &[evidence.ref | &1])

    assert {:ok, candidate} = Mind.candidate(result.turn, [evidence], attrs)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert evidence.ref in proposal.primary.act.evidence_refs
    assert projection(c).evidence[message.ref] === message
    assert_completed(c, result.turn, proposal, 42)
  end

  test "a rejected input pipeline keeps the observation but cannot advance local state or dispatch",
       c do
    before = projection(c)
    assert {:ok, pipeline} = Pipeline.new([TranscriptPlug])

    assert {:error, {:input_plug_failed, TranscriptPlug, :missing_transcript}} =
             turn(c, %{"audio_ref" => "audio:untranscribed"}, input_pipeline: pipeline)

    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c).acts == before.acts
    assert projection(c).decisions == before.decisions
    assert map_size(projection(c).evidence) == map_size(before.evidence) + 1
    refute_receive {:routed, _, _, _, _}
    assert executions(c) == 0
    assert_history(c)
  end

  test "halting normalization does not fabricate a refused Decision or erase the message", c do
    before = projection(c)
    assert {:ok, pipeline} = Pipeline.new([HoldInput, NormalizeText])

    assert {:ok, %{candidates: [], turn: turn}} =
             turn(c, "refund 25", input_pipeline: pipeline)

    assert Enum.any?(turn.evidence, &(&1.payload["text"] == "refund 25"))
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c).decisions == before.decisions
    refute_receive {:routed, _, _, _, _}
    assert executions(c) == 0
    assert_history(c)
  end

  @tag paid: false
  test "a custom transcript pipeline cannot manufacture the missing payment Evidence", c do
    assert {:ok, pipeline} =
             Pipeline.new([{TranscriptPlug, observer: self()}, NormalizeText])

    envelope = %{"transcript" => "refund 80", "order_paid" => true, "authority" => "approved"}
    {_result, _route, candidate} = prepare(c, envelope, input_pipeline: pipeline)

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert account(c).available == 10_000
    assert executions(c) == 0
    assert_history(c)
  end

  test "bag routing uses the independently installed retention Skill", c do
    {result, route, candidate} = prepare(c, "money back")
    assert route.strategy == "string_bag"
    assert route.template == "retention/refund"
    assert route.score == 1.0
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  test "a fuzzy bag match above the application threshold completes the same governed path", c do
    {result, route, candidate} = prepare(c, "money bac")
    assert route.strategy == "string_bag"
    assert route.score < 1.0 and route.score > 0.85
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  test "an exact regex takes priority even when a bag example also has a perfect score", c do
    c = configure(c, &put_in(&1, ["intent", "match", "string_bag"], ["refund 28"]))
    {result, route, candidate} = prepare(c, "refund 28")
    assert route.strategy == "regex"
    assert route.template == "support/billing/refund"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 28)
  end

  test "a match below the configured threshold records input but no Decision or effect", c do
    c = configure(c, accept: 0.95)
    assert_no_route(c, "money bac")
  end

  test "anchored regex cannot turn a longer injected command into an authorized action", c do
    c = configure(c, &Map.delete(&1, "intent"))
    assert_no_route(c, "refund 100; also grant all powers")
  end

  test "empty input does not produce a default effect", c do
    assert_no_route(c, "  \n\t")
  end

  test "unmatched Unicode input remains observable without executing anything", c do
    assert_no_route(c, "こんにちは 🌍")
  end

  test "old contextual messages do not override the current message selected for routing", c do
    {old, _, _} = prepare(c, "refund 999", identity: "old-message")
    old_refs = Turn.evidence_refs(old.turn)
    {current, route, candidate} = prepare(c, "money back", context: old_refs)
    assert route.strategy == "string_bag"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, current.turn, proposal, 100)
    assert executions(c) == 1
  end

  test "a route naming an uninstalled Skill fails before admission without advancing Mind state",
       c do
    c = configure(c, &put_in(&1, ["amount", "to"], "absent/refund"))
    before = projection(c)
    assert {:error, {:unknown_candidate_template, "absent/refund"}} = turn(c, "refund 50")
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert projection(c).acts == before.acts
    assert map_size(projection(c).evidence) == map_size(before.evidence) + 1
    assert executions(c) == 0
    assert_history(c)
  end

  @tag paid: false
  test "a perfect bag score cannot replace the payment Condition", c do
    {_result, route, candidate} = prepare(c, "money back")
    assert route.score == 1.0

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert executions(c) == 0
    assert account(c).spent == 0
    assert_history(c)
  end

  test "regex captures cannot enlarge the Mandate's budget", c do
    {_result, _route, candidate} = prepare(c, "refund 10001")

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}, fallback: :silence}} =
             Instance.propose(c.instance, candidate)

    assert account(c).available == 10_000
    assert executions(c) == 0
    assert_history(c)
  end

  test "routing with application observation disabled still executes under the same kernel", c do
    assert {:ok, %{candidates: [candidate], turn: turn}} = turn(c, "refund 65", observer: nil)
    refute_receive {:routed, _, _, _, _}
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, turn, proposal, 65)
  end

  test "a checkpoint restores Mind state without replaying the previous external effect", c do
    store = start_supervised!(Spectre.Store.Memory)
    config = {Spectre.Store.Memory, server: store}
    {result, _route, candidate} = prepare(c, "refund 37")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 37)
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    before = projection(c)
    GenServer.stop(c.instance)

    assert {:ok, restored} =
             Instance.start_link(
               scope: c.scope,
               definition_ref: c.definition.ref,
               checkpoint: {config, "mind"}
             )

    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert Instance.state(restored) == %{revision: 1, value: 1}
    assert projection(c) == before
    assert {:ok, _} = Instance.propose(restored, candidate)
    assert executions(c) == 1
    assert {:error, :conflict} = Instance.checkpoint(restored, config, "mind", 0)
    assert {:ok, 2} = Instance.checkpoint(restored, config, "mind", 1)
  end

  test "custom via binary routes a complete skilled agent through ordinary GAM admission", c do
    c =
      configure(
        c,
        fn _rules ->
          %{"custom" => %{to: "support/billing/refund", match: %{binary: "refund by binary"}}}
        end,
        via: [:binary],
        adapters: [binary: BinaryMatcher]
      )

    {result, route, candidate} = prepare(c, "refund by binary")
    assert route.strategy == "binary"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  test "a checkpoint committed before a lost acknowledgement is never written twice implicitly",
       c do
    store = start_supervised!(ApplicationStore)
    config = {CheckpointStore, server: store, observer: self(), lose_ack: true}
    {result, _route, candidate} = prepare(c, "refund 29")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 29)
    before = projection(c)

    assert {:error,
            {:ambiguous,
             {:adapter_callback_exception, CheckpointStore, :compare_and_swap, RuntimeError}}} =
             Instance.checkpoint(c.instance, config, "mind", 0)

    assert_receive {:checkpoint_written, "mind", {:ok, 1}}
    refute_receive {:checkpoint_written, _, _}
    assert {:ok, 1, record} = Spectre.Store.get({ApplicationStore, server: store}, "mind")
    assert record["state_revision"] == 1 and record["value"] == 1
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c) == before
    assert executions(c) == 1
  end

  test "restoring a checkpoint cannot silently override an explicit host state", c do
    store = start_supervised!(ApplicationStore)
    config = {CheckpointStore, server: store, observer: self()}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    assert_receive {:checkpoint_written, "mind", {:ok, 1}}

    assert {:error, {:instance_state_checkpoint_collision, _child}} =
             start_supervised(
               {Instance,
                scope: c.scope,
                definition_ref: c.definition.ref,
                state: 9,
                checkpoint: {config, "mind"}},
               id: :invalid_checkpoint
             )

    refute_receive {:checkpoint_read, _}
    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert executions(c) == 0
  end

  test "a live revised Definition cannot silently inherit the old Definition's checkpoint", c do
    store = start_supervised!(ApplicationStore)
    config = {ApplicationStore, server: store}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    before = projection(c)

    assert {:error, {:instance_checkpoint_binding_mismatch, _child}} =
             start_supervised(
               {Instance,
                scope: c.scope, definition_ref: c.successor.ref, checkpoint: {config, "mind"}},
               id: :invalid_checkpoint
             )

    assert {:ok, fresh} =
             Instance.start_link(scope: c.scope, definition_ref: c.successor.ref, state: 0)

    assert {:ok, definition} = Instance.definition(fresh)
    assert definition.ref == c.successor.ref
    GenServer.stop(fresh)
    assert projection(c) == before
    assert executions(c) == 0
  end

  @tag status: :ambiguous
  test "restoring Mind state cannot extinguish an ambiguous effect or release suspended Meter",
       c do
    {_result, _route, candidate} = prepare(c, "refund 31")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, _, _, _}
    assert account(c).suspended == 31
    assert Enum.any?(projection(c).duties, fn {_ref, duty} -> duty.status == :open end)

    store = start_supervised!(ApplicationStore)
    config = {ApplicationStore, server: store}
    assert {:ok, 1} = Instance.checkpoint(c.instance, config, "mind", 0)
    before = projection(c)
    GenServer.stop(c.instance)

    assert {:ok, restored} =
             Instance.start_link(
               scope: c.scope,
               definition_ref: c.definition.ref,
               checkpoint: {config, "mind"}
             )

    assert {:ok, ^proposal} = Instance.propose(restored, candidate)
    assert projection(c) == before
    assert Instance.state(restored) == %{revision: 1, value: 1}
    assert executions(c) == 1 and account(c).suspended == 31
    GenServer.stop(restored)
    assert_history(c)
  end

  test "routing Evidence cannot override trusted origin or become an observed fact", c do
    {result, _route, _candidate} = prepare(c, "refund 10")
    {_definition, router} = c.configurations[c.definition.ref]
    assert {:ok, selection} = Spectre.Router.route(router, "refund 10")
    before = projection(c)

    for attrs <- [
          [provenance: :observed],
          [issuer_ref: c.fixture.refs.grantor],
          [parent_refs: []],
          [bindings: %{"scope_ref" => "foreign"}],
          [payload: "forged"],
          [proposition: "payment.confirmed"]
        ] do
      assert {:error, _} = Selection.evidence(selection, result.turn, Runtime.now(), attrs)
    end

    assert projection(c) == before
    assert executions(c) == 0
  end

  test "library routing provenance remains derived Evidence and reaches the canonical export",
       c do
    {result, _route, candidate} = prepare(c, "refund 37")
    {_definition, router} = c.configurations[c.definition.ref]
    assert {:ok, selection} = Spectre.Router.route(router, "refund 37")
    assert {:ok, evidence} = Selection.evidence(selection, result.turn, Runtime.now())
    assert evidence.provenance == :derived
    assert evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert evidence.proposition["router_ref"] == router.ref
    assert evidence.proposition["turn_ref"] == result.turn.ref

    assert evidence.payload == %{
             "rule" => selection.rule,
             "candidate" => selection.candidate,
             "via" => "regex",
             "score" => 1.0
           }

    refute Map.has_key?(evidence.payload, "matched")
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, result.turn, evidence)

    attrs =
      candidate
      |> Map.take(Candidate.request_fields())
      |> Map.update!(:evidence_refs, &[evidence.ref | &1])

    assert {:ok, candidate} = Mind.candidate(result.turn, [evidence], attrs)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert evidence.ref in proposal.primary.act.evidence_refs
    assert_completed(c, result.turn, proposal, 37)
  end

  test "an application observer exception cannot execute or partially advance the Instance", c do
    observer = fn _event -> raise "host diagnostic observer crashed" end

    assert {:error, {:mind_failed, RoutingMind, RuntimeError}} =
             turn(c, "refund 65", observer: observer)

    assert Instance.state(c.instance) == %{revision: 0, value: 0}
    assert executions(c) == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.acts == []
    assert Enum.any?(view.evidence, &(&1.proposition == "chat.message"))
    assert_history(c)
  end

  test "route Evidence is recorded before admission and is causally linked without becoming authority",
       c do
    {result, route, candidate} = prepare(c, "refund 71")
    {route_evidence, candidate} = record_route(c, result.turn, route, candidate)
    assert route_evidence.provenance == :derived
    assert route_evidence.parent_refs == Turn.evidence_refs(result.turn)
    assert route_evidence.issuer_ref == RoutingMind.ref()
    assert route_evidence.bindings["scope_ref"] == c.scope.context.scope_ref
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 71)
    assert route_evidence.ref in proposal.primary.act.evidence_refs

    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)

    assert event_revision(snapshot, "evidence_recorded", route_evidence.ref) <
             event_revision(snapshot, "decision_recorded", proposal.primary.decision.ref)

    assert {:ok, view} = Spectre.view(c.scope)
    assert route_evidence in view.evidence
  end

  @tag paid: false
  test "a router cannot launder its derived conclusion into observed payment authority", c do
    {result, route, candidate} = prepare(c, "money back")

    {_route_evidence, candidate} =
      record_route(c, result.turn, route, candidate,
        proposition: "order_paid",
        bindings: %{"order_ref" => c.fixture.refs.order}
      )

    assert {:ok, %{primary: %{decision: %{outcome: :undecidable}, act: nil}}} =
             Instance.propose(c.instance, candidate)

    assert executions(c) == 0
    assert account(c).available == 10_000
    assert_history(c)
  end

  test "public observability correlates Decision, Act, Attempt and Outcome with one ledger head",
       c do
    {result, _, candidate} = prepare(c, "refund 83")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 83)
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.decisions == [proposal.primary.decision]
    assert view.acts == [proposal.primary.act]
    assert view.attempts == [proposal.primary.attempt]
    assert view.outcomes == [proposal.primary.outcome]
    assert view.pending_act_refs == []
    assert {:ok, acts} = Spectre.acts(c.scope)
    assert acts == view.acts
    assert {:ok, []} = Spectre.duties(c.scope)
    assert {:ok, head} = Spectre.head(c.scope.domain)
    assert head.revision == view.revision
    assert head.head_digest == projection(c).head_digest
    refute inspect({proposal, view}) =~ inspect(c.capability)
    assert_portable_leaves(view)
    assert_history(c)
  end

  test "one Scope's route and execution do not appear in another authenticated Scope's view", c do
    {result, _, candidate} = prepare(c, "refund 19")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 19)
    other = open_other_scope(c)
    assert {:ok, view} = Spectre.view(other)
    assert view.decisions == [] and view.acts == [] and view.attempts == []
    assert view.outcomes == [] and view.duties == [] and view.evidence == []

    assert {:error, {:evidence_outside_scope, _}} =
             Spectre.turn(other, input(c, "money back", "other"),
               context_evidence_refs: candidate.evidence_refs
             )

    assert executions(c) == 1
    assert_history(c)
  end

  test "an authenticated foreign Scope cannot replay a routed Candidate to retrieve its result",
       c do
    {result, _, candidate} = prepare(c, "refund 20")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 20)
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  test "another principal cannot retrieve a routed result through the idempotent proposal path",
       c do
    {result, _, candidate} = prepare(c, "refund 21")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 21)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(c.admin, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  test "a foreign Scope cannot trigger delivery of another agent's committed but pending Act",
       c do
    {result, _, candidate} = prepare(c, "refund 22")
    # Stop at the actual admission/dispatch seam: no hand-built Act or Grant.
    assert {:ok, %{act: act}} =
             Sequencer.submit(c.fixture.server, c.scope.context, candidate)

    assert MapSet.member?(projection(c).pending_dispatches, act.ref)
    assert executions(c) == 0
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert executions(c) == 0
    assert projection(c) == before
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 22)
  end

  test "Morph activates a new Definition but preserves the running agent's exact routing configuration",
       c do
    {prepared, _, candidate} = prepare(c, "refund 101")
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    assert {:ok, definition} = Instance.definition(c.instance)
    assert definition == c.definition
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, prepared.turn, proposal, 101)
    {_next, route, _candidate} = prepare(c, "refund 102", identity: "after-morph")
    assert route.template == "support/billing/refund"
    assert_history(c)
  end

  test "old and new Instances route through their pinned Definitions while sharing the same Meter",
       c do
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)

    updated =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.successor.ref, state: 40},
        id: :updated
      )

    updated_c = %{c | instance: updated}
    {first, old_route, old_candidate} = prepare(c, "money back", identity: "old")
    {second, new_route, new_candidate} = prepare(updated_c, "money back", identity: "new")
    assert old_route.template == "retention/refund"
    assert new_route.template == "revised/refund"
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert Instance.state(updated) == %{revision: 1, value: 41}
    assert {:ok, proposal} = Instance.propose(c.instance, old_candidate)
    assert_completed(c, first.turn, proposal, 100)
    assert {:ok, proposal} = Instance.propose(updated, new_candidate)
    assert_completed(c, second.turn, proposal, 200)
    assert_history(c)
  end

  test "a routing agent cannot approve its own Morph by knowing the governance Mandate ref", c do
    before = projection(c)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             revise(%{c | admin: c.scope}, c.successor)

    assert projection(c).catalog == before.catalog
    {result, route, candidate} = prepare(c, "money back")
    assert route.template == "retention/refund"
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 100)
  end

  @tag paid: false
  test "a non-admitted result is private to its original context and is never reevaluated on retry",
       c do
    {_turn, _, candidate} = prepare(c, "money back")
    assert {:ok, original} = Instance.propose(c.instance, candidate)
    assert original.primary.decision.outcome == :undecidable
    other = open_other_scope(c)
    before = projection(c)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(other, candidate)
    assert projection(c) == before
    attrs = c.fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)
    assert {:ok, [_payment]} = Spectre.observe(c.scope, attrs)
    after_payment = projection(c)
    assert {:ok, ^original} = Instance.propose(c.instance, candidate)
    assert projection(c) == after_payment
    assert executions(c) == 0
    assert_history(c)
  end

  test "retry of spoofed-claim refusal belongs to the authenticated caller, not the claimed proposer",
       c do
    {_result, _, candidate} = prepare(c, "refund 26")

    attrs =
      candidate
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:proposer_ref, c.fixture.refs.grantor)

    assert {:ok, spoofed} = Candidate.new(attrs)
    assert {:ok, refused} = Instance.propose(c.instance, spoofed)
    assert refused.primary.decision.outcome == :refused
    assert refused.primary.decision.reasons == [:proposer_context_mismatch]
    before = projection(c)
    assert {:ok, ^refused} = Instance.propose(c.instance, spoofed)
    assert {:error, :candidate_retry_context_mismatch} = Spectre.propose(c.admin, spoofed)
    assert projection(c) == before
    assert executions(c) == 0
    assert_history(c)
  end

  @tag status: :paused
  test "concurrent retry from a second Instance observes the live Attempt without executing twice",
       c do
    {_result, _, candidate} = prepare(c, "refund 23")

    other =
      start_supervised!({Instance, scope: c.scope, definition_ref: c.definition.ref, state: 0},
        id: :concurrent
      )

    first = Task.async(fn -> Instance.propose(c.instance, candidate) end)

    # The provider blocks after checkout. This is a deterministic interleaving,
    # not a sleep hoping that two calls happen to race in the right window.
    assert_receive {:executed, act, attempt, capability, snapshot}
    assert capability == c.capability
    assert event_revision(snapshot, "attempt_started", attempt.ref) > 0
    assert {:ok, pending} = Instance.propose(other, candidate)
    assert pending.primary.act == act and pending.primary.attempt == attempt
    assert pending.primary.outcome == nil
    assert executions(c) == 1
    assert account(c).reserved == 23 and account(c).spent == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.attempts == [attempt] and view.outcomes == []
    assert_history(c)

    send(c.instance, :complete_execution)
    assert {:ok, completed} = Task.await(first, 5_000)
    assert completed.primary.outcome.status == :succeeded
    assert {:ok, ^completed} = Instance.propose(other, candidate)
    assert executions(c) == 1
    assert account(c).reserved == 0 and account(c).spent == 23
    assert_history(c)
  end

  @tag status: :failed
  test "a routed definitive failure remains an observed effect and settles its reservation", c do
    {_result, _, candidate} = prepare(c, "refund 24")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.decision.outcome == :admitted
    assert proposal.primary.outcome.status == :failed
    assert_receive {:executed, _, _, _, _}
    assert account(c).spent == 24 and account(c).reserved == 0
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.outcomes == [proposal.primary.outcome]
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert_history(c)
  end

  @tag status: :definitive_no_effect
  test "only a definitive no-effect attestation returns a routed reservation to availability",
       c do
    {_result, _, candidate} = prepare(c, "refund 25")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.decision.outcome == :admitted
    assert proposal.primary.outcome.status == :definitive_no_effect
    assert_receive {:executed, _, _, _, _}
    assert account(c).spent == 0 and account(c).reserved == 0
    assert account(c).available == 10_000
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert_history(c)
  end

  @tag status: :ambiguous
  test "a routed ambiguous effect remains visible as debt and retry cannot execute again", c do
    {_result, _, candidate} = prepare(c, "refund 215")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, _, _, _}
    assert executions(c) == 1
    assert account(c).suspended == 215
    assert {:ok, [duty]} = Spectre.duties(c.scope, status: :open)
    assert duty.act_ref == proposal.primary.act.ref
    assert duty.containment["retry"] == :forbidden
    assert {:ok, view} = Spectre.view(c.scope)
    assert view.outcomes == [proposal.primary.outcome]
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert executions(c) == 1
    assert {:ok, [^duty]} = Spectre.duties(c.scope, status: :open)
    assert_history(c)
  end

  @tag status: :crash
  test "executor failure after checkout leaves durable Attempt and Duty observable after agent loss",
       c do
    {_result, _, candidate} = prepare(c, "refund 216")
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert proposal.primary.outcome.status == :ambiguous
    assert_receive {:executed, _, attempt, _, snapshot}
    assert event_revision(snapshot, "attempt_started", attempt.ref) > 0
    assert {:ok, [duty]} = Spectre.duties(c.scope)
    GenServer.stop(c.instance, :normal)
    assert {:ok, [^duty]} = Spectre.duties(c.scope)
    assert account(c).suspended == 216
    assert executions(c) == 1
    assert_history(c)
  end

  @tag mock_store: true
  test "lost commit acknowledgement after a routed admission cannot cause a second effect", c do
    {result, _, candidate} = prepare(c, "refund 91")
    assert :ok = Mock.push(c.fixture.mock, [{:append, :after, {:error, :ambiguous}}])
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 91)
    before = projection(c)
    assert {:ok, ^proposal} = Instance.propose(c.instance, candidate)
    assert projection(c) == before
    assert executions(c) == 1
    assert_history(c)
  end

  @tag mock_store: true
  test "failure before a routed admission commit cannot deliver an executor capability", c do
    {_result, _, candidate} = prepare(c, "refund 92")
    assert :ok = Mock.push(c.fixture.mock, [{:append, :before, {:error, :disk_full}}])
    before = projection(c)
    assert {:error, _} = Instance.propose(c.instance, candidate)
    assert executions(c) == 0
    assert projection(c) == before
    assert_history(c)
  end

  for store <- [:ets, :disk] do
    @tag store: store
    test "a full routed agent's history survives Domain restart using #{store}", c do
      {result, route, candidate} = prepare(c, "refund 93")
      {_evidence, candidate} = record_route(c, result.turn, route, candidate)
      assert {:ok, proposal} = Instance.propose(c.instance, candidate)
      assert_completed(c, result.turn, proposal, 93)
      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
      before = projection(c)
      monitor = Process.monitor(c.instance)
      GenServer.stop(c.fixture.server)
      assert_receive {:DOWN, ^monitor, :process, _, _}
      # ETS survives Domain loss; Disk must also survive losing its own process.
      recovered = c.fixture |> restart_store() |> Fixture.restart_domain(generation: 8)
      on_exit(fn -> Fixture.stop_domain(recovered) end)
      :ets.insert(c.effects, {:store, recovered.store_config, recovered.refs.domain})
      assert Sequencer.projection(recovered.server) == before
      assert {:ok, domain} = Spectre.lookup_domain(recovered.refs.domain)
      # A different host generation cannot silently rewrite the old Opening.
      assert {:error, {:scope_context_binding_mismatch, _}} =
               Spectre.resume_scope(domain, Fixture.context(recovered))

      assert {:ok, context} =
               Spectre.authenticate(domain, c.recovered_scope_ref, %{
                 principal_ref: recovered.refs.proposer,
                 authentication_ref: "auth:recovered",
                 session_ref: "session:recovered"
               })

      assert {:ok, scope} = Spectre.open_scope(domain, context, opened_at: Runtime.now())

      # The payment Condition is Domain-wide: while the old proof is current
      # it must not be hidden from recognition. Obtain a fresh attestation in
      # this new session after the old proof's explicit validity interval ends.
      Runtime.set_time(c.payment.valid_until)

      payment_attrs =
        recovered
        |> Fixture.paid_evidence(valid_until: Runtime.now() + 1_000)
        |> Map.from_struct()
        |> Map.delete(:ref)

      assert {:ok, [payment]} = Spectre.observe(scope, payment_attrs)

      instance =
        start_supervised!({Instance, scope: scope, definition_ref: c.successor.ref, state: 0},
          id: :recovered
        )

      c = %{c | fixture: recovered, scope: scope, instance: instance, payment: payment}
      assert {:error, :candidate_retry_context_mismatch} = Instance.propose(instance, candidate)
      assert executions(c) == 1
      {next, route, candidate} = prepare(c, "money back", identity: "recovered-message")
      assert route.template == "revised/refund"
      assert {:ok, proposal} = Instance.propose(instance, candidate)
      assert_completed(c, next.turn, proposal, 193)
      assert_history(c)
    end
  end

  test "an offline audit retains the routing trace, Morph history and exact head without live agents",
       c do
    {result, route, candidate} = prepare(c, "refund 94")
    {evidence, candidate} = record_route(c, result.turn, route, candidate)
    assert {:ok, proposal} = Instance.propose(c.instance, candidate)
    assert_completed(c, result.turn, proposal, 94)
    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = revise(c, c.successor)
    assert {:ok, ledger} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, export} = Export.new(ledger, c.fixture.constitution, Runtime.now())
    assert {:ok, bytes} = Export.encode(export)
    assert {:ok, head} = Spectre.head(c.scope.domain)
    Fixture.stop_domain(c.fixture)
    assert {:ok, report} = Export.verify(bytes)
    assert report.ledger_revision == head.revision
    assert report.head_digest == head.head_digest
    assert report.counts.outcomes == 1
    assert Enum.any?(report.definitions, &(&1["ref"] == c.definition.ref))
    assert Enum.any?(report.definitions, &(&1["ref"] == c.successor.ref))
    assert {:ok, decoded} = Export.decode(bytes)

    assert Enum.any?(
             decoded["ledger"]["entries"],
             &(&1["payload"]["data"] == Evidence.canonical(evidence))
           )

    refute bytes =~ inspect(c.capability)
  end

  defp ledger_store(%{store: :disk}) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "spectre-routed-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir!(directory)
    {:ok, server} = Disk.start_link(directory: directory)

    on_exit(fn ->
      Fixture.stop_process(server)
      File.rm_rf!(directory)
    end)

    {Disk, server: server}
  end

  defp ledger_store(_tags) do
    {:ok, server} = ETS.start_link([])
    {ETS, server: server}
  end

  defp restart_store(%{store_config: {Disk, _opts}} = fixture) do
    %{directory: directory} = :sys.get_state(fixture.store)
    Fixture.stop_process(fixture.store)
    {:ok, server} = Disk.start_link(directory: directory)
    config = {Disk, server: server}

    %{
      fixture
      | store: server,
        store_config: config,
        sequencer_opts: Keyword.put(fixture.sequencer_opts, :store, config)
    }
  end

  defp restart_store(fixture), do: fixture

  defp rules(regex_template, bag_template) do
    {:ok, router} =
      Spectre.Router.new(
        %{
          "amount" => %{to: regex_template, match: %{regex: ~r/\Arefund (?<amount>[0-9]+)\z/u}},
          "intent" => %{to: bag_template, match: %{string_bag: ["money back", "refund please"]}}
        },
        via: [:regex, :string_bag]
      )

    router
  end

  defp configure(c, update) when is_function(update, 1), do: configure(c, update, [])
  defp configure(c, opts), do: configure(c, &Function.identity/1, opts)

  defp configure(c, update, opts) do
    configurations =
      Map.update!(c.configurations, c.definition.ref, fn {definition, rules} ->
        declarations =
          Map.new(rules.rules, fn {name, rule} -> {name, Rule.canonical(rule)} end)

        {:ok, router} =
          Spectre.Router.new(
            update.(declarations),
            Keyword.merge([via: [:regex, :string_bag]], opts)
          )

        {definition, router}
      end)

    %{c | configurations: configurations}
  end

  defp turn(c, text, opts \\ []) do
    identity = Keyword.get(opts, :identity, "message:refund")
    # Capture the test observer here, not self() inside the Instance callback.
    observer = Keyword.get(opts, :observer, observer_for(self()))
    context = if c.payment, do: [c.payment.ref], else: []

    Instance.turn(c.instance, input(c, text, identity),
      context_evidence_refs: Enum.uniq(context ++ Keyword.get(opts, :context, [])),
      mind_opts: [
        configurations: c.configurations,
        input_pipeline: Keyword.get(opts, :input_pipeline, c.input_pipeline),
        message_ref: identity,
        observer: observer,
        candidate_builder: fn amount, refs -> candidate_attrs(c, identity, amount, refs) end
      ]
    )
  end

  defp observer_for(pid), do: fn event -> send(pid, event) end

  defp input(c, text, identity) do
    %{
      proposition: "chat.message",
      issuer_ref: c.fixture.refs.proposer,
      provenance: :observed,
      bindings: %{},
      payload: %{"text" => text, "message_ref" => identity},
      labels: []
    }
  end

  defp candidate_attrs(c, identity, amount, refs) do
    c.fixture
    |> Fixture.refund_candidate(amount, identity_key: identity, evidence_refs: refs)
    |> Map.drop([:class, :row, :proposer_ref, :scope_ref, :evidence_refs])
  end

  defp prepare(c, text, opts \\ []) do
    assert {:ok, %{candidates: [candidate]} = result} = turn(c, text, opts)
    assert_receive {:routed, pid, turn_ref, definition_ref, route}
    assert pid == c.instance
    refute pid == c.fixture.server
    assert turn_ref == result.turn.ref
    assert definition_ref == Instance.info(c.instance).definition_ref
    assert result.turn.context.seal == nil
    refute inspect(result.turn) =~ inspect(c.capability)
    {result, route, candidate}
  end

  defp record_route(c, turn, route, candidate, attrs \\ []) do
    route = Map.new(route, fn {key, value} -> {Atom.to_string(key), value} end)

    attrs =
      Keyword.merge(
        [proposition: "app.route.selected", provenance: :derived, payload: route],
        attrs
      )

    assert {:ok, evidence} = Mind.evidence(turn, Runtime.now(), attrs)
    assert {:ok, ^evidence} = Spectre.record_derivation(c.scope, turn, evidence)
    attrs = Map.take(candidate, Candidate.request_fields())
    attrs = Map.put(attrs, :evidence_refs, Enum.sort([evidence.ref | candidate.evidence_refs]))
    assert {:ok, candidate} = Mind.candidate(turn, [evidence], attrs)
    {evidence, candidate}
  end

  defp assert_no_route(c, text) do
    before = projection(c)
    assert {:ok, %{candidates: [], turn: turn}} = turn(c, text)
    assert_receive {:routed, _, ref, _, nil}
    assert ref == turn.ref
    assert Instance.state(c.instance) == %{revision: 1, value: 1}
    assert projection(c).decisions == before.decisions
    assert map_size(projection(c).evidence) == map_size(before.evidence) + 1
    assert executions(c) == 0
    assert_history(c)
  end

  defp assert_completed(c, turn, proposal, total_spent) do
    assert proposal.primary.decision.outcome == :admitted,
           inspect(proposal.primary.decision.reasons)

    assert proposal.primary.outcome.status == :succeeded
    assert proposal.primary.act.scope_ref == turn.context.scope_ref
    assert_receive {:executed, act, attempt, capability, snapshot}
    assert act == proposal.primary.act and attempt == proposal.primary.attempt
    assert capability == c.capability

    assert event_revision(snapshot, "decision_recorded", act.decision_ref) <
             event_revision(snapshot, "act_committed", act.ref)

    assert event_revision(snapshot, "act_committed", act.ref) <
             event_revision(snapshot, "attempt_started", attempt.ref)

    assert account(c).spent == total_spent
    assert account(c).reserved == 0 and account(c).suspended == 0
    assert_history(c)
  end

  defp assert_history(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
    assert replayed == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, report} = Audit.verify(export, c.fixture.constitution, Runtime.now())
    assert report.head_digest == snapshot.head_digest
    assert report.counts.attempts == executions(c)
  end

  defp event_revision(snapshot, type, ref) do
    entry =
      Enum.find(
        snapshot.entries,
        &(&1.payload["type"] == type and &1.payload["data"]["ref"] == ref)
      )

    assert entry, "missing durable #{type} for #{ref}"
    entry.revision
  end

  defp revise(c, definition) do
    Spectre.revise_definition(c.admin, definition,
      identity_key: "publish:#{definition.ref}",
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    )
  end

  defp assert_portable_leaves(value) when is_struct(value),
    do: value |> Map.from_struct() |> assert_portable_leaves()

  defp assert_portable_leaves(value) when is_map(value),
    do: Enum.each(value, fn {key, child} -> assert_portable_leaves({key, child}) end)

  defp assert_portable_leaves(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> assert_portable_leaves()

  defp assert_portable_leaves(value) when is_list(value),
    do: Enum.each(value, &assert_portable_leaves/1)

  defp assert_portable_leaves(value), do: assert(:ok == Portable.validate(value))

  defp open_other_scope(c) do
    assert {:ok, context} =
             Spectre.authenticate(c.scope.domain, "scope:other-routing-session", %{
               principal_ref: c.fixture.refs.proposer,
               authentication_ref: "auth:other",
               session_ref: "session:other"
             })

    assert {:ok, scope} = Spectre.open_scope(c.scope.domain, context, opened_at: Runtime.now())
    scope
  end

  defp projection(c), do: Sequencer.projection(c.fixture.server)
  defp account(c), do: projection(c).meters[c.fixture.mandate.ref][c.fixture.refs.meter]
  defp executions(c), do: :ets.lookup_element(c.effects, :executions, 2, 0)
end
