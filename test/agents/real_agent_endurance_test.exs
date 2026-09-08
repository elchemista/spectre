defmodule Spectre.Agents.RealAgentEnduranceTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Condition, Instance, Ledger, Scope}
  alias Spectre.Consequence.Contract
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Input.Pipeline
  alias Spectre.Ledger.Store.Disk
  alias Spectre.Router.SemanticCache
  alias Spectre.SemanticCache.Test.CustomerSupport
  alias Spectre.SemanticCache.Vettore, as: Cache
  alias Spectre.Store.Memory, as: Checkpoints

  alias Spectre.Test.EnduranceAgent.{
    Envelope,
    Executor,
    ReceiptWatch,
    Refunds,
    RefundWork,
    Support
  }

  alias Spectre.Test.HandlerAgentCase.Text
  alias Spectre.V04Test.Fixture

  @duration_ms 60_000
  @interval_ms 5_000
  @moduletag :endurance
  @moduletag :tmp_dir
  @moduletag timeout: 240_000

  setup %{tmp_dir: temporary_directory} do
    vectors = CustomerSupport.embed!()
    now = Spectre.Clock.System.now()

    components =
      Map.new(["billing", "returns"], &{&1, Refunds.definition(revision: 1, declared_at: now)})

    definition = Support.definition(revision: 1, declared_at: now, components: components)

    jobs = %{
      worker: RefundWork.definition(revision: 1, declared_at: now),
      vigil: ReceiptWatch.definition(revision: 1, declared_at: now)
    }

    namespace = "endurance-#{System.unique_integer([:positive])}"
    domain_ref = "v0.4:#{namespace}:domain"
    scopes = %{worker: "scope:#{namespace}:refunds", vigil: "scope:#{namespace}:receipts"}
    {:ok, governance_row} = Spectre.Row.new(write: true, govern: true)
    {:ok, model_row} = Spectre.Row.new(attempt: true)

    {:ok, model_contract} =
      Contract.new(
        shape: %{
          "target_ref" => "target_ref",
          "prompt" => %{
            "parts" => %{
              "$list" => %{
                "name" => "string",
                "role" => "atom",
                "text" => "string",
                "template_ref" => "ref"
              }
            },
            "definition_ref" => "ref",
            "turn_ref" => "ref",
            "configuration" => "portable"
          }
        }
      )

    journal = start_supervised!({Agent, fn -> %{} end})
    ledger_directory = Path.join(temporary_directory, "ledger")
    ledger = start_supervised!({Disk, path: ledger_directory, compressed: true})

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        store: {Disk, server: ledger},
        name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
        clock: Spectre.Clock.System,
        clock_tolerance_ms: 5_000,
        mind: Spectre.Agent,
        classes: ["refund.issue", "model.embed"],
        condition_bindings: %{"scope_ref" => "v0.4:#{namespace}:scope:refunds"},
        additional_mandates: fn root ->
          [condition] = root.conditions

          {:ok, scoped} =
            condition
            |> Map.from_struct()
            |> Map.delete(:ref)
            |> Map.update!(:bindings, &Map.put(&1, "scope_ref", scopes.worker))
            |> Condition.new()

          {:ok, worker_mandate} =
            root
            |> Map.from_struct()
            |> Map.delete(:ref)
            |> Map.merge(%{
              scope_refs: [scopes.worker],
              classes: ["refund.issue"],
              conditions: [scoped]
            })
            |> Spectre.Mandate.new()

          [worker_mandate]
        end,
        governance_allowed: true,
        governance_classes: ["definition.revise", "scope.open"],
        governance_targets:
          [definition.ref | Enum.map(jobs, &elem(&1, 1).ref)] ++ Map.values(scopes),
        governance_ceiling: governance_row,
        governance_declarations: %{"scope.open" => governance_row, "model.embed" => model_row},
        consequence_contracts: %{"model.embed" => model_contract},
        executors: [{Executor, journal: journal, observer: self()}]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.lookup_domain(domain_ref)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))
    {:ok, payment} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))
    fixture = put_in(fixture.refs.payment_evidence, payment.ref)

    {:ok, admin} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    candidate = %{
      identity_key: "publish",
      requested_mandate_ref: fixture.governance_mandate.ref,
      accountable_ref: fixture.refs.accountable,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"}
    }

    for published <- [definition | Map.values(jobs)] do
      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revise_definition(admin, published, %{
                 candidate
                 | identity_key: published.ref
               })
    end

    binding = %{
      namespace: namespace,
      definition_ref: definition.ref,
      flow: "support",
      profile_ref: CustomerSupport.profile()
    }

    cache_server =
      start_supervised!(
        {Cache,
         Map.to_list(binding) ++
           [dimensions: 384, index: :hnsw, max_entries: 20, labels: ["support/refund"]]}
      )

    {:ok, cache} = SemanticCache.bind({Cache, server: cache_server}, binding)

    for {"refund", text} <- CustomerSupport.examples() do
      {:ok, example} =
        SemanticCache.put(cache, %{
          text: text,
          label: "support/refund",
          embedding: vectors[text],
          profile_ref: binding.profile_ref
        })

      assert {:ok, _} = SemanticCache.verify(cache, example.id, example.revision)
    end

    {:ok, envelope} = Pipeline.new([Envelope])
    {:ok, text} = Pipeline.new([Text])
    attrs = Fixture.refund_candidate(fixture, 10)

    common =
      Map.take(attrs, [
        :requested_mandate_ref,
        :executor_ref,
        :executor_contract_ref,
        :accountable_ref,
        :purpose_ref,
        :purpose_params,
        :observation_window_ms
      ])

    bindings = %{
      "refund.issue" => common,
      "model.embed" => common
    }

    state = %{
      count: 0,
      consequence: attrs.consequence,
      assigns: %{customer: "Giulia Rossi", order_id: "ORD-2041"}
    }

    opts = [
      agent: Support,
      scope: scope,
      definition: definition,
      state: state,
      bindings: bindings,
      component_states: %{billing: state, returns: state},
      adapters: %{
        request: %{encoder: [target_ref: fixture.refs.payment_target]},
        pipelines: %{"envelope" => envelope, "billing/text" => text, "returns/text" => text},
        semantic_cache: %{
          routing:
            {Cache, namespace: namespace, profile_ref: binding.profile_ref, server: cache_server}
        },
        observer: %{events: [to: self()]}
      }
    ]

    instance = start_supervised!({Instance, opts})

    coordinator =
      start_supervised!(
        Supervisor.child_spec({Instance, Keyword.put(opts, :scope, admin)}, id: :coordinator)
      )

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    checkpoints = start_supervised!(Checkpoints)

    c = %{
      fixture: fixture,
      domain: domain,
      instance: instance,
      definition: definition,
      cache: cache,
      cache_server: cache_server,
      journal: journal,
      bindings: bindings,
      state: state,
      scopes: scopes,
      candidate: candidate,
      coordinator: coordinator,
      supervisor: supervisor,
      checkpoints: {Checkpoints, server: checkpoints},
      ledger_directory: ledger_directory
    }

    worker = start_job(c, :worker, :refunds, jobs.worker, :work, now + 45_000)
    vigil = start_job(c, :vigil, :receipts, jobs.vigil, :vigil, now + 180_000)

    assert {:error, {:evidence_outside_scope, _}} =
             Instance.turn(worker, evidence(c, %{"event" => "refund"}),
               context_evidence_refs: [payment.ref]
             )

    payment_input = fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)
    {:ok, [worker_payment]} = Spectre.observe(Instance.scope(worker), payment_input)
    GenServer.stop(coordinator, :normal)
    Map.merge(c, %{worker: worker, vigil: vigil, worker_payment: worker_payment.ref})
  end

  test "real embeddings, prompts, two mounted skills and governed jobs run for a full minute",
       c do
    processes = %{
      agent: c.instance,
      worker: c.worker,
      vigil: c.vigil,
      domain: c.fixture.server,
      cache: c.cache_server,
      ledger: c.fixture.store
    }

    monitors = Enum.map(processes, fn {_name, pid} -> Process.monitor(pid) end)
    started = System.monotonic_time(:millisecond)
    initial_revision = Sequencer.projection(c.fixture.server).revision
    initial_memory = memory(processes)
    rounds = exercise_until(c, started + @duration_ms, 0)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= @duration_ms
    assert rounds >= 10
    assert Instance.state(c.instance).value.count == rounds
    assert Instance.state(c.worker).value.count == rounds
    assert Instance.state(c.vigil).value.count == rounds
    assert {:ok, %{count: 3}} = SemanticCache.info(c.cache)

    assert {:ok, 1} = Instance.checkpoint(c.instance, c.checkpoints, "endurance", 0)
    assert {:ok, 1, saved} = Spectre.Store.get(c.checkpoints, "endurance")

    for name <- ["billing/", "returns/"] do
      assert saved["components"][name][:value][:count] == rounds
      assert saved["components"][name][:value][:result] == :done
    end

    journal = Agent.get(c.journal, & &1)
    assert map_size(journal) == rounds * 4
    refunds = for {_key, %{kind: :refund, cents: cents}} <- journal, do: cents
    assert length(refunds) == rounds * 3
    assert Enum.sum(refunds) == rounds * 30
    projection = Sequencer.projection(c.fixture.server)
    assert projection.recorded_at - c.fixture.genesis.issued_at >= 45_000
    assert map_size(projection.attempts) == rounds * 4
    assert Enum.all?(projection.outcomes, fn {_ref, outcome} -> outcome.status == :succeeded end)
    [worker_mandate] = c.fixture.additional_mandates

    for {mandate, spent} <- [{c.fixture.mandate, rounds * 20}, {worker_mandate, rounds * 10}] do
      assert %{spent: ^spent, reserved: 0, suspended: 0} =
               projection.meters[mandate.ref][c.fixture.refs.meter]
    end

    assert MapSet.size(projection.pending_dispatches) == 0

    # A real wall-clock deadline opens a Duty. Work completion/process death
    # alone must not erase the promised obligation or release its authority.
    assert [{_ref, duty}] = Map.to_list(projection.duties)
    assert duty.class == :scope_promise_overdue
    assert duty.cause_key == {:scope_promise_overdue, c.scopes.worker}
    assert duty.status == :open
    final_memory = memory(processes)

    GenServer.stop(c.worker, :normal)
    assert Sequencer.projection(c.fixture.server).duties === projection.duties
    assert Process.alive?(c.vigil)
    assert_replay(c)

    Enum.each(monitors, &Process.demonitor(&1, [:flush]))

    IO.puts(
      "\nendurance: #{elapsed} ms, #{rounds} rounds, #{map_size(journal)} effects, #{projection.revision - initial_revision} new ledger entries, #{ledger_bytes(c.ledger_directory)} disk bytes; BEAM process bytes before=#{inspect(initial_memory)} after=#{inspect(final_memory)}"
    )
  end

  defp start_job(c, kind, name, definition, scope_kind, due_at) do
    scope_ref = c.scopes[kind]

    {:ok, context} =
      Spectre.authenticate(c.domain, scope_ref, %{
        principal_ref: c.fixture.refs.proposer,
        authentication_ref: "auth:" <> scope_ref,
        session_ref: "session:" <> scope_ref
      })

    {:ok, condition} =
      Condition.new(proposition: "job.finished", bindings: %{"scope_ref" => scope_ref})

    opening = %{
      kind: scope_kind,
      promise_condition: condition,
      accountable_ref: c.fixture.refs.accountable,
      disposition_authority_refs: [c.fixture.refs.executor],
      due_at: due_at
    }

    state = if kind == :worker, do: c.state, else: %{count: 0, last_receipt: nil}
    [worker_mandate] = c.fixture.additional_mandates

    bindings =
      Map.update!(
        c.bindings,
        "refund.issue",
        &Map.put(&1, :requested_mandate_ref, worker_mandate.ref)
      )

    assert {:ok, child} =
             Spectre.Agent.start_component(c.coordinator, kind, name,
               definition: definition,
               state: state,
               bindings: bindings,
               supervisor: c.supervisor,
               adapters: %{observer: %{events: [to: self()]}},
               input: evidence(c, %{"event" => "ready"}),
               opening: [
                 context: context,
                 attributes: opening,
                 candidate: %{c.candidate | identity_key: scope_ref}
               ]
             )

    assert Scope.ref(Instance.scope(child)) == scope_ref
    child
  end

  defp exercise_until(c, deadline, rounds) do
    if System.monotonic_time(:millisecond) >= deadline do
      rounds
    else
      next_tick = System.monotonic_time(:millisecond) + @interval_ms
      exercise_round(c, rounds)
      remaining = max(0, min(next_tick, deadline) - System.monotonic_time(:millisecond))

      receive do
        {:DOWN, _monitor, :process, pid, reason} ->
          flunk("endurance process #{inspect(pid)} died: #{inspect(reason)}")
      after
        remaining -> exercise_until(c, deadline, rounds + 1)
      end
    end
  end

  defp exercise_round(c, round) do
    queries = for {"refund", text} <- CustomerSupport.queries(), do: text
    text = Enum.at(queries, rem(round, length(queries)))
    # Real local inference runs again every tick, outside Router.evaluate/2.
    {:ok, [vector]} = ExFastembed.embed_text([text])
    assert length(vector) == 384

    envelope = %{
      "text" => text,
      "embedding" => vector,
      "profile_ref" => CustomerSupport.profile()
    }

    assert {:ok, turn} = turn(c, c.instance, %{"text" => envelope}, flow: :support)
    assert turn.selection.via == "semantic_cache"
    assert turn.selection.score >= 0.70
    assert_prompt(hd(turn.requests).candidate.consequence["prompt"], turn)
    complete(c, c.instance, turn)

    for {skill, message, via} <- [
          {"billing", "refund ORD-2041", "regex"},
          {"returns", "refund my order", "string_bag"}
        ] do
      assert {:ok, skill_turn} =
               turn(c, c.instance, %{"text" => message}, flow: skill <> "/support")

      assert skill_turn.selection.via == via

      assert skill_turn.definition_ref ==
               c.definition.body["authoring"]["component_definitions"][skill]["ref"]

      complete(c, c.instance, skill_turn)
    end

    assert {:ok, work} =
             turn(c, c.worker, %{"event" => "refund", "order_id" => "ORD-2041", "round" => round})

    completed = complete(c, c.worker, work)
    outcome = completed.result.details.primary.outcome
    [receipt] = outcome.evidence_refs

    assert {:ok, %{requests: []}} =
             Instance.turn(
               c.vigil,
               evidence(c, %{
                 "outcome_ref" => outcome.ref,
                 "receipt_ref" => receipt,
                 "status" => "succeeded"
               })
             )

    assert Instance.state(c.vigil, 1_000).value.last_receipt == outcome.ref
    assert Instance.info(c.instance, 1_000).definition_ref == c.definition.ref
    if rem(round, 4) == 0, do: assert_no_nomination(c)
    refute_received {:endurance_effect, _, _, _, _}
    drain_observer_events()
  end

  defp complete(c, instance, turn) do
    [request] = turn.requests
    refute_received {:endurance_effect, _, _, _, _}
    assert {:ok, completed} = Instance.advance(instance, request)

    assert completed.result.status == :done,
           inspect(completed.result.details.primary.decision.reasons)

    primary = completed.result.details.primary
    assert_receive {:endurance_effect, executor, act, attempt, result}, 1_000
    assert act === primary.act
    assert attempt === primary.attempt
    refute executor in [instance, c.fixture.server]
    assert primary.outcome.status == :succeeded
    if result.kind == :embedding, do: assert(length(result.vector) == 384)
    assert {:error, :invalid_or_superseded_instance_request} = Instance.advance(instance, request)

    assert_receive {:spectre_agent_event, [:spectre, :agent, :result], %{}, metadata}, 1_000
    assert metadata.request_ref == request.ref
    assert metadata.act_ref == act.ref
    assert metadata.outcome_ref == primary.outcome.ref
    completed
  end

  defp assert_prompt(prompt, turn) do
    assert Enum.map(prompt["parts"], & &1["name"]) == [
             "safety",
             "system",
             "refund_policy",
             "receipt_policy",
             "task"
           ]

    assert prompt["definition_ref"] == turn.definition_ref
    assert prompt["turn_ref"] == turn.ref
    assert List.last(prompt["parts"])["text"] =~ "Order ORD-2041"
    assert List.last(prompt["parts"])["text"] =~ "Giulia Rossi"
    assert Enum.all?(prompt["parts"], &is_binary(&1["template_ref"]))
  end

  defp assert_no_nomination(c) do
    text = CustomerSupport.unrelated()
    {:ok, [vector]} = ExFastembed.embed_text([text])
    before = Sequencer.projection(c.fixture.server)

    envelope = %{
      "text" => text,
      "embedding" => vector,
      "profile_ref" => CustomerSupport.profile()
    }

    for input <- [envelope, Map.delete(envelope, "embedding")] do
      assert {:ok, %{requests: [], selection: nil}} =
               turn(c, c.instance, %{"text" => input}, flow: :support)
    end

    after_turns = Sequencer.projection(c.fixture.server)
    assert after_turns.acts === before.acts
    assert after_turns.decisions === before.decisions
    refute_received {:endurance_effect, _, _, _, _}
  end

  defp turn(c, instance, payload, opts \\ []) do
    payment = if instance == c.worker, do: c.worker_payment, else: c.fixture.refs.payment_evidence

    Instance.turn(
      instance,
      evidence(c, payload),
      Keyword.put(opts, :context_evidence_refs, [payment])
    )
  end

  defp evidence(c, payload),
    do:
      c.fixture
      |> Fixture.paid_evidence(proposition: "customer.message", payload: payload)
      |> Map.from_struct()
      |> Map.delete(:ref)

  defp assert_replay(c) do
    {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, recovered} = Projection.replay(snapshot, c.fixture.constitution)
    assert recovered === Sequencer.projection(c.fixture.server)
    {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, recovered.recorded_at)
  end

  defp drain_observer_events do
    receive do
      {:spectre_agent_event, _event, _measurements, metadata} ->
        assert Map.take(metadata, [:input, :consequence, :capability, :options, :prompt]) == %{}
        drain_observer_events()
    after
      0 -> :ok
    end
  end

  # BEAM process bytes, not total RSS or the native ONNX/HNSW allocations.
  defp memory(processes),
    do: Map.new(processes, fn {name, pid} -> {name, Process.info(pid, :memory) |> elem(1)} end)

  defp ledger_bytes(directory),
    do:
      directory
      |> File.ls!()
      |> Enum.map(&File.stat!(Path.join(directory, &1)).size)
      |> Enum.sum()
end
