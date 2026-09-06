defmodule Spectre.Core.PublicBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.{Domain, Outcome}
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())

    f =
      Fixture.start_domain(
        namespace: "public-boundary",
        name: {:via, Registry, {Spectre.Domain.Registry, "v0.4:public-boundary:domain"}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, domain} = Spectre.lookup_domain(f.refs.domain)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(f))
    %{f: f, domain: domain, scope: scope}
  end

  for {function, args, reason} <- [
        {:definition, ["definition:x"], :invalid_scope},
        {:observe, [%{}], :invalid_observation},
        {:record_derivation, [%{}, %{}], :invalid_evidence_derivation},
        {:prepare_presentation, [%{}], :invalid_presentation},
        {:show_presentation, ["presentation:x", %{}], :invalid_presentation_show},
        {:record_outcome, [%{}], :invalid_outcome},
        {:record_late_observation, ["attempt:x", %{}], :invalid_late_observation},
        {:turn, [%{}], :invalid_turn},
        {:propose, [%{}], :invalid_proposal},
        {:view, [], :invalid_scope},
        {:authority, [], :authenticated_scope_required},
        {:acts, [], :authenticated_scope_required},
        {:duties, [], :authenticated_scope_required},
        {:erasures, [], :authenticated_scope_required},
        {:declassifications, [], :authenticated_scope_required},
        {:register_principal, [%{}, %{}], :invalid_principal_registration},
        {:delegate_mandate, [%{}, %{}], :invalid_mandate_delegation},
        {:issue_mandate, [%{}, %{}], :invalid_mandate_delegation},
        {:devolve_mandate, ["mandate:x", %{}, %{}], :invalid_mandate_devolution},
        {:restrict_mandate, ["mandate:x", %{}, %{}], :invalid_mandate_restriction},
        {:revoke_mandate, ["mandate:x", %{}], :invalid_mandate_revocation},
        {:dispose_duty, [%{}, %{}], :invalid_duty_disposition},
        {:revise_surface, ["surface:x", %{}, %{}], :invalid_surface_revision},
        {:revise_host_profile, ["profile:x", %{}, %{}], :invalid_host_profile_revision},
        {:revise_definition, [%{}, %{}], :invalid_definition_revision},
        {:declassify_evidence, [%{}, [], %{}], :invalid_evidence_declassification},
        {:request_erasure, [%{}, %{}], :invalid_erasure_request}
      ] do
    test "#{function} cannot use a serialized Scope or bare Domain as authentication", c do
      before = Sequencer.projection(c.f.server)

      for forged <- [Map.from_struct(c.scope), c.domain, c.scope.context, c.f.server] do
        assert {:error, unquote(reason)} =
                 apply(Spectre, unquote(function), [forged | unquote(Macro.escape(args))])
      end

      assert Sequencer.projection(c.f.server) == before
    end
  end

  test "unknown and malformed query options do not become privileged query controls", c do
    assert {:error, {:unknown_query_options, :duties, [:limit]}} =
             Spectre.duties(c.scope, limit: 1)

    assert {:error, _} = Spectre.duties(c.scope, [:not_keyword])
    assert {:error, {:invalid_definition_ref, nil}} = Spectre.definition(c.scope, nil)

    assert {:error, {:mandate_not_found, "missing"}} =
             Spectre.revoke_mandate(c.scope, "missing", %{})

    assert {:error, :invalid_mandate_ref} = Spectre.revoke_mandate(c.scope, nil, %{})

    assert {:error, {:presentation_not_found, "missing"}} =
             Spectre.show_presentation(c.scope, "missing", %{})
  end

  test "late outcomes require an existing Act in the caller's Scope and actual evidence", c do
    payment = Fixture.paid_evidence(c.f)
    {:ok, _} = Fixture.observe_payment(c.f, payment)

    {:ok, %{act: act, grant: grant}} =
      Sequencer.submit(
        c.f.server,
        Fixture.context(c.f),
        Fixture.refund_candidate(c.f, 100, evidence_refs: [payment.ref])
      )

    {:ok, _, attempt, _} = Sequencer.consume_grant(c.f.server, grant)
    ambiguous = Fixture.outcome(c.f, act, attempt, :ambiguous)

    assert {:error, :public_ambiguous_outcome_forbidden} =
             Spectre.record_outcome(c.scope, ambiguous)

    receipt = Fixture.receipt_evidence(c.f, act.ref)
    {:ok, _} = Fixture.record_receipt(c.f, receipt)
    success = Fixture.outcome(c.f, act, attempt, :succeeded, [receipt.ref])
    assert {:ok, ^success} = Spectre.record_outcome(c.scope, success)

    {:ok, missing} =
      success |> Map.from_struct() |> Map.merge(%{ref: nil, act_ref: "missing"}) |> Outcome.new()

    assert {:error, {:outcome_act_not_found, "missing"}} =
             Spectre.record_outcome(c.scope, missing)

    assert {:error, _} = Spectre.record_outcome(c.scope, success, unknown: true)
    assert {:error, _} = Spectre.record_outcome(c.scope, success, sequencer_opts: [unknown: true])
  end

  test "Domain startup owns registration and rejects duplicate identities or wiring overrides",
       c do
    Fixture.stop_process(c.f.server)
    opts = Keyword.drop(c.f.sequencer_opts, [:domain_ref, :store, :name, :registry])
    assert {:ok, domain} = Spectre.start_domain(c.f.refs.domain, c.f.store_config, opts)
    on_exit(fn -> DynamicSupervisor.terminate_child(Spectre.Domain.Supervisor, domain.server) end)
    assert Domain.whereis(domain.ref) == domain.server
    assert {:ok, ^domain} = Spectre.lookup_domain(domain.ref)
    assert {:ok, _} = Spectre.head(domain.ref)

    assert {:error, {:domain_already_started, _}} =
             Spectre.start_domain(domain.ref, c.f.store_config, opts)

    for key <- [:domain_ref, :store, :registry, :name] do
      assert {:error, {:reserved_domain_option, ^key}} =
               Spectre.start_domain(
                 domain.ref,
                 c.f.store_config,
                 Keyword.put(opts, key, :override)
               )
    end

    assert Spectre.version() == "0.4.0"
  end

  test "malformed Domain handles and context shapes fail explicitly before lookup", c do
    assert {:error, :invalid_domain_start} = Spectre.start_domain(nil, c.f.store_config)
    assert {:error, _} = Spectre.start_domain("new", c.f.store_config, [:invalid])
    assert {:error, :invalid_domain_ref} = Spectre.lookup_domain(nil)
    assert {:error, :invalid_domain} = Spectre.head(%{})
    assert Domain.whereis(nil) == nil
    assert Domain.whereis("missing") == nil
    assert {:error, :invalid_domain_options} = Domain.start_link(nil)
    assert {:error, :invalid_domain_options} = Domain.start_link(domain_ref: "", registry: nil)
    assert {:error, :authenticated_context_required} = Spectre.resume_scope(c.domain, %{})
    assert {:error, _} = Spectre.authenticate(c.domain, nil, %{}, :invalid)
    assert {:error, _} = Spectre.open_scope(c.domain, %{}, [])
    assert {:error, _} = Spectre.open_scope(%{}, %{}, %{}, %{}, [])
  end
end
