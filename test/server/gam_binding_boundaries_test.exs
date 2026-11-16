Code.require_file("../gam/helper.exs", __DIR__)

defmodule Spectre.Server.GAMBindingBoundariesTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.GAM.{Domain, Scope}
  alias Spectre.GAM.Mind.Turn
  alias Spectre.GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server.GAM, as: Bridge

  defmodule Mind do
    use Spectre.GAM.Mind, ref: "mind:binding-boundaries"
    def deliberate(_turn, _opts), do: {:ok, []}
  end

  def resolve_scope(context), do: {:ok, context.scope}

  def candidate(args, turn, context) do
    attrs =
      Fixture.refund_candidate(context.fixture, args.amount,
        identity_key: "bridge:boundary",
        evidence_refs:
          Enum.uniq([context.fixture.refs.payment_evidence | Turn.evidence_refs(turn)])
      )

    {:ok, attrs}
  end

  def interpret(_input, _presentation), do: :unclear
  def unavailable_presentation(_candidate, _context, _opts), do: {:error, :renderer_unavailable}
  def malformed_presentation(_candidate, _context, _opts), do: :invalid_material

  setup do
    Runtime.reset(Fixture.default_now())
    namespace = "bridge-boundary-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"

    f =
      Fixture.start_domain(
        namespace: namespace,
        mind: Mind,
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}}
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    {:ok, _} = Fixture.observe_payment(f, Fixture.paid_evidence(f))
    {:ok, scope} = Scope.new(Domain.handle(f.server, f.refs.domain), Fixture.context(f))

    input =
      f
      |> Fixture.paid_evidence(%{proposition: "request refund", issuer_ref: f.refs.proposer})
      |> Map.from_struct()
      |> Map.delete(:ref)

    binding = %{candidate: {__MODULE__, :candidate}}
    context = %{scope: scope, fixture: f, input: input}
    config = [scope: {__MODULE__, :resolve_scope}, bindings: %{refund: binding}]
    %{f: f, scope: scope, context: context, config: config, binding: binding}
  end

  test "a deterministic binding crosses normal GAM admission and preserves uncertainty", c do
    assert {:governed, result} =
             Bridge.propose(:refund, %{amount: 100}, c.context, bridge(c.config))

    assert result.decision.outcome == :admitted
    assert result.outcome.status == :ambiguous
    assert result.attempt != nil
    {:ok, reference} = Bridge.result_reference({:governed, result})

    assert {:error, :result_revision_changed} =
             Bridge.resolve_result(%{reference | outcome_ref: nil}, c.context, bridge(c.config))

    assert {:error, :invalid_result_reference} =
             Bridge.resolve_result(nil, c.context, bridge(c.config))

    assert {:error, :invalid_result_reference} =
             Bridge.resolve_result(%{}, c.context, bridge(c.config))

    assert {:error, :invalid_result_reference} =
             Bridge.resolve_result(%{reference | outcome_ref: 7}, c.context, bridge(c.config))

    assert {:error, :governed_recovery_required} =
             Bridge.resolve_command_result("unknown", reference, c.context, bridge(c.config))
  end

  @tag :tmp_dir
  test "a journal requires stable command identity and rejects changed material on retry", c do
    store =
      start_supervised!(
        {Spectre.Server.Store.Disk, path: Path.join(c.tmp_dir, "journal.snapshot")}
      )

    opts = bridge(Keyword.put(c.config, :store, store))

    assert {:error, :durable_command_id_required} =
             Bridge.propose(:refund, %{amount: 100}, c.context, opts)

    context = Map.put(c.context, :command_id, "command:boundary")
    assert {:governed, original} = Bridge.propose(:refund, %{amount: 100}, context, opts)
    assert {:governed, repeated} = Bridge.propose(:refund, %{amount: 100}, context, opts)
    assert repeated.act.ref == original.act.ref
    assert repeated.attempt.ref == original.attempt.ref

    assert {:error, :governed_command_conflict} =
             Bridge.propose(:refund, %{amount: 200}, context, opts)

    {:ok, ref} = Bridge.result_reference({:governed, original})

    assert {:error, :governed_recovery_required} =
             Bridge.resolve_command_result("absent", ref, context, opts)
  end

  test "host scope, interpreter, TTL and renderer failures remain explicit", c do
    assert {:error, :authenticated_scope_required} =
             Bridge.propose(
               :refund,
               %{amount: 100},
               c.context,
               bridge(Keyword.put(c.config, :scope, nil))
             )

    binding = Map.put(c.binding, :presentation, {__MODULE__, :unavailable_presentation})

    assert {:error, :confirmation_interpreter_required} =
             Bridge.propose(
               :refund,
               %{amount: 100},
               c.context,
               bridge(Keyword.put(c.config, :bindings, %{refund: binding}))
             )

    binding = Map.put(binding, :interpreter, {__MODULE__, :interpret})
    config = Keyword.put(c.config, :bindings, %{refund: binding})

    assert {:error, :invalid_consent_ttl_ms} =
             Bridge.propose(
               :refund,
               %{amount: 100},
               c.context,
               bridge(Keyword.put(config, :consent_ttl_ms, -1))
             )

    assert {:error, :renderer_unavailable} =
             Bridge.propose(
               :refund,
               %{amount: 100},
               c.context,
               bridge(Keyword.put(config, :consent_ttl_ms, :infinity))
             )

    invalid = %{binding | presentation: {__MODULE__, :malformed_presentation}}

    assert {:error, {:invalid_confirmation_material, :invalid_material}} =
             Bridge.propose(
               :refund,
               %{amount: 100},
               c.context,
               bridge(Keyword.put(config, :bindings, %{refund: invalid}))
             )

    assert {:error, :renderer_unavailable} =
             Bridge.explain(
               %{
                 operation: :refund,
                 candidate: candidate(c),
                 domain_ref: c.f.refs.domain,
                 scope_ref: c.f.refs.scope,
                 principal_ref: c.f.refs.proposer
               },
               nil,
               c.context,
               bridge(config)
             )
  end

  defp candidate(c) do
    {:ok, value} = GAM.Candidate.new(Fixture.refund_candidate(c.f, 100))
    value
  end

  defp bridge(config), do: [bridge_config: config]
end
