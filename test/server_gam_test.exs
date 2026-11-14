# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
Code.require_file("gam/helper.exs", __DIR__)

defmodule Spectre.ServerGAMTest do
  use ExUnit.Case, async: false
  alias Spectre.GAM
  alias Spectre.GAM.{Candidate, Consent, Domain, Presentation, Scope}
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server.GAM, as: Bridge

  defmodule Mind do
    use Spectre.GAM.Mind, ref: "mind:server-bridge-test"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.GAM.V04Test.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.GAM.V04Test.Ingress

    def observe(context, %{kind: :presentation_response} = envelope, now, _) do
      Spectre.GAM.Presentation.response_evidence(
        context,
        envelope.presentation,
        envelope.show_act,
        envelope.stance,
        now,
        payload: %{text: envelope.input.text},
        valid_until: Map.get(envelope, :expires_at)
      )
    end

    def observe(context, %Spectre.Input{} = input, now, _) do
      Spectre.GAM.Ingress.evidence(context, now,
        proposition: "request:refund",
        stance: :supports,
        issuer_ref: context.authenticated_principal_ref,
        payload: %{text: input.text}
      )
    end

    defdelegate observe(context, attrs, now, opts), to: Spectre.GAM.V04Test.Ingress
  end

  defmodule Executor do
    defdelegate executor_ref(), to: Spectre.GAM.V04Test.Executor
    defdelegate contract_ref(), to: Spectre.GAM.V04Test.Executor

    def execute(act, attempt, _capability, opts) do
      send(opts[:observer], {:effect, act.class})

      {:ok, evidence} =
        Spectre.GAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
          payload: %{receipt: "server-bridge"}
        )

      {:ok, %{evidence: [evidence], details_ref: "receipt:server-bridge"}}
    end
  end

  defmodule RuntimeServer do
    use Spectre.Server

    def handle_flow({:support, :refund}, _input, ctx),
      do: propose(ctx, :refund, %{amount: 500}, on_result: :refunded)

    def handle_flow(:unmatched, _input, ctx), do: respond(ctx, "Please state a new request")

    def handle_pending(_pending, input, ctx),
      do: classify(ctx, input, choices: [:confirm, :reject], on_result: :interpret)

    def handle_result(:interpret, {:classified, :confirm}, ctx),
      do: confirm_pending(ctx, ctx.pending.id)

    def handle_result(:refunded, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
      do: respond(ctx, "Refund completed")

    def handle_result(:refunded, {:error, :confirmation_unclear}, ctx),
      do: respond(ctx, "Please confirm explicitly")

    def handle_result(:refunded, {:consent, :expired}, ctx),
      do: respond(ctx, "Confirmation expired")

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_cast({:resume, id}, ctx), do: {:noreply, resume_pending(ctx, id)}
  end

  defmodule RuntimeAgent do
    use Spectre.Agent, server: RuntimeServer
    router(strategies: [:regex])

    flow :support do
      on(:refund, regex: ~r/^refund$/i, protected: true)
    end
  end

  defmodule AlwaysConfirmClassifier do
    def classify(_request, _context, _opts), do: {:classified, :confirm}
  end

  defmodule HoldConfirmedBridge do
    defdelegate propose(operation, args, context, opts), to: Spectre.Server.GAM
    defdelegate recover_command(id, context, opts), to: Spectre.Server.GAM

    def confirm(pending, input, context, opts) do
      result = Spectre.Server.GAM.confirm(pending, input, context, opts)
      recipient = :ets.lookup_element(Spectre.ServerGAMTest.FixtureRegistry, "observer", 2)
      send(recipient, {:confirmed_before_continuation, self()})

      receive do
        :release -> result
      end
    end
  end

  defmodule FailingResumeBridge do
    defdelegate propose(operation, args, context, opts), to: Spectre.Server.GAM
    defdelegate confirm(pending, input, context, opts), to: Spectre.Server.GAM
    def resume(_pending, _input, _context, _opts), do: {:error, :presentation_failed}
  end

  def candidate(args, turn, context) do
    fixture = fixture(context)
    refs = Enum.uniq([fixture.refs.payment_evidence | Turn.evidence_refs(turn)])
    attrs = Fixture.refund_candidate(fixture, args.amount, evidence_refs: refs)
    {:ok, digest} = Consent.data_digest(attrs.consequence)

    consent = %{
      schema_version: 1,
      recipient_refs: [fixture.refs.proposer],
      data_digest: digest,
      cost: args.amount,
      purpose_ref: fixture.refs.purpose,
      purpose_params: attrs.purpose_params,
      risk: "irreversible refund",
      reversibility: false,
      alternatives: ["cancel"]
    }

    {:ok, Map.put(attrs, :consent, consent)}
  end

  def presentation(candidate, context, _) do
    fixture = fixture(context)

    consent =
      Map.new(candidate.consent, fn {key, value} -> {String.to_existing_atom(key), value} end)

    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: Candidate.presentation_binding_ref(candidate),
        scope_ref: candidate.scope_ref,
        recipient_refs: consent.recipient_refs,
        approval_source_refs: [Ingress.ref()],
        data: candidate.consequence,
        cost: consent.cost,
        purpose_ref: consent.purpose_ref,
        purpose_params: consent.purpose_params,
        risk: consent.risk,
        reversibility: consent.reversibility,
        alternatives: consent.alternatives,
        renderer_ref: "renderer:server-bridge",
        rendered_payload: "Refund?",
        prepared_at: Runtime.now()
      })

    {:ok, presentation,
     %{
       identity_key: "show:#{System.unique_integer([:positive])}",
       requested_mandate_ref: fixture.mandate.ref,
       executor_ref: fixture.refs.executor,
       executor_contract_ref: fixture.refs.executor_contract,
       accountable_ref: fixture.refs.accountable,
       subject_refs: candidate.subject_refs,
       evidence_refs: candidate.evidence_refs,
       observation_window_ms: fixture.observation_window_ms
     }}
  end

  def interpret(%{text: "yes"}, _), do: :confirm
  def interpret(%{text: "no"}, _), do: :reject
  def interpret(_, _), do: :unclear

  def held_interpreter(_input, _presentation) do
    observer = :ets.lookup_element(__MODULE__.FixtureRegistry, "observer", 2)
    send(observer, {:interpreter_started, self()})

    receive do
      :release -> :confirm
    end
  end

  defp fixture(%{fixture: fixture}), do: fixture
  defp fixture(%{assigns: %{fixture: fixture}}), do: fixture

  defp fixture(%{assigns: %{fixture_key: key}}),
    do: :ets.lookup_element(__MODULE__.FixtureRegistry, key, 2)

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "server-bridge-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        consent: true,
        mind: Mind,
        ingress: Ingress,
        executors: [{Executor, observer: self()}],
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, _} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))
    {:ok, scope} = Scope.new(Domain.handle(fixture.server, domain_ref), Fixture.context(fixture))
    context = %{input: %Spectre.Input{text: "refund"}, fixture: fixture}

    config = [
      scope: scope,
      bindings: %{
        refund: %{
          candidate: {__MODULE__, :candidate},
          presentation: {__MODULE__, :presentation},
          interpreter: {__MODULE__, :interpret}
        }
      }
    ]

    %{fixture: fixture, scope: scope, context: context, opts: [bridge_config: config]}
  end

  test "real show and authenticated approval precede the effect", c do
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, c.context, c.opts)
    assert_receive {:effect, "presentation.show"}
    refute_receive {:effect, "refund.issue"}
    Runtime.set_time(Runtime.now() + 1)
    yes = %Spectre.Input{text: "yes"}

    assert {:governed, %{outcome: %{status: :succeeded}, proposal: proposal} = result} =
             Bridge.confirm(pending, yes, %{c.context | input: yes}, c.opts)

    assert_receive {:effect, "refund.issue"}
    assert {:ok, _} = GAM.recover_proposal(c.scope, proposal)
    {:ok, reference} = Bridge.result_reference({:governed, result})

    assert {:governed, %{outcome: %{status: :succeeded}} = recovered} =
             Bridge.resolve_result(reference, c.context, c.opts)

    assert Bridge.result_key({:governed, result}) == Bridge.result_key({:governed, recovered})

    assert {:error, :execution_result_not_found} =
             Bridge.resolve_result(
               %{reference | outcome_ref: pending.show.primary.outcome.ref},
               c.context,
               c.opts
             )

    refute_receive {:effect, "refund.issue"}
  end

  test "a classifier label cannot replace original consent; scope and expiry remain bound", c do
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, c.context, c.opts)

    assert {:error, :confirmation_unclear} =
             Bridge.confirm(pending, %{text: "maybe"}, c.context, c.opts)

    assert {:error, :pending_scope_mismatch} =
             Bridge.confirm(%{pending | scope_ref: "other"}, %{text: "yes"}, c.context, c.opts)

    assert {:error, :consent_expired} =
             Bridge.confirm(%{pending | expires_at: 1}, %{text: "yes"}, c.context, c.opts)

    refute_receive {:effect, "refund.issue"}
  end

  test "unbound operations and missing host config fail closed", c do
    assert {:error, :gam_bridge_config_required} = Bridge.propose(:refund, %{}, c.context, [])

    assert {:error, {:unbound_governed_operation, :other}} =
             Bridge.propose(:other, %{}, c.context, c.opts)

    refute_receive {:effect, _}
  end

  test "a protected route cannot execute through a binding without a presentation", c do
    config = c.opts[:bridge_config]
    binding = config[:bindings].refund |> Map.delete(:presentation)
    opts = [bridge_config: Keyword.put(config, :bindings, %{refund: binding})]
    context = Map.put(c.context, :routing, %{protected: true})

    assert {:error, :gam_binding_callback_required} =
             Bridge.propose(:refund, %{amount: 500}, context, opts)

    refute_receive {:effect, _}
  end

  test "a Server supplied interpreter is retained when the host does not override it", c do
    config = c.opts[:bridge_config]
    binding = config[:bindings].refund |> Map.delete(:interpreter)

    opts = [
      bridge_config: Keyword.put(config, :bindings, %{refund: binding}),
      confirmation: [interpreter: {__MODULE__, :interpret}]
    ]

    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, c.context, opts)
    assert pending.interpreter == {__MODULE__, :interpret}
    Runtime.set_time(Runtime.now() + 1)

    assert {:governed, %{outcome: %{status: :succeeded}}} =
             Bridge.confirm(
               pending,
               %{text: "yes"},
               c.context,
               Keyword.delete(opts, :confirmation)
             )

    assert_receive {:effect, "refund.issue"}
  end

  test "rejection uses original input and records authenticated contradictory Evidence", c do
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, c.context, c.opts)

    assert {:error, :rejection_unclear} =
             Bridge.reject(pending, %Spectre.Input{text: "maybe"}, c.context, c.opts)

    assert {:error, :pending_scope_mismatch} =
             Bridge.reject(
               %{pending | scope_ref: "other"},
               %Spectre.Input{text: "no"},
               c.context,
               c.opts
             )

    refute_receive {:effect, "refund.issue"}, 50

    Runtime.set_time(Runtime.now() + 1)
    no = %Spectre.Input{text: "no"}
    assert {:consent, :rejected} = Bridge.reject(pending, no, %{c.context | input: no}, c.opts)

    proposition =
      Presentation.approval_proposition(pending.presentation.ref, pending.show.primary.act.ref)

    projection = Spectre.GAM.Domain.Sequencer.projection(c.fixture.server)

    [rejection] =
      projection.evidence |> Map.values() |> Enum.filter(&(&1.proposition == proposition))

    assert rejection.stance == :contradicts
    assert rejection.issuer_ref == c.scope.context.authenticated_principal_ref
    assert rejection.source_ref == Ingress.ref()
    refute_receive {:effect, "refund.issue"}, 50
  end

  test "journaled show and effect recover the exact committed operation without repeating it",
       c do
    path =
      Path.join(System.tmp_dir!(), "spectre-bridge-journal-#{System.unique_integer([:positive])}")

    store = start_supervised!({Spectre.Server.Store.Disk, path: path})
    on_exit(fn -> File.rm(path) end)
    config = Keyword.put(c.opts[:bridge_config], :store, store)
    opts = [bridge_config: config]
    show_context = Map.put(c.context, :command_id, "show-command")
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, show_context, opts)
    assert_receive {:effect, "presentation.show"}
    assert {:pending, recovered} = Bridge.recover_command("show-command", show_context, opts)
    assert recovered.show.primary.act.ref == pending.show.primary.act.ref
    assert recovered.status == :suspended
    assert recovered.expires_at == pending.expires_at
    refute_receive {:effect, "presentation.show"}

    Runtime.set_time(Runtime.now() + 1)
    yes = %Spectre.Input{text: "yes"}
    effect_context = c.context |> Map.put(:input, yes) |> Map.put(:command_id, "effect-command")
    assert {:governed, first} = Bridge.confirm(pending, yes, effect_context, opts)
    assert_receive {:effect, "refund.issue"}
    assert {:governed, recovered} = Bridge.recover_command("effect-command", effect_context, opts)
    assert recovered.act.ref == first.act.ref
    assert recovered.outcome.status == :succeeded
    {:ok, reference} = Bridge.result_reference({:governed, first})

    assert {:governed, resolved} =
             Bridge.resolve_command_result("effect-command", reference, effect_context, opts)

    assert resolved.act.ref == first.act.ref

    assert {:error, :result_continuation_mismatch} =
             Bridge.resolve_command_result("show-command", reference, effect_context, opts)

    assert :ok = Bridge.release_command("effect-command", effect_context, opts)
    assert :ok = Bridge.release_command("effect-command", effect_context, opts)

    assert {:error, :governed_recovery_required} =
             Bridge.recover_command("effect-command", effect_context, opts)

    refute_receive {:effect, "refund.issue"}
  end

  @tag :tmp_dir
  test "the real Server restores consent and preserves original input despite a classifier label",
       c do
    # Host-owned test wiring stays outside the portable Server checkpoint.
    :ets.new(__MODULE__.FixtureRegistry, [:named_table, :public])
    :ets.insert(__MODULE__.FixtureRegistry, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "consent.snapshot")}
      )

    opts = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:refund"},
      gam: {Bridge, c.opts[:bridge_config]},
      services: [classify: AlwaysConfirmClassifier]
    ]

    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)

    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    refute_receive {:effect, "refund.issue"}, 50

    assert {:ok, unclear_id} = Spectre.Server.input(server, "maybe")

    assert_receive {Spectre.Server, ^server,
                    {:response, ^unclear_id, "Please confirm explicitly", response_options}},
                   2_000

    assert is_binary(response_options[:message_id])

    refute_receive {:effect, "refund.issue"}, 50
    assert length(Spectre.Server.status(server).pending) == 1

    :ok = stop_supervised(:runtime)
    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
    [pending] = Spectre.Server.status(server).pending
    assert pending.status == :suspended
    GenServer.cast(server, {:resume, pending.id})
    assert_receive {:effect, "presentation.show"}, 2_000

    eventually(fn ->
      match?([%{status: :foreground}], Spectre.Server.status(server).pending)
    end)

    Runtime.set_time(Runtime.now() + 1)
    assert {:ok, confirmed_id} = Spectre.Server.input(server, "yes")
    assert_receive {:effect, "refund.issue"}, 2_000

    assert_receive {Spectre.Server, ^server,
                    {:response, ^confirmed_id, "Refund completed", _options}},
                   2_000

    assert Spectre.Server.status(server).pending == []

    {:ok, view} = GAM.view(c.scope)
    act = Enum.find(view.acts, &(&1.class == "refund.issue"))
    outcome = Enum.find(view.outcomes, &(&1.act_ref == act.ref))
    reference = %{decision_ref: act.decision_ref, act_ref: act.ref, outcome_ref: outcome.ref}

    assert :ok =
             Spectre.Server.deliver(
               server,
               "alternate-transport-id",
               :refunded,
               {:governed_ref, reference}
             )

    refute_receive {Spectre.Server, ^server, {:response, _, "Refund completed", _}}, 100
  end

  @tag :tmp_dir
  test "fresh consent TTL is relative and journal recovery preserves the exact deadline", c do
    store =
      start_supervised!({Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "ttl.snapshot")})

    config =
      c.opts[:bridge_config] |> Keyword.put(:store, store) |> Keyword.put(:consent_ttl_ms, 20)

    opts = [bridge_config: config]
    context = Map.put(c.context, :command_id, "show:ttl")
    before = System.system_time(:millisecond)
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, context, opts)
    assert pending.expires_at >= before + 20
    assert pending.expires_at <= System.system_time(:millisecond) + 20
    Process.sleep(25)
    assert {:pending, recovered} = Bridge.recover_command("show:ttl", context, opts)
    assert recovered.expires_at == pending.expires_at
    assert recovered.status == :suspended

    assert {:error, :consent_expired} =
             Bridge.confirm(pending, %Spectre.Input{text: "yes"}, context, opts)

    refute_receive {:effect, "refund.issue"}, 50
  end

  test "a slow interpreter cannot execute after the consent deadline", c do
    :ets.new(__MODULE__.FixtureRegistry, [:named_table, :public])
    :ets.insert(__MODULE__.FixtureRegistry, {"observer", self()})

    binding = %{
      c.opts[:bridge_config][:bindings].refund
      | interpreter: {__MODULE__, :held_interpreter}
    }

    config =
      c.opts[:bridge_config]
      |> Keyword.put(:consent_ttl_ms, 300)
      |> Keyword.put(:bindings, %{refund: binding})

    opts = [bridge_config: config]
    {:pending, pending} = Bridge.propose(:refund, %{amount: 500}, c.context, opts)
    before = Spectre.GAM.Domain.Sequencer.projection(c.fixture.server)

    task =
      Task.async(fn -> Bridge.confirm(pending, %Spectre.Input{text: "yes"}, c.context, opts) end)

    assert_receive {:interpreter_started, worker}, 1_000
    Process.sleep(max(pending.expires_at - System.system_time(:millisecond) + 1, 1))
    send(worker, :release)
    assert {:error, :consent_expired} = Task.await(task)
    assert Spectre.GAM.Domain.Sequencer.projection(c.fixture.server) == before
    refute_receive {:effect, "refund.issue"}, 50
  end

  @tag :tmp_dir
  test "the Runtime expires a restored consent exactly once instead of reactivating it", c do
    :ets.new(__MODULE__.FixtureRegistry, [:named_table, :public])
    :ets.insert(__MODULE__.FixtureRegistry, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "expiry.snapshot")}
      )

    config = Keyword.put(c.opts[:bridge_config], :consent_ttl_ms, 300)

    opts = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:refund"},
      gam: {Bridge, config},
      services: [classify: AlwaysConfirmClassifier]
    ]

    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
    assert {:ok, input_id} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    :ok = stop_supervised(:runtime)
    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)

    assert_receive {Spectre.Server, ^server,
                    {:response, ^input_id, "Confirmation expired", _options}},
                   1_000

    assert Spectre.Server.status(server).pending == []
    refute_receive {:effect, "refund.issue"}, 50
    :ok = stop_supervised(:runtime)
    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
    refute_receive {Spectre.Server, ^server, {:response, _, "Confirmation expired", _}}, 50
  end

  @tag :tmp_dir
  test "a crash after the effect preserves the pending continuation tag without replay", c do
    :ets.new(__MODULE__.FixtureRegistry, [:named_table, :public])
    :ets.insert(__MODULE__.FixtureRegistry, [{"fixture", c.fixture}, {"observer", self()}])

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "recovery.snapshot")}
      )

    bridge_config = Keyword.put(c.opts[:bridge_config], :store, store)

    opts = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:refund"},
      gam: {HoldConfirmedBridge, bridge_config},
      services: [classify: AlwaysConfirmClassifier]
    ]

    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)

    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    Runtime.set_time(Runtime.now() + 1)
    assert {:ok, input_id} = Spectre.Server.input(server, "yes")
    assert_receive {:effect, "refund.issue"}, 2_000
    assert_receive {:confirmed_before_continuation, worker}, 2_000
    assert Process.alive?(worker)

    :ok = stop_supervised(:runtime)
    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)

    assert_receive {Spectre.Server, ^server,
                    {:response, ^input_id, "Refund completed", _options}},
                   2_000

    assert Spectre.Server.status(server).pending == []
    refute_receive {:effect, "refund.issue"}, 100
  end

  @tag :tmp_dir
  test "a failed fresh presentation keeps restored consent suspended", c do
    :ets.new(__MODULE__.FixtureRegistry, [:named_table, :public])
    :ets.insert(__MODULE__.FixtureRegistry, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "failed-resume.snapshot")}
      )

    opts = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:refund"},
      gam: {FailingResumeBridge, c.opts[:bridge_config]},
      services: [classify: AlwaysConfirmClassifier]
    ]

    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    :ok = stop_supervised(:runtime)
    server = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
    [pending] = Spectre.Server.status(server).pending
    assert pending.status == :suspended

    GenServer.cast(server, {:resume, pending.id})
    assert_receive {Spectre.Server, ^server, {:response, nil, _error, _options}}, 2_000
    assert [%{status: :suspended}] = Spectre.Server.status(server).pending
    assert {:ok, _} = Spectre.Server.input(server, "yes")
    eventually(fn -> not Spectre.Server.status(server).busy end)
    refute_receive {:effect, "refund.issue"}, 100
    assert [%{status: :suspended}] = Spectre.Server.status(server).pending
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      eventually(predicate, attempts - 1)
    end
  end
end
