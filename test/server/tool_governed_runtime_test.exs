Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.ToolGovernedRuntimeTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Candidate, Consent, Domain, Presentation, Scope}
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server

  # Low-level bridge protocol fixture; public managed integration has separate tests.
  alias Spectre.Server.Store.Disk
  alias Spectre.Server.{Checkpoint, Command, Tool}

  defmodule Mind do
    use GAM.Mind, ref: "mind:tool-runtime"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.GAM.V04Test.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.GAM.V04Test.Ingress

    def observe(context, %{kind: :presentation_response} = envelope, now, _) do
      Presentation.response_evidence(
        context,
        envelope.presentation,
        envelope.show_act,
        envelope.stance,
        now,
        payload: envelope.input.text,
        valid_until: envelope.expires_at
      )
    end

    def observe(context, %Spectre.Input{text: text}, now, _) do
      GAM.Ingress.evidence(context, now,
        proposition: "request:tool",
        issuer_ref: context.authenticated_principal_ref,
        payload: text
      )
    end

    defdelegate observe(context, attrs, now, opts), to: Spectre.GAM.V04Test.Ingress
  end

  defmodule Executor do
    defdelegate executor_ref(), to: Spectre.GAM.V04Test.Executor
    defdelegate contract_ref(), to: Spectre.GAM.V04Test.Executor

    def execute(act, attempt, _, opts) do
      send(opts[:observer], {:effect, act.class, self()})

      if act.class == "presentation.show" do
        receive do
          :release -> :ok
        end
      end

      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
          payload: "tool receipt"
        )

      {:ok, %{evidence: [evidence], details_ref: "receipt:tool-runtime"}}
    end
  end

  defmodule Adapter do
    def prepare(:refund, args, _trusted) when is_map(args), do: {:ok, args}
    def project(_, value), do: {:ok, value}
    # There deliberately is no invoke/3: governed work must use the GAM executor.
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :refund_tools, version: "0.1.0", spectre: "~> 0.4.0"
    @impl true
    def tools(_) do
      %{
        refund: %{
          contract: 1,
          adapter: Adapter,
          default: :refund,
          operations: %{refund: %{path: :governed, operation: :refund, max_bytes: 1024}}
        }
      }
    end
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule App do
    use Spectre.Server, tools: Stack
    def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}
    def handle_flow(_, _, ctx), do: refund(ctx, %{amount: 100}, on_result: :refund)

    def handle_call({:refund, opts}, _from, ctx),
      do: {:reply, :queued, refund(ctx, %{amount: 100}, opts)}

    def handle_call(message, from, ctx), do: super(message, from, ctx)
    def handle_pending(%{id: id}, %{text: "yes"}, ctx), do: confirm_pending(ctx, id)
    def handle_pending(%{id: id}, %{text: "no"}, ctx), do: reject_pending(ctx, id)
    def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

    def handle_result(tag, result, ctx) do
      send(get_private(ctx, :observer), {:result, tag, result})
      no_response(ctx)
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App

    flow :support do
      on(:refund, regex: ~r/.*/)
    end
  end

  def candidate(args, turn, context) do
    fixture = context.options[:fixture]

    attrs =
      Fixture.refund_candidate(fixture, args.amount,
        evidence_refs: Enum.uniq([fixture.refs.payment_evidence | Turn.evidence_refs(turn)])
      )

    {:ok, digest} = Consent.data_digest(attrs.consequence)

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
    fixture = context.options[:fixture]
    consent = candidate.consent

    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: Candidate.presentation_binding_ref(candidate),
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
        renderer_ref: "renderer:tool-runtime",
        rendered_payload: "Approve refund?",
        prepared_at: Runtime.now()
      })

    show = %{
      identity_key: "show:tool-runtime",
      requested_mandate_ref: fixture.mandate.ref,
      executor_ref: fixture.refs.executor,
      executor_contract_ref: fixture.refs.executor_contract,
      accountable_ref: fixture.refs.accountable,
      subject_refs: candidate.subject_refs,
      evidence_refs: candidate.evidence_refs,
      observation_window_ms: fixture.observation_window_ms
    }

    {:ok, presentation, show}
  end

  def interpret(%Spectre.Input{text: "yes"}, _), do: :confirm
  def interpret(%Spectre.Input{text: "no"}, _), do: :reject
  def interpret(_, _), do: :unclear

  setup context do
    Runtime.reset(Fixture.default_now())
    namespace = "tools-governed-#{System.unique_integer([:positive])}"
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
    {:ok, _} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))
    {:ok, scope} = Scope.new(Domain.handle(fixture.server, domain_ref), Fixture.context(fixture))
    path = Path.join(context.tmp_dir, "tool-governed.snapshot")
    store = start_supervised!({Disk, path: path})

    bindings = %{
      refund: %{
        candidate: {__MODULE__, :candidate},
        presentation: {__MODULE__, :presentation},
        interpreter: {__MODULE__, :interpret}
      }
    }

    opts = [
      agent: Agent,
      init_arg: self(),
      fixture: fixture,
      consumer: self(),
      checkpoint: {store, :server},
      gam:
        {Server.GAM,
         [
           scope: scope,
           bindings: bindings,
           store: {Disk, store},
           consent_ttl_ms: Map.get(context, :ttl, 300_000)
         ]}
    ]

    server = start_supervised!({Spectre.Server.Runtime, opts}, restart: :temporary)
    %{server: server, opts: opts, scope: scope, store: store}
  end

  @tag :tmp_dir
  test "governed helper is a real propose in durable outbox before GAM presentation and effect",
       c do
    {:ok, _} = Server.input(c.server, "refund")
    assert_receive {:effect, "presentation.show", executor}, 2000

    entry =
      :sys.get_state(c.server).outbox
      |> Map.values()
      |> Enum.find(&Map.has_key?(&1, :tool_origin))

    assert entry.command.kind == :propose
    assert entry.command.args == [:refund, %{amount: 100}]
    assert entry.tool_origin.tool == :refund
    refute Keyword.has_key?(entry.command.opts, :tool_origin)
    refute_receive {:effect, "refund.issue", _}
    send(executor, :release)
    eventually(fn -> Server.status(c.server).pending != [] end)
    {:ok, _} = Server.input(c.server, "yes")
    assert_receive {:effect, "refund.issue", _}, 2000
    assert_receive {:result, :refund, {:governed, %{outcome: %{status: :succeeded}}}}, 2000
    {:ok, view} = GAM.view(c.scope)
    assert Enum.any?(view.acts, &(&1.class == "refund.issue"))
  end

  @tag :tmp_dir
  test "rejecting the policy never invokes the concrete effect", c do
    {:ok, _} = Server.input(c.server, "refund")
    assert_receive {:effect, "presentation.show", executor}, 2000
    send(executor, :release)
    eventually(fn -> Server.status(c.server).pending != [] end)
    {:ok, _} = Server.input(c.server, "no")
    assert_receive {:result, :refund, {:consent, :rejected}}, 2000
    refute_receive {:effect, "refund.issue", _}
  end

  @tag :tmp_dir
  test "governed tool startup rejects missing host binding and nonstandard bridge", c do
    Process.flag(:trap_exit, true)

    assert {:error, _} =
             Spectre.Server.Runtime.start_link(
               Keyword.put(c.opts, :gam, {Server.GAM, [bindings: %{}]})
             )

    assert {:error, _} = Spectre.Server.Runtime.start_link(Keyword.put(c.opts, :gam, __MODULE__))
  end

  def migrate(projection, _metadata), do: {:ok, projection}

  @tag :tmp_dir
  test "nonportable confirmation is a programming failure before GAM acquisition", c do
    monitor = Process.monitor(c.server)
    assert catch_exit(GenServer.call(c.server, {:refund, [confirmation: self()]}))
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2000
    refute_receive {:effect, _, _}
  end

  @tag :tmp_dir
  @tag ttl: 200
  test "tool originated consent expiry records completion without executing the requested effect",
       c do
    {:ok, _} = Server.input(c.server, "refund")
    assert_receive {:effect, "presentation.show", executor}, 2000
    send(executor, :release)
    assert_receive {:result, :refund, {:consent, :expired}}, 2000
    assert Server.status(c.server).pending == []
    refute_receive {:effect, "refund.issue", _}
  end

  @tag :tmp_dir
  test "explicit migration reconciles a started governed tool after a real process kill", c do
    {:ok, _} = Server.input(c.server, "refund")
    assert_receive {:effect, "presentation.show", executor}, 2000
    monitor = Process.monitor(c.server)
    Process.exit(c.server, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2000
    mark_previous_descriptor(c.store)
    send(executor, :release)

    eventually(fn ->
      {:ok, view} = GAM.view(c.scope)
      view.outcomes != []
    end)

    opts =
      Keyword.merge(c.opts, checkpoint_version: 2, checkpoint_migrator: {__MODULE__, :migrate})

    restored =
      start_supervised!({Spectre.Server.Runtime, opts}, id: :restored, restart: :temporary)

    assert_receive {Server, ^restored, {:tool_contract_changed, _, :reconciliation_required}},
                   2000

    eventually(fn -> Server.status(restored).pending != [] end)
    assert Server.status(restored).outbox_size == 0
    refute_receive {:effect, "presentation.show", _}
    refute_receive {:effect, "refund.issue", _}
  end

  @tag :tmp_dir
  test "migration rejects an acquired but unstarted governed request without entering GAM", c do
    state = :sys.get_state(c.server)
    snapshot = Tool.snapshot(App).refund

    request = %Command{
      kind: :tool,
      args: [:refund, %{amount: 100}, snapshot],
      opts: [on_result: :refund]
    }

    {command, origin} = Tool.normalize(state, request, nil)
    entry = %{command: command, tool_origin: origin, event: nil, execution_started: false}
    state = %{state | outbox: %{"unstarted-tool" => entry}}
    _saved = Checkpoint.save(state)
    monitor = Process.monitor(c.server)
    Process.exit(c.server, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 2000
    mark_previous_descriptor(c.store)

    opts =
      Keyword.merge(c.opts, checkpoint_version: 2, checkpoint_migrator: {__MODULE__, :migrate})

    restored =
      start_supervised!({Spectre.Server.Runtime, opts}, id: :restored, restart: :temporary)

    assert_receive {:result, :refund, {:error, :tool_contract_changed}}, 2000
    assert Server.status(restored).outbox_size == 0
    refute_receive {:effect, _, _}
  end

  defp mark_previous_descriptor(store) do
    {:ok, %{revision: revision, value: bytes}} = Disk.fetch(store, :server)
    {:ok, projection} = Checkpoint.decode_snapshot(bytes)

    outbox =
      Map.new(projection.outbox, fn {id, entry} ->
        origin = %{entry.tool_origin | descriptor_digest: "previous-deployment-descriptor"}
        {id, %{entry | tool_origin: origin}}
      end)

    {:ok, encoded} = Checkpoint.encode_value(%{projection | outbox: outbox})
    {:ok, _} = Disk.compare_and_swap(store, :server, revision, encoded)
  end

  defp eventually(check, attempts \\ 200)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    unless check.() do
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
