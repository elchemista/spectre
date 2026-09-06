defmodule Spectre.Bench.Payloads do
  @moduledoc false
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

defmodule Spectre.Bench.Workload do
  @moduledoc false
  alias Spectre.Bench.P1.{Executor, Fixture}
  alias Spectre.Bench.Payloads
  alias Spectre.Domain.Sequencer
  alias Spectre.{Domain, Evidence, Governance, Scope}

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
        erasure_target: target
      )

    f =
      Map.merge(f, %{
        payload_root: root,
        payload_counter: counter,
        erasure_target: target,
        payload_bytes: input.payload_bytes,
        input: input,
        mode: mode
      })

    if mode in [:erasure, :after_erasure] do
      {:ok, _evidence} =
        Sequencer.observe(f.server, f.context, %{
          proposition: "spectre:bench:erasable",
          payload_ref: target
        })
    end

    each(input.history, fn n ->
      cycle(f, n, if(mode == :external, do: :external, else: :inline))
    end)

    if mode == :after_erasure, do: erase(f)
    f
  end

  def stop(f) do
    Fixture.stop(f)
    # This directory is freshly created by start/2, never a host store path.
    File.rm_rf!(f.payload_root)
  end

  def run(f, :individual) do
    each(f.input.operations, &cycle(f, f.input.history + &1, :inline))
    f
  end

  def run(f, :group) do
    1..f.input.operations
    |> Task.async_stream(fn n -> cycle(f, f.input.history + n, :inline) end,
      max_concurrency: f.input.operations,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)

    f
  end

  def run(f, :external) do
    each(f.input.operations, &cycle(f, f.input.history + &1, :external))
    f
  end

  def run(f, :erasure) do
    erase(f)
    f
  end

  def run(f, :recovery), do: %{f | server: Fixture.restart(f)}

  def cycle(f, sequence, mode) do
    candidate = Fixture.candidate(f, sequence)

    {:ok, %{decision: %{outcome: :admitted}, act: act, grant: grant}} =
      Sequencer.submit(f.server, f.context, candidate)

    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)
    complete(f, act, attempt, mode, sequence)
  end

  def erase(f) do
    {:ok, scope} = Scope.new(Domain.handle(f.server, f.refs.domain), f.context)
    projection = Sequencer.projection(f.server)
    now = System.system_time(:millisecond)

    {:ok, candidate} =
      Governance.request_erasure(
        scope,
        projection,
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

    {:ok, %{decision: %{outcome: :admitted}, act: act, grant: grant}} =
      Sequencer.submit(f.server, f.context, candidate)

    {:ok, ^act, attempt, _receipt} = Sequencer.consume_grant(f.server, grant)
    Payloads.delete(f.payload_root, f.erasure_target)
    complete(f, act, attempt, :inline, 0)
  end

  defp complete(f, act, attempt, mode, sequence) do
    evidence = Fixture.outcome_evidence(f, act, attempt)
    evidence = if mode == :external, do: external(f, evidence, sequence), else: evidence

    {:ok, [^evidence]} =
      Sequencer.record_executor_evidence(f.server, act.ref, attempt.ref, evidence)

    outcome = Fixture.outcome(act, attempt, evidence)
    {:ok, ^outcome} = Sequencer.record_outcome(f.server, outcome)
    :ok
  end

  defp external(f, evidence, sequence) do
    body = Integer.to_string(sequence) <> ":" <> String.duplicate("p", f.payload_bytes)
    ref = Payloads.put(f.payload_root, body)

    {:ok, evidence} =
      evidence
      |> Map.from_struct()
      |> Map.delete(:ref)
      |> Map.merge(%{payload: nil, payload_ref: ref})
      |> Evidence.new()

    evidence
  end

  defp each(0, _fun), do: :ok
  defp each(n, fun), do: Enum.each(1..n, fun)
end
