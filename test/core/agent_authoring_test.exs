Code.require_file("../../bench/support/p1_fixture.exs", __DIR__)

defmodule Spectre.Core.AgentAuthoringTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Audit, Candidate, Definition, Ledger}
  alias Spectre.Bench.P1.Fixture
  alias Spectre.Candidate.Template
  alias Spectre.Domain.Sequencer
  alias Spectre.Mind.Turn

  defmodule EffectSkill do
    use Spectre.Skill, namespace: "test", name: "effect", revision: 1, declared_at: 0
    candidate("effect", class: "bench.effect", row: %{attempt: true, spend: true})
  end

  defmodule Bundle do
    use Spectre.Skill, namespace: "test", name: "bundle", revision: 1, declared_at: 0
    install(EffectSkill, as: "effects")
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "test", name: "assistant", revision: 1, declared_at: 0
    install(Bundle, as: "bundle")
    install(EffectSkill, as: "direct")
  end

  defmodule SameAssistant do
    use Spectre.Agent, namespace: "test", name: "assistant", revision: 1, declared_at: 0
    install(EffectSkill, as: "direct")
    install(Bundle, as: "bundle")
  end

  setup do
    fixture = Fixture.start(:ets, "authoring-#{System.unique_integer([:positive])}", 3, 8, 1)
    on_exit(fn -> Fixture.stop(fixture) end)

    assert {:ok, turn} =
             Turn.new(
               fixture.context,
               "turn:authoring",
               "mind:authoring",
               [fixture.evidence],
               System.system_time(:millisecond)
             )

    attrs =
      fixture
      |> Fixture.candidate(1)
      |> Map.drop([:class, :row, :proposer_ref, :scope_ref, :evidence_refs])

    %{fixture: fixture, turn: turn, attrs: attrs}
  end

  test "skill expansion pins content without module identity or declaration-order dependence" do
    definition = Assistant.definition()
    assert definition == SameAssistant.definition()

    assert {:ok, ^definition} =
             definition |> Definition.canonical() |> Definition.from_canonical()

    assert {:ok, templates, components} = Agent.declarations(definition)
    assert Enum.sort(Map.keys(templates)) == ["bundle/effects/effect", "direct/effect"]

    assert components == %{
             "bundle" => Bundle.definition().ref,
             "bundle/effects" => EffectSkill.definition().ref,
             "direct" => EffectSkill.definition().ref
           }
  end

  test "materializing an installed Skill is inert and its Candidate uses ordinary admission", %{
    fixture: f,
    turn: turn,
    attrs: attrs
  } do
    before = Sequencer.projection(f.server)
    assert {:ok, candidate} = Assistant.candidate("bundle/effects/effect", turn, attrs)
    assert {:ok, expected} = Candidate.new(Fixture.candidate(f, 1))
    assert candidate == expected
    assert Sequencer.projection(f.server) == before
    assert candidate.proposer_ref == f.context.authenticated_principal_ref
    assert candidate.scope_ref == f.context.scope_ref

    assert {:ok, %{decision: %{outcome: :admitted}, act: act}} =
             Sequencer.submit(f.server, f.context, candidate)

    assert act.candidate_identity_key == candidate.identity_key
    assert act.material_digest == candidate.material_digest
    assert {:ok, snapshot} = Ledger.load(f.store_config, f.refs.domain)

    assert {:ok, _report} =
             Audit.verify(snapshot, before.constitution, System.system_time(:millisecond))
  end

  test "an installed Skill supplies no authority of its own", %{
    fixture: f,
    turn: turn,
    attrs: attrs
  } do
    assert {:ok, candidate} =
             Assistant.candidate(
               "direct/effect",
               turn,
               Map.put(attrs, :requested_mandate_ref, "absent")
             )

    assert {:ok, %{decision: %{outcome: :refused}, act: nil, grant: nil}} =
             Sequencer.submit(f.server, f.context, candidate)
  end

  test "occurrences cannot override declarations or claim trusted bindings", %{
    turn: turn,
    attrs: attrs
  } do
    for {field, value} <- [class: "other", row: %{}, proposer_ref: "admin", scope_ref: "foreign"] do
      assert {:error, _} =
               Assistant.candidate("direct/effect", turn, Map.put(attrs, field, value))
    end

    assert {:error, {:unknown_candidate_template, "missing"}} =
             Assistant.candidate("missing", turn, attrs)

    assert {:error, _} = Assistant.candidate("direct/effect", turn, [{:identity_key, "x"} | :bad])
  end

  test "reusable templates cannot freeze identities, capabilities or computed digests" do
    for {field, value} <- [
          identity_key: "fixed",
          proposer_ref: "admin",
          scope_ref: "scope",
          ref: "candidate:forged",
          material_digest: "digest",
          grant: "grant",
          callback: fn -> :ok end
        ] do
      assert {:error, _} = Template.new(%{field => value})
    end

    assert {:error, _} = Template.new(consequence: %{callback: fn -> :ok end})
    assert {:ok, template} = Template.new(%{"class" => "example", "row" => %{"read" => true}})
    assert {:ok, ^template} = Template.new(class: "example", row: %{read: true})

    assert {:error, {:candidate_template_override, [:class]}} =
             Template.bind(template, class: "example")
  end

  test "duplicate names and occurrence identity in the DSL fail compilation" do
    assert_raise CompileError, ~r/duplicate_declaration/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Spectre.Core.AgentAuthoringTest.Duplicate do
            use Spectre.Agent, namespace: "test", name: "invalid", revision: 1, declared_at: 0
            candidate("same", class: "one")
            candidate("same", class: "two")
          end
        end
      )
    end

    assert_raise CompileError, ~r/unknown_attribute/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Spectre.Core.AgentAuthoringTest.FrozenIdentity do
            use Spectre.Agent, namespace: "test", name: "invalid", revision: 1, declared_at: 0
            candidate("fixed", identity_key: "reused")
          end
        end
      )
    end
  end

  test "Morph prepares a new immutable revision without mutating the original or a Domain", %{
    fixture: f
  } do
    before = Sequencer.projection(f.server)
    current = Assistant.definition()
    body = put_in(current.body, ["candidates", "new"], %{"class" => "new.effect"})
    assert {:ok, successor} = Definition.revise(current, body, 10)
    assert successor.ref != current.ref
    assert successor.previous_ref == current.ref
    assert successor.revision == current.revision + 1
    assert Definition.key(successor) == Definition.key(current)
    assert successor.declared_at == 10
    assert {:ok, ^successor} = successor |> Definition.canonical() |> Definition.from_canonical()
    refute Map.has_key?(current.body["candidates"], "new")
    assert Sequencer.projection(f.server) == before

    assert {:error, _} = Definition.revise(%{current | body: %{}}, body, 10)
    assert {:error, _} = Definition.revise(current, %{callback: fn -> :ok end}, 10)
  end
end
