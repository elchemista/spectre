defmodule Spectre.Core.IngressIsolationTest.Ingress do
  @behaviour Spectre.Ingress
  @impl true
  defdelegate ref(), to: Spectre.V04Test.Ingress

  @impl true
  def authenticate(domain, scope, input, generation, opts) do
    wait(opts)
    Spectre.V04Test.Ingress.authenticate(domain, scope, input, generation, opts)
  end

  @impl true
  def observe(context, input, time, opts) do
    wait(opts)
    Spectre.V04Test.Ingress.observe(context, input, time, opts)
  end

  defp wait(opts) do
    if opts[:wait] do
      send(opts[:observer], {:ingress_started, self()})

      receive do
        :continue -> :ok
      end
    end
  end
end

defmodule Spectre.Core.IngressIsolationTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  @moduletag capture_log: true

  setup tags do
    Runtime.reset(Fixture.default_now())

    f =
      Fixture.start_domain(
        namespace: "isolated-ingress-#{System.unique_integer([:positive])}",
        ingress: __MODULE__.Ingress,
        ingress_timeout: Map.get(tags, :ingress_timeout, 5_000),
        ingress_max_concurrency: 1,
        max_pending_submissions: 1,
        batch_wait_ms: 60_000
      )

    on_exit(fn -> Fixture.stop_domain(f) end)
    %{f: f, wait_opts: [ingress_opts: [wait: true, observer: self()]]}
  end

  test "a blocked authenticator neither blocks the head nor creates unlimited workers", c do
    request = %{
      principal_ref: c.f.refs.proposer,
      authentication_ref: c.f.refs.authentication,
      session_ref: c.f.refs.session
    }

    task =
      Task.async(fn ->
        Sequencer.authenticate(c.f.server, c.f.refs.scope, request, c.wait_opts)
      end)

    assert_receive {:ingress_started, worker}
    refute worker == c.f.server
    assert {:ok, _} = Sequencer.head(c.f.server)
    assert {:error, :ingress_busy} = Sequencer.authenticate(c.f.server, c.f.refs.scope, request)
    send(worker, :continue)
    assert {:ok, context} = Task.await(task)
    assert {:ok, _} = Sequencer.resume_scope(c.f.server, context)
    assert map_size(:sys.get_state(c.f.server).ingress_jobs) == 0
  end

  test "observation commits at completion while retaining its original observed time", c do
    before = Sequencer.projection(c.f.server)
    task = observation(c)
    assert_receive {:ingress_started, worker}
    assert {:ok, %{revision: revision}} = Sequencer.head(c.f.server)
    assert revision == before.revision
    Runtime.set_time(Runtime.now() + 100)
    send(worker, :continue)
    assert {:ok, [evidence]} = Task.await(task)
    after_input = Sequencer.projection(c.f.server)
    assert evidence.observed_at == before.recorded_at
    assert after_input.event_metadata[evidence.ref].recorded_at == Runtime.now()
    assert after_input.revision == before.revision + 1
  end

  test "completion rechecks the generation instead of trusting the worker's old context", c do
    task = observation(c)
    assert_receive {:ingress_started, worker}
    before = Sequencer.projection(c.f.server)
    :sys.replace_state(c.f.server, fn state -> %{state | generation: state.generation + 1} end)
    send(worker, :continue)
    assert {:error, :submission_context_generation_mismatch} = Task.await(task)
    assert Sequencer.projection(c.f.server) === before
  end

  test "a killed ingress worker returns an error without killing the Domain", c do
    task = observation(c)
    assert_receive {:ingress_started, worker}
    Process.exit(worker, :kill)
    assert {:error, {:ingress_worker_failed, :killed}} = Task.await(task)
    assert {:ok, _} = Sequencer.head(c.f.server)
    assert map_size(:sys.get_state(c.f.server).ingress_jobs) == 0
  end

  @tag ingress_timeout: 50
  test "timed out callbacks release the worker slot and cannot append late", c do
    before = Sequencer.projection(c.f.server)
    task = observation(c)
    assert_receive {:ingress_started, worker}
    monitor = Process.monitor(worker)
    assert {:error, :ingress_timeout} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert Sequencer.projection(c.f.server) === before
    assert map_size(:sys.get_state(c.f.server).ingress_jobs) == 0
    assert {:ok, [_]} = Sequencer.observe(c.f.server, Fixture.context(c.f), input(c.f))
  end

  test "even an untrappable Domain kill terminates its ingress workers", c do
    task =
      Task.async(fn ->
        catch_exit(Sequencer.observe(c.f.server, Fixture.context(c.f), input(c.f), c.wait_opts))
      end)

    assert_receive {:ingress_started, worker}
    monitor = Process.monitor(worker)
    Process.unlink(c.f.server)
    Process.exit(c.f.server, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert Task.await(task)
  end

  test "the accepted submission queue is bounded without persisting refused work", c do
    payment = Fixture.paid_evidence(c.f)
    assert {:ok, ^payment} = Fixture.observe_payment(c.f, payment)
    before = Sequencer.projection(c.f.server)
    candidate = Fixture.refund_candidate(c.f, 100, identity_key: "first")
    request = :gen_server.send_request(c.f.server, {:submit, Fixture.context(c.f), candidate, []})
    other = Fixture.refund_candidate(c.f, 100, identity_key: "overflow")

    assert {:error, :submission_queue_full} =
             Sequencer.submit(c.f.server, Fixture.context(c.f), other)

    state = :sys.get_state(c.f.server)
    assert state.pending_count == 1
    assert state.projection === before
    {token, _timer} = state.flush
    send(c.f.server, {:flush, token})

    assert {:reply, {:ok, %{decision: %{outcome: :admitted}}}} =
             :gen_server.wait_response(request, 1_000)

    assert :not_found =
             Projection.candidate_decision(
               Sequencer.projection(c.f.server),
               "overflow"
             )
  end

  defp observation(c),
    do:
      Task.async(fn ->
        Sequencer.observe(c.f.server, Fixture.context(c.f), input(c.f), c.wait_opts)
      end)

  defp input(f),
    do: %{
      proposition: "isolated:observation",
      issuer_ref: f.refs.proposer,
      provenance: :observed,
      bindings: %{},
      payload: "event"
    }
end
