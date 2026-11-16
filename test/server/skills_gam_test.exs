# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.SkillsGAMTest do
  use ExUnit.Case, async: false
  alias Spectre.GAM
  alias Spectre.GAM.{Candidate, Consent, Domain, Presentation, Scope}
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server

  defmodule Mind do
    use GAM.Mind, ref: "mind:skills"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.GAM.V04Test.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.GAM.V04Test.Ingress

    def observe(context, %{kind: :spectre_skill_invocation}, now, omit_invocation: true) do
      GAM.Ingress.evidence(context, now,
        proposition: "ordinary:user",
        issuer_ref: context.authenticated_principal_ref,
        payload: "not host attribution"
      )
    end

    def observe(context, %{kind: :spectre_skill_invocation, invocation: data}, now, _) do
      Spectre.Server.GAM.Invocation.evidence(context, data, now)
    end

    def observe(context, %{kind: :spectre_server_lifecycle, event: event}, now, _) do
      Spectre.Server.GAM.Lifecycle.evidence(context, event, now)
    end

    def observe(context, %{kind: :presentation_response} = envelope, now, _) do
      Presentation.response_evidence(
        context,
        envelope.presentation,
        envelope.show_act,
        envelope.stance,
        now,
        payload: %{text: envelope.input.text},
        valid_until: envelope.expires_at
      )
    end

    def observe(context, %Spectre.Input{} = input, now, _) do
      GAM.Ingress.evidence(context, now,
        proposition: "request:refund",
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
      send(opts[:observer], {:effect, act.class, act.ref})

      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
          payload: %{receipt: "skill-receipt"}
        )

      {:ok, %{evidence: [evidence], details_ref: "receipt:skills"}}
    end
  end

  defmodule SkillServer do
    use Spectre.Server

    def init(_, ctx) do
      send(
        :ets.lookup_element(Spectre.Server.SkillsGAMTest.Fixtures, "observer", 2),
        {:started, ctx.skill.id, self()}
      )

      {:ok, ctx}
    end

    def handle_flow({:billing, :refund}, _, ctx),
      do: propose(ctx, :refund, %{amount: 500}, on_result: :refunded)

    def handle_flow({:billing, :forbidden}, _, ctx),
      do: propose(ctx, :root_only, %{amount: 500}, on_result: :refunded)

    def handle_flow(:unmatched, _, ctx), do: respond(ctx, "skill unmatched")
    def handle_pending(pending, %{text: "yes"}, ctx), do: confirm_pending(ctx, pending.id)

    def handle_pending(pending, %{text: "close"}, ctx),
      do: close_pending_after(ctx, pending.id, 0)

    def handle_pending(pending, %{text: "resume"}, ctx), do: resume_pending(ctx, pending.id)
    def handle_pending(pending, _, ctx), do: route_current_input(ctx, suspend: pending.id)

    def handle_result(:refunded, {:governed, %{outcome: %{status: :succeeded}}}, ctx) do
      if :ets.lookup(Spectre.Server.SkillsGAMTest.Fixtures, :hold_result) == [
           {:hold_result, true}
         ] do
        send(
          :ets.lookup_element(Spectre.Server.SkillsGAMTest.Fixtures, "observer", 2),
          {:result_ready, self()}
        )

        receive do: (:release -> :ok)
      end

      respond(ctx, "refunded")
    end

    def handle_result(_tag, {:error, reason}, ctx), do: respond(ctx, inspect(reason))

    def handle_result(_tag, {:pending_lifecycle, %{kind: :close, status: :applied}}, ctx),
      do: respond(ctx, "closed")

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
    def handle_cast(:forbidden, ctx), do: {:noreply, propose(ctx, :root_only, %{amount: 500})}
  end

  defmodule Billing do
    use Spectre.Skill, id: :billing, server: SkillServer

    flow :billing do
      on(:refund, regex: ~r/^refund$/, protected: true)
      on(:forbidden, regex: ~r/^forbidden$/)
    end
  end

  defmodule DispatchStore do
    defdelegate fetch(store, key), to: Spectre.Server.Store.Disk
    defdelegate put_new(store, key, bytes), to: Spectre.Server.Store.Disk
    defdelegate delete(store, key, revision), to: Spectre.Server.Store.Disk

    def compare_and_swap(store, key, revision, bytes) do
      result = Spectre.Server.Store.Disk.compare_and_swap(store, key, revision, bytes)
      {:ok, saved} = Spectre.Server.Checkpoint.decode_snapshot(bytes)

      if Enum.any?(saved.outbox, fn {_id, entry} ->
           entry.command.kind == :delegate_route and entry.execution_started == true
         end) do
        send(
          :ets.lookup_element(Spectre.Server.SkillsGAMTest.Fixtures, "observer", 2),
          {:dispatch_durable, key}
        )
      end

      result
    end
  end

  defmodule RootServer do
    use Spectre.Server
    def handle_flow({:root, :status}, _, ctx), do: respond(ctx, "ready")
    def handle_flow({:root, :delegate_yes}, _, ctx), do: delegate(ctx, :one, "yes")
    def handle_flow(:unmatched, _, ctx), do: respond(ctx, "choose a skill")

    def handle_result(:delegate, {:skill_unknown, _}, ctx),
      do: respond(ctx, "delegation uncertain")

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defmodule Root do
    use Spectre.Agent, server: RootServer
    router(strategies: [:regex])

    flow :root do
      on(:status, regex: ~r/^status$/)
      on(:delegate_yes, regex: ~r/^delegate yes$/)
    end

    skill(Billing, as: :one, governed: [:refund])
    skill(Billing, as: :two, governed: [:refund])
  end

  def candidate(args, turn, context) do
    fixture = :ets.lookup_element(__MODULE__.Fixtures, context.assigns.fixture_key, 2)
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
    fixture = :ets.lookup_element(__MODULE__.Fixtures, context.assigns.fixture_key, 2)

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

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "skills-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        consent: true,
        mind: Mind,
        ingress: Ingress,
        executors: [{Executor, observer: self()}],
        name: {:via, Registry, {GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    :ets.new(__MODULE__.Fixtures, [:named_table, :public])
    :ets.insert(__MODULE__.Fixtures, [{"fixture", fixture}, {"observer", self()}])
    {:ok, _} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))
    {:ok, scope} = Scope.new(Domain.handle(fixture.server, domain_ref), Fixture.context(fixture))

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = [scope: scope, bindings: %{refund: binding, root_only: binding}, lifecycle: true]
    %{scope: scope, config: config}
  end

  defp start(c, extra \\ []) do
    start_supervised!(
      {Spectre.Server.Runtime,
       Keyword.merge(
         [
           agent: Root,
           consumer: self(),
           assigns: %{fixture_key: "fixture"},
           gam: {Server.GAM, c.config}
         ],
         extra
       )},
      id: :root
    )
  end

  test "two skills share one ledger, require their own confirmation and keep root responsive",
       c do
    root = start(c)
    {:ok, _} = Server.input(root, "refund", skill: :one)
    {:ok, _} = Server.input(root, "refund", skill: :two)
    assert_receive {Server, ^root, {:skill, :one, {:pending, _, _}}}, 3000
    assert_receive {Server, ^root, {:skill, :two, {:pending, _, _}}}, 3000
    refute_receive {:effect, "refund.issue", _}
    {:ok, status} = Server.input(root, "status")
    assert_receive {Server, ^root, {:response, ^status, "ready", _}}, 2000
    {:ok, yes} = Server.input(root, "yes")
    assert_receive {Server, ^root, {:response, ^yes, "choose a skill", _}}, 2000
    {:ok, _} = Server.input(root, "delegate yes")
    assert_receive {Server, ^root, {:skill, :one, {:response, _, "skill unmatched", _}}}, 2000
    refute_receive {:effect, "refund.issue", _}
    Runtime.set_time(Runtime.now() + 1)
    {:ok, _} = Server.input(root, "yes", skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:response, _, "refunded", _}}}, 3000
    {:ok, second} = Server.skill_server(root, :two)
    assert length(Server.status(second).pending) == 1
    {:ok, view} = GAM.view(c.scope)
    refunds = Enum.filter(view.acts, &(&1.class == "refund.issue"))
    assert length(refunds) == 1

    invocations =
      Enum.filter(view.evidence, &match?({:spectre_skill_invocation, _}, &1.proposition))

    assert Enum.sort(Enum.map(invocations, & &1.payload.skill)) == [:one, :two]
    assert Enum.all?(invocations, &(&1.bindings["domain_ref"] == Scope.domain_ref(c.scope)))
  end

  test "a skill cannot propose a root-only operation, including native callbacks", c do
    root = start(c)
    {:ok, _} = Server.input(root, "forbidden", skill: :one)

    assert_receive {Server, ^root,
                    {:skill, :one,
                     {:response, _, "{:skill_operation_not_allowed, :root_only}", _}}},
                   2000

    {:ok, skill} = Server.skill_server(root, :one)
    GenServer.cast(skill, :forbidden)

    assert_receive {Server, ^root,
                    {:skill, :one,
                     {:response, nil, "{:skill_operation_not_allowed, :root_only}", _}}},
                   2000

    refute_receive {:effect, _, _}
  end

  @tag :tmp_dir
  test "skill timers close pending through shared GAM lifecycle", c do
    store = start_supervised!({Server.Store.Disk, path: Path.join(c.tmp_dir, "timer.snapshot")})
    root = start(c, checkpoint: {store, "agent"})
    {:ok, _} = Server.input(root, "refund", skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:pending, _, _}}}, 3000
    {:ok, _} = Server.input(root, "close", skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:response, _, "closed", _}}}, 3000
    {:ok, view} = GAM.view(c.scope)
    assert Enum.any?(view.evidence, &match?({:spectre_server_lifecycle, _}, &1.proposition))
    refute_receive {:effect, "refund.issue", _}
  end

  @tag :tmp_dir
  test "a Skill crash after the effect recovers its scoped inbox without executing twice", c do
    store = start_supervised!({Server.Store.Disk, path: Path.join(c.tmp_dir, "crash.snapshot")})
    config = Keyword.put(c.config, :store, store)
    root = start(%{c | config: config}, checkpoint: {store, "agent"})
    assert_receive {:started, :one, old}
    {:ok, _} = Server.input(root, "refund", skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:pending, _, _}}}, 3000
    Runtime.set_time(Runtime.now() + 1)
    :ets.insert(__MODULE__.Fixtures, {:hold_result, true})
    {:ok, confirmation} = Server.input(root, "yes", skill: :one)
    assert_receive {:effect, "refund.issue", _}, 3000
    assert_receive {:result_ready, ^old}, 3000
    :ets.insert(__MODULE__.Fixtures, {:hold_result, false})
    monitor = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old, :killed}
    assert_receive {:started, :one, restarted}, 3000
    assert restarted != old

    assert_receive {Server, ^root, {:skill, :one, {:response, ^confirmation, "refunded", _}}},
                   3000

    assert Server.status(restarted).pending == []
    assert Process.alive?(root)
    refute_receive {:effect, "refund.issue", _}
  end

  @tag :tmp_dir
  test "root dispatch is checkpointed and repeated invocation is not executed again", c do
    store =
      start_supervised!({Server.Store.Disk, path: Path.join(c.tmp_dir, "dispatch.snapshot")})

    root = start(c, checkpoint: {store, "agent"})
    {:ok, _} = Server.input(root, "refund")
    assert_receive {Server, ^root, {:skill, mount, {:pending, invocation, _}}}, 3000
    assert_receive {:effect, "presentation.show", _}
    {:ok, skill} = Server.skill_server(root, mount)

    assert {:ok, ^invocation} =
             GenServer.call(skill, {Server.Runtime, :skill_input, invocation, "refund", nil})

    refute_receive {:effect, "presentation.show", _}
  end

  test "missing authenticated Skill attribution fails before presentation or effect", c do
    root = start(%{c | config: Keyword.put(c.config, :ingress_opts, omit_invocation: true)})
    {:ok, _} = Server.input(root, "refund", skill: :one)

    assert_receive {Server, ^root,
                    {:skill, :one, {:response, _, ":skill_invocation_evidence_missing", _}}},
                   3000

    refute_receive {:effect, _, _}
  end

  @tag :tmp_dir
  test "started delegation is durable before acquisition and is not replayed after root loss",
       c do
    store =
      start_supervised!({Server.Store.Disk, path: Path.join(c.tmp_dir, "root-loss.snapshot")})

    root = start(c, checkpoint: {DispatchStore, store, "agent"})
    {:ok, child} = Server.skill_server(root, :one)
    {:ok, other} = Server.skill_server(root, :two)
    :sys.suspend(child)
    :sys.suspend(other)
    {:ok, _} = Server.input(root, "refund")
    assert_receive {:dispatch_durable, "agent"}, 3000
    # Stop the root without waiting for the unacknowledged child admission.
    child_monitor = Process.monitor(child)
    root_monitor = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^root_monitor, :process, ^root, :killed}
    # Both suspended children receive the supervisor's normal 5-second
    # shutdown allowance, in reverse start order.
    assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, 12_000
    # The test supervisor restarts the root; the recovered command reports uncertainty.
    assert_receive {Server, restarted, {:response, _, "delegation uncertain", _}}, 6000
    assert restarted != root
    refute_receive {:effect, "presentation.show", _}
  end

  test "the GAM bridge rechecks mount operations before proposing recovered work", c do
    context = %{skill: %{id: :one, module: Billing, governed: []}}

    assert {:error, {:skill_operation_not_allowed, :refund}} =
             Server.GAM.propose(:refund, %{amount: 500}, context, bridge_config: c.config)

    refute_receive {:effect, _, _}
  end

  test "confirmation controls pin a pending id and presentation revision", c do
    root = start(c)
    {:ok, _} = Server.input(root, "refund", skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:pending, _, _}}}, 3000
    {:ok, child} = Server.skill_server(root, :one)
    [pending] = Server.status(child).pending

    assert {:error, :stale_pending} =
             Server.input(root, "yes", skill: :one, pending: {pending.id, pending.revision + 1})

    assert {:error, :stale_pending} =
             Server.input(root, "yes", skill: :two, pending: {pending.id, pending.revision})

    refute_receive {:effect, "refund.issue", _}
    Runtime.set_time(Runtime.now() + 1)
    {:ok, _} = Server.input(root, "yes", pending: {pending.id, pending.revision}, skill: :one)
    assert_receive {Server, ^root, {:skill, :one, {:response, _, "refunded", _}}}, 3000

    assert {:error, :stale_pending} =
             Server.input(root, "yes", skill: :one, pending: {pending.id, pending.revision})
  end
end
