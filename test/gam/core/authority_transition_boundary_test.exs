Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.AuthorityTransitionBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Act, Definition, Governance, HostProfile, Mandate, Row}
  alias Spectre.GAM.Domain.Event
  alias Spectre.GAM.GovernedAct.{AuthorityChange, State, Transition}

  test "revocation replay checks the controller, effect Row, target and exact time", c do
    act =
      internal_act(
        c.act,
        "mandate.revoke",
        %{"mandate_revoke" => %{"mandate_ref" => c.f.mandate.ref}},
        [c.f.mandate.ref]
      )

    act = %{act | proposer_ref: c.f.mandate.grantor_ref}

    event = %Event{
      type: "mandate_revoked",
      identity: act.ref,
      data: %{"mandate_ref" => c.f.mandate.ref, "effective_at" => act.committed_at}
    }

    state = c.before
    state = put_in(state.acts[act.ref], act)
    assert {:ok, revoked} = Transition.Authority.apply(state, event, nil)
    assert revoked.revocations[c.f.mandate.ref].effective_at == act.committed_at

    assert {:ok, mandate_ref, true} = AuthorityChange.resolve(revoked, act, :mandate_revoked)
    assert mandate_ref == c.f.mandate.ref

    assert {:error, {:dispatch_cancellation_revocation_not_recorded, _}} =
             AuthorityChange.resolve(%{revoked | revocations: %{}}, act, :mandate_revoked)

    wrong_identity = put_in(revoked.revocations[mandate_ref].identity, "act:other")

    assert {:error, {:dispatch_cancellation_revocation_mismatch, _}} =
             AuthorityChange.resolve(wrong_identity, act, :mandate_revoked)

    assert {:error, {:dispatch_cancellation_revocation_mismatch, _}} =
             AuthorityChange.resolve(
               %{revoked | revocations: %{mandate_ref => :corrupt_record}},
               act,
               :mandate_revoked
             )

    assert {:error, {:mandate_not_found, ^mandate_ref}} =
             AuthorityChange.resolve(%{revoked | mandates: %{}}, act, :mandate_revoked)

    assert {:error, {:invalid_dispatch_cancellation_cause, _, :mandate_restricted}} =
             AuthorityChange.resolve(revoked, act, :mandate_restricted)

    assert {:error, {:mandate_already_revoked, _}} =
             Transition.Authority.apply(revoked, event, nil)

    for {field, value, reason} <- [
          {:class, "refund.issue", :revocation_act_class_mismatch},
          {:row, c.act.row, :revocation_act_row_mismatch},
          {:reservations, c.act.reservations, :revocation_act_has_reservations},
          {:target_refs, [], :revocation_act_target_missing},
          {:proposer_ref, "unappointed-controller", :revocation_controller_not_authorized},
          {:consequence, %{}, :revocation_consequence_mismatch}
        ] do
      assert {:error, error} =
               Transition.Authority.apply(
                 put_in(state.acts[act.ref], Map.put(act, field, value)),
                 event,
                 nil
               )

      assert elem(error, 0) == reason
    end

    assert {:error, {:invalid_revocation_effective_at, _, _}} =
             Transition.Authority.apply(
               state,
               put_in(event.data["effective_at"], act.committed_at / 1),
               nil
             )

    assert {:error, {:act_not_found, _}} = Transition.Authority.apply(c.before, event, nil)
  end

  test "Definition replay cannot publish a different effect than the authorizing Act", c do
    {:ok, definition} =
      Definition.new(
        namespace: "proof",
        name: "assistant",
        revision: 1,
        declared_at: c.act.committed_at,
        body: %{"prompt" => "Propose, do not claim execution."}
      )

    consequence = %{
      "definition_revision" => %{
        "previous_ref" => nil,
        "definition" => Definition.canonical(definition)
      }
    }

    act = internal_act(c.act, "definition.revise", consequence, [definition.ref])
    {:ok, payload} = Event.definition_revised(act, definition)
    {:ok, event} = Event.decode(payload)
    state = c.before
    state = put_in(state.acts[act.ref], act)
    assert {:ok, published} = Transition.Foundation.apply(state, event, nil)
    assert published.catalog.definition_heads[Definition.key(definition)] == definition.ref

    for {field, value, reason} <- [
          {:class, "refund.issue", :definition_revision_act_class_mismatch},
          {:row, c.act.row, :definition_revision_act_row_mismatch},
          {:reservations, c.act.reservations, :definition_revision_act_has_reservations},
          {:target_refs, [], :definition_revision_targets_missing},
          {:consequence, %{}, :definition_revision_consequence_mismatch},
          {:committed_at, definition.declared_at - 1, :definition_revision_from_future}
        ] do
      assert {:error, error} =
               Transition.Foundation.apply(
                 put_in(state.acts[act.ref], Map.put(act, field, value)),
                 event,
                 nil
               )

      assert elem(error, 0) == reason
    end

    assert {:error, {:definition_revision_previous_ref_mismatch, _}} =
             Transition.Foundation.apply(
               state,
               put_in(event.data["previous_ref"], "false-predecessor"),
               nil
             )
  end

  test "initial records cannot smuggle runtime revisions or foreign Genesis", c do
    state = c.before
    {:ok, mandate} = Mandate.new(%{c.f.mandate | ref: nil, revision: 2})

    assert {:error, {:invalid_initial_mandate_revision, _, 2}} =
             record(state, :mandate, mandate, Transition.Authority)

    profile = State.host_profile(state)
    {:ok, profile} = HostProfile.new(%{profile | ref: nil, revision: 2})
    empty = State.new(state.domain_ref, state.constitution)
    empty = put_in(empty.catalog.genesis, %{c.f.genesis | host_profile_ref: profile.ref})

    assert {:error, {:invalid_initial_host_profile_revision, _, 2}} =
             record(empty, :host_profile, profile, Transition.Foundation)

    assert {:error, :genesis_domain_mismatch} =
             record(State.new("another-domain"), :genesis, c.f.genesis, Transition.Foundation)

    assert {:error, :genesis_required} =
             Transition.Foundation.named_by_genesis(State.new("empty"), :surface_ref, "surface")

    assert {:error, {:record_not_named_by_genesis, :surface_ref, "surface"}} =
             Transition.Foundation.named_by_genesis(state, :surface_ref, "surface")
  end

  test "transition drivers do not accept events owned by a different semantic family", c do
    event = %Event{type: "unknown", identity: "unknown", data: %{}}

    for {module, reason} <- [
          {Transition.Authority, :unsupported_authority_event},
          {Transition.Foundation, :unsupported_foundation_event},
          {Transition.Execution, :unsupported_execution_event},
          {Transition.Information, :unsupported_information_event},
          {Transition.Scope, :unsupported_scope_event},
          {Transition.Duty, :unsupported_duty_event}
        ] do
      assert {:error, {^reason, "unknown"}} = module.apply(c.before, event, nil)
    end
  end

  defp internal_act(base, class, consequence, targets) do
    {:ok, row} = Row.new(%{govern: true})

    {:ok, act} =
      Act.new(%{
        base
        | ref: nil,
          class: class,
          consequence: consequence,
          target_refs: targets,
          row: row,
          reservations: %{},
          disclosure: nil,
          observation_window_ms: 0,
          executor_ref: Governance.kernel_executor_ref(),
          executor_contract_ref: Governance.kernel_contract_ref()
      })

    act
  end

  defp record(state, kind, value, module) do
    {:ok, payload} = Event.record(kind, value)
    {:ok, event} = Event.decode(payload)
    module.apply(state, event, nil)
  end
end
