defmodule Spectre.CoreTest.FoundationBuilderTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Foundation, Genesis, HostProfile, Ledger, Mandate, Principal, Surface}
  alias Spectre.Domain.Bootstrap
  alias Spectre.Ledger.Store.ETS
  alias Spectre.Mind.Turn
  alias Spectre.V04Test.{Fixture, Runtime}

  @bundle_keys [:constitution, :principals, :host_profile, :surface, :root_mandates]
  @metadata_keys [:ref, :issued_at, :attestation_ref, :emergency_mandate_ref]
  @moduletag capture_log: true

  defmodule Assistant do
    use Spectre.Agent, namespace: "foundation", name: "assistant", revision: 1, declared_at: 0
    use Spectre.Mind, ref: "mind:foundation"
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})

    @impl true
    def deliberate(turn, opts) do
      attrs = Keyword.fetch!(opts, :attrs) |> Map.put(:evidence_refs, Turn.evidence_refs(turn))
      candidate("refund", turn, attrs)
    end
  end

  defmodule Reject do
    @behaviour Spectre.Genesis.Verifier
    @impl true
    def verify(_genesis, _opts), do: {:error, :external_recognition_refused}
  end

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "foundation-builder")
    on_exit(fn -> Fixture.stop_domain(fixture) end)

    attrs =
      fixture.sequencer_opts
      |> Keyword.take(@bundle_keys)
      |> Keyword.put(:genesis, Map.take(Map.from_struct(fixture.genesis), @metadata_keys))

    %{fixture: fixture, domain: fixture.refs.domain, attrs: attrs}
  end

  test "links are derived from the exact records without changing authority or writing history",
       c do
    before = Fixture.snapshot(c.fixture)
    assert {:ok, options} = Foundation.new(c.domain, c.attrs)
    assert options[:genesis] === c.fixture.genesis

    for field <- @bundle_keys do
      assert options[field] === c.fixture.sequencer_opts[field]
    end

    assert options[:root_mandates] == [c.fixture.mandate]
    assert Fixture.snapshot(c.fixture) === before
    refute Keyword.has_key?(options, :genesis_verifier)
    assert :ok = Bootstrap.validate(c.domain, options, Runtime.now())

    assert {:error, :genesis_verifier_required} =
             Bootstrap.prepare(c.domain, options, Runtime.now())
  end

  test "all choices including absence of emergency authority must be explicit", c do
    for key <- [:genesis | @bundle_keys] do
      assert {:error, {:missing_foundation_fields, [^key]}} =
               Foundation.new(c.domain, Keyword.delete(c.attrs, key))
    end

    for key <- @metadata_keys do
      attrs = Keyword.update!(c.attrs, :genesis, &Map.delete(&1, key))
      assert {:error, {:missing_foundation_fields, [^key]}} = Foundation.new(c.domain, attrs)
    end
  end

  test "canonical boundary maps restore the same records and never bypass content identity", c do
    assert {:ok, expected} = Foundation.new(c.domain, c.attrs)

    attrs = %{
      "genesis" =>
        Map.new(c.attrs[:genesis], fn {key, value} -> {Atom.to_string(key), value} end),
      "constitution" => c.attrs[:constitution],
      "principals" => Enum.map(c.attrs[:principals], &Principal.canonical/1),
      "root_mandates" => Enum.map(c.attrs[:root_mandates], &Mandate.canonical/1),
      "host_profile" => HostProfile.canonical(c.attrs[:host_profile]),
      "surface" => Surface.canonical(c.attrs[:surface])
    }

    assert {:ok, ^expected} = Foundation.new(c.domain, attrs)

    corrupted = put_in(attrs["surface"]["ref"], "forged")
    assert {:error, _} = Foundation.new(c.domain, corrupted)
    collision = Map.put(attrs, :surface, c.attrs[:surface])
    assert {:error, _} = Foundation.new(c.domain, collision)
    collision = put_in(attrs["genesis"][:issued_at], c.attrs[:genesis].issued_at)
    assert {:error, _} = Foundation.new(c.domain, collision)
  end

  test "callers cannot override derived links or smuggle a verifier into pure assembly", c do
    for field <- [
          :domain_ref,
          :principal_refs,
          :root_mandate_refs,
          :constitution_ref,
          :surface_ref,
          :surface_revision,
          :host_profile_ref
        ] do
      attrs = Keyword.update!(c.attrs, :genesis, &Map.put(&1, field, "forged"))
      assert {:error, _} = Foundation.new(c.domain, attrs)
    end

    assert {:error, _} = Foundation.new(c.domain, Keyword.put(c.attrs, :genesis_verifier, Reject))
    assert {:error, _} = Foundation.new(c.domain, c.attrs ++ [surface: c.attrs[:surface]])
  end

  test "missing principals, duplicate records and a root from another Genesis fail the actual fold",
       c do
    assert {:error, _} = Foundation.new(c.domain, Keyword.put(c.attrs, :principals, []))
    duplicated = Keyword.update!(c.attrs, :principals, fn records -> records ++ [hd(records)] end)
    assert {:error, _} = Foundation.new(c.domain, duplicated)

    {:ok, foreign} =
      c.fixture.mandate
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.put(:source_ref, "genesis:other")
      |> Mandate.new()

    assert {:error, _} = Foundation.new(c.domain, Keyword.put(c.attrs, :root_mandates, [foreign]))
  end

  test "removing independent Duty routes is not repaired by inventing an administrator", c do
    attrs = Keyword.put(c.attrs, :constitution, %{})
    assert {:error, {:duty_disposition_route_required, _}} = Foundation.new(c.domain, attrs)
  end

  test "unknown emergency references and malformed metadata cannot create a usable bundle", c do
    for {field, value} <- [
          emergency_mandate_ref: "missing",
          issued_at: 1.0,
          issued_at: -1,
          attestation_ref: nil,
          ref: nil
        ] do
      attrs = Keyword.update!(c.attrs, :genesis, &Map.put(&1, field, value))
      assert {:error, _} = Foundation.new(c.domain, attrs)
    end

    assert {:error, _} = Foundation.new(nil, c.attrs)
    assert {:error, _} = Foundation.new(c.domain, [:invalid])

    assert {:error, _} =
             Foundation.new(
               c.domain,
               Keyword.put(c.attrs, :principals, [hd(c.attrs[:principals]) | :bad])
             )
  end

  test "pure success never substitutes for external recognition at public Domain startup", c do
    {:ok, options} = Foundation.new(c.domain, c.attrs)
    store = {ETS, server: start_supervised!(ETS)}
    boundary = boundary(c)

    assert {:error, :genesis_verifier_required} =
             Spectre.start_domain(c.domain, store, options ++ boundary)

    assert {:error, :external_recognition_refused} =
             Spectre.start_domain(
               c.domain,
               store,
               options ++ boundary ++ [genesis_verifier: Reject]
             )

    assert :not_found = Ledger.load(store, c.domain)
  end

  test "an assembled foundation boots a full agent but its static check does not admit an over-budget proposal",
       c do
    {:ok, options} = Foundation.new(c.domain, c.attrs)
    store = {ETS, server: start_supervised!(ETS)}

    assert {:ok, domain} =
             Spectre.start_domain(
               c.domain,
               store,
               options ++
                 boundary(c) ++
                 [genesis_verifier: c.fixture.sequencer_opts[:genesis_verifier], mind: Assistant]
             )

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Spectre.Domain.Supervisor, domain.server)
    end)

    assert {:ok, _report} = Surface.verify_definition(options[:surface], Assistant.definition())

    auth = %{
      principal_ref: c.fixture.refs.proposer,
      authentication_ref: c.fixture.refs.authentication,
      session_ref: c.fixture.refs.session
    }

    assert {:ok, context} = Spectre.authenticate(domain, c.fixture.refs.scope, auth)
    assert {:ok, scope} = Spectre.open_scope(domain, context, opened_at: Runtime.now())
    input = c.fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)

    for {amount, expected} <- [{20_000, :refused}, {100, :admitted}] do
      attrs =
        c.fixture
        |> Fixture.refund_candidate(amount, identity_key: "refund:#{amount}")
        |> Map.drop([:class, :row, :proposer_ref, :scope_ref])

      assert {:ok, %{candidates: [candidate]}} =
               Spectre.turn(scope, input, mind_opts: [attrs: attrs])

      assert {:ok, result} = Spectre.propose(scope, candidate)
      assert result.primary.decision.outcome == expected

      if expected == :refused do
        assert result.primary.attempt == nil
      else
        assert result.primary.outcome.status == :ambiguous
      end
    end

    assert {:ok, snapshot} = Ledger.load(store, c.domain)
    assert {:ok, _} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())

    assert snapshot.entries
           |> hd()
           |> then(&(&1.payload["data"] == Genesis.canonical(options[:genesis])))
  end

  defp boundary(c) do
    Keyword.take(c.fixture.sequencer_opts, [
      :ingress,
      :clock,
      :id_source,
      :executors,
      :broker,
      :checkout_receipt_secret,
      :grant_secret,
      :generation,
      :clock_tolerance_ms
    ])
  end
end
