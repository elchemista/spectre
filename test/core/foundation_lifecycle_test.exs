Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.Core.FoundationLifecycleTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, HostProfile, Ledger, Principal, Row, Surface}
  alias Spectre.Domain.{Event, Projection, Sequencer}
  alias Spectre.GovernedAct.State
  alias Spectre.GovernedAct.Transition.Foundation
  alias Spectre.V04Test.{Fixture, Runtime}

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "foundation-lifecycle"

    opts = [
      namespace: namespace,
      governance_allowed: true,
      governance_classes: ["principal.register", "host_profile.revise", "surface.revise"]
    ]

    # Compute content-addressed targets before Genesis. No authority is inserted
    # into a running projection to make these operations pass.
    planning = Fixture.start_domain(opts)
    initial = Sequencer.projection(planning.server)
    profile = State.host_profile(initial)
    surface = State.surface(initial)
    Fixture.stop_domain(planning)

    {:ok, principal} = Principal.new(kind: :agent, display_name: "New agent")

    profiles =
      for {name, revision, time} <- [
            {:next, 2, Runtime.now()},
            {:skipped, 3, Runtime.now()},
            {:past, 2, Runtime.now() - 1},
            {:future, 2, Runtime.now() + 1}
          ],
          into: %{} do
        {:ok, value} =
          profile
          |> Map.from_struct()
          |> Map.merge(%{ref: nil, revision: revision, mode: :mediated, declared_at: time})
          |> HostProfile.new()

        {name, value}
      end

    surfaces =
      for revision <- [2, 3], into: %{} do
        {:ok, value} =
          surface
          |> Map.from_struct()
          |> Map.merge(%{ref: nil, revision: revision})
          |> Surface.new()

        {revision, value}
      end

    targets =
      [principal.ref, profile.ref, surface.ref] ++
        Enum.map(Map.values(profiles) ++ Map.values(surfaces), & &1.ref)

    fixture =
      Fixture.start_domain(
        opts ++
          [
            governance_targets: targets,
            name: {:via, Registry, {Spectre.Domain.Registry, initial.domain_ref}}
          ]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(initial.domain_ref)

    {:ok, scope} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    %{
      fixture: fixture,
      scope: scope,
      principal: principal,
      profile: profile,
      profiles: profiles,
      surface: surface,
      surfaces: surfaces
    }
  end

  test "registering an agent records identity, not a new Mandate or budget", c do
    before = Sequencer.projection(c.fixture.server)
    assert {:ok, result} = Spectre.register_principal(c.scope, c.principal, attrs(c, "register"))
    assert result.primary.decision.outcome == :admitted
    assert result.primary.attempt == nil
    after_registration = Sequencer.projection(c.fixture.server)
    assert after_registration.catalog.principals[c.principal.ref] == c.principal
    assert after_registration.mandates == before.mandates
    assert after_registration.meters == before.meters
    assert after_registration.revision == before.revision + 3
    assert_replay(c)

    assert {:ok, duplicate} =
             Spectre.register_principal(c.scope, c.principal, attrs(c, "register-again"))

    assert duplicate.primary.decision.outcome == :refused
    assert duplicate.primary.act == nil
    assert Sequencer.projection(c.fixture.server).catalog == after_registration.catalog
  end

  test "host revision freezes the old context on its Act and preserves both profiles", c do
    assert {:ok, result} =
             Spectre.revise_host_profile(
               c.scope,
               c.profile.ref,
               c.profiles.next,
               attrs(c, "host")
             )

    assert result.primary.decision.outcome == :admitted, inspect(result)
    assert result.primary.act.host_profile_ref == c.profile.ref
    state = Sequencer.projection(c.fixture.server)
    assert State.host_profile(state) == c.profiles.next
    assert state.catalog.host_profiles[c.profile.ref] == c.profile

    assert {:ok, registration} =
             Spectre.register_principal(c.scope, c.principal, attrs(c, "new-context"))

    assert registration.primary.act.host_profile_ref == c.profiles.next.ref
    assert_replay(c)
  end

  for {variant, reason} <- [
        skipped: :host_profile_revision_not_sequential,
        past: :invalid_host_profile_revision_time,
        future: :event_from_future
      ] do
    test "host profile rejects #{variant} revision without changing the foundation", c do
      before = Sequencer.projection(c.fixture.server)

      assert {:ok, result} =
               Spectre.revise_host_profile(
                 c.scope,
                 c.profile.ref,
                 c.profiles[unquote(variant)],
                 attrs(c, "bad-host")
               )

      assert result.primary.decision.outcome == :refused
      assert Enum.any?(result.primary.decision.reasons, &(elem(&1, 0) == unquote(reason)))
      assert result.primary.act == nil
      assert Sequencer.projection(c.fixture.server).catalog == before.catalog
      assert_replay(c)
    end
  end

  test "surface revisions are sequential and a stale predecessor cannot replace the head", c do
    assert {:ok, skipped} =
             Spectre.revise_surface(c.scope, c.surface.ref, c.surfaces[3], attrs(c, "skip"))

    assert skipped.primary.decision.outcome == :refused

    assert {:ok, result} =
             Spectre.revise_surface(c.scope, c.surface.ref, c.surfaces[2], attrs(c, "surface"))

    assert result.primary.decision.outcome == :admitted, inspect(result)
    assert result.primary.act.surface_revision == 1

    assert {:ok, stale} =
             Spectre.revise_surface(c.scope, c.surface.ref, c.surfaces[3], attrs(c, "stale"))

    assert stale.primary.decision.outcome == :refused
    assert State.surface(Sequencer.projection(c.fixture.server)) == c.surfaces[2]

    assert {:ok, third} =
             Spectre.revise_surface(c.scope, c.surfaces[2].ref, c.surfaces[3], attrs(c, "third"))

    assert third.primary.decision.outcome == :admitted
    assert State.surface(Sequencer.projection(c.fixture.server)) == c.surfaces[3]
    assert_replay(c)
  end

  # Isolate the transition contract after obtaining a genuinely admitted Act.
  # Mutation here models corruption of its input, not extra host authority.
  for {kind, changes} <- [
        {:principal,
         [
           class: "refund.issue",
           row: %Row{},
           reservations: %{"meter:x" => 1},
           executor_ref: "executor:outside",
           target_refs: [],
           consequence: %{}
         ]},
        {:host_profile,
         [
           class: "refund.issue",
           row: %Row{},
           target_refs: [],
           host_profile_ref: "profile:other",
           consequence: %{}
         ]},
        {:surface,
         [
           class: "refund.issue",
           row: %Row{},
           target_refs: [],
           surface_revision: 999,
           consequence: %{}
         ]}
      ],
      {field, value} <- changes do
    test "#{kind} materialization rejects a mismatched Act #{field}", c do
      before = Sequencer.projection(c.fixture.server)
      {:ok, result} = commit(c, unquote(kind))
      act = result.primary.act
      assert act != nil
      snapshot = Fixture.snapshot(c.fixture)
      event = snapshot.entries |> List.last() |> Event.decode_entry() |> elem(1)
      corrupted = Map.replace!(act, unquote(field), unquote(Macro.escape(value)))
      prefix = %{before | acts: Map.put(before.acts, act.ref, corrupted)}
      assert {:error, _reason} = Foundation.apply(prefix, event, event.revision)

      assert {:ok, _} =
               Foundation.apply(
                 %{before | acts: Map.put(before.acts, act.ref, act)},
                 event,
                 event.revision
               )
    end
  end

  defp commit(c, :principal),
    do: Spectre.register_principal(c.scope, c.principal, attrs(c, "register"))

  defp commit(c, :host_profile),
    do: Spectre.revise_host_profile(c.scope, c.profile.ref, c.profiles.next, attrs(c, "host"))

  defp commit(c, :surface),
    do: Spectre.revise_surface(c.scope, c.surface.ref, c.surfaces[2], attrs(c, "surface"))

  defp attrs(c, identity),
    do: [
      identity_key: identity,
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    ]

  defp assert_replay(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, rebuilt} = Projection.replay(snapshot, c.fixture.constitution)
    assert rebuilt == Sequencer.projection(c.fixture.server)
    assert {:ok, _} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())
  end
end
