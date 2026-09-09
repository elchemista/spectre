defmodule Spectre.Bench.Payloads do
  @moduledoc """
  Benchmark-only content-addressed files and a verification I/O counter.

  Payload bodies live outside the append-only ledger. The counter records real
  verification calls, so old payloads being reread on every append is visible.
  This is a local fixture, not an application storage or privacy policy.
  """
  @behaviour Spectre.Payload.Store
  alias Spectre.Portable

  def put(root, body) do
    ref = Portable.content_ref!(:payload, body)
    File.write!(path(root, ref), body)
    ref
  end

  def delete(root, ref), do: File.rm!(path(root, ref))

  @impl true
  def verify(ref, opts) do
    :counters.add(Keyword.fetch!(opts, :counter), 1, 1)
    root = Keyword.fetch!(opts, :root)

    case File.read(path(root, ref)) do
      {:ok, body} ->
        if Portable.content_ref!(:payload, body) === ref,
          do: :ok,
          else: {:error, :digest_mismatch}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp path(root, "payload:" <> digest), do: Path.join(root, digest)
end

defmodule Spectre.Bench.Executor do
  @moduledoc """
  Small local executor for the public 0.4 proposal benchmark.

  The Runner invokes this only after durable admission and capability checkout.
  Inline work returns a receipt; external work writes that receipt to a file;
  `data.erase` deletes the exact target of the admitted erasure request.
  No provider/network latency is simulated and no effect is retried.
  """
  @behaviour Spectre.Attempt.Executor

  alias Spectre.Attempt.Executor
  alias Spectre.Bench.Payloads

  @impl true
  defdelegate executor_ref(), to: Spectre.Bench.P1.Executor

  @impl true
  defdelegate contract_ref(), to: Spectre.Bench.P1.Executor

  @impl true
  def execute(act, attempt, :benchmark_only, opts) do
    payload = perform(act, opts)

    {:ok, evidence} =
      Executor.outcome_evidence(
        act,
        attempt,
        :succeeded,
        System.system_time(:millisecond),
        payload
      )

    {:ok, %{evidence: [evidence], details_ref: "spectre:bench:receipt:succeeded"}}
  end

  defp perform(%{class: "data.erase", consequence: consequence}, opts) do
    Payloads.delete(Keyword.fetch!(opts, :root), consequence["erasure_request"]["target_ref"])
    %{payload: %{"benchmark" => "erased"}}
  end

  defp perform(%{class: "bench.effect", consequence: consequence}, opts) do
    if Keyword.fetch!(opts, :mode) == :external do
      body =
        Integer.to_string(consequence["sequence"]) <>
          ":" <> String.duplicate("p", Keyword.fetch!(opts, :payload_bytes))

      %{payload_ref: Payloads.put(Keyword.fetch!(opts, :root), body)}
    else
      %{payload: %{"benchmark" => "succeeded"}}
    end
  end
end

defmodule Spectre.Bench.Workload do
  @moduledoc """
  One real governed lifecycle per cycle through `Spectre.propose/3`.

  Foundation, authentication and history seeding are setup, outside the timer.
  Every measured cycle must reach an admitted Act and a successful Outcome;
  rejection, a pending dispatch or ambiguity fails the benchmark, not its speed.
  The isolated manual-stage comparison remains in `bench/p1.exs`.
  """
  alias Spectre.Bench.P1.Fixture
  alias Spectre.Bench.{Executor, Payloads}
  alias Spectre.Domain.Sequencer
  alias Spectre.{Domain, Scope}

  def start(input, mode) do
    namespace = "suite-#{System.unique_integer([:positive])}"

    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-#{namespace}-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}"
      )

    File.mkdir!(root)
    counter = :counters.new(1, [:atomics])
    target = Payloads.put(root, "erasure target")

    f =
      Fixture.start(
        input.store,
        namespace,
        input.history + input.operations + 1,
        input.batch_size,
        input.batch_wait_ms,
        payload_store: {Payloads, root: root, counter: counter},
        executors: [{Executor, root: root, mode: mode, payload_bytes: input.payload_bytes}],
        erasure_target: target
      )

    {:ok, scope} = Scope.new(Domain.handle(f.server, f.refs.domain), f.context)

    f =
      Map.merge(f, %{
        payload_root: root,
        payload_counter: counter,
        erasure_target: target,
        input: input,
        scope: scope
      })

    if mode in [:erasure, :after_erasure] do
      {:ok, _evidence} =
        Sequencer.observe(f.server, f.context, %{
          proposition: "spectre:bench:erasable",
          payload_ref: target
        })
    end

    each(input.history, &cycle(f, &1))

    if mode == :after_erasure, do: erase(f)
    f
  end

  def stop(f) do
    Fixture.stop(f)
    # This directory is freshly created by start/2, never a host store path.
    File.rm_rf!(f.payload_root)
  end

  def run(f, :individual) do
    each(f.input.operations, &cycle(f, f.input.history + &1))
    f
  end

  def run(f, :group) do
    1..f.input.operations
    |> Task.async_stream(fn n -> cycle(f, f.input.history + n) end,
      max_concurrency: f.input.operations,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    f
  end

  def run(f, :external) do
    each(f.input.operations, &cycle(f, f.input.history + &1))
    f
  end

  def run(f, :erasure) do
    erase(f)
    f
  end

  def run(f, :recovery), do: %{f | server: Fixture.restart(f)}

  def cycle(f, sequence) do
    candidate = Fixture.candidate(f, sequence)
    completed!(Spectre.propose(f.scope, candidate))
  end

  def erase(f) do
    now = System.system_time(:millisecond)

    result =
      Spectre.request_erasure(
        f.scope,
        %{target_ref: f.erasure_target, requested_at: now, reason: "benchmark governed erasure"},
        identity_key: "benchmark:erase",
        requested_mandate_ref: f.mandate.ref,
        accountable_ref: f.mandate.accountable_ref,
        purpose_ref: f.refs.purpose,
        purpose_params: %{},
        executor_ref: Executor.executor_ref(),
        executor_contract_ref: Executor.contract_ref(),
        evidence_refs: [f.evidence.ref],
        observation_window_ms: 600_000
      )

    completed!(result)
  end

  defp completed!(result) do
    {:ok, %{primary: %{decision: %{outcome: :admitted}, outcome: %{status: :succeeded}}}} = result
    :ok
  end

  defp each(0, _fun), do: :ok
  defp each(n, fun), do: Enum.each(1..n, fun)
end
