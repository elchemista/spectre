defmodule Spectre.ConsequenceValidatorBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Consequence.Validator

  test "portable validator identifiers never turn ledger data into executable callbacks", c do
    none = Validator.none()
    assert :ok = Validator.validate(none, c.candidate, c.before, c.act.committed_at)
    assert :ok = Validator.validate_transition(none, c.candidate, c.decision, c.act, c.before)

    for id <- [nil, Validator, &Validator.none/0, "app:execute-arbitrary-code"] do
      assert {:error, {:unknown_consequence_validator, ^id}} = Validator.validate_id(id)

      assert {:error, {:unknown_consequence_validator, ^id}} =
               Validator.validate(id, nil, nil, nil)
    end

    assert {:error, {:invalid_consequence_validator_binding, nil, ^none}} =
             Validator.validate_binding(nil, none)

    assert {:error, :invalid_consequence_validator_input} =
             Validator.validate(none, nil, c.before, 1)

    assert {:error, :invalid_consequence_transition_input} =
             Validator.validate_transition(none, nil, nil, nil, nil)

    assert {:error, :invalid_consequence_transition} =
             Validator.validate_transition(
               none,
               c.candidate,
               %{c.decision | outcome: :refused},
               c.act,
               c.before
             )

    assert {:error, :consequence_transition_class_mismatch} =
             Validator.validate_transition(
               none,
               c.candidate,
               c.decision,
               %{c.act | class: "another.class"},
               c.before
             )
  end

  test "governance validators require an exact command rather than trusting its class label", c do
    for {class, reason} <- [
          {"data.erase", :invalid_erasure_request},
          {"mandate.revoke", :invalid_mandate_revocation}
        ] do
      candidate = %{c.candidate | class: class, consequence: %{}}

      assert {:error, ^reason} =
               Validator.validate(
                 Validator.default_for_class(class),
                 candidate,
                 c.before,
                 c.act.committed_at
               )
    end

    candidate = %{c.candidate | class: "data.erase", consequence: %{"erasure_request" => %{}}}
    id = Validator.default_for_class(candidate.class)
    assert {:error, _} = Validator.validate(id, candidate, c.before, c.act.committed_at)

    digest = Spectre.Portable.digest!("private customer data")

    {:ok, draft} =
      Spectre.Erasure.request_draft(%{
        target_ref: "payload:" <> digest,
        target_digest: digest,
        scope_ref: "another-scope",
        affected_refs: [],
        reason: "retention",
        reduces_verifiability: false,
        requested_at: c.act.committed_at
      })

    assert {:error, :invalid_erasure_request} =
             Validator.validate(
               id,
               %{candidate | consequence: %{"erasure_request" => draft}},
               c.before,
               c.act.committed_at
             )
  end
end
