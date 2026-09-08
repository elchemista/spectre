defmodule Spectre.Core.AttemptEvidenceBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Attempt.Evidence, as: AttemptEvidence
  alias Spectre.Attempt.Executor
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.Runtime

  test "one batch of executor facts must all belong to the consumed Attempt", c do
    assert :ok = AttemptEvidence.validate_all([c.receipt], c.act, c.attempt)
    assert :ok = AttemptEvidence.validate_all([], c.act, c.attempt)

    for invalid <- [nil, %{}, [c.receipt, nil]] do
      assert {:error, :invalid_executor_evidence} =
               AttemptEvidence.validate_all(invalid, c.act, c.attempt)
    end

    assert {:error, :invalid_executor_evidence} =
             AttemptEvidence.validate(%{}, c.act, c.attempt)

    assert {:error, :invalid_executor_evidence_cause} =
             AttemptEvidence.validate_attempt(c.act, %{})
  end

  for {field, value, error} <- [
        {:act_ref, "another-act", :executor_evidence_act_mismatch},
        {:executor_ref, "another-executor", :executor_evidence_executor_mismatch},
        {:material_digest, String.duplicate("f", 64), :executor_evidence_material_mismatch}
      ] do
    test "an Attempt with foreign #{field} cannot attest any Evidence", c do
      attempt = Map.replace!(c.attempt, unquote(field), unquote(value))

      assert {:error, unquote(error)} = AttemptEvidence.validate(c.receipt, c.act, attempt)

      assert {:error, unquote(error)} =
               AttemptEvidence.validate_all([c.receipt], c.act, attempt)
    end
  end

  for {field, value, error} <- [
        {:bindings, %{}, :executor_evidence_binding_mismatch},
        {:issuer_ref, "another-executor", :executor_evidence_source_mismatch},
        {:source_ref, "another-executor", :executor_evidence_source_mismatch},
        {:observed_at, 0, :executor_evidence_before_attempt},
        {:provenance, :invented, :invalid_executor_evidence_provenance},
        {:parent_refs, ["unobserved-input"], :observed_executor_evidence_has_parents}
      ] do
    test "executor reply validation rejects forged #{field} before any recording", c do
      evidence = Map.replace!(c.receipt, unquote(field), unquote(Macro.escape(value)))
      ref = evidence.ref

      assert {:error, {unquote(error), ^ref}} =
               AttemptEvidence.validate(evidence, c.act, c.attempt)

      assert {:error, {unquote(error), ^ref}} =
               AttemptEvidence.validate_all([c.receipt, evidence], c.act, c.attempt)

      assert Sequencer.projection(c.f.server) === c.attempted
    end
  end

  for provenance <- [:derived, :generated] do
    test "#{provenance} executor facts can depend only on inputs frozen in the Act", c do
      evidence = %{c.receipt | provenance: unquote(provenance), parent_refs: [c.payment.ref]}
      assert :ok = AttemptEvidence.validate(evidence, c.act, c.attempt)
      ref = evidence.ref

      assert {:error, {:invalid_executor_evidence_lineage, ^ref}} =
               AttemptEvidence.validate(%{evidence | parent_refs: []}, c.act, c.attempt)

      assert {:error, {:executor_evidence_parent_outside_act_inputs, ^ref}} =
               AttemptEvidence.validate(
                 %{evidence | parent_refs: [c.payment.ref, "later-input"]},
                 c.act,
                 c.attempt
               )
    end
  end

  test "builders reject untyped causes and unsupported outcome classifications", c do
    assert {:error, :invalid_executor_evidence} =
             Executor.evidence(c.act, c.attempt, 1.0, %{})

    assert {:error, :invalid_executor_evidence} =
             Executor.evidence(%{}, c.attempt, Runtime.now(), %{})

    assert {:error, :invalid_executor_outcome_evidence} =
             Executor.outcome_evidence(c.act, c.attempt, :timeout, Runtime.now(), %{})

    assert {:error, :invalid_executor_outcome_evidence} =
             Executor.outcome_evidence(c.act, c.attempt, :succeeded, 1.0, %{})
  end
end
