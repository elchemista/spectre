defmodule Spectre.Core.LateObservationTest do
  use ExUnit.Case, async: false

  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.{Audit, Evidence, Ledger}
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Executor do
    @behaviour Spectre.Attempt.Executor
    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor
    @impl true
    def execute(act, attempt, capability, opts) do
      send(Keyword.fetch!(opts, :observer), {:executed, act.ref, attempt.ref, capability})
      status = Keyword.fetch!(opts, :status)

      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(),
          payload: "initial receipt"
        )

      metadata = %{evidence: [evidence], details_ref: "receipt:initial"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end

  defmodule Observer do
    @behaviour Spectre.Attempt.Observer
    @impl true
    def observe(act, attempt, input, opts) do
      send(Keyword.fetch!(opts, :observer), {:observed, self(), act, attempt, input, opts})

      case Map.get(input, :behavior, :normal) do
        :raise -> raise "private observer credentials"
        :throw -> throw({:private, "observer credentials"})
        :exit -> exit({:private, "observer credentials"})
        :error -> {:error, {:private, "observer credentials"}}
        :malformed -> {:ok, :not_an_observation}
        :normal -> observation(act, attempt, input)
      end
    end

    defp observation(act, attempt, input) do
      status = Map.get(input, :status, :succeeded)
      attested = Map.get(input, :attested, status)

      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(
          act,
          attempt,
          attested,
          Map.get(input, :observed_at, Runtime.now()),
          payload: "verified late receipt"
        )

      evidence =
        case Map.get(input, :tamper) do
          nil ->
            evidence

          attrs ->
            {:ok, modified} =
              evidence
              |> Map.from_struct()
              |> Map.delete(:ref)
              |> Map.merge(attrs)
              |> Evidence.new()

            modified
        end

      evidence = if input[:empty_evidence], do: [], else: [evidence]

      metadata =
        Map.merge(
          %{evidence: evidence, details_ref: "receipt:late"},
          Map.get(input, :metadata, %{})
        )

      {:ok, Map.get(input, :reported, status), Map.get(input, :corrected_ref), metadata}
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    namespace = "late-observation-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    name = {:via, Registry, {Spectre.Domain.Registry, domain_ref}}
    capability = {:private_capability, make_ref()}
    initial = Map.get(tags, :initial, :ambiguous)

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: name,
        capability: capability,
        late_observer: if(tags[:no_observer], do: nil, else: Observer),
        governance_allowed: true,
        executors: [{Executor, observer: self(), status: initial}]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(domain_ref)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))
    payment = Fixture.paid_evidence(fixture)
    assert {:ok, ^payment} = Fixture.observe_payment(fixture, payment)

    candidate =
      Fixture.refund_candidate(fixture, 2000,
        evidence_refs: [payment.ref],
        observation_window_ms: 100
      )

    assert {:ok, result} = Spectre.propose(scope, candidate)
    assert result.primary.outcome.status == initial
    assert_receive {:executed, _, _, ^capability}
    Runtime.set_time(Runtime.now() + 1000)

    %{
      fixture: fixture,
      scope: scope,
      initial: result.primary,
      candidate: candidate,
      capability: capability
    }
  end

  test "late success settles suspended resources without another external attempt", c do
    before = projection(c)
    assert {:ok, result} = observe(c, %{status: :succeeded})
    assert result.outcome.status == :succeeded
    assert result.outcome.attempt_ref == c.initial.attempt.ref
    assert account(c).spent == 2000
    assert account(c).suspended == 0
    assert projection(c).duties == before.duties
    assert projection(c).attempts == before.attempts
    assert_replay(c)
  end

  test "late failure acknowledges an effect and cannot refund the reservation", c do
    assert {:ok, result} = observe(c, %{status: :failed})
    assert result.outcome.status == :failed
    assert account(c).spent == 2000
    assert account(c).available == 8000
    assert account(c).suspended == 0
    assert_replay(c)
  end

  test "only definitive no-effect returns the reserved quantity", c do
    before = projection(c)
    assert {:ok, result} = observe(c, %{status: :definitive_no_effect})
    assert result.outcome.status == :definitive_no_effect
    assert account(c).available == 10_000
    assert account(c).spent == 0
    assert account(c).suspended == 0
    assert projection(c).duties == before.duties
    assert_replay(c)
  end

  test "another ambiguous observation keeps resources suspended and the original Duty open", c do
    before = projection(c)
    assert {:ok, result} = observe(c, %{status: :ambiguous})
    assert result.outcome.status == :ambiguous
    assert account(c).suspended == 2000
    assert Map.has_key?(projection(c).outcomes, c.initial.outcome.ref)
    assert Enum.all?(before.duties, fn {key, duty} -> projection(c).duties[key] == duty end)
    assert_replay(c)
  end

  test "a late observer receives no capability and runs outside the Domain process", c do
    assert {:ok, _} = observe(c, %{})
    assert_receive {:observed, pid, act, attempt, _input, opts}
    assert pid == self()
    refute pid == c.fixture.server
    assert act == c.initial.act
    assert attempt == c.initial.attempt
    refute inspect({act, attempt, opts}) =~ inspect(c.capability)
    assert_replay(c)
  end

  test "replaying the exact late observation is idempotent", c do
    assert {:ok, first} = observe(c, %{})
    before = projection(c)
    assert {:ok, repeated} = observe(c, %{})
    assert repeated == first
    assert projection(c) == before
    assert_replay(c)
  end

  test "a claimed success with no attestation remains ambiguous", c do
    assert {:ok, result} = observe(c, %{empty_evidence: true})
    assert result.outcome.status == :ambiguous
    assert result.outcome.evidence_refs == []
    assert account(c).suspended == 2000
    assert account(c).spent == 0
    assert_replay(c)
  end

  test "success reported over failure Evidence remains ambiguous", c do
    assert {:ok, result} = observe(c, %{status: :succeeded, attested: :failed})
    assert result.outcome.status == :ambiguous
    assert account(c).suspended == 2000
    assert_replay(c)
  end

  for behavior <- [:raise, :throw, :exit, :error] do
    test "observer #{behavior} cannot leak private diagnostics or change durable balances", c do
      before = projection(c)
      assert {:error, :late_observation_unavailable} = observe(c, %{behavior: unquote(behavior)})
      assert projection(c) == before
      assert_replay(c)
    end
  end

  test "malformed observer success is rejected without recording a fact", c do
    before = projection(c)
    assert {:error, :invalid_late_observer_response} = observe(c, %{behavior: :malformed})
    assert projection(c) == before
    assert_replay(c)
  end

  test "unknown reported status cannot become a successful Outcome", c do
    before = projection(c)
    assert {:error, :invalid_late_observer_response} = observe(c, %{reported: :done})
    assert projection(c) == before
    assert_replay(c)
  end

  test "private adapter metadata cannot be persisted alongside the receipt", c do
    before = projection(c)
    assert {:error, _} = observe(c, %{metadata: %{credentials: c.capability}})
    assert projection(c) == before
    assert_replay(c)
  end

  for {field, value} <- [
        {:issuer_ref, "impostor"},
        {:source_ref, "wrong-executor"},
        {:bindings, %{"attempt_ref" => "foreign-attempt"}}
      ] do
    test "tampered #{field} on late Evidence cannot mutate the original Attempt", c do
      before = projection(c)

      assert {:error, _} =
               observe(c, %{tamper: %{unquote(field) => unquote(Macro.escape(value))}})

      assert projection(c) == before
      assert_replay(c)
    end
  end

  test "future-dated Evidence is rejected, not treated as a result already observed", c do
    before = projection(c)
    assert {:error, _} = observe(c, %{observed_at: Runtime.now() + 1})
    assert projection(c) == before
    assert_replay(c)
  end

  test "an unknown Attempt is rejected before invoking the observer", c do
    before = projection(c)

    assert {:error, {:late_observation_attempt_not_found, "attempt:unknown"}} =
             Spectre.record_late_observation(c.scope, "attempt:unknown", %{},
               observer_opts: [observer: self()]
             )

    refute_received {:observed, _, _, _, _, _}
    assert projection(c) == before
  end

  @tag no_observer: true
  test "a missing host observer cannot be replaced from request options", c do
    before = projection(c)
    assert {:error, :late_observer_not_configured} = observe(c, %{})

    assert {:error, _} =
             Spectre.record_late_observation(c.scope, c.initial.attempt.ref, %{},
               observer: Observer
             )

    assert projection(c) == before
    refute_received {:observed, _, _, _, _, _}
  end

  test "another Scope cannot inspect an Attempt using the late-observation API", c do
    assert {:ok, domain} = Spectre.lookup_domain(c.fixture.refs.domain)

    assert {:ok, admin} =
             Spectre.resume_scope(
               domain,
               Fixture.context(c.fixture, authenticated_principal_ref: c.fixture.refs.grantor)
             )

    before = projection(c)

    assert {:error, :late_observation_cause_mismatch} =
             Spectre.record_late_observation(admin, c.initial.attempt.ref, %{},
               observer_opts: [observer: self()]
             )

    assert projection(c) == before
    refute_received {:observed, _, _, _, _, _}
  end

  for kind <- [:observer_opts, :sequencer_opts] do
    test "invalid #{kind} is rejected before consulting the world", c do
      before = projection(c)

      assert {:error, _} =
               Spectre.record_late_observation(c.scope, c.initial.attempt.ref, %{}, [
                 {unquote(kind), ["not keyword"]}
               ])

      assert projection(c) == before
      refute_received {:observed, _, _, _, _, _}
    end
  end

  test "a correction must name a known prior Outcome", c do
    before = projection(c)

    assert {:error, {:corrected_outcome_not_found, "outcome:unknown"}} =
             observe(c, %{corrected_ref: "outcome:unknown"})

    assert projection(c) == before
    assert_replay(c)
  end

  test "ambiguity cannot be relabeled as the no-effect claim being corrected", c do
    before = projection(c)

    assert {:error, :invalid_late_outcome_correction} =
             observe(c, %{corrected_ref: c.initial.outcome.ref})

    assert projection(c) == before
    assert_replay(c)
  end

  @tag initial: :definitive_no_effect
  test "a contradicted no-effect report recontains released resources and opens a Duty", c do
    assert account(c).available == 10_000
    assert {:ok, result} = observe(c, %{corrected_ref: c.initial.outcome.ref})
    assert result.outcome.status == :succeeded
    assert result.outcome.contradicts_outcome_ref == c.initial.outcome.ref
    assert account(c).available == 8000
    assert account(c).suspended == 2000
    assert Map.has_key?(projection(c).outcomes, c.initial.outcome.ref)
    assert Enum.any?(Map.values(projection(c).duties), &(&1.class == :contradicted_outcome))
    assert_replay(c)
  end

  @tag initial: :definitive_no_effect
  test "an unattested correction cannot retract a recorded no-effect claim", c do
    before = projection(c)

    assert {:error, :invalid_late_outcome_correction} =
             observe(c, %{corrected_ref: c.initial.outcome.ref, empty_evidence: true})

    assert projection(c) == before
    assert_replay(c)
  end

  @tag initial: :definitive_no_effect
  test "another no-effect claim is not a correction", c do
    before = projection(c)

    assert {:error, :invalid_late_outcome_correction} =
             observe(c, %{status: :definitive_no_effect, corrected_ref: c.initial.outcome.ref})

    assert projection(c) == before
    assert_replay(c)
  end

  @tag initial: :succeeded
  test "a late no-effect claim cannot silently undo an already successful execution", c do
    assert {:error, _} = observe(c, %{status: :definitive_no_effect})
    assert account(c).spent == 2000
    assert account(c).available == 8000
    assert projection(c).outcomes[c.initial.outcome.ref] == c.initial.outcome
    assert_replay(c)
  end

  test "recovery preserves both late settlement and the original ambiguous Duty", c do
    assert {:ok, _} = observe(c, %{})
    before = projection(c)
    GenServer.stop(c.fixture.server)
    recovered = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    assert Sequencer.projection(recovered.server) == before
    assert_replay(%{c | fixture: recovered})
  end

  test "an old Scope is fenced after Domain restart, before another observation", c do
    GenServer.stop(c.fixture.server)
    recovered = Fixture.restart_domain(c.fixture, generation: 8)
    on_exit(fn -> Fixture.stop_process(recovered.server) end)
    before = Sequencer.projection(recovered.server)
    assert {:error, _} = observe(c, %{})
    assert Sequencer.projection(recovered.server) == before
    refute_received {:observed, _, _, _, _, _}
  end

  defp observe(c, input),
    do:
      Spectre.record_late_observation(c.scope, c.initial.attempt.ref, input,
        observer_opts: [observer: self()]
      )

  defp projection(c), do: Sequencer.projection(c.fixture.server)
  defp account(c), do: projection(c).meters[c.fixture.mandate.ref][c.fixture.refs.meter]

  defp assert_replay(c) do
    refute_received {:executed, _, _, _}
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, replayed} = Projection.replay(snapshot, c.fixture.constitution)
    assert replayed == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
