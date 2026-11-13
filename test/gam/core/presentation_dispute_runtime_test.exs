Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.PresentationDisputeRuntimeTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Candidate, Consent, Domain, Ledger, Presentation, Scope}
  alias Spectre.GAM.Domain.{Projection, Sequencer}
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule Executor do
    defdelegate executor_ref(), to: Spectre.GAM.V04Test.Executor
    defdelegate contract_ref(), to: Spectre.GAM.V04Test.Executor

    def execute(act, attempt, _capability, _opts) do
      {:ok, evidence} =
        GAM.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
          payload: "provider-confirmed receipt"
        )

      {:ok, %{evidence: [evidence], details_ref: "receipt:presentation-dispute"}}
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "presentation-dispute-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    f =
      Fixture.start_domain(
        namespace: namespace,
        consent: true,
        executors: [Executor],
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, scope} = Scope.new(Domain.handle(f.server, f.refs.domain), Fixture.context(f))
    {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    attrs = Fixture.refund_candidate(f, 500)
    {:ok, digest} = Consent.data_digest(attrs.consequence)

    consent = %{
      schema_version: 1,
      recipient_refs: [f.refs.proposer],
      data_digest: digest,
      cost: 500,
      purpose_ref: f.refs.purpose,
      purpose_params: attrs.purpose_params,
      risk: "irreversible",
      reversibility: false,
      alternatives: ["cancel"]
    }

    %{f: f, scope: scope, attrs: Map.put(attrs, :consent, consent)}
  end

  test "retracting authenticated approval creates a Duty without rewriting the successful effect",
       c do
    {presentation, show, result, approval} = execute_with_consent(c, [], [])
    before = Sequencer.projection(c.f.server)
    Runtime.set_time(Runtime.now() + 1)

    {:ok, counter} =
      Presentation.response_evidence(
        c.scope.context,
        presentation,
        show.primary.act,
        :contradicts,
        Runtime.now(),
        payload: "I retract that approval"
      )

    {:ok, [_]} = observe(c, counter)
    after_counter = Sequencer.projection(c.f.server)
    [duty] = Map.values(after_counter.duties)
    assert duty.class == :disputed_evidence
    assert duty.act_ref == result.primary.act.ref
    assert approval.ref in duty.evidence_refs
    assert counter.ref in duty.evidence_refs
    assert duty.containment["retry"] == :forbidden
    assert after_counter.acts == before.acts
    assert after_counter.outcomes == before.outcomes
    assert_replay(c)
  end

  test "later dispute of a nested consent premise preserves its complete causal basis", c do
    shared = premise(c, "terms-known", [])
    fee = premise(c, "fee-known", [shared.proposition])
    {_, _, result, approval} = execute_with_consent(c, [shared, fee], [fee.proposition])

    assert Enum.all?(
             [shared.ref, fee.ref, approval.ref],
             &(&1 in result.primary.act.recognition_evidence_refs)
           )

    before = Sequencer.projection(c.f.server)
    Runtime.set_time(Runtime.now() + 1)
    counter = premise(c, shared.proposition, [], :contradicts)
    after_counter = Sequencer.projection(c.f.server)
    [duty] = Map.values(after_counter.duties)
    assert duty.class == :disputed_evidence
    assert duty.act_ref == result.primary.act.ref

    assert Enum.all?(
             [shared.ref, fee.ref, approval.ref, counter.ref],
             &(&1 in duty.evidence_refs)
           )

    assert after_counter.acts == before.acts
    assert after_counter.outcomes == before.outcomes
    assert_replay(c)
  end

  defp execute_with_consent(c, premises, assumptions) do
    attrs =
      Map.update!(c.attrs, :evidence_refs, &(&1 ++ Enum.map(premises, fn item -> item.ref end)))

    {:ok, draft} = Candidate.new(attrs)
    consent = c.attrs.consent

    {:ok, presentation} =
      GAM.prepare_presentation(c.scope, %{
        candidate_binding_ref: Candidate.presentation_binding_ref(draft),
        scope_ref: Scope.ref(c.scope),
        recipient_refs: consent.recipient_refs,
        approval_source_refs: [GAM.V04Test.Ingress.ref()],
        data: draft.consequence,
        cost: consent.cost,
        purpose_ref: consent.purpose_ref,
        purpose_params: consent.purpose_params,
        risk: consent.risk,
        reversibility: false,
        alternatives: consent.alternatives,
        renderer_ref: "renderer:dispute",
        rendered_payload: "Approve refund?",
        prepared_at: Runtime.now()
      })

    {:ok, show} =
      GAM.show_presentation(c.scope, presentation.ref, %{
        identity_key: "show:dispute",
        requested_mandate_ref: c.f.mandate.ref,
        executor_ref: c.f.refs.executor,
        executor_contract_ref: c.f.refs.executor_contract,
        accountable_ref: c.f.refs.accountable,
        subject_refs: draft.subject_refs,
        evidence_refs: draft.evidence_refs,
        observation_window_ms: c.f.observation_window_ms
      })

    Runtime.set_time(Runtime.now() + 1)

    {:ok, approval} =
      Presentation.response_evidence(
        c.scope.context,
        presentation,
        show.primary.act,
        :supports,
        Runtime.now(),
        assumptions: assumptions,
        payload: "Approved subject to these premises"
      )

    {:ok, [_]} = observe(c, approval)

    {:ok, candidate} =
      attrs
      |> Map.put(:presentation_ref, presentation.ref)
      |> Map.update!(:evidence_refs, &(&1 ++ [approval.ref]))
      |> Candidate.new()

    {:ok, result} = GAM.propose(c.scope, candidate)
    assert result.primary.outcome.status == :succeeded
    {presentation, show, result, approval}
  end

  defp premise(c, proposition, assumptions, stance \\ :supports) do
    {:ok, evidence} =
      GAM.Ingress.evidence(c.scope.context, Runtime.now(),
        proposition: proposition,
        issuer_ref: c.f.refs.proposer,
        assumptions: assumptions,
        stance: stance,
        payload: "User observation"
      )

    {:ok, [recorded]} = observe(c, evidence)
    recorded
  end

  defp observe(c, evidence),
    do: GAM.observe(c.scope, evidence |> Map.from_struct() |> Map.delete(:ref))

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.f.store_config, c.f.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.f.constitution)
    assert replayed == Sequencer.projection(c.f.server)
    {:ok, exported} = Ledger.export(c.f.store_config, c.f.refs.domain)
    assert {:ok, _} = GAM.Audit.verify(exported, c.f.constitution, Runtime.now())
  end
end
