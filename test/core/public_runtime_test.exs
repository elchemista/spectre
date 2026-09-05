Code.require_file("../v0_4/support/fixture.ex", __DIR__)

defmodule Spectre.CoreTest.PublicRuntimeTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Definition, Domain, Instance, Ledger, Mind, Scope}
  alias Spectre.Domain.Sequencer
  alias Spectre.Mind.Turn
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule StatefulMind do
    @behaviour Spectre.Mind

    @impl true
    def ref, do: "spectre:test:stateful-mind"

    @impl true
    def deliberate(turn, opts), do: deliberate_result(turn, opts)

    @impl true
    def deliberate(turn, state, opts) do
      with {:ok, candidates} <- deliberate_result(turn, opts) do
        {:ok, candidates, state + 1}
      end
    end

    defp deliberate_result(turn, opts) do
      send(Keyword.fetch!(opts, :observer), {:deliberated, self(), turn, opts})
      {:ok, Keyword.get(opts, :candidates, [])}
    end
  end

  setup do
    Runtime.reset(Fixture.default_now())
    first = definition(1)
    second = definition(2, first.ref)
    namespace = "public-runtime"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [first.ref, second.ref],
        mind: StatefulMind
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)

    assert {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    assert {:ok, governance_scope} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    %{
      fixture: fixture,
      domain: domain,
      scope: scope,
      governance_scope: governance_scope,
      first: first,
      second: second
    }
  end

  test "public queries expose scoped facts and authority but no execution capability", context do
    %{fixture: fixture, domain: domain, scope: scope} = context
    assert Domain.whereis(domain.ref) == fixture.server
    assert Scope.ref(scope) == fixture.refs.scope
    assert Scope.domain_ref(scope) == domain.ref
    assert {:ok, %{revision: revision}} = Spectre.head(domain)
    assert revision > 0
    assert {:ok, []} = Spectre.acts(scope)
    assert {:ok, []} = Spectre.duties(scope, status: :open)
    assert {:ok, []} = Spectre.erasures(scope)
    assert {:ok, []} = Spectre.declassifications(scope)
    assert {:ok, authority} = Spectre.authority(scope)
    assert authority.principal_ref == fixture.refs.proposer
    assert length(authority.held_mandates) == 1
    refute Map.has_key?(authority, :grant)
    assert {:ok, view} = Spectre.view(scope)
    assert view.opening.ref == fixture.refs.scope

    assert {:error, {:invalid_duty_status_filter, :invalid}} =
             Spectre.duties(scope, status: :invalid)

    assert {:error, {:unknown_query_options, :acts, [:limit]}} = Spectre.acts(scope, limit: 1)
  end

  test "Definition revisions are governed, immutable and independently auditable", context do
    %{fixture: fixture, scope: scope, first: first, second: second} = context
    assert {:error, {:definition_not_found, _}} = Spectre.definition(scope, first.ref)
    assert {:ok, result} = revise(context, first)
    assert result.primary.decision.outcome == :admitted
    assert is_nil(result.primary.attempt)
    assert result.fallback == :not_applicable
    assert {:ok, ^first} = Spectre.definition(scope, first.ref)

    assert {:ok, result} = revise(context, second)
    assert result.primary.decision.outcome == :admitted
    assert {:ok, ^first} = Spectre.definition(scope, first.ref)
    assert {:ok, ^second} = Spectre.definition(scope, second.ref)
    projection = Sequencer.projection(fixture.server)
    assert projection.definition_heads[Definition.key(first)] == second.ref
    assert {:ok, snapshot} = Ledger.load(fixture.store_config, fixture.refs.domain)
    assert {:ok, _report} = Audit.verify(snapshot, fixture.constitution, Runtime.now())
  end

  test "Mind receives sanitized durable Evidence outside the trusted Domain process", context do
    %{fixture: fixture, scope: scope} = context

    assert {:ok, %{candidates: [], state: 8, turn: turn, evidence: [evidence]}} =
             Spectre.turn(scope, input(fixture), 7, mind_opts: [observer: self()])

    assert_receive {:deliberated, caller, ^turn, _opts}
    assert caller == self()
    refute caller == fixture.server
    assert is_nil(turn.context.seal)
    assert turn.mind_ref == StatefulMind.ref()
    assert Turn.evidence_refs(turn) == [evidence.ref]
    assert Sequencer.projection(fixture.server).evidence[evidence.ref] == evidence

    assert {:ok, %{candidates: []}} =
             Spectre.turn(scope, input(fixture), mind_opts: [observer: self()])
  end

  test "Mind cannot return a Candidate for another proposer or Scope", context do
    %{fixture: fixture, scope: scope} = context
    candidate = fixture |> Fixture.refund_candidate(100) |> Spectre.Candidate.new() |> record!()

    assert {:ok, %{turn: turn}} =
             Spectre.turn(scope, input(fixture), mind_opts: [observer: self()])

    wrong =
      record!(
        Spectre.Candidate.new(%{
          Map.from_struct(candidate)
          | proposer_ref: fixture.refs.grantor,
            ref: nil,
            material_digest: nil
        })
      )

    assert {:error, {:mind_candidate_proposer_mismatch, _, _}} =
             Mind.deliberate(StatefulMind, turn, observer: self(), candidates: [wrong])

    wrong =
      record!(
        Spectre.Candidate.new(%{
          Map.from_struct(candidate)
          | scope_ref: fixture.refs.governance_scope,
            ref: nil,
            material_digest: nil
        })
      )

    assert {:error, {:mind_candidate_scope_mismatch, _, _}} =
             Mind.deliberate(StatefulMind, turn, observer: self(), candidates: [wrong])

    assert Sequencer.projection(fixture.server).acts == %{}
  end

  test "Instance pins its chosen revision and advances only successful local turns", context do
    assert {:ok, _} = revise(context, context.first)

    instance =
      start_supervised!(
        {Instance, scope: context.scope, definition_ref: context.first.ref, state: 0}
      )

    assert Instance.scope(instance) == context.scope
    assert Instance.state(instance) == %{revision: 0, value: 0}

    assert {:ok, result} =
             Instance.turn(instance, input(context.fixture), mind_opts: [observer: self()])

    assert_receive {:deliberated, ^instance, turn, opts}
    assert result.turn == turn
    assert opts[:definition_ref] == context.first.ref
    assert opts[:state_revision] == 0
    refute Keyword.has_key?(opts, :instance_ref)
    assert Instance.state(instance) == %{revision: 1, value: 1}

    assert {:error, {:reserved_instance_mind_option, :state_revision}} =
             Instance.turn(instance, input(context.fixture), mind_opts: [state_revision: 42])

    assert Instance.state(instance) == %{revision: 1, value: 1}
    assert {:ok, _} = revise(context, context.second)
    assert {:ok, first} = Instance.definition(instance)
    assert first == context.first
    assert Instance.info(instance).definition_ref == first.ref
  end

  test "Instance terminates on Domain loss instead of retaining a permanently fenced Scope",
       context do
    assert {:ok, _} = revise(context, context.first)

    instance =
      start_supervised!({Instance, scope: context.scope, definition_ref: context.first.ref})

    monitor = Process.monitor(instance)
    GenServer.stop(context.fixture.server)
    assert_receive {:DOWN, ^monitor, :process, ^instance, {:shutdown, {:domain_down, :normal}}}
    refute Process.alive?(instance)
    assert {:error, :domain_not_found} = Spectre.definition(context.scope, context.first.ref)
  end

  defp definition(revision, previous_ref \\ nil) do
    record!(
      Definition.new(
        namespace: "test",
        name: "assistant",
        revision: revision,
        previous_ref: previous_ref,
        declared_at: Fixture.default_now(),
        body: %{"revision" => revision}
      )
    )
  end

  defp revise(context, definition) do
    fixture = context.fixture

    Spectre.revise_definition(context.governance_scope, definition,
      identity_key: "revise:#{definition.ref}",
      requested_mandate_ref: fixture.governance_mandate.ref,
      accountable_ref: fixture.refs.accountable,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    )
  end

  defp input(fixture),
    do: fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)

  defp record!({:ok, record}), do: record
end
