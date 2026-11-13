Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.DomainConfigurationBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Domain.{Configuration, Sequencer}
  alias Spectre.GAM.Domain.Sequencer.Control
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule BrokenClock do
    def now, do: :unknown
  end

  test "configuration never retains the bootstrap authority as mutable runtime wiring", %{f: f} do
    assert {:ok, config} = Configuration.new(f.sequencer_opts)
    runtime = Configuration.runtime_values(config)
    assert Enum.sort(Map.keys(runtime)) == Enum.sort(Configuration.runtime_fields())
    refute Map.has_key?(runtime, :constitution)
    refute Map.has_key?(runtime, :domain_ref)
    refute Map.has_key?(runtime, :bootstrap_opts)
    assert Configuration.genesis_verifier(config) == f.sequencer_opts[:genesis_verifier]

    assert Configuration.verification_opts(config) ==
             Keyword.take(f.sequencer_opts, [:genesis_verifier])
  end

  for key <- [:domain_ref, :store, :ingress] do
    test "missing #{key} is diagnosed before starting a Domain", %{f: f} do
      assert {:error, {:missing_sequencer_option, unquote(key)}} =
               Configuration.new(Keyword.delete(f.sequencer_opts, unquote(key)))
    end
  end

  for {key, value} <- [
        domain_ref: "",
        generation: 1.0,
        clock: "clock",
        id_source: "id",
        late_observer: [],
        recovery_timeout: 0,
        ingress_max_concurrency: 0,
        ingress_timeout: 0,
        max_pending_submissions: 0,
        grant_secret: "short",
        checkout_receipt_secret: "short",
        grant_ttl_ms: 0,
        batch_size: 0,
        batch_wait_ms: -1,
        conflict_retries: -1,
        ambiguous_retries: -1,
        ledger_opts: [:invalid],
        ledger_opts: %{}
      ] do
    test "invalid #{key}=#{inspect(value)} is rejected at configuration time", %{f: f} do
      assert {:error, {:invalid_sequencer_option, unquote(key)}} =
               Configuration.new(
                 Keyword.put(f.sequencer_opts, unquote(key), unquote(Macro.escape(value)))
               )
    end
  end

  test "adapter availability is checked without invoking an unrelated module", %{f: f} do
    for {key, callback, arity} <-
          [clock: {:now, 0}, id_source: {:generate, 0}, late_observer: {:observe, 4}]
          |> Enum.map(fn {key, {callback, arity}} -> {key, callback, arity} end) do
      assert {:error, {:sequencer_callback_unavailable, ^key, String, ^callback, ^arity}} =
               Configuration.new(Keyword.put(f.sequencer_opts, key, String))
    end

    assert {:error, :invalid_clock_value} =
             Configuration.new(Keyword.put(f.sequencer_opts, :clock, BrokenClock))

    assert {:error, :invalid_constitution} =
             Configuration.new(Keyword.put(f.sequencer_opts, :constitution, []))
  end

  test "unknown and malformed options cannot silently select defaults", %{f: f} do
    for opts <- [nil, %{}, [:invalid]] do
      assert {:error, :invalid_sequencer_options} = Configuration.new(opts)

      assert {:error, {:invalid_keyword_options, :domain_options}} =
               Configuration.validate_host_options(opts)
    end

    assert {:error, {:unknown_sequencer_configuration_options, [:batch_szie]}} =
             Configuration.new([batch_szie: 2] ++ f.sequencer_opts)

    assert {:error, {:unknown_options, :domain, [:batch_szie]}} =
             Configuration.validate_host_options(batch_szie: 2)

    assert :ok = Configuration.validate_host_options(batch_size: 2)
  end

  test "public sequencer guards reject unauthenticated calls without contacting a process" do
    server = :not_a_running_domain
    assert {:error, :invalid_sequencer_options} = Sequencer.start_link(%{})
    assert {:error, :invalid_submission_input} = Sequencer.submit(server, nil, %{})

    assert {:error, :invalid_governed_scope_opening_input} =
             Sequencer.submit_scope_opening(server, nil, nil, %{})

    assert {:error, :invalid_authentication_options} =
             Sequencer.authenticate(server, "scope", nil, %{})

    assert {:error, :invalid_grant} = Sequencer.consume_grant(server, %{})
    assert {:error, :invalid_execution_route} = Sequencer.execution_route(server, %{})
    assert {:error, :invalid_outcome_options} = Sequencer.record_outcome(server, %{}, %{})
    assert {:error, :invalid_observation_input} = Sequencer.observe(server, nil, %{})
    assert {:error, :invalid_turn_input} = Sequencer.begin_turn(server, nil, "hello", [])

    assert {:error, :invalid_derivation_input} =
             Sequencer.record_derivation(server, nil, nil, %{})

    assert {:error, :invalid_executor_evidence_input} =
             Sequencer.record_executor_evidence(server, "", "", [])

    for {function, args} <- [
          record_presentation: [nil, %{}],
          open_scope: [nil, %{}],
          resume_scope: [nil],
          scope_projection: [nil],
          definition: [nil, "missing"]
        ] do
      assert {:error, :authenticated_scope_context_required} =
               apply(Sequencer, function, [server | args])
    end
  end

  test "read options and malformed definition refs leave the durable head unchanged", %{f: f} do
    context = Fixture.context(f)
    head = Sequencer.head(f.server)
    assert {:ok, projection} = Sequencer.scope_projection(f.server, context)
    assert projection.domain_ref == f.refs.domain
    assert {:ok, time} = Sequencer.trusted_time(f.server)
    assert time == Runtime.now()
    assert {:error, {:invalid_definition_ref, nil}} = Sequencer.definition(f.server, context, nil)
    assert {:error, _} = Sequencer.trusted_time(f.server, unexpected: true)
    assert {:error, _} = Sequencer.trusted_time(f.server, %{})
    assert head == Sequencer.head(f.server)
  end

  test "operational option errors and stale timers cannot mutate a live Domain", c do
    context = Fixture.context(c.f)
    before = Sequencer.projection(c.f.server)

    assert {:error, {:unknown_options, :execution_route, [:unexpected]}} =
             Sequencer.execution_route(c.f.server, c.act, unexpected: true)

    assert {:error, {:unknown_options, :sequencer, [:unexpected]}} =
             Sequencer.submit(c.f.server, context, c.candidate, unexpected: true)

    assert {:error, {:unknown_options, :sequencer, [:unexpected]}} =
             Sequencer.submit_scope_opening(
               c.f.server,
               context,
               context,
               c.candidate,
               unexpected: true
             )

    assert {:error, {:unknown_options, :observation, [:unexpected]}} =
             Sequencer.observe(c.f.server, context, %{}, unexpected: true)

    assert {:error, {:unknown_options, :sequencer, [:unexpected]}} =
             Sequencer.record_executor_evidence(
               c.f.server,
               c.act.ref,
               c.attempt.ref,
               [],
               unexpected: true
             )

    send(c.f.server, {:flush, make_ref()})
    send(c.f.server, {:stop_halted, :stale_failure})
    _barrier = :sys.get_state(c.f.server)
    assert Process.alive?(c.f.server)
    assert Sequencer.projection(c.f.server) === before
  end

  test "a halted process fences operational calls and preserves its first fatal cause", c do
    original = :sys.get_state(c.f.server)
    halted = %{original | halted_reason: :verified_fatal_cause}
    :sys.replace_state(c.f.server, fn _state -> halted end)

    assert {:error, {:sequencer_halted, :verified_fatal_cause}} =
             Sequencer.late_observer(c.f.server)

    assert Control.halt(halted, :later_noise) === halted
    :sys.replace_state(c.f.server, fn state -> %{state | halted_reason: nil} end)
    assert Process.alive?(c.f.server)
  end
end
