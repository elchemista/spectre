defmodule SpectreMorphObligationContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, id: :morph_obligation_agent

  morph(
    may_propose: [:mount_skill, :replace_skill, :disable_skill],
    within: [scopes: [:agent], prompt_tokens: 256],
    approval: :human
  )
end

defmodule SpectreMorphObligationContractTest.WrongAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_obligation_wrong_agent

  morph(
    may_propose: [:mount_skill],
    within: [scopes: [:agent], prompt_tokens: 256],
    approval: :human
  )
end

defmodule SpectreMorphObligationContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory
  alias Spectre.Execution.Closure
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.Approval
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.Composer
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Governance.Review
  alias Spectre.Instance
  alias Spectre.Morph
  alias Spectre.Morph.Change
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.Subject

  alias SpectreMorphObligationContractTest.Agent
  alias SpectreMorphObligationContractTest.WrongAgent

  @protected_cases [
    %{
      "id" => "unrelated-behaviour-remains-unknown",
      "input" => "weather",
      "expected_outcome" => "clarify",
      "context" => %{"scope" => "agent"},
      "llm" => "forbidden"
    }
  ]

  test "removing Morph-owned eval evidence fails in core composition without publishing" do
    %{instance: instance, server: server} = baseline()
    before_count = Memory.count(server)

    draft = draft(instance, "reviewed {{input.text}}")
    [mount, evaluation_case] = draft.operations
    assert evaluation_case["type"] == "add_eval_case"

    reviewed =
      %{draft | operations: [mount]}
      |> Morph.evaluate(cases: @protected_cases, now: 10)

    assert %Change{state: :draft, ref: nil} = reviewed
    assert {:morph_evaluation_obligation_missing, case_id} = reviewed.error
    assert is_binary(case_id)
    assert Memory.count(server) == before_count

    assert {:ok, turn} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = turn.decision
  end

  test "reply and eval-case mutations are both rejected while the exact pair changes a real turn" do
    %{instance: instance} = baseline()
    original = draft(instance, "reviewed {{input.text}}")
    [mount, evaluation_case] = original.operations

    changed_reply =
      put_in(
        mount,
        ["payload", "definition", "prompt_fragments", Access.at(0), "content"],
        "unreviewed {{input.text}}"
      )

    reply_tamper =
      %{original | operations: [changed_reply, evaluation_case]}
      |> Morph.evaluate(cases: @protected_cases, now: 20)

    assert {:morph_evaluation_obligation_mismatch, case_id} = reply_tamper.error

    changed_case =
      put_in(
        evaluation_case,
        ["payload", "case", "expected_output"],
        "unreviewed refund"
      )

    case_tamper =
      %{original | operations: [mount, changed_case]}
      |> Morph.evaluate(cases: @protected_cases, now: 21)

    assert case_tamper.error == {:morph_evaluation_obligation_mismatch, case_id}

    approved =
      original
      |> Morph.evaluate(cases: @protected_cases, now: 22)
      |> Morph.approve(by: "actor:reviewer", mode: :human, now: 23)

    assert %Change{state: :approved, error: nil} = approved
    assert {:ok, activation} = Morph.activate(approved, now: 24)
    assert activation.generation == 2

    assert {:ok, turn} = Spectre.turn(instance, "refund")
    assert {:reply, "reviewed refund", _turn_ref} = turn.observable
  end

  test "tampering transient change.agent cannot select a different checker Agent" do
    %{instance: instance} = baseline()

    evaluated =
      instance
      |> draft("bound {{input.text}}")
      |> then(&%{&1 | agent: WrongAgent})
      |> Morph.evaluate(cases: @protected_cases, now: 30)

    assert %Change{state: :evaluated, error: nil, agent: WrongAgent} = evaluated

    approved =
      Morph.approve(evaluated,
        by: "actor:reviewer",
        mode: :human,
        now: 31
      )

    assert {:ok, _activation} = Morph.activate(approved, now: 32)
    assert Instance.agent(instance) == Agent

    assert {:ok, turn} = Spectre.turn(instance, "refund")
    assert {:reply, "bound refund", _turn_ref} = turn.observable
  end

  test "runtime Loader rejects a Definition owned by another Agent module" do
    %{store: store, canonical: canonical} = baseline()
    definition_ref = Canonical.ref(canonical)

    assert {:ok, loaded} = Loader.load(store, definition_ref, Agent)
    assert loaded.agent == Agent

    assert {:error, {:runtime_skill_agent_definition_mismatch, expected}} =
             Loader.load(store, definition_ref, WrongAgent)

    assert expected == Atom.to_string(WrongAgent)
  end

  test "activation re-derives obligations from a durable Candidate instead of trusting receipts" do
    %{store: store, instance: instance, activation: activation} = baseline()
    valid_draft = draft(instance, "reviewed {{input.text}}")

    change_set =
      ChangeSet.new!(%{
        base_activation_receipt: activation.activation_receipt,
        base_candidate_ref: activation.candidate_ref,
        observed_definition_ref: activation.definition_ref,
        observed_authority_epoch: activation.authority_epoch,
        observed_evidence_digest: ChangeSet.evidence_digest(activation, %{}),
        operations: valid_draft.operations,
        author_ref: "actor:adversarial-host",
        provenance: %{"origin" => "obligation-contract-test"},
        reason: "construct a valid Definition before removing its review obligation",
        created_at: 40
      })

    assert {:ok, composed_ref} =
             Composer.compose(store, change_set,
               activation: activation,
               evidence: %{},
               created_at: 40
             )

    assert {:ok, composed} = Store.fetch_candidate(store, composed_ref)
    assert [_required_case] = composed.governance.candidate_cases

    forged_composed = publish_without_candidate_cases!(store, composed, 41)
    assert forged_composed.governance.candidate_cases == []

    assert {:ok, delta, receipts} =
             Declarative.run(store, forged_composed, @protected_cases,
               agent: Agent,
               issued_at: 42
             )

    assert delta.candidate_owned_results == []

    assert {:ok, evaluated_ref, _report} =
             Review.evaluate(store, Candidate.ref(forged_composed), delta, receipts,
               reviewed_at: 43,
               now: 43,
               checker_versions: Declarative.checker_versions()
             )

    assert {:ok, approved_ref} =
             Approval.approve(store, evaluated_ref,
               mode: :human,
               actor_ref: "actor:reviewer",
               approved_at: 44
             )

    assert {:error, {:morph_evaluation_obligation_missing, case_id}} =
             Spectre.activate(instance, approved_ref,
               expected_generation: 1,
               now: 45,
               checker_versions: Declarative.checker_versions()
             )

    assert is_binary(case_id)
    assert Instance.activation(instance).generation == 1
    assert {:ok, turn} = Spectre.turn(instance, "refund")
    assert {:no_response, _result} = turn.decision
  end

  defp publish_without_candidate_cases!(store, composed, created_at) do
    governance = composed.governance

    evaluation_cases_digest =
      Value.digest!(%{
        "protected_corpus_digest" => governance.protected_cases_digest,
        "candidate_cases" => []
      })

    empty_governance =
      governance
      |> CandidateState.to_data()
      |> Map.delete("proposal_digest")
      |> Map.put("candidate_cases", [])
      |> Map.put("candidate_case_ids", [])
      |> Map.put("evaluation_cases_digest", evaluation_cases_digest)
      |> Map.put("gate_receipt_refs", [])
      |> CandidateState.new!()

    rebound_receipt_refs =
      Enum.map(governance.gate_receipt_refs, fn receipt_ref ->
        assert {:ok, receipt} = Store.fetch_gate_receipt(store, receipt_ref)

        rebound =
          receipt
          |> Receipt.to_data()
          |> Map.put("candidate_digest", empty_governance.proposal_digest)
          |> Map.put("evaluation_cases_digest", evaluation_cases_digest)
          |> Receipt.new!()

        assert {:ok, rebound_ref} = Store.publish_gate_receipt(store, rebound)
        to_string(rebound_ref)
      end)

    forged_governance =
      empty_governance
      |> CandidateState.to_data()
      |> Map.put("gate_receipt_refs", rebound_receipt_refs)
      |> CandidateState.new!()

    forged =
      composed
      |> Map.from_struct()
      |> Map.put(:governance, forged_governance)
      |> Map.put(:created_at, created_at)
      |> Candidate.new!()

    assert {:ok, forged_ref} = Store.publish_candidate(store, forged)
    assert {:ok, ^forged} = Store.fetch_candidate(store, forged_ref)
    forged
  end

  defp draft(instance, reply) do
    instance
    |> Morph.change(by: "actor:author", reason: "teach one reviewed exact reply")
    |> Morph.mount_skill("refunds", match: "refund", reply: reply)
  end

  defp baseline do
    id = {:morph_obligation, System.unique_integer([:positive, :monotonic])}
    server = start_supervised!(%{id: id, start: {Memory, :start_link, [[id: id]]}})
    store = {Memory, server: server}
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, authority(), closure())

    assert {:ok, _publication} = Store.publish(store, canonical, manifest)

    assert {:ok, bootstrap} =
             Resolver.bootstrap_candidate(store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    subject = Subject.new("morph-obligation-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!(%{
        id: {:morph_obligation_instance, make_ref()},
        start:
          {Instance, :start_link,
           [
             [
               agent: Agent,
               subject: subject,
               definition_store: store,
               opts: [checker_versions: Declarative.checker_versions()],
               idle: false
             ]
           ]}
      })

    assert {:ok, activation} = Spectre.activate(instance, bootstrap, expected_generation: 0)

    %{
      server: server,
      store: store,
      instance: instance,
      activation: activation,
      bootstrap: bootstrap,
      canonical: canonical
    }
  end

  defp authority do
    Envelope.new!(
      open_capabilities: [
        Spectre.Skill.Runtime.capability(:mount),
        Spectre.Skill.Runtime.capability(:replace),
        Spectre.Skill.Runtime.capability(:disable)
      ],
      prompt_budget_classes: [:small, :standard],
      limits: %{max_tokens: 1_024}
    )
  end

  defp closure do
    {:ok, build_digest} = Closure.fingerprint(Agent)

    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [%{id: "spectre.projection.audit", version: 1}],
      state_schema_ref: "spectre.instance.canonical/2",
      state_codec_ref: "spectre.instance.canonical.codec/2",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{("beam:" <> Atom.to_string(Agent)) => build_digest},
      evaluation_corpus_digest: EvaluationDelta.protected_corpus_digest!(@protected_cases),
      compatibility_mode: :native_v2
    })
  end
end
