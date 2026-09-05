defmodule Spectre.Core.DefinitionGovernanceTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Definition, Ledger}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  # Re-expresses the stale activation, exact proposal, rollback and recovery
  # contracts of main's morph_test/morph_runtime_turn_test through GAM admission.
  # No ChangeSet store, mutable runtime loader or old Instance activation path.
  setup do
    Runtime.reset(Fixture.default_now())
    now = Runtime.now()

    assert {:ok, first} =
             Definition.new(
               namespace: "test",
               name: "assistant",
               revision: 1,
               declared_at: now,
               body: %{"reply" => "first"}
             )

    assert {:ok, second} = Definition.revise(first, %{"reply" => "second"}, now)
    assert {:ok, fork} = Definition.revise(first, %{"reply" => "fork"}, now)
    assert {:ok, rollback} = Definition.revise(second, first.body, now)
    assert {:ok, future} = Definition.revise(first, second.body, now + 1)
    assert {:ok, regressed} = Definition.revise(first, second.body, now - 1)

    assert {:ok, skipped} =
             second
             |> Map.from_struct()
             |> Map.merge(%{ref: nil, revision: 3})
             |> Definition.new()

    definitions = %{
      first: first,
      second: second,
      fork: fork,
      rollback: rollback,
      future: future,
      regressed: regressed,
      skipped: skipped
    }

    namespace = "definition-governance"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: Enum.map(definitions, fn {_name, definition} -> definition.ref end)
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(domain_ref)

    assert {:ok, scope} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    Map.merge(definitions, %{fixture: fixture, scope: scope})
  end

  test "a successor cannot create a lineage whose parent was never committed", c do
    assert_refused(c, c.second, :invalid_initial_definition_revision)
    assert_admitted(c, c.first)

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             revise(c, c.second, "second-after-parent")

    assert_replay(c)
  end

  test "a valid predecessor does not authorize skipping a revision number", c do
    assert_admitted(c, c.first)
    assert_refused(c, c.skipped, :definition_revision_not_sequential)
    assert_admitted(c, c.second)
    assert_replay(c)
  end

  test "a refused proposal remains refused on retry after its missing predecessor is committed",
       c do
    assert_refused(c, c.second, :invalid_initial_definition_revision)
    assert_admitted(c, c.first)
    before = Sequencer.projection(c.fixture.server)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} = revise(c, c.second)
    assert Sequencer.projection(c.fixture.server) == before
    assert_head(c, c.first)
    assert_replay(c)
  end

  test "a revision cannot move declaration time backwards", c do
    assert_admitted(c, c.first)
    assert_refused(c, c.regressed, :definition_revision_time_regressed)
    assert_admitted(c, c.second)
    assert_replay(c)
  end

  test "a future declaration is rejected without poisoning the Domain", c do
    assert_admitted(c, c.first)
    assert_refused(c, c.future, :event_from_future)
    assert_admitted(c, c.second)
    assert_replay(c)
  end

  test "a stale fork cannot replace the current head even with an authorized target", c do
    assert_admitted(c, c.first)
    assert_admitted(c, c.second)
    assert_refused(c, c.fork, :definition_revision_not_based_on_current)
    assert_head(c, c.second)
    assert_replay(c)
  end

  test "replaying the exact proposal reuses the committed Act without appending", c do
    first = assert_admitted(c, c.first)
    before = Sequencer.projection(c.fixture.server)
    assert {:ok, replay} = revise(c, c.first)
    assert replay.primary.act == first.primary.act
    assert replay.primary.decision == first.primary.decision
    assert is_nil(replay.primary.attempt)
    assert Sequencer.projection(c.fixture.server) == before
    assert_replay(c)
  end

  test "reusing a proposal identity for a different revision cannot change its meaning", c do
    assert_admitted(c, c.first)
    assert {:ok, _} = revise(c, c.second, "shared-identity")
    before = Sequencer.projection(c.fixture.server)

    assert {:error, {:candidate_identity_conflict, "shared-identity"}} =
             revise(c, c.fork, "shared-identity")

    assert Sequencer.projection(c.fixture.server) == before
    assert_replay(c)
  end

  test "rollback appends a new governed revision and preserves the intervening history", c do
    Enum.each([c.first, c.second, c.rollback], &assert_admitted(c, &1))
    assert_head(c, c.rollback)
    assert c.rollback.body == c.first.body
    refute c.rollback.ref == c.first.ref
    assert c.rollback.previous_ref == c.second.ref

    for definition <- [c.first, c.second, c.rollback] do
      assert {:ok, ^definition} = Spectre.definition(c.scope, definition.ref)
    end

    assert_replay(c)
  end

  test "concurrent successors commit exactly one head and no partial loser", c do
    assert_admitted(c, c.first)
    parent = self()

    tasks =
      for definition <- [c.second, c.fork] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> {definition, revise(c, definition)}
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks)

    assert [{winner, {:ok, %{primary: %{decision: %{outcome: :admitted}}}}}] =
             Enum.filter(
               results,
               &match?({_, {:ok, %{primary: %{decision: %{outcome: :admitted}}}}}, &1)
             )

    assert [{loser, {:ok, %{primary: %{decision: %{reasons: reasons}, act: nil}}}}] =
             Enum.filter(
               results,
               &match?({_, {:ok, %{primary: %{decision: %{outcome: :refused}}}}}, &1)
             )

    assert [{:definition_revision_not_based_on_current, _, _, _}] = reasons

    assert_head(c, winner)
    projection = Sequencer.projection(c.fixture.server)
    refute Map.has_key?(projection.catalog.definitions, loser.ref)
    assert map_size(projection.acts) == 2
    assert map_size(projection.decisions) == 3
    assert_replay(c)
  end

  test "durable revisions survive a Domain restart but the old Scope is fenced", c do
    assert_admitted(c, c.first)
    assert_admitted(c, c.second)
    before = Sequencer.projection(c.fixture.server)
    GenServer.stop(c.fixture.server)
    restarted = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(restarted.server) end)
    assert Sequencer.projection(restarted.server) == before
    assert {:error, _} = Spectre.definition(c.scope, c.first.ref)
    assert {:ok, domain} = Spectre.lookup_domain(restarted.refs.domain)

    assert {:ok, new_context} =
             Spectre.authenticate(domain, "scope:after-restart", %{
               principal_ref: restarted.refs.grantor,
               authentication_ref: "authentication:after-restart",
               session_ref: "session:after-restart"
             })

    assert {:ok, fresh_scope} =
             Spectre.open_scope(domain, new_context, kind: :session, opened_at: Runtime.now())

    assert {:ok, first} = Spectre.definition(fresh_scope, c.first.ref)
    assert first == c.first
    assert_replay(%{c | fixture: restarted})
  end

  test "knowing the governance Mandate ref does not let another principal revise a Definition",
       c do
    assert {:ok, domain} = Spectre.lookup_domain(c.fixture.refs.domain)
    assert {:ok, ordinary_scope} = Spectre.resume_scope(domain, Fixture.context(c.fixture))
    before = Sequencer.projection(c.fixture.server)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             revise(%{c | scope: ordinary_scope}, c.first)

    after_refusal = Sequencer.projection(c.fixture.server)
    assert after_refusal.catalog == before.catalog
    assert after_refusal.acts == before.acts
    assert_replay(c)
  end

  defp revise(c, definition, identity \\ nil) do
    Spectre.revise_definition(c.scope, definition,
      identity_key: identity || "revise:#{definition.ref}",
      requested_mandate_ref: c.fixture.governance_mandate.ref,
      accountable_ref: c.fixture.refs.accountable,
      purpose_ref: c.fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    )
  end

  defp assert_admitted(c, definition) do
    assert {:ok, result} = revise(c, definition)
    assert result.primary.decision.outcome == :admitted
    assert is_nil(result.primary.attempt)
    result
  end

  defp assert_refused(c, definition, expected_reason) do
    before = Sequencer.projection(c.fixture.server)

    assert {:ok, %{primary: %{decision: %{outcome: :refused, reasons: [reason]}, act: nil}}} =
             revise(c, definition)

    assert elem(reason, 0) == expected_reason
    after_refusal = Sequencer.projection(c.fixture.server)
    assert after_refusal.catalog == before.catalog
    assert after_refusal.acts == before.acts
    assert after_refusal.meters == before.meters
    assert after_refusal.revision == before.revision + 1
  end

  defp assert_head(c, definition) do
    projection = Sequencer.projection(c.fixture.server)
    assert projection.catalog.definition_heads[Definition.key(definition)] == definition.ref
  end

  defp assert_replay(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, recovered} = Projection.replay(snapshot, c.fixture.constitution)
    assert recovered == Sequencer.projection(c.fixture.server)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
