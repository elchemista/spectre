Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.ScopedQueryBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Condition, Scope, Surface}
  alias Spectre.GAM.Domain.Command.Scope, as: ScopeCommand
  alias Spectre.GAM.Domain.{Configuration, Query}
  alias Spectre.GAM.Domain.Sequencer.State
  alias Spectre.GAM.Scope.Opening
  alias Spectre.GAM.V04Test.Fixture

  setup c do
    {:ok, config} = Configuration.new(c.f.sequencer_opts)

    {:ok, scope} =
      Scope.new(Spectre.GAM.Domain.handle(c.f.server, c.f.refs.domain), Fixture.context(c.f))

    %{state: State.new(config, c.attempted), scope: scope}
  end

  test "local recovery queries do not confuse absent records with another Scope", c do
    assert {:error, {:act_not_found, "missing"}} = query(c, {:dispatch_status, "missing"})

    assert {:error, :execution_result_not_found} =
             query(c, {:recover_attempt, "missing", c.act.ref})

    assert {:ok, %{mode: :executor_mediated, pending?: false}} =
             query(c, {:dispatch_status, c.act.ref})

    state = c.state
    other = put_in(state.projection.acts[c.act.ref].scope_ref, "another-session")
    c = %{c | state: other}
    assert {:error, :act_scope_mismatch} = query(c, {:dispatch_status, c.act.ref})

    assert {:error, :execution_result_scope_mismatch} =
             query(c, {:recover_attempt, c.decision.ref, c.act.ref})

    assert {:error, :outcome_scope_mismatch} = query(c, {:outcome_scope, c.act.ref})

    assert {:error, :late_observation_cause_mismatch} =
             query(c, {:late_observation, c.attempt.ref})
  end

  test "invalid read models cannot masquerade as a typed Mandate or Presentation", c do
    state = c.state
    broken = put_in(state.projection.mandates[c.f.mandate.ref], %{})

    assert {:error, {:invalid_mandate_record, _}} =
             query(%{c | state: broken}, {:mandate, c.f.mandate.ref})

    broken = put_in(state.projection.presentations["presentation"], %{})

    assert {:error, {:invalid_presentation_record, "presentation"}} =
             query(%{c | state: broken}, {:presentation, "presentation"})

    broken = put_in(state.projection.acts[c.act.ref].class, "mandate.revoke")
    assert {:error, _} = query(%{c | state: broken}, {:dispatch_status, c.act.ref})
    assert {:error, :invalid_domain_query} = query(c, {:records, :all_private_state})
  end

  test "historical Surface selection refuses absence or an ambiguous revision", c do
    state = c.state
    surface = Spectre.GAM.GovernedAct.State.surface(state.projection)
    assert {:ok, ^surface} = query(c, {:surface, surface.revision})
    assert {:error, {:historical_surface_not_found, 99}} = query(c, {:surface, 99})

    {:ok, duplicate_revision} =
      Surface.new(%{surface | ref: nil, presentation_required_classes: [c.candidate.class]})

    state = put_in(state.projection.catalog.surfaces[duplicate_revision.ref], duplicate_revision)
    assert {:error, {:ambiguous_surface_revision, 1}} = query(%{c | state: state}, {:surface, 1})
  end

  test "direct opening retries are idempotent and cannot rewrite the existing occurrence", c do
    opening = c.state.projection.catalog.scopes[c.f.refs.scope]
    assert {:ok, same, ^opening} = ScopeCommand.open(c.state, c.scope.context, opening)
    assert same === c.state
    changed = %{opening | opened_at: opening.opened_at - 1}

    assert {:error, ^same, {:scope_identity_conflict, _}} =
             ScopeCommand.open(c.state, c.scope.context, changed)

    future = %{opening | opened_at: opening.opened_at + 1}

    assert {:error, ^same, {:scope_opening_from_future, _}} =
             ScopeCommand.open(c.state, c.scope.context, future)
  end

  test "Work and Vigil promises cannot bypass governed admission through direct opening", c do
    base = c.state.projection.catalog.scopes[c.f.refs.scope]

    {:ok, condition} =
      Condition.new(proposition: "work.finished", bindings: %{"scope_ref" => base.ref})

    for kind <- [:work, :vigil] do
      {:ok, opening} =
        Opening.new(%{
          base
          | parent_ref: "parent",
            kind: kind,
            source_act_ref: "act:opening",
            promise_condition: condition,
            accountable_ref: c.f.mandate.accountable_ref,
            disposition_authority_refs: [c.f.mandate.grantor_ref],
            due_at: base.opened_at + 100
        })

      assert {:error, unchanged, {:governed_scope_opening_required, ^kind}} =
               ScopeCommand.open(c.state, c.scope.context, opening)

      assert unchanged === c.state
    end
  end

  defp query(c, query), do: Query.scoped(c.state, c.scope, query)
end
