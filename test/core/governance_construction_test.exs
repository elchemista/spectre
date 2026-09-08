defmodule Spectre.GovernanceConstructionTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Governance, Scope}
  alias Spectre.Governance.Builder
  alias Spectre.V04Test.Fixture

  setup c do
    domain = Spectre.Domain.handle(c.f.server, c.f.refs.domain)
    {:ok, scope} = Scope.new(domain, Fixture.context(c.f))

    attrs = %{
      identity_key: "administrative-proposal",
      requested_mandate_ref: c.f.mandate.ref,
      accountable_ref: c.f.mandate.accountable_ref,
      purpose_ref: c.candidate.purpose_ref
    }

    %{scope: scope, attrs: attrs}
  end

  test "administrative construction binds authority claims without granting or appending", c do
    before = Fixture.snapshot(c.f)
    child = %{c.f.mandate | ref: nil, parent_ref: c.f.mandate.ref}
    assert {:ok, delegate} = Governance.delegate_mandate(c.scope, child, c.attrs)
    assert delegate.class == "mandate.delegate"
    assert delegate.target_refs == [c.f.mandate.ref]

    assert {:ok, devolve} =
             Governance.devolve_mandate(c.scope, "child", %{"budget" => 12}, c.attrs)

    assert devolve.consequence["mandate_devolve"]["amounts"] === %{"budget" => 12}
    assert {:ok, revoke} = Governance.revoke_mandate(c.scope, c.f.mandate.ref, c.attrs)
    assert {:ok, revoke_record} = Governance.revoke_mandate(c.scope, c.f.mandate, c.attrs)
    assert revoke_record === revoke

    for candidate <- [delegate, devolve, revoke] do
      assert candidate.proposer_ref == c.scope.context.authenticated_principal_ref
      assert candidate.scope_ref == Scope.ref(c.scope)
      assert candidate.executor_ref == Governance.kernel_executor_ref()
      assert candidate.executor_contract_ref == Governance.kernel_contract_ref()
      assert candidate.meter_requests == %{}
      assert Governance.ledger_internal?(candidate)
      refute Governance.executor_mediated?(candidate)
      assert {:ok, :ledger_internal} = Governance.execution_mode(candidate)
      assert :ok = Governance.execution_boundary(candidate)
    end

    assert Governance.executor_mediated?(c.candidate)
    assert {:ok, :executor_mediated} = Governance.execution_mode(c.candidate)
    assert Governance.scope_open_dimensions() == [:write, :govern]
    assert is_binary(Governance.retained_revocation_purpose_ref())
    assert Fixture.snapshot(c.f) === before
  end

  test "helper failures cannot replace missing authority with a permissive default", c do
    assert {:error, :delegated_mandate_parent_required} =
             Governance.delegate_mandate(c.scope, c.f.mandate, c.attrs)

    assert {:error, _} = Governance.delegate_mandate(c.scope, %{}, c.attrs)
    assert {:error, _} = Governance.devolve_mandate(c.scope, "child", %{"budget" => 0}, c.attrs)

    assert {:error, :invalid_mandate_devolution} =
             Governance.devolve_mandate(c.scope, nil, %{}, c.attrs)

    assert {:error, :invalid_mandate_restriction} =
             Governance.restrict_mandate(c.scope, nil, %{}, c.attrs)

    assert {:error, :invalid_mandate_revocation} =
             Governance.revoke_mandate(c.scope, nil, c.attrs)

    assert {:error, :invalid_governed_scope_opening} =
             Governance.open_scope(c.scope, nil, %{}, c.attrs)

    assert {:error, :invalid_surface_revision} =
             Governance.revise_surface(c.scope, nil, %{}, c.attrs)

    assert {:error, :invalid_host_profile_revision} =
             Governance.revise_host_profile(c.scope, nil, %{}, c.attrs)

    assert {:error, :invalid_erasure_request} =
             Governance.request_erasure(c.scope, nil, %{}, c.attrs)

    for field <- [:identity_key, :requested_mandate_ref, :accountable_ref, :purpose_ref] do
      assert {:error, {:missing_governance_candidate_field, ^field}} =
               Governance.revoke_mandate(c.scope, c.f.mandate.ref, Map.delete(c.attrs, field))
    end

    assert {:error, {:non_intrinsic_governance_class, "refund.issue"}} =
             Builder.internal(c.scope, "refund.issue", %{}, c.attrs, [])
  end

  test "a Duty disposition proposal carries the exact opening, not a new discretionary cause",
       c do
    disposition = %{
      kind: :accept_loss,
      duty_ref: "duty:open",
      opening_digest: String.duplicate("a", 64),
      cause_key: {:ambiguous_outcome, c.act.ref, c.attempt.ref},
      supporting_refs: [c.payment.ref],
      meter_resolution: :none
    }

    assert {:ok, candidate} = Governance.dispose_duty(c.scope, disposition, c.attrs)
    assert candidate.class == "duty.dispose"
    assert candidate.target_refs == ["duty:open"]
    assert candidate.consequence["duty_disposition"]["cause_key"] === disposition.cause_key

    assert {:error, _} =
             Governance.dispose_duty(c.scope, %{disposition | opening_digest: "unknown"}, c.attrs)
  end
end
