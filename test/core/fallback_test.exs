Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.CoreTest.FallbackTest do
  use ExUnit.Case, async: false

  alias Spectre.{Candidate, Fallback, Kernel}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Fallback.Policy
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "fallback")
    on_exit(fn -> Fixture.stop_domain(fixture) end)
    context = Fixture.context(fixture)
    projection = Sequencer.projection(fixture.server)

    assert {:ok, candidate} =
             fixture
             |> Fixture.refund_candidate(100)
             |> Map.put(:requested_mandate_ref, "missing-mandate")
             |> Candidate.new()

    assert {:ok, %{outcome: :refused} = decision, nil} =
             Kernel.evaluate(candidate, context, projection, Runtime.now())

    %{fixture: fixture, context: context, projection: projection, decision: decision}
  end

  test "silence is explicit and policy encoding has one canonical form", %{
    decision: d,
    context: c
  } do
    assert {:ok, policy} = Policy.new(:silence)
    assert {:ok, ^policy} = policy |> Policy.canonical() |> Policy.from_canonical()
    assert {:ok, :silence} = Fallback.materialize(policy, d, c)

    assert {:error, :noncanonical_fallback_policy} =
             Policy.from_canonical(%{"mode" => :silence})

    assert {:error, :invalid_fallback_policy} = Policy.from_canonical(nil)
    assert {:error, :invalid_fallback_input} = Fallback.materialize(:silence, nil, c)
  end

  test "templates bind fresh identity and context without inheriting authority or Evidence",
       data do
    for mode <- [:candidate_template, :governed_handoff] do
      assert {:ok, policy} = Policy.new(mode: mode, template: template(data.fixture))
      assert {:ok, ^policy} = policy |> Policy.canonical() |> Policy.from_canonical()

      assert {:ok, {^mode, candidate}} =
               Fallback.materialize(policy, data.decision, data.context)

      assert candidate.identity_key == "fallback:" <> data.decision.ref
      assert candidate.scope_ref == data.context.scope_ref
      assert candidate.proposer_ref == data.context.authenticated_principal_ref
      assert candidate.requested_mandate_ref == nil
      assert candidate.evidence_refs == []
      assert candidate.presentation_ref == nil
      assert candidate.consent == nil

      # Materializing a response does not admit it or reserve a Meter.
      assert Sequencer.projection(data.fixture.server) == data.projection

      assert {:ok, decision, nil} =
               Kernel.evaluate(candidate, data.context, data.projection, Runtime.now())

      refute decision.outcome == :admitted
    end
  end

  test "fallback cannot be rebound to another authenticated context", data do
    assert {:ok, other} =
             data.context
             |> Map.from_struct()
             |> Map.merge(%{ref: nil, seal: nil, authentication_ref: "another-authentication"})
             |> Spectre.SubmissionContext.new()

    assert {:error, :fallback_context_mismatch} =
             Fallback.materialize(:silence, data.decision, other)
  end

  test "the real proposal driver stops after one refused fallback without guessing its origin",
       data do
    template = Map.put(template(data.fixture), :requested_mandate_ref, "missing-mandate")
    assert {:ok, policy} = Policy.new(mode: :candidate_template, template: template)

    domain_ref = "v0.4:fallback-bounded:domain"

    fixture =
      Fixture.start_domain(
        namespace: "fallback-bounded",
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        fallbacks: %{"refund.issue" => policy}
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(domain_ref)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))
    attrs = Map.put(Fixture.refund_candidate(fixture, 100), :requested_mandate_ref, "absent")

    assert {:ok, result} = Spectre.propose(scope, attrs)
    assert result.primary.decision.outcome == :refused
    assert %{mode: :candidate_template, result: fallback} = result.fallback
    assert fallback.decision.outcome == :refused
    assert fallback.act == nil
    projection = Sequencer.projection(fixture.server)
    assert map_size(projection.decisions) == 2
    assert projection.acts == %{}
    assert projection.attempts == %{}

    assert {:ok, ^result} = Spectre.propose(scope, attrs)
    assert Sequencer.projection(fixture.server) === projection

    assert {:ok, ^projection} =
             Projection.replay(
               Fixture.snapshot(fixture),
               fixture.constitution
             )
  end

  test "undecidable and unknown classes remain distinct from refusal", data do
    for {changes, outcome} <- [
          {%{}, :undecidable},
          {%{class: "undeclared-class"}, :unknown_class}
        ] do
      assert {:ok, candidate} =
               data.fixture
               |> Fixture.refund_candidate(100, evidence_refs: [])
               |> Map.merge(changes)
               |> Candidate.new()

      assert {:ok, %{outcome: ^outcome} = decision, nil} =
               Kernel.evaluate(candidate, data.context, data.projection, Runtime.now())

      assert {:error, {:fallback_not_applicable, ^outcome}} =
               Fallback.materialize(:silence, decision, data.context)
    end
  end

  test "templates cannot supply the occurrence identity or trusted proposer", data do
    for {key, value} <- [identity_key: "reused", proposer_ref: "other", scope_ref: "other"] do
      assert {:error, _reason} =
               Policy.new(
                 mode: :candidate_template,
                 template: Map.put(template(data.fixture), key, value)
               )
    end
  end

  defp template(fixture) do
    fixture
    |> Fixture.refund_candidate(100, evidence_refs: [])
    |> Map.drop([
      :identity_key,
      :proposer_ref,
      :scope_ref,
      :requested_mandate_ref,
      :evidence_refs,
      :consent,
      :presentation_ref
    ])
  end
end
