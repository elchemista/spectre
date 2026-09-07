defmodule Spectre.Test.RoutedAgentCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  # Every scenario gets isolated storage and host adapters. Shared fixture
  # functions run in the test process, so observers and teardown keep their
  # original ownership; no background execution is hidden by this template.
  using do
    quote do
      import Spectre.Test.RoutedAgentCase,
        only: [
          restart_store: 1,
          configure: 2,
          configure: 3,
          turn: 2,
          turn: 3,
          input: 3,
          candidate_attrs: 4,
          prepare: 2,
          prepare: 3,
          record_route: 4,
          record_route: 5,
          assert_no_route: 2,
          assert_completed: 4,
          assert_history: 1,
          event_revision: 3,
          revise: 2,
          assert_portable_leaves: 1,
          open_other_scope: 1,
          projection: 1,
          account: 1,
          executions: 1
        ]
    end
  end

  alias Spectre.{Agent, Audit, Candidate, Instance, Ledger, Mind, Portable}
  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Plugs.NormalizeText
  alias Spectre.Ledger.Store.{Disk, ETS}
  alias Spectre.Mind.Turn
  alias Spectre.Router.Rule
  alias Spectre.Store.Memory, as: ApplicationStore
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule RefundSkill do
    @moduledoc false

    use Spectre.Skill, namespace: "routing-tests", name: "refund", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule SupportSkill do
    @moduledoc false

    use Spectre.Skill, namespace: "routing-tests", name: "support", revision: 1, declared_at: 0
    install(RefundSkill, as: "billing")
  end

  defmodule SkilledAgent do
    @moduledoc false

    use Spectre.Agent, namespace: "routing-tests", name: "skilled", revision: 1, declared_at: 0
    install(SupportSkill, as: "support")
    install(RefundSkill, as: "retention")
  end

  defmodule PlainAgent do
    @moduledoc false

    use Spectre.Agent, namespace: "routing-tests", name: "plain", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  # Application glue supplies observed input to the library's compiled Router
  # and binds its selection to a template. Observation remains host-supplied.
  # Selection happens before admission; neither a match nor its score is power.
  defmodule RoutingMind do
    @moduledoc false

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
    @moduledoc false

    @behaviour Spectre.Input.Plug

    @impl true
    def call(%{"transcript" => text} = envelope, opts) do
      send(opts[:observer], {:transcript_input, envelope, self()})
      {:cont, text}
    end

    def call(_input, _opts), do: {:error, :missing_transcript}
  end

  defmodule HoldInput do
    @moduledoc false

    @behaviour Spectre.Input.Plug
    @impl true
    def call(input, _opts), do: {:halt, input}
  end

  defmodule BinaryMatcher do
    @moduledoc false

    use Spectre.Router.Adapter
    @impl true
    def evaluate(request, _opts) do
      {:ok, for(rule <- request.rules, rule.data === request.input, do: result(rule, 1.0))}
    end
  end

  defmodule CheckpointStore do
    @moduledoc false

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
    @moduledoc false

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
        :crash ->
          raise "provider failed after receiving capability"

        :paused ->
          send(opts[:observer], {:execution_worker, self()})
          await_completion(act, attempt)

        status ->
          outcome(act, attempt, status)
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

  def restart_store(%{store_config: {Disk, _opts}} = fixture) do
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

  def restart_store(fixture), do: fixture

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

  def configure(c, update) when is_function(update, 1), do: configure(c, update, [])
  def configure(c, opts), do: configure(c, &Function.identity/1, opts)

  def configure(c, update, opts) do
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

  def turn(c, text, opts \\ []) do
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

  def input(c, text, identity) do
    %{
      proposition: "chat.message",
      issuer_ref: c.fixture.refs.proposer,
      provenance: :observed,
      bindings: %{},
      payload: %{"text" => text, "message_ref" => identity},
      labels: []
    }
  end

  def candidate_attrs(c, identity, amount, refs) do
    c.fixture
    |> Fixture.refund_candidate(amount, identity_key: identity, evidence_refs: refs)
    |> Map.drop([:class, :row, :proposer_ref, :scope_ref, :evidence_refs])
  end

  def prepare(c, text, opts \\ []) do
    assert {:ok, %{candidates: [candidate]} = result} = turn(c, text, opts)
    assert_receive {:routed, pid, turn_ref, definition_ref, route}
    refute pid == c.instance
    refute pid == c.fixture.server
    assert turn_ref == result.turn.ref
    assert definition_ref == Instance.info(c.instance).definition_ref
    assert result.turn.context.seal == nil
    refute inspect(result.turn) =~ inspect(c.capability)
    {result, route, candidate}
  end

  def record_route(c, turn, route, candidate, attrs \\ []) do
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

  def assert_no_route(c, text) do
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

  def assert_completed(c, turn, proposal, total_spent) do
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

  def assert_history(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
    assert replayed == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, report} = Audit.verify(export, c.fixture.constitution, Runtime.now())
    assert report.head_digest == snapshot.head_digest
    assert report.counts.attempts == executions(c)
  end

  def event_revision(snapshot, type, ref) do
    entry =
      Enum.find(
        snapshot.entries,
        &(&1.payload["type"] == type and &1.payload["data"]["ref"] == ref)
      )

    assert entry, "missing durable #{type} for #{ref}"
    entry.revision
  end

  def revise(c, definition) do
    Spectre.revise_definition(c.admin, definition,
      identity_key: "publish:#{definition.ref}",
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    )
  end

  def assert_portable_leaves(value) when is_struct(value),
    do: value |> Map.from_struct() |> assert_portable_leaves()

  def assert_portable_leaves(value) when is_map(value),
    do: Enum.each(value, fn {key, child} -> assert_portable_leaves({key, child}) end)

  def assert_portable_leaves(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> assert_portable_leaves()

  def assert_portable_leaves(value) when is_list(value),
    do: Enum.each(value, &assert_portable_leaves/1)

  def assert_portable_leaves(value), do: assert(:ok == Portable.validate(value))

  def open_other_scope(c) do
    assert {:ok, context} =
             Spectre.authenticate(c.scope.domain, "scope:other-routing-session", %{
               principal_ref: c.fixture.refs.proposer,
               authentication_ref: "auth:other",
               session_ref: "session:other"
             })

    assert {:ok, scope} = Spectre.open_scope(c.scope.domain, context, opened_at: Runtime.now())
    scope
  end

  def projection(c), do: Sequencer.projection(c.fixture.server)
  def account(c), do: projection(c).meters[c.fixture.mandate.ref][c.fixture.refs.meter]
  def executions(c), do: :ets.lookup_element(c.effects, :executions, 2, 0)
end
