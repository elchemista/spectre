# Protocol component tests use the internal Runtime to inject boundary adapters.
# Application AgentServers always start through the automatic Spectre.Server API.
Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.NoEffectCorrectionTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Domain, Scope}
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server
  alias Spectre.Server.GAM, as: Bridge
  alias Spectre.Server.Store.Disk

  defmodule Mind do
    use Spectre.GAM.Mind, ref: "mind:no-effect-correction"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.GAM.V04Test.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.GAM.V04Test.Ingress

    def observe(context, %Spectre.Input{text: text}, now, _) do
      GAM.Ingress.evidence(context, now,
        proposition: "request:refund",
        issuer_ref: context.authenticated_principal_ref,
        payload: text
      )
    end

    defdelegate observe(context, attrs, now, opts), to: Spectre.GAM.V04Test.Ingress
  end

  defmodule Executor do
    @behaviour GAM.Attempt.Executor
    defdelegate executor_ref(), to: Spectre.GAM.V04Test.Executor
    defdelegate contract_ref(), to: Spectre.GAM.V04Test.Executor

    def execute(act, attempt, _capability, opts) do
      send(opts[:observer], {:execution, act.ref, attempt.ref})

      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(
          act,
          attempt,
          :definitive_no_effect,
          Runtime.now(),
          payload: "provider initially reports no effect"
        )

      {:error, :definitive_no_effect,
       %{evidence: [evidence], details_ref: "receipt:initial-no-effect"}}
    end
  end

  defmodule Observer do
    @behaviour GAM.Attempt.Observer

    def observe(act, attempt, input, _opts) do
      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, input.status, Runtime.now(),
          payload: "independently verified correction of provider receipt"
        )

      {:ok, input.status, input.corrected_ref,
       %{evidence: [evidence], details_ref: "receipt:corrected"}}
    end
  end

  defmodule RuntimeServer do
    use Server

    def handle_flow({:support, :refund}, _input, ctx),
      do: propose(ctx, :refund, %{amount: 500}, on_result: :refunded)

    def handle_result(:refunded, {:governed, %{outcome: %{status: status}}}, ctx) do
      ctx
      |> assign(:observations, Map.get(ctx.assigns, :observations, []) ++ [status])
      |> respond(Atom.to_string(status))
    end
  end

  defmodule RuntimeAgent do
    use Spectre.Agent, server: RuntimeServer
    router(strategies: [:regex])

    flow :support do
      on(:refund, regex: ~r/^refund$/)
    end
  end

  def candidate(args, turn, context) do
    fixture = :ets.lookup_element(__MODULE__.Fixtures, context.assigns.fixture_key, 2)
    evidence_refs = Enum.uniq([fixture.refs.payment_evidence | Turn.evidence_refs(turn)])
    {:ok, Fixture.refund_candidate(fixture, args.amount, evidence_refs: evidence_refs)}
  end

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "no-effect-correction-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        mind: Mind,
        ingress: Ingress,
        late_observer: Observer,
        executors: [{Executor, observer: self()}],
        name: {:via, Registry, {GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, _} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))
    {:ok, scope} = Scope.new(Domain.handle(fixture.server, domain_ref), Fixture.context(fixture))
    :ets.new(__MODULE__.Fixtures, [:named_table, :protected])
    :ets.insert(__MODULE__.Fixtures, {"fixture", fixture})
    %{fixture: fixture, scope: scope}
  end

  for correction <- [:succeeded, :failed] do
    @tag :tmp_dir
    @tag correction: correction
    test "a real no-effect result retains its continuation across restart for late #{correction}",
         c do
      store = start_supervised!({Disk, path: Path.join(c.tmp_dir, "runtime.snapshot")})

      config = [
        scope: c.scope,
        store: store,
        bindings: %{refund: %{candidate: {__MODULE__, :candidate}}}
      ]

      opts = [
        agent: RuntimeAgent,
        consumer: self(),
        assigns: %{fixture_key: "fixture"},
        checkpoint: {store, "refund-agent"},
        gam: {Bridge, config}
      ]

      first = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
      assert {:ok, input_id} = Server.input(first, "refund")
      assert_receive {:execution, act_ref, attempt_ref}, 2_000
      assert_receive {Server, ^first, {:response, ^input_id, "definitive_no_effect", _}}, 2_000
      eventually(fn -> not Server.status(first).busy and Server.status(first).workers == 0 end)
      [command_id] = Map.keys(Server.status(first).operations)
      assert Server.status(first).assigns.observations == [:definitive_no_effect]
      assert :not_found = Disk.fetch(store, {:spectre_gam_command, command_id})
      {:ok, before} = GAM.view(c.scope)
      [initial_outcome] = before.outcomes
      assert initial_outcome.status == :definitive_no_effect

      :ok = stop_supervised(:runtime)
      restored = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)
      eventually(fn -> Server.status(restored).workers == 0 end)
      assert Map.has_key?(Server.status(restored).operations, command_id)
      Runtime.set_time(Runtime.now() + 10)

      assert {:ok, correction} =
               GAM.record_late_observation(c.scope, attempt_ref, %{
                 status: c.correction,
                 corrected_ref: initial_outcome.ref
               })

      assert correction.outcome.status == c.correction
      assert correction.outcome.contradicts_outcome_ref == initial_outcome.ref

      reference = %{
        decision_ref: hd(before.acts).decision_ref,
        act_ref: act_ref,
        outcome_ref: correction.outcome.ref
      }

      assert :ok =
               Server.deliver(
                 restored,
                 "late-provider-correction",
                 {:command, command_id},
                 {:governed_ref, reference}
               )

      corrected_text = Atom.to_string(c.correction)
      assert_receive {Server, ^restored, {:response, ^input_id, ^corrected_text, _}}, 2_000
      assert Server.status(restored).assigns.observations == [:definitive_no_effect, c.correction]
      assert Server.status(restored).operations == %{}

      :ok = stop_supervised(:runtime)
      final = start_supervised!({Spectre.Server.Runtime, opts}, id: :runtime)

      assert :ok =
               Server.deliver(
                 final,
                 "another-transport-id",
                 {:command, command_id},
                 {:governed_ref, reference}
               )

      assert Server.status(final).assigns.observations == [:definitive_no_effect, c.correction]
      refute_receive {Server, ^final, {:response, _, _, _}}, 50
      refute_receive {:execution, _, _}, 50
      {:ok, after_correction} = GAM.view(c.scope)
      assert after_correction.acts == before.acts
      assert after_correction.attempts == before.attempts
      assert length(after_correction.outcomes) == 2
      assert Enum.any?(after_correction.outcomes, &(&1.ref == initial_outcome.ref))
    end
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
