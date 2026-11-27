Code.require_file("../support/gam/helper.exs", __DIR__)

defmodule Spectre.Server.GAMConsentBoundariesTest do
  use ExUnit.Case, async: false

  alias ExGAM, as: GAM
  alias ExGAM.{Candidate, Consent, Domain, Presentation, Scope}
  alias ExGAM.Domain.Sequencer
  alias ExGAM.Mind.Turn
  alias Spectre.Test.GAM.{Fixture, Runtime}
  alias Spectre.Server.GAM, as: Bridge

  defmodule Mind do
    use ExGAM.Mind, ref: "mind:consent-boundaries"
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule Ingress do
    defdelegate ref(), to: Spectre.Test.GAM.Ingress
    defdelegate authenticate(d, s, i, g, o), to: Spectre.Test.GAM.Ingress

    def observe(context, %{kind: :presentation_response} = envelope, now, _) do
      Presentation.response_evidence(
        context,
        envelope.presentation,
        envelope.show_act,
        envelope.stance,
        now,
        payload: envelope.input,
        valid_until: envelope.expires_at
      )
    end

    defdelegate observe(context, attrs, now, opts), to: Spectre.Test.GAM.Ingress
  end

  defmodule Executor do
    defdelegate executor_ref(), to: Spectre.Test.GAM.Executor
    defdelegate contract_ref(), to: Spectre.Test.GAM.Executor

    def execute(act, attempt, _, opts) do
      send(opts[:observer], {:effect, act.class})

      status =
        if opts[:fail_show] and act.class == "presentation.show", do: :failed, else: :succeeded

      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, status, Runtime.now(),
          payload: "provider receipt"
        )

      observation = %{evidence: [evidence], details_ref: "receipt:consent-boundaries"}
      if status == :succeeded, do: {:ok, observation}, else: {:error, :failed, observation}
    end
  end

  def candidate(args, turn, context) do
    f = context.fixture

    attrs =
      Fixture.refund_candidate(f, args.amount,
        evidence_refs: Enum.uniq([f.refs.payment_evidence | Turn.evidence_refs(turn)])
      )

    {:ok, digest} = Consent.data_digest(attrs.consequence)

    consent = %{
      schema_version: 1,
      recipient_refs: [f.refs.proposer],
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
    f = context.fixture
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
        renderer_ref: "renderer:consent-boundaries",
        rendered_payload: "Approve refund?",
        prepared_at: Runtime.now()
      })

    show = %{
      identity_key: "show:fixed",
      requested_mandate_ref: f.mandate.ref,
      executor_ref: f.refs.executor,
      executor_contract_ref: f.refs.executor_contract,
      accountable_ref: f.refs.accountable,
      subject_refs: candidate.subject_refs,
      evidence_refs: candidate.evidence_refs,
      observation_window_ms: f.observation_window_ms
    }

    case Map.get(context, :presentation_mode) do
      :wrong_candidate ->
        attrs = presentation |> Map.from_struct() |> Map.drop([:ref, :material_digest])
        {:ok, Map.put(attrs, :candidate_binding_ref, "candidate:other"), show}

      :keyword_window ->
        {:ok, presentation, observation_window_ms: 0}

      :invalid_show ->
        {:ok, presentation, :no_show_material}

      _ ->
        {:ok, presentation, show}
    end
  end

  def interpret("no", _), do: :reject
  def interpret("yes", _), do: :confirm
  def interpret(_, _), do: :unsupported

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "consent-boundaries-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    f =
      Fixture.start_domain(
        namespace: namespace,
        consent: Map.get(tags, :consent, true),
        mind: Mind,
        ingress: Ingress,
        executors: [{Executor, observer: self(), fail_show: Map.get(tags, :fail_show, false)}],
        name: {:via, Registry, {ExGAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    {:ok, scope} = Scope.new(Domain.handle(f.server, domain_ref), Fixture.context(f))

    input =
      f
      |> Fixture.paid_evidence(%{proposition: "request refund"})
      |> Map.from_struct()
      |> Map.delete(:ref)

    binding = %{
      candidate: {__MODULE__, :candidate},
      presentation: {__MODULE__, :presentation},
      interpreter: {__MODULE__, :interpret}
    }

    config = [scope: scope, consent_ttl_ms: :infinity, bindings: %{refund: binding}]

    %{
      f: f,
      scope: scope,
      context: %{fixture: f, input: input},
      config: config,
      opts: [bridge_config: config]
    }
  end

  test "an explicit no through confirm records rejection and never executes the requested effect",
       c do
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 100}, c.context, c.opts)
    assert pending.expires_at == nil
    assert {:consent, :rejected} = Bridge.confirm(pending, "no", c.context, c.opts)

    proposition =
      Presentation.approval_proposition(pending.presentation.ref, pending.show.primary.act.ref)

    assert {:ok, view} = GAM.view(c.scope)

    assert Enum.any?(
             view.evidence,
             &(&1.proposition == proposition and &1.stance == :contradicts)
           )

    refute_receive {:effect, "refund.issue"}, 20
  end

  test "resume cannot reuse the old show identity, and unknown interpreters cannot become approval",
       c do
    assert {:pending, pending} = Bridge.propose(:refund, %{amount: 100}, c.context, c.opts)

    assert {:error, :presentation_show_identity_reused} =
             Bridge.resume(pending, nil, c.context, c.opts)

    assert {:error, :confirmation_not_supported} =
             Bridge.confirm(pending, "maybe", c.context, c.opts)

    config =
      Keyword.update!(c.config, :bindings, fn bindings ->
        put_in(bindings, [:refund, :interpreter], nil)
      end)

    assert {:error, :confirmation_unclear} =
             Bridge.confirm(%{pending | interpreter: nil}, "yes", c.context, bridge(config))

    refute_receive {:effect, "refund.issue"}, 20
  end

  test "show material must bind the exact candidate and contain a positive observation window",
       c do
    for {mode, error} <- [
          wrong_candidate: :presentation_candidate_mismatch,
          keyword_window: :presentation_observation_window_required,
          invalid_show: :presentation_observation_window_required
        ] do
      assert {:error, ^error} =
               Bridge.propose(
                 :refund,
                 %{amount: 100},
                 Map.put(c.context, :presentation_mode, mode),
                 c.opts
               )
    end

    assert {:ok, view} = GAM.view(c.scope)
    assert view.acts == []
  end

  @tag fail_show: true
  test "a failed show cannot open a confirmable consent", c do
    assert {:error, :presentation_not_shown} =
             Bridge.propose(:refund, %{amount: 100}, c.context, c.opts)

    refute_receive {:effect, "refund.issue"}, 20
  end

  @tag consent: false
  test "an admitted Act without an Outcome is recoverable but unknown record references are not",
       c do
    attrs = Fixture.refund_candidate(c.f, 100)

    assert {:ok, %{decision: decision, act: act}} =
             Sequencer.submit(c.f.server, c.scope.context, attrs)

    reference = %{decision_ref: decision.ref, act_ref: act.ref, outcome_ref: nil}

    assert {:governed, %{decision: ^decision, act: ^act, attempt: nil, outcome: nil}} =
             Bridge.resolve_result(reference, c.context, c.opts)

    for unknown <- [
          %{reference | decision_ref: "decision:missing"},
          %{reference | act_ref: "act:missing"}
        ] do
      assert {:error, :execution_result_not_found} =
               Bridge.resolve_result(unknown, c.context, c.opts)
    end

    assert {:error, :domain_not_found} = GAM.lookup_domain("domain:absent")
    assert {:error, :invalid_scope} = Scope.new(c.scope.domain, nil)
  end

  @tag :tmp_dir
  test "journal capacity failures never acquire the effect or hide recovery errors", c do
    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "small.snapshot"), max_bytes: 32}
      )

    opts = bridge(Keyword.put(c.config, :store, store))
    context = Map.put(c.context, :command_id, "command:too-large")

    assert {:error, :store_capacity_exceeded} =
             Bridge.propose(:refund, %{amount: 100}, context, opts)

    assert {:error, :governed_recovery_required} = Bridge.recover_command("absent", context, opts)
    assert {:error, :gam_bridge_config_required} = Bridge.recover_command("absent", context, [])
    refute_receive {:effect, _}, 20
  end

  defp bridge(config), do: [bridge_config: config]
end
