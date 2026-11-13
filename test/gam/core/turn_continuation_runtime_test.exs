Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.TurnContinuationRuntimeTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Domain, Scope}
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule Mind do
    use Spectre.GAM.Mind, ref: "mind:continuation-runtime"
    def deliberate(_turn, _opts), do: {:ok, []}
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "turn-continuation-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        mind: Mind,
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}},
        context: Map.get(tags, :context)
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    domain = Domain.handle(fixture.server, domain_ref)
    {:ok, scope} = Scope.new(domain, Fixture.context(fixture))
    %{fixture: fixture, domain: domain, scope: scope}
  end

  test "continuing a sealed Turn adds durable context without observing the input twice", c do
    {:ok, turn} = GAM.open_turn(c.scope, input(c, "request"))
    Runtime.set_time(Runtime.now() + 1)
    {:ok, [added]} = GAM.observe(c.scope, input(c, "additional context"))
    before = Sequencer.projection(c.fixture.server)
    assert {:ok, continued} = GAM.continue_turn(c.scope, turn, [added.ref, added.ref])

    assert Enum.sort(Turn.evidence_refs(continued)) ==
             Enum.sort(Turn.evidence_refs(turn) ++ [added.ref])

    assert continued.ref != turn.ref
    assert Sequencer.projection(c.fixture.server) == before
    assert {:ok, same_basis} = GAM.continue_turn(c.scope, continued, [])
    assert Turn.evidence_refs(same_basis) == Turn.evidence_refs(continued)
  end

  test "generated Evidence remains bound to the original sealed Turn and records once", c do
    {:ok, turn} = GAM.open_turn(c.scope, input(c, "request"))

    {:ok, derived} =
      GAM.Mind.evidence(turn, Runtime.now(),
        proposition: "derived.intent",
        payload: "A derived interpretation"
      )

    assert {:ok, ^derived} = GAM.record_derivation(c.scope, turn, derived)
    recorded = Sequencer.projection(c.fixture.server)
    assert {:ok, ^derived} = GAM.record_derivation(c.scope, turn, derived)
    assert Sequencer.projection(c.fixture.server) == recorded
    assert {:ok, continued} = GAM.continue_turn(c.scope, turn, [derived.ref])
    assert derived.ref in Turn.evidence_refs(continued)
  end

  test "a model cannot backdate or forge a sealed Turn or record a future derivation", c do
    {:ok, turn} = GAM.open_turn(c.scope, input(c, "request"))

    {:ok, derived} =
      GAM.Mind.evidence(turn, Runtime.now() + 1,
        proposition: "future.intent",
        payload: "A future interpretation"
      )

    before = Sequencer.projection(c.fixture.server)

    assert {:error, {:mind_derivation_from_future, _}} =
             GAM.record_derivation(c.scope, turn, derived)

    assert {:error, :turn_authentication_failed} =
             GAM.continue_turn(c.scope, %{turn | opened_at: turn.opened_at - 1}, [])

    assert {:error, :turn_authentication_failed} =
             GAM.record_derivation(c.scope, %{turn | seal: nil}, derived)

    assert Sequencer.projection(c.fixture.server) == before
  end

  test "another authenticated Scope cannot reuse this Turn or its contextual Evidence", c do
    {:ok, turn} = GAM.open_turn(c.scope, input(c, "request"))

    {:ok, context} =
      GAM.authenticate(c.domain, "scope:other", %{
        principal_ref: c.fixture.refs.proposer,
        authentication_ref: "authentication:other",
        session_ref: "session:other"
      })

    {:ok, other} = GAM.open_scope(c.domain, context, opened_at: Runtime.now())
    {:ok, [foreign]} = GAM.observe(other, input(c, "foreign context"))
    before = Sequencer.projection(c.fixture.server)
    assert {:error, :turn_context_mismatch} = GAM.continue_turn(other, turn, [])
    assert {:error, _} = GAM.continue_turn(c.scope, turn, [foreign.ref])
    assert {:error, _} = GAM.continue_turn(c.scope, turn, ["evidence:missing"])
    assert Sequencer.projection(c.fixture.server) == before
  end

  @tag context: [max_evidence: 1]
  test "continuation fails rather than silently dropping required context beyond the window", c do
    {:ok, turn} = GAM.open_turn(c.scope, input(c, "request"))
    Runtime.set_time(Runtime.now() + 1)
    {:ok, [added]} = GAM.observe(c.scope, input(c, "additional context"))
    before = Sequencer.projection(c.fixture.server)

    assert {:error, :continuation_context_exceeds_window} =
             GAM.continue_turn(c.scope, turn, [added.ref])

    assert Sequencer.projection(c.fixture.server) == before
  end

  defp input(c, proposition) do
    c.fixture
    |> Fixture.paid_evidence(%{proposition: proposition, payload: "authenticated input"})
    |> Map.from_struct()
    |> Map.delete(:ref)
  end
end
