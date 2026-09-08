defmodule Spectre.AuthorityBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Authority.View
  alias Spectre.Domain.Projection
  alias Spectre.Kernel.Authority
  alias Spectre.Kernel.Authority.Coverage
  alias Spectre.V04Test.{Fixture, Runtime}

  test "invalid authority inputs consistently fail closed", c do
    facts = Projection.authority_view(c.before)
    context = Fixture.context(c.f)
    assert :none = Authority.resolve(nil, context, facts, Runtime.now())

    assert {:error, :invalid_authority_input} =
             Authority.eligible?(c.candidate, context, nil, facts, Runtime.now())

    assert {:error, :invalid_authority_input} =
             Authority.authorize(c.candidate, context, c.f.mandate, facts, 1.0)

    assert {:error, :invalid_authority_input} = Authority.meter_debt_status(nil, facts)
    assert {:error, :invalid_authority_input} = Authority.restriction_status(nil, facts)
    assert {:error, :invalid_authority_input} = Authority.containment_status(nil, facts)

    assert {:error, :invalid_authority_input} =
             Authority.dispatchable?(nil, c.f.mandate, facts, Runtime.now())

    assert :ok = Authority.eligible?(c.candidate, context, c.f.mandate, facts, Runtime.now())

    assert {:error, :mandate_expired} =
             Authority.eligible?(c.candidate, context, c.f.mandate, facts, c.f.mandate.expires_at)

    assert {:error, :act_mandate_snapshot_mismatch} =
             Authority.dispatchable?(
               %{c.act | mandate_revision: c.act.mandate_revision + 1},
               c.f.mandate,
               facts,
               Runtime.now()
             )
  end

  test "no missing authentication binding can be filled from a Candidate claim", c do
    facts = Projection.authority_view(c.before)
    context = Fixture.context(c.f)

    for key <- [:domain_ref, :scope_ref, :authentication_ref, :ingress_ref, :host_generation],
        absent <- [nil, ""] do
      assert {:error, {:incomplete_submission_context, ^key}} =
               Authority.authorize(
                 c.candidate,
                 Map.put(context, key, absent),
                 c.f.mandate,
                 facts,
                 Runtime.now()
               )
    end

    assert {:error, :unauthenticated_submission} =
             Authority.authorize(
               c.candidate,
               %{context | authenticated_principal_ref: nil},
               c.f.mandate,
               facts,
               Runtime.now()
             )

    assert {:error, :invalid_host_generation} =
             Authority.authorize(
               c.candidate,
               %{context | host_generation: 0.0},
               c.f.mandate,
               facts,
               Runtime.now()
             )

    assert {:error, :candidate_scope_mismatch} =
             Authority.authorize(
               %{c.candidate | scope_ref: "other"},
               context,
               c.f.mandate,
               facts,
               Runtime.now()
             )
  end

  test "authority coverage never invents absent claims or label-owner grants", c do
    facts = Projection.authority_view(c.before)
    context = Fixture.context(c.f)

    assert {:error, :candidate_proposer_missing} =
             Coverage.matching_principal(%{c.candidate | proposer_ref: nil}, context, c.f.mandate)

    assert {:error, :accountable_claim_mismatch} =
             Coverage.matching_accountable(
               %{c.candidate | accountable_ref: "another-owner"},
               c.f.mandate
             )

    assert {:error, :invalid_declassification_consequence} =
             Coverage.declassification_owners(
               %{c.candidate | class: "data.declassify", consequence: %{}},
               c.f.mandate,
               facts
             )

    assert {:error, _} =
             Coverage.declassification_owners(
               %{
                 c.candidate
                 | class: "data.declassify",
                   consequence: %{"evidence_declassification" => %{}}
               },
               c.f.mandate,
               facts
             )

    assert :ok =
             Authority.owners_authorize_mandate?(c.f.mandate, [c.f.mandate.grantor_ref], facts)

    assert {:error, {:label_owner_not_in_mandate_lineage, "outside-owner"}} =
             Authority.owners_authorize_mandate?(c.f.mandate, ["outside-owner"], facts)

    assert {:error, :declassification_label_owners_required} =
             Authority.owners_authorize_mandate?(c.f.mandate, [], facts)

    assert {:error, :invalid_declassification_authority} =
             Authority.owners_authorize_mandate?(c.f.mandate, nil, facts)

    assert {:error, :mandate_not_in_authority_view} =
             Authority.owners_authorize_mandate?(c.f.mandate, ["owner"], %{facts | mandates: %{}})
  end

  test "authority inventory rejects another Domain, missing foundation and broken lineage", c do
    domain = Spectre.Domain.handle(c.f.server, c.f.refs.domain)
    assert {:ok, scope} = Spectre.Scope.new(domain, Fixture.context(c.f))
    state = c.before
    assert {:ok, view} = View.from_projection(state, scope, Runtime.now())
    assert Enum.any?(view.held_mandates, &(&1.mandate.ref == c.f.mandate.ref))

    assert {:error, :authority_view_scope_mismatch} =
             View.from_projection(%{state | domain_ref: "foreign"}, scope, Runtime.now())

    assert {:error, :authority_view_foundation_missing} =
             View.from_projection(put_in(state.catalog.surface_ref, nil), scope, Runtime.now())

    assert {:error, :invalid_authority_view_input} = View.from_projection(state, scope, nil)

    mandate = %{c.f.mandate | parent_ref: "lost-ancestor"}
    corrupt = put_in(state.mandates[mandate.ref], mandate)

    assert {:error, {:invalid_authority_status, _, {:mandate_ancestor_missing, "lost-ancestor"}}} =
             View.from_projection(corrupt, scope, Runtime.now())
  end

  test "retained revocation controls are visible but never become executable capabilities", c do
    domain = Spectre.Domain.handle(c.f.server, c.f.refs.domain)
    assert {:ok, scope} = Spectre.Scope.new(domain, Fixture.context(c.f))

    mandate = %{
      c.f.mandate
      | revocation: %{
          "mode" => :retained_controller,
          "controller_refs" => [c.f.refs.proposer]
        }
    }

    state = c.before
    state = put_in(state.mandates[mandate.ref], mandate)
    assert {:ok, view} = View.from_projection(state, scope, Runtime.now())

    assert [control] = view.retained_revocation_controls
    assert control.mandate_ref == mandate.ref
    assert control.accountable_ref == mandate.accountable_ref
    assert control.blockers == []

    # A damaged revocation index cannot silently turn a retained control into
    # an apparently usable one. Keep it out of held Mandates to isolate the
    # retained-control derivation under test.
    mandate = %{mandate | scope_refs: ["scope:not-held-here"]}
    corrupt = put_in(state.mandates[mandate.ref], mandate)
    corrupt = %{corrupt | revocations: %{mandate.ref => :corrupt_record}}

    assert {:error, {:invalid_retained_revocation_state, _, {:invalid_mandate_revocation, _}}} =
             View.from_projection(corrupt, scope, Runtime.now())
  end
end
