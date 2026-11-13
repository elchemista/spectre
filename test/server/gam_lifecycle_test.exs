Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.GAMLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Domain, Evidence, Scope}
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server.GAM, as: Bridge
  alias Spectre.Server.GAM.Lifecycle

  defmodule Mind do
    use GAM.Mind, ref: "mind:gam-lifecycle"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.GAM.V04Test.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.GAM.V04Test.Ingress

    def observe(context, %{kind: :spectre_server_lifecycle, event: event}, now, opts) do
      if opts[:observer], do: send(opts[:observer], {:host_lifecycle_observed, event.id})
      Runtime.set_time(now + 1)

      case opts[:mode] do
        :unavailable -> {:error, :host_lifecycle_unavailable}
        :ordinary_user -> user_evidence(context, event, now)
        _ -> Lifecycle.evidence(context, event, now)
      end
    end

    def observe(context, %Spectre.Input{text: text}, now, _opts) do
      GAM.Ingress.evidence(context, now,
        proposition: "request:lifecycle",
        issuer_ref: context.authenticated_principal_ref,
        payload: text
      )
    end

    defdelegate observe(context, attrs, now, opts), to: Spectre.GAM.V04Test.Ingress

    defp user_evidence(context, event, now) do
      {:ok, evidence} = Lifecycle.evidence(context, event, now)

      evidence
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.put(:issuer_ref, context.authenticated_principal_ref)
      |> Evidence.new()
    end
  end

  defmodule Executor do
    defdelegate executor_ref(), to: Spectre.GAM.V04Test.Executor
    defdelegate contract_ref(), to: Spectre.GAM.V04Test.Executor

    def execute(act, attempt, _capability, opts) do
      send(opts[:observer], {:effect, act.class})
      status = if opts[:control], do: Agent.get(opts[:control], & &1), else: :succeeded

      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, status, Runtime.now(),
          payload: "provider receipt"
        )

      observation = %{evidence: [evidence], details_ref: "receipt:gam-lifecycle"}
      if status == :succeeded, do: {:ok, observation}, else: {:error, status, observation}
    end
  end

  defmodule RuntimeServer do
    use Spectre.Server

    def handle_flow({:support, :refund}, _input, ctx),
      do: propose(ctx, :refund, %{amount: 100}, on_result: :refund)

    def handle_flow({:support, :other}, _input, ctx), do: respond(ctx, "another topic")

    def handle_flow({:support, :wait}, _input, ctx),
      do: await_input(ctx, ctx.assigns.wait_id, timeout: :infinity)

    def handle_pending(pending, %{text: "schedule"}, ctx),
      do:
        close_pending_after(ctx, pending.id, Map.get(ctx.assigns, :close_delay, 350),
          reason: :inactivity
        )

    def handle_pending(pending, %{text: "other"}, ctx),
      do: route_current_input(ctx, suspend: pending.id)

    def handle_pending(pending, %{text: "close"}, ctx),
      do: close_pending(ctx, pending.id, reason: :host_policy)

    def handle_result(
          _tag,
          {:pending_lifecycle, %{kind: :schedule_close, status: :applied}},
          ctx
        ),
        do: respond(ctx, "closure scheduled")

    def handle_result(_tag, {:pending_lifecycle, %{kind: :close, status: :applied}}, ctx),
      do: respond(ctx, "intention closed")

    def handle_result(_tag, {:pending_lifecycle, _}, ctx), do: no_response(ctx)

    def handle_result(_tag, {:error, {:pending_lifecycle, reason}}, ctx),
      do: ctx |> assign(:lifecycle_error, reason) |> respond("closure unavailable")

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defmodule FailedShowServer do
    use Spectre.Server

    def handle_flow(route, input, ctx), do: RuntimeServer.handle_flow(route, input, ctx)

    def handle_pending(pending, %{text: "resume"}, ctx),
      do: ctx |> assign(:fail_next_show, true) |> resume_pending(pending.id)

    def handle_pending(pending, %{text: "explain"}, ctx),
      do: ctx |> assign(:fail_next_show, true) |> explain_pending(pending.id)

    def handle_pending(pending, input, ctx), do: RuntimeServer.handle_pending(pending, input, ctx)

    def handle_result(:refund, {:error, error}, ctx),
      do: ctx |> assign(:show_error, error) |> respond("fresh show unavailable")

    def handle_result(:refund, {:consent, :closed_by_policy}, ctx),
      do: respond(ctx, "intention closed")

    def handle_result(tag, result, ctx), do: RuntimeServer.handle_result(tag, result, ctx)
  end

  defmodule RuntimeAgent do
    use Spectre.Agent, server: RuntimeServer
    router(strategies: [:regex])

    flow :support do
      on(:refund, regex: ~r/^refund$/, protected: true)
      on(:other, regex: ~r/^other$/)
      on(:wait, regex: ~r/^wait$/)
    end
  end

  defmodule NativeTimerServer do
    use Spectre.Server

    def handle_flow(route, input, ctx), do: RuntimeServer.handle_flow(route, input, ctx)

    def handle_pending(pending, %{text: "schedule"}, ctx),
      do: close_pending_after(ctx, pending.id, 400, timer: :application, reason: :inactivity)

    def handle_pending(pending, input, ctx), do: RuntimeServer.handle_pending(pending, input, ctx)

    def handle_result(
          _tag,
          {:pending_lifecycle, %{kind: :schedule_close, status: :applied} = schedule},
          ctx
        ) do
      delay = max(schedule.deadline - System.system_time(:millisecond), 0)

      timer =
        Process.send_after(
          self(),
          {:native_close, schedule.pending_id, schedule.command_id},
          delay
        )

      ctx |> put_private(:native_timer, timer) |> respond("native closure scheduled")
    end

    def handle_result(_tag, {:pending_lifecycle, %{kind: :close, status: :applied}}, ctx),
      do: respond(ctx, "native intention closed")

    def handle_result(tag, result, ctx), do: RuntimeServer.handle_result(tag, result, ctx)

    def handle_info({:native_close, id, schedule_id}, ctx) do
      {:noreply,
       ctx
       |> delete_private(:native_timer)
       |> close_pending(id, if_schedule: schedule_id, reason: :inactivity)}
    end
  end

  defmodule CheckpointGate do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts),
      do: {:ok, %{store: opts[:store], observer: opts[:observer], armed: false, blocked: nil}}

    def handle_call(:arm, _from, state), do: {:reply, :ok, %{state | armed: true}}

    def handle_call(:release, _from, %{blocked: {from, result}} = state) do
      GenServer.reply(from, result)
      {:reply, :ok, %{state | blocked: nil}}
    end

    def handle_call(message, from, state) do
      result = GenServer.call(state.store, message, :infinity)

      if state.armed and retired?(message) do
        send(state.observer, {:lifecycle_checkpoint_acquired, self()})
        {:noreply, %{state | armed: false, blocked: {from, result}}}
      else
        {:reply, result, state}
      end
    end

    defp retired?({:cas, _key, _revision, binary}) when is_binary(binary) do
      case GAM.Canonical.Value.decode(binary,
             allowed_structs: [Spectre.Input, Spectre.Input.Source, Spectre.Server.Command]
           ) do
        {:ok, %{pending: pending, outbox: outbox, inbox: inbox}} ->
          completion =
            Enum.any?(inbox, fn {_id, entry} ->
              entry.worker.kind == :lifecycle_completion
            end)

          pending == %{} and (outbox == %{} or completion)

        _ ->
          false
      end
    end

    defp retired?(_message), do: false
  end

  def candidate(args, turn, context) do
    fixture = :ets.lookup_element(__MODULE__.Fixtures, context.assigns.fixture_key, 2)
    refs = Enum.uniq([fixture.refs.payment_evidence | GAM.Mind.Turn.evidence_refs(turn)])
    attrs = Fixture.refund_candidate(fixture, args.amount, evidence_refs: refs)
    {:ok, digest} = GAM.Consent.data_digest(attrs.consequence)

    consent = %{
      schema_version: 1,
      recipient_refs: [fixture.refs.proposer],
      data_digest: digest,
      cost: args.amount,
      purpose_ref: attrs.purpose_ref,
      purpose_params: attrs.purpose_params,
      risk: "irreversible",
      reversibility: false,
      alternatives: ["cancel"]
    }

    {:ok, Map.put(attrs, :consent, consent)}
  end

  def presentation(candidate, context, _) do
    fixture = :ets.lookup_element(__MODULE__.Fixtures, context.assigns.fixture_key, 2)
    consent = candidate.consent

    {:ok, presentation} =
      GAM.Presentation.new(%{
        candidate_binding_ref: GAM.Candidate.presentation_binding_ref(candidate),
        scope_ref: candidate.scope_ref,
        recipient_refs: consent["recipient_refs"],
        approval_source_refs: [Ingress.ref()],
        data: candidate.consequence,
        cost: consent["cost"],
        purpose_ref: consent["purpose_ref"],
        purpose_params: consent["purpose_params"],
        risk: consent["risk"],
        reversibility: consent["reversibility"],
        alternatives: consent["alternatives"],
        renderer_ref: "renderer:gam-lifecycle",
        rendered_payload: "Approve refund?",
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

  def interpret(_, _), do: :unclear

  def conditional_presentation(candidate, context, opts) do
    case {Map.get(context.assigns, :fail_next_show, false), context.assigns.show_failure} do
      {true, :builder} ->
        {:error, :new_presentation_unavailable}

      {true, :held_builder} ->
        observer = :ets.lookup_element(__MODULE__.Fixtures, "observer", 2)
        send(observer, {:fresh_presentation_waiting, self()})

        receive do
          :release -> {:error, :new_presentation_unavailable}
        end

      {true, :delivery} ->
        control = :ets.lookup_element(__MODULE__.Fixtures, "show_control", 2)
        Agent.update(control, fn _ -> :failed end)
        presentation(candidate, context, opts)

      _ ->
        presentation(candidate, context, opts)
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "gam-lifecycle-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    control = if tags[:failed_show], do: start_supervised!({Agent, fn -> :succeeded end})

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        ingress: Ingress,
        mind: Mind,
        governance_allowed: Map.get(tags, :scope_binding, false),
        consent: Map.get(tags, :runtime_lifecycle, false),
        executors: [{Executor, observer: self(), control: control}],
        name: {:via, Registry, {GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, scope} = Scope.new(Domain.handle(fixture.server, domain_ref), Fixture.context(fixture))
    config = [scope: scope, lifecycle: true, ingress_opts: [observer: self()]]

    %{
      fixture: fixture,
      scope: scope,
      config: config,
      opts: [bridge_config: config],
      show_control: control
    }
  end

  @tag :tmp_dir
  @tag runtime_lifecycle: true
  test "a scheduled suspended consent closes after restart with every transition recorded in GAM",
       c do
    {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "lifecycle.snapshot")}
      )

    bindings = %{
      refund: %{
        candidate: {__MODULE__, :candidate},
        presentation: {__MODULE__, :presentation},
        interpreter: {__MODULE__, :interpret}
      }
    }

    config = c.config |> Keyword.put(:bindings, bindings) |> Keyword.put(:store, store)

    options = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture", close_delay: 1_000},
      checkpoint: {store, "agent:lifecycle"},
      gam: {Bridge, config}
    ]

    server = start_supervised!({Spectre.Server, options}, id: :runtime)
    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    [pending] = Spectre.Server.status(server).pending
    assert {:ok, schedule_id} = Spectre.Server.input(server, "schedule")

    assert_receive {Spectre.Server, ^server, {:response, ^schedule_id, "closure scheduled", _}},
                   2_000

    assert {:ok, other_id} = Spectre.Server.input(server, "other")
    assert_receive {Spectre.Server, ^server, {:response, ^other_id, "another topic", _}}, 2_000
    assert [%{id: id, status: :suspended}] = Spectre.Server.status(server).pending
    assert id == pending.id
    :ok = stop_supervised(:runtime)
    restored = start_supervised!({Spectre.Server, options}, id: :runtime)
    assert_receive {Spectre.Server, ^restored, {:response, _, "intention closed", _}}, 2_000
    assert Spectre.Server.status(restored).pending == []
    {:ok, view} = GAM.view(c.scope)

    events =
      for %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}} <-
            view.evidence,
          do: event

    for kind <- [:schedule_close, :suspend, :close], phase <- [:requested, :applied] do
      assert Enum.count(events, &(&1.kind == kind and &1.phase == phase)) == 1
    end

    assert Enum.all?(events, &(&1.pending_id == pending.id))
    assert Enum.map(view.acts, & &1.class) == ["presentation.show"]

    approval =
      GAM.Presentation.approval_proposition(
        pending.presentation.ref,
        pending.show.primary.act.ref
      )

    refute Enum.any?(view.evidence, &(&1.proposition == approval))
    refute Enum.any?(view.evidence, &(&1.stance == :contradicts))
    refute_receive {:effect, "refund.issue"}, 30
    before = Enum.map(view.evidence, & &1.ref) |> Enum.sort()
    :ok = stop_supervised(:runtime)
    final = start_supervised!({Spectre.Server, options}, id: :runtime)
    assert Spectre.Server.status(final).pending == []
    refute_receive {Spectre.Server, ^final, {:response, _, "intention closed", _}}, 30
    {:ok, after_restart} = GAM.view(c.scope)
    assert Enum.sort(Enum.map(after_restart.evidence, & &1.ref)) == before
  end

  test "host lifecycle phases create scoped Evidence without creating an Act or user consent",
       c do
    phases = [:requested, :applied, :ignored]

    for phase <- phases do
      event = event("close:#{phase}", phase)
      assert {:lifecycle_recorded, receipt} = Bridge.record_lifecycle(event, %{}, c.opts)
      assert receipt.event_id == event.id
      assert receipt.event_digest == GAM.Canonical.Value.digest!(event)
      assert [_] = receipt.evidence_refs
    end

    {:ok, view} = GAM.view(c.scope)
    assert length(view.evidence) == 3
    assert view.acts == []
    assert view.decisions == []
    assert view.attempts == []
    assert view.outcomes == []

    Enum.each(view.evidence, fn evidence ->
      assert evidence.source_ref == Ingress.ref()
      assert evidence.issuer_ref == Ingress.ref()
      assert evidence.issuer_ref != c.fixture.refs.proposer
      assert evidence.stance == :supports
      assert {:spectre_server_lifecycle, id} = evidence.proposition
      assert evidence.payload.event.id == id
      assert evidence.bindings["scope_ref"] == Scope.ref(c.scope)
      assert evidence.bindings["authenticated_principal_ref"] == c.fixture.refs.proposer
    end)
  end

  test "retry and concurrent recording recover the same durable observation despite a changing clock",
       c do
    event = event("command:stable:requested", :requested)
    tasks = for _ <- 1..4, do: Task.async(fn -> Bridge.record_lifecycle(event, %{}, c.opts) end)
    results = Task.await_many(tasks, 2_000)
    assert [{:lifecycle_recorded, first}] = Enum.uniq(results)
    assert_receive {:host_lifecycle_observed, "command:stable:requested"}
    Runtime.set_time(Runtime.now() + 10)
    assert {:lifecycle_recorded, ^first} = Bridge.record_lifecycle(event, %{}, c.opts)
    refute_receive {:host_lifecycle_observed, _}, 20

    assert {:error, :lifecycle_event_conflict} =
             Bridge.record_lifecycle(%{event | reason: :different}, %{}, c.opts)

    {:ok, view} = GAM.view(c.scope)
    assert Enum.map(view.evidence, & &1.ref) == first.evidence_refs
  end

  test "a configured ingress failure leaves no lifecycle receipt or invented host observation",
       c do
    event = event("command:unavailable", :requested)
    opts = [bridge_config: Keyword.put(c.config, :ingress_opts, mode: :unavailable)]

    assert {:error, :host_lifecycle_unavailable} = Bridge.record_lifecycle(event, %{}, opts)
    {:ok, view} = GAM.view(c.scope)
    assert view.evidence == []
    assert view.acts == []
    assert {:lifecycle_recorded, _} = Bridge.record_lifecycle(event, %{}, c.opts)
  end

  test "an ordinary user observation cannot be acquired as a host lifecycle receipt", c do
    opts = [bridge_config: Keyword.put(c.config, :ingress_opts, mode: :ordinary_user)]

    assert {:error, :invalid_lifecycle_evidence} =
             Bridge.record_lifecycle(event("user:lookalike", :requested), %{}, opts)

    {:ok, view} = GAM.view(c.scope)
    assert view.acts == []
    assert [evidence] = view.evidence
    assert evidence.issuer_ref == c.fixture.refs.proposer
  end

  test "missing host configuration, Scope and malformed events fail before observation", c do
    event = event("command:invalid", :requested)
    refute Bridge.lifecycle_configured?(nil)
    refute Bridge.lifecycle_configured?(lifecycle: :yes)
    refute Bridge.lifecycle_configured?([{:lifecycle, true}, :invalid])

    assert {:error, :gam_bridge_config_required} = Bridge.record_lifecycle(event, %{}, [])

    assert {:error, :lifecycle_not_configured} =
             Bridge.record_lifecycle(event, %{}, bridge_config: [scope: c.scope])

    assert {:error, :authenticated_scope_required} =
             Bridge.record_lifecycle(event, %{}, bridge_config: [lifecycle: true])

    for {invalid, error} <- [
          {nil, :invalid_lifecycle_event},
          {%{}, :lifecycle_event_fields_required},
          {Map.put(event, :input, "private text"), :unknown_lifecycle_event_fields},
          {%{event | id: ""}, :invalid_lifecycle_identity},
          {%{event | pending_id: nil}, :invalid_lifecycle_identity},
          {%{event | revision: -1}, :invalid_lifecycle_revision},
          {%{event | phase: :confirmed}, :invalid_lifecycle_transition},
          {Map.put(event, :deadline, :later), :invalid_lifecycle_deadline},
          {Map.put(event, :schema_version, 2), :unsupported_lifecycle_schema_version},
          {Map.put(event, :timer_owner, :remote), :invalid_lifecycle_timer_owner}
        ] do
      assert {:error, ^error} = Bridge.record_lifecycle(invalid, %{}, c.opts)
    end

    assert {:error, _} = Bridge.record_lifecycle(Map.put(event, :reason, self()), %{}, c.opts)

    assert {:error, :invalid_lifecycle_observation} =
             Lifecycle.evidence(nil, event, Runtime.now())

    {:ok, view} = GAM.view(c.scope)
    assert view.evidence == []
  end

  @tag scope_binding: true
  test "an intention's original Scope and principal cannot be replaced by a host resolver", c do
    bound =
      event("command:bound", :requested)
      |> Map.merge(%{
        domain_ref: Scope.domain_ref(c.scope),
        scope_ref: Scope.ref(c.scope),
        principal_ref: c.scope.context.authenticated_principal_ref
      })

    {:ok, admin} =
      GAM.resume_scope(
        c.scope.domain,
        Fixture.context(c.fixture, authenticated_principal_ref: c.fixture.refs.grantor)
      )

    options = [bridge_config: Keyword.put(c.config, :scope, admin)]
    assert {:error, :lifecycle_scope_mismatch} = Bridge.record_lifecycle(bound, %{}, options)

    assert {:error, :lifecycle_scope_mismatch} =
             Bridge.record_lifecycle(
               %{bound | principal_ref: c.fixture.refs.grantor},
               %{},
               c.opts
             )

    refute_receive {:host_lifecycle_observed, _}, 20
    {:ok, view} = GAM.view(c.scope)
    assert view.evidence == []
    {:ok, admin_view} = GAM.view(admin)
    assert admin_view.evidence == []
  end

  @tag :tmp_dir
  @tag runtime_lifecycle: true
  test "failed lifecycle recording preserves the consent and retries the same command after restart",
       c do
    {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "lifecycle-failure.snapshot")}
      )

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = c.config |> Keyword.put(:bindings, %{refund: binding}) |> Keyword.put(:store, store)
    failure = Keyword.put(config, :ingress_opts, mode: :unavailable)

    options = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:lifecycle-failure"},
      gam: {Bridge, failure}
    ]

    server = start_supervised!({Spectre.Server, options}, id: :runtime)
    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    [pending] = Spectre.Server.status(server).pending
    assert {:ok, close_input} = Spectre.Server.input(server, "close")

    assert_receive {Spectre.Server, ^server, {:response, ^close_input, "closure unavailable", _}},
                   2_000

    assert [%{id: id, status: :foreground}] = Spectre.Server.status(server).pending
    assert id == pending.id
    assert Spectre.Server.status(server).outbox_size == 1
    [command_id] = Map.keys(:sys.get_state(server).outbox)
    {:ok, before} = GAM.view(c.scope)
    refute Enum.any?(before.evidence, &match?({:spectre_server_lifecycle, _}, &1.proposition))
    :ok = stop_supervised(:runtime)

    restored =
      start_supervised!({Spectre.Server, Keyword.put(options, :gam, {Bridge, config})},
        id: :runtime
      )

    assert_receive {Spectre.Server, ^restored, {:response, ^close_input, "intention closed", _}},
                   2_000

    assert Spectre.Server.status(restored).pending == []
    {:ok, after_recovery} = GAM.view(c.scope)

    events =
      for %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}} <-
            after_recovery.evidence,
          do: event

    assert Enum.sort(Enum.map(events, & &1.id)) == [
             command_id <> ":applied",
             command_id <> ":requested"
           ]

    applied = Enum.find(events, &(&1.phase == :applied))
    assert applied.from_status == :suspended
    assert applied.to_status == :closed
    assert after_recovery.acts == before.acts
    assert after_recovery.attempts == before.attempts
    refute_receive {:effect, "refund.issue"}, 30
  end

  @tag :tmp_dir
  @tag runtime_lifecycle: true
  test "an application OTP timer closes through GAM while its reference remains private", c do
    {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "native-timer.snapshot")}
      )

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = c.config |> Keyword.put(:bindings, %{refund: binding}) |> Keyword.put(:store, store)

    options = [
      agent: RuntimeAgent,
      server: NativeTimerServer,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {store, "agent:native-timer"},
      gam: {Bridge, config}
    ]

    server = start_supervised!({Spectre.Server, options})
    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    assert {:ok, _} = Spectre.Server.input(server, "schedule")
    assert_receive {Spectre.Server, ^server, {:response, _, "native closure scheduled", _}}, 2_000
    state = :sys.get_state(server)
    assert is_reference(state.private.native_timer)
    assert state.close_timers == %{}
    [pending] = Spectre.Server.status(server).pending
    assert pending.close_schedule.timer_owner == :application
    assert {:ok, _} = Spectre.Server.Store.Disk.fetch(store, "agent:native-timer")
    assert_receive {Spectre.Server, ^server, {:response, _, "native intention closed", _}}, 2_000
    assert Spectre.Server.status(server).pending == []
    refute Map.has_key?(:sys.get_state(server).private, :native_timer)
    {:ok, view} = GAM.view(c.scope)

    events =
      for %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}} <-
            view.evidence,
          do: event

    assert length(events) == 4
    assert Enum.all?(events, &(&1.timer_owner == :application))
    assert Enum.count(events, &(&1.kind == :schedule_close)) == 2
    assert Enum.count(events, &(&1.kind == :close)) == 2
    assert Enum.map(view.acts, & &1.class) == ["presentation.show"]
    refute_receive {:effect, "refund.issue"}, 30
  end

  @tag :tmp_dir
  @tag runtime_lifecycle: true
  test "a crash at durable lifecycle completion cannot lose its result callback", c do
    {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, {"fixture", c.fixture})

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "lifecycle-callback.snapshot")}
      )

    gate = start_supervised!({CheckpointGate, store: store, observer: self()})

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = c.config |> Keyword.put(:bindings, %{refund: binding}) |> Keyword.put(:store, store)

    options = [
      agent: RuntimeAgent,
      consumer: self(),
      assigns: %{fixture_key: "fixture"},
      checkpoint: {gate, "agent:lifecycle-callback"},
      gam: {Bridge, config}
    ]

    {:ok, first} = Spectre.Server.start_link(options)
    Process.unlink(first)
    on_exit(fn -> if Process.alive?(first), do: GenServer.stop(first) end)
    assert {:ok, _} = Spectre.Server.input(first, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(first).pending) == 1 end)
    assert :ok = GenServer.call(gate, :arm)
    assert {:ok, close_input} = Spectre.Server.input(first, "close")
    assert_receive {:lifecycle_checkpoint_acquired, ^gate}, 2_000
    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 1_000
    assert :ok = GenServer.call(gate, :release)
    {:ok, before} = GAM.view(c.scope)

    events_before =
      for %{proposition: {:spectre_server_lifecycle, _}} = e <- before.evidence, do: e.ref

    assert length(events_before) == 2
    restored = start_supervised!({Spectre.Server, options}, id: :runtime)

    assert_receive {Spectre.Server, ^restored, {:response, ^close_input, "intention closed", _}},
                   2_000

    assert Spectre.Server.status(restored).pending == []
    assert Spectre.Server.status(restored).outbox_size == 0

    refute_receive {Spectre.Server, ^restored, {:response, ^close_input, "intention closed", _}},
                   30

    {:ok, after_recovery} = GAM.view(c.scope)

    events_after =
      for %{proposition: {:spectre_server_lifecycle, _}} = e <- after_recovery.evidence, do: e.ref

    assert Enum.sort(events_after) == Enum.sort(events_before)
    assert after_recovery.acts == before.acts
    assert after_recovery.attempts == before.attempts
    refute_receive {:effect, "refund.issue"}, 30
  end

  @tag :tmp_dir
  test "portable application wait identities remain usable through the real GAM lifecycle", c do
    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "portable-wait.snapshot")}
      )

    for {pending_id, index} <- Enum.with_index([:quote, {:quote, 42}, 7]) do
      options = [
        agent: RuntimeAgent,
        consumer: self(),
        assigns: %{wait_id: pending_id},
        checkpoint: {store, "agent:portable-wait:#{index}"},
        gam: {Bridge, c.config}
      ]

      server = start_supervised!({Spectre.Server, options}, id: {:runtime, index})
      assert {:ok, _} = Spectre.Server.input(server, "wait")
      eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
      assert [%{id: ^pending_id}] = Spectre.Server.status(server).pending
      assert {:ok, close_input} = Spectre.Server.input(server, "close")

      assert_receive {Spectre.Server, ^server, {:response, ^close_input, "intention closed", _}},
                     2_000

      assert Spectre.Server.status(server).pending == []
      assert Spectre.Server.status(server).outbox_size == 0
      assert Spectre.Server.status(server).workers == 0
    end

    {:ok, view} = GAM.view(c.scope)
    assert view.acts == []
    assert length(view.evidence) == 6

    for id <- [:quote, {:quote, 42}, 7] do
      assert Enum.count(view.evidence, &(&1.payload.event.pending_id == id)) == 2
    end
  end

  for {operation, failure, error} <- [
        {:resume, :builder, :new_presentation_unavailable},
        {:explain, :delivery, :presentation_not_shown}
      ] do
    @tag :tmp_dir
    @tag runtime_lifecycle: true,
         failed_show: true,
         retry_operation: operation,
         show_failure: failure,
         expected_error: error
    test "a failed #{operation} #{failure} preserves the consent closure deadline across restart",
         c do
      {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
      :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
      :ets.insert(__MODULE__.Fixtures, [{"fixture", c.fixture}, {"show_control", c.show_control}])

      store =
        start_supervised!(
          {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "failed-show-deadline.snapshot")}
        )

      binding = %{
        candidate: {__MODULE__, :candidate},
        presentation: {__MODULE__, :conditional_presentation},
        interpreter: {__MODULE__, :interpret}
      }

      config =
        c.config |> Keyword.put(:bindings, %{refund: binding}) |> Keyword.put(:store, store)

      options = [
        agent: RuntimeAgent,
        server: FailedShowServer,
        consumer: self(),
        assigns: %{fixture_key: "fixture", close_delay: 1_000, show_failure: c.show_failure},
        checkpoint: {store, "agent:failed-show-deadline"},
        gam: {Bridge, config}
      ]

      first = start_supervised!({Spectre.Server, options}, id: :runtime)
      assert {:ok, _} = Spectre.Server.input(first, "refund")
      assert_receive {:effect, "presentation.show"}, 2_000
      eventually(fn -> length(Spectre.Server.status(first).pending) == 1 end)
      assert {:ok, schedule_input} = Spectre.Server.input(first, "schedule")

      assert_receive {Spectre.Server, ^first,
                      {:response, ^schedule_input, "closure scheduled", _}},
                     2_000

      [original] = Spectre.Server.status(first).pending
      schedule = original.close_schedule
      assert schedule.deadline > System.system_time(:millisecond)
      assert {:ok, failed_input} = Spectre.Server.input(first, Atom.to_string(c.retry_operation))

      assert_receive {Spectre.Server, ^first,
                      {:response, ^failed_input, "fresh show unavailable", _}},
                     2_000

      assert Spectre.Server.status(first).assigns.show_error == c.expected_error
      [after_failure] = Spectre.Server.status(first).pending
      assert Map.get(after_failure, :close_schedule) == schedule
      assert after_failure.revision == original.revision
      assert after_failure.show.primary.act.ref == original.show.primary.act.ref
      assert after_failure.presentation.ref == original.presentation.ref
      assert schedule.deadline > System.system_time(:millisecond)
      :ok = stop_supervised(:runtime)
      restored = start_supervised!({Spectre.Server, options}, id: :runtime)
      [after_restart] = Spectre.Server.status(restored).pending
      assert after_restart.status == :suspended
      assert Map.get(after_restart, :close_schedule) == schedule
      assert_receive {Spectre.Server, ^restored, {:response, _, "intention closed", _}}, 2_000
      assert System.system_time(:millisecond) >= schedule.deadline
      assert Spectre.Server.status(restored).pending == []
      {:ok, view} = GAM.view(c.scope)

      events =
        for %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}} <-
              view.evidence,
            do: event

      closes = Enum.filter(events, &(&1.kind == :close))
      assert Enum.sort(Enum.map(closes, & &1.phase)) == [:applied, :requested]

      assert Enum.all?(closes, fn event ->
               event.pending_id == original.id and event.deadline == schedule.deadline and
                 event.source == %{schedule_id: schedule.command_id} and
                 event.candidate_ref == original.candidate.ref and
                 event.show_ref == original.show.primary.act.ref
             end)

      assert Enum.all?(view.acts, &(&1.class == "presentation.show"))
      expected_shows = if c.show_failure == :delivery, do: 2, else: 1
      assert length(view.acts) == expected_shows

      if c.show_failure == :delivery,
        do: assert(Enum.any?(view.outcomes, &(&1.status == :failed)))

      approval =
        GAM.Presentation.approval_proposition(
          original.presentation.ref,
          original.show.primary.act.ref
        )

      refute Enum.any?(view.evidence, &(&1.proposition == approval))
      refute Enum.any?(view.evidence, &(&1.stance == :contradicts))
      refute_receive {:effect, "refund.issue"}, 30
    end
  end

  @tag :tmp_dir
  @tag runtime_lifecycle: true, failed_show: true
  test "a failed held presentation automatically closes after its deadline was deferred by the running attempt",
       c do
    {:ok, _} = Fixture.observe_payment(c.fixture, Fixture.paid_evidence(c.fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, [{"fixture", c.fixture}, {"observer", self()}])

    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "held-show-deadline.snapshot")}
      )

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :conditional_presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = c.config |> Keyword.put(:bindings, %{refund: binding}) |> Keyword.put(:store, store)

    options = [
      agent: RuntimeAgent,
      server: FailedShowServer,
      consumer: self(),
      assigns: %{fixture_key: "fixture", close_delay: 1_000, show_failure: :held_builder},
      checkpoint: {store, "agent:held-show-deadline"},
      gam: {Bridge, config}
    ]

    server = start_supervised!({Spectre.Server, options})
    assert {:ok, _} = Spectre.Server.input(server, "refund")
    assert_receive {:effect, "presentation.show"}, 2_000
    eventually(fn -> length(Spectre.Server.status(server).pending) == 1 end)
    assert {:ok, schedule_input} = Spectre.Server.input(server, "schedule")

    assert_receive {Spectre.Server, ^server,
                    {:response, ^schedule_input, "closure scheduled", _}},
                   2_000

    [original] = Spectre.Server.status(server).pending
    assert {:ok, failed_input} = Spectre.Server.input(server, "resume")
    assert_receive {:fresh_presentation_waiting, worker}, 2_000
    assert System.system_time(:millisecond) < original.close_schedule.deadline

    eventually(
      fn ->
        {:ok, view} = GAM.view(c.scope)

        Enum.any?(view.evidence, fn evidence ->
          match?(%{event: %{kind: :close, phase: :ignored}}, evidence.payload)
        end)
      end,
      200
    )

    [during_attempt] = Spectre.Server.status(server).pending
    assert during_attempt.status == :resolving
    assert during_attempt.close_schedule.fired
    send(worker, :release)

    assert_receive {Spectre.Server, ^server,
                    {:response, ^failed_input, "fresh show unavailable", _}},
                   2_000

    assert_receive {Spectre.Server, ^server, {:response, _, "intention closed", _}}, 2_000
    assert Spectre.Server.status(server).pending == []
    {:ok, view} = GAM.view(c.scope)

    closes =
      for %{
            proposition: {:spectre_server_lifecycle, _},
            payload: %{event: %{kind: :close} = event}
          } <- view.evidence,
          do: event

    assert Enum.count(closes, &(&1.phase == :ignored)) == 1
    assert Enum.count(closes, &(&1.phase == :applied)) == 1
    assert Enum.all?(closes, &(&1.deadline == original.close_schedule.deadline))
    assert Enum.map(view.acts, & &1.class) == ["presentation.show"]

    approval =
      GAM.Presentation.approval_proposition(
        original.presentation.ref,
        original.show.primary.act.ref
      )

    refute Enum.any?(view.evidence, &(&1.proposition == approval))
    refute Enum.any?(view.evidence, &(&1.stance == :contradicts))
    refute_receive {:effect, "refund.issue"}, 30
  end

  defp event(id, phase) do
    %{
      id: id,
      phase: phase,
      kind: :close,
      pending_id: "intent:refund",
      revision: 1,
      command_id: "command:close",
      reason: :timeout,
      from_status: :suspended,
      to_status: :closed
    }
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(function, attempts - 1)
        )
  end
end
