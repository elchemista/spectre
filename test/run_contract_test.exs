defmodule SpectreRunContractTest.Renderer do
  @moduledoc false

  def render(prompt, input, _ctx), do: "#{prompt}:#{input.text}"
end

defmodule SpectreRunContractTest.EnrichInput do
  @moduledoc false
  @behaviour Spectre.Router.Plug

  alias Spectre.Input
  alias Spectre.Router.Context

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _opts) do
    input = Input.put_meta(context.input, :tenant_id, "tenant-42")
    {:cont, Context.put_input(context, input)}
  end
end

defmodule SpectreRunContractTest.Actions do
  @moduledoc false

  def work(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:run_action, :work, args, Keyword.fetch!(ctx.opts, :idempotency_key)})
    end

    {:ok, "worked"}
  end

  def danger(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:run_action, :danger, args, Keyword.fetch!(ctx.opts, :idempotency_key)})
    end

    {:ok, "approved"}
  end

  def inspect_input(_args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:run_enriched_input, Spectre.Input.fetch_meta(ctx.input, :tenant_id)})
    end

    {:ok, "inspected"}
  end
end

defmodule SpectreRunContractTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:run_journal, record})
    Keyword.get(opts, :reply, :ok)
  end
end

defmodule SpectreRunContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  actions SpectreRunContractTest.Actions do
    protect(:danger, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :contract do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreRunContractTest.Renderer, :render})
    end

    on :WORK, regex: ~r/^work$/i do
      action(:work, args: %{source: :run_contract})
    end

    on :DANGER, regex: ~r/^danger$/i do
      action(:danger,
        args: %{source: :run_contract},
        reply: :approval,
        renderer: {SpectreRunContractTest.Renderer, :render}
      )
    end

    on :ENRICH, regex: ~r/^enrich$/i do
      action(:inspect_input)
    end
  end
end

defmodule SpectreRunContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Invocation
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Runtime
  alias Spectre.State

  @agent SpectreRunContractTest.Agent

  test "start, advance, checkpoint, boundary, and completion form a closed protocol" do
    input = %Spectre.Input{
      text: "hello",
      raw: %{transport: self()},
      meta: %{locale: "it", process: self()}
    }

    assert {:continue, %Run{status: :ready, cursor: :turn, revision: 0} = started} =
             Runtime.start(@agent, input)

    assert {:ok, checkpoint} = Run.checkpoint(started)
    assert {:ok, %Run{} = restored} = Run.restore(checkpoint)
    assert restored.id == started.id
    assert restored.trace_id == started.trace_id
    assert restored.input.raw == nil
    assert restored.input.meta == %{locale: "it"}

    assert {:boundary, %Boundary{kind: :reply, ref: %Ref{} = ref} = boundary,
            %Run{status: :boundary, cursor: :complete, revision: 1} = waiting} =
             Runtime.advance(restored)

    assert boundary.output == "hello:hello"
    assert ref.run_id == waiting.id
    assert ref.revision == waiting.revision
    assert get_in(waiting.result.metadata, [:run, :ref]) == ref

    assert {:ok, boundary_checkpoint} = Run.checkpoint(waiting)

    assert {:ok, %Run{waiting: %Boundary{ref: ^ref}} = recovered} =
             Run.restore(boundary_checkpoint)

    assert %Spectre.Route{} = recovered.result.route

    assert {:complete, result, %Run{status: :complete, revision: 2} = completed} =
             Runtime.advance(recovered)

    assert result.reply_text == "hello:hello"
    assert completed.id == started.id
    assert {:complete, ^result, ^completed} = Runtime.advance(completed)
  end

  test "effect invocations are explicit, fenced, and resumable" do
    assert {:continue, started} = Runtime.start(@agent, "work")

    assert {:await, %Invocation{} = invocation,
            %Run{status: :awaiting, cursor: :effect} = awaiting} =
             Runtime.advance(started)

    refute_received {:run_action, :work, _args, _key}
    assert invocation.run_id == awaiting.id
    assert invocation.run_revision == awaiting.revision
    assert invocation.operation == {:action, :work}
    invocation_id = invocation.id

    assert {:error, {:invalid_invocation_reference, "wrong", ^invocation_id}, ^awaiting} =
             Runtime.resume(awaiting, {:execute, "wrong"}, test_pid: self())

    assert {:ok, checkpoint} = Run.checkpoint(awaiting)

    assert {:ok, %Run{waiting: %Invocation{id: ^invocation_id}} = recovered} =
             Run.restore(checkpoint)

    assert {:boundary, %Boundary{kind: :reply, output: "worked"},
            %Run{status: :boundary} = replied} =
             Runtime.resume(recovered, {:execute, invocation_id}, test_pid: self())

    assert_receive {:run_action, :work, %{source: :run_contract}, key}
    assert key == invocation.idempotency_key
    refute_received {:run_action, :work, _args, _key}

    assert {:complete, _result, completed} = Runtime.advance(replied)

    assert {:error, {:run_already_complete, completed_id, completed_revision}, ^completed} =
             Runtime.resume(completed, {:execute, invocation_id}, test_pid: self())

    assert completed_id == completed.id
    assert completed_revision == completed.revision
    refute_received {:run_action, :work, _args, _key}
  end

  test "replaying one awaiting checkpoint retries with the same provider idempotency key" do
    assert {:continue, started} = Runtime.start(@agent, "work")
    assert {:await, %Invocation{} = invocation, awaiting} = Runtime.advance(started)
    assert {:ok, checkpoint} = Run.checkpoint(awaiting)

    assert {:ok, first_copy} = Run.restore(checkpoint)
    assert {:ok, second_copy} = Run.restore(checkpoint)

    assert {:boundary, %Boundary{kind: :reply}, _run} =
             Runtime.resume(first_copy, {:execute, invocation.ref}, test_pid: self())

    assert {:boundary, %Boundary{kind: :reply}, _run} =
             Runtime.resume(second_copy, {:execute, invocation.ref}, test_pid: self())

    assert_receive {:run_action, :work, %{source: :run_contract}, first_key}
    assert_receive {:run_action, :work, %{source: :run_contract}, second_key}
    assert first_key == invocation.idempotency_key
    assert second_key == first_key
  end

  test "router-enriched logical input survives an awaiting checkpoint" do
    pipeline = [
      SpectreRunContractTest.EnrichInput,
      Spectre.Router.Plugs.Regex,
      Spectre.Router.Plugs.Arbitrate,
      Spectre.Router.Plugs.Terminalize
    ]

    assert {:continue, started} = Runtime.start(@agent, "enrich")

    assert {:await, %Invocation{} = invocation, awaiting} =
             Runtime.advance(started, pipeline: pipeline)

    assert Spectre.Input.fetch_meta(awaiting.input, :tenant_id) == {:ok, "tenant-42"}
    assert awaiting.result.input == awaiting.input
    assert {:ok, checkpoint} = Run.checkpoint(awaiting)
    assert {:ok, recovered} = Run.restore(checkpoint)

    assert {:boundary, %Boundary{kind: :reply}, _run} =
             Runtime.resume(recovered, {:execute, invocation.ref}, test_pid: self())

    assert_receive {:run_enriched_input, {:ok, "tenant-42"}}
  end

  test "policy and effect resume use distinct revision-fenced boundaries" do
    assert {:continue, started} = Runtime.start(@agent, "danger")

    assert {:boundary,
            %Boundary{
              kind: :needs,
              ref: %Ref{kind: :policy} = policy_ref,
              request: %Request{name: :confirmation}
            }, policy_run} = Runtime.advance(started)

    stale_ref = %{policy_ref | revision: policy_ref.revision + 1}

    assert {:error, {:stale_run_reference, _, _, _, _}, ^policy_run} =
             Runtime.resume(policy_run, {:policy, stale_ref, {:accept, :approved}})

    assert {:ok, checkpoint} = Run.checkpoint(policy_run)
    assert {:ok, recovered} = Run.restore(checkpoint)

    assert {:await, %Invocation{ref: %Ref{kind: :invocation}} = invocation,
            %Run{revision: approved_revision} = approved} =
             Runtime.resume(recovered, {:policy, policy_ref, {:accept, :approved}})

    assert approved_revision == policy_run.revision + 1

    assert {:boundary, %Boundary{kind: :reply, output: "approved"}, executed} =
             Runtime.resume(approved, {:execute, invocation}, test_pid: self())

    assert_receive {:run_action, :danger, %{source: :run_contract}, _key}
    assert executed.state.pending_effects == []
  end

  test "Turn is the public projection and exposes only the boundary reference" do
    assert {:ok, turn} = Spectre.turn(@agent, "hello")
    assert {:reply, "hello:hello", %Ref{} = ref} = turn.observable
    assert turn.ref == ref
    assert %Boundary{ref: ^ref} = turn.boundary
    refute Map.has_key?(Map.from_struct(turn), :run)

    assert {:ok, effect_turn} = Spectre.turn(@agent, "work")
    assert {:awaiting, %Ref{} = invocation_ref} = effect_turn.observable
    assert effect_turn.ref == invocation_ref
    assert %Invocation{ref: ^invocation_ref} = effect_turn.boundary

    assert {:ok, policy_turn} = Spectre.turn(@agent, "danger")
    assert {:needs, %Boundary{ref: %Ref{} = policy_ref}} = policy_turn.observable
    assert policy_turn.ref == policy_ref
    assert %Request{name: :confirmation} = policy_turn.boundary.request

    assert {:ok, approved_turn} =
             Spectre.Turn.resolve_policy(policy_turn, {:accept, :approved})

    assert approved_turn.ref.run_id == policy_ref.run_id
    assert approved_turn.ref.revision == policy_ref.revision + 1
    assert approved_turn.ref.kind == :invocation
    approved_ref = approved_turn.ref
    assert {:awaiting, ^approved_ref} = approved_turn.observable
  end

  test "checkpoint fails closed when authoritative state contains a process handle" do
    state = %State{data: %{runtime_client: self()}}

    assert {:continue, run} = Runtime.start(@agent, "hello", state: state)

    assert {:error, {:nonportable_run_value, path, :pid}} = Run.checkpoint(run)
    assert :state in path
    assert :runtime_client in path

    keyed = %State{data: %{self() => :runtime_client}}
    assert {:continue, keyed_run} = Runtime.start(@agent, "hello", state: keyed)
    assert {:error, {:nonportable_run_value, _path, :pid}} = Run.checkpoint(keyed_run)
  end

  test "restore rejects compressed external terms before decoding them" do
    compressed =
      :erlang.term_to_binary(
        %{format: "spectre/run", payload: String.duplicate("continuation", 10_000)},
        compressed: 9
      )

    assert <<131, 80, _rest::binary>> = compressed
    assert {:error, :compressed_run_checkpoint_not_supported} = Run.restore(compressed)
  end

  test "the checkpoint envelope is atom-free before typed decoding" do
    assert {:continue, run} = Runtime.start(@agent, "hello")
    assert {:ok, checkpoint} = Run.checkpoint(run)

    assert %{"format" => "spectre/run", "version" => 1, "run" => encoded_run} =
             :erlang.binary_to_term(checkpoint, [:safe])

    refute contains_unsafe_atom?(encoded_run)
  end

  test "checkpoint validation rejects inconsistent lifecycle combinations" do
    assert {:continue, started} = Runtime.start(@agent, "work")
    assert {:await, _invocation, awaiting} = Runtime.advance(started)

    invalid = %{awaiting | waiting: nil}
    assert {:error, :invalid_run_lifecycle} = Run.checkpoint(invalid)

    complete_ref = complete_ref(awaiting)

    identity =
      awaiting.result.metadata
      |> Map.fetch!(:run)
      |> Map.merge(%{status: :complete, cursor: :complete, ref: complete_ref})

    terminal_result = %{
      awaiting.result
      | metadata: Map.put(awaiting.result.metadata, :run, identity)
    }

    forged_complete = %{
      awaiting
      | status: :complete,
        cursor: :complete,
        waiting: nil,
        result: terminal_result
    }

    assert {:error, :invalid_run_terminal_work} = Run.checkpoint(forged_complete)

    tampered_invocation = %{awaiting.waiting | idempotency_key: "tampered"}

    assert {:error, :invalid_run_effect_boundary} =
             Run.checkpoint(%{awaiting | waiting: tampered_invocation})

    assert {:error, :invalid_run_lifecycle} =
             Run.checkpoint(%{awaiting | last_error: :stale_error})

    assert {:error, _reason, %Run{} = failed} =
             Runtime.start(@agent, "work", run_id: self())

    assert {:error, :invalid_run_lifecycle} =
             Run.checkpoint(%{failed | status: :ready, cursor: :turn})

    assert {:error, :invalid_run_lifecycle} =
             Run.checkpoint(%{started | status: :failed, cursor: :complete, last_error: :forged})
  end

  test "Run identities reject handles and normalize portable logical identifiers" do
    assert {:error, {:invalid_run_option, :run_id, {:nonportable_run_value, _, :pid}},
            %Run{status: :failed}} = Runtime.start(@agent, "hello", run_id: self())

    assert {:continue, run} =
             Runtime.start(@agent, "hello",
               run_id: {:tenant, 42},
               correlation_id: {:message, 7}
             )

    assert "run:" <> _digest = run.id
    assert "correlation:" <> _digest = run.correlation_id

    invalid_agent = %Run{
      id: "invalid-agent",
      agent: nil,
      input: %Spectre.Input{},
      state: %State{},
      trace_id: "invalid-agent"
    }

    assert {:error, :invalid_run_identity} = Run.checkpoint(invalid_agent)
  end

  test "Turn ignores a forged non-portable Run reference" do
    unsafe_ref = %Ref{
      run_id: "forged-run",
      revision: 1,
      kind: :reply,
      boundary_id: "forged-boundary",
      subject_id: self()
    }

    result = %Spectre.Result{
      input: Spectre.Input.new("hello"),
      state: %State{},
      reply_text: "hello",
      metadata: %{run: %{id: "forged-run", revision: 1, ref: unsafe_ref}}
    }

    turn = Spectre.Turn.from_result(@agent, result.input, [], result)
    refute turn.ref == unsafe_ref
    assert is_nil(turn.ref.subject_id) or is_binary(turn.ref.subject_id)
    assert {:reply, "hello", %Ref{} = ref} = turn.observable
    assert ref == turn.ref
  end

  test "source identity fields are preserved whole or removed whole" do
    source = %Spectre.Input.Source{
      kind: :test,
      reply_to: %{chat: "c-1", session: self()},
      metadata: %{locale: "it", client: self()}
    }

    assert {:continue, run} =
             Runtime.start(@agent, %Spectre.Input{text: "hello", source: source})

    assert {:ok, checkpoint} = Run.checkpoint(run)
    assert {:ok, restored} = Run.restore(checkpoint)
    assert restored.input.source.reply_to == nil
    assert restored.input.source.metadata == %{locale: "it"}
  end

  test "run journal events are selectable as one privacy-safe phase group" do
    journal = {
      SpectreRunContractTest.JournalStore,
      events: [:run], mode: :sync, store_opts: [pid: self()]
    }

    assert {:continue, started} = Runtime.start(@agent, "hello", journal: journal)
    assert_receive {:run_journal, %{phase: :run_started, metadata: started_meta}}
    assert started_meta.run_id == started.id
    refute Map.has_key?(started_meta, :input)

    assert {:boundary, _boundary, _run} = Runtime.advance(started, journal: journal)
    assert_receive {:run_journal, %{phase: :run_boundary, metadata: boundary_meta}}
    assert boundary_meta.run_id == started.id
    refute Map.has_key?(boundary_meta, :result)
  end

  test "a resumed Run records both the resume and its terminal outcome" do
    journal = {
      SpectreRunContractTest.JournalStore,
      events: [:run], mode: :sync, store_opts: [pid: self()]
    }

    assert {:continue, started} = Runtime.start(@agent, "danger", journal: journal)
    assert_receive {:run_journal, %{phase: :run_started}}

    assert {:boundary, %Boundary{ref: policy_ref}, policy_run} =
             Runtime.advance(started, journal: journal)

    assert_receive {:run_journal, %{phase: :run_boundary}}

    assert {:complete, _result, _completed} =
             Runtime.resume(
               policy_run,
               {:policy, policy_ref, {:reject, :rejected}},
               journal: journal
             )

    assert_receive {:run_journal, %{phase: :run_resumed}}
    assert_receive {:run_journal, %{phase: :run_completed}}
  end

  test "a strict post-commit Run journal failure carries and retains the committed result" do
    {:ok, session} = start_supervised({Spectre.Session, agent: @agent})

    journal = {
      SpectreRunContractTest.JournalStore,
      events: [:run_boundary],
      mode: :sync,
      on_error: :error,
      store_opts: [reply: {:error, :journal_down}]
    }

    assert {:error,
            {:run_journal_failed, :run_boundary, _journal_failure, %Spectre.Result{} = committed}} =
             Spectre.turn(session, "hello", journal: journal)

    assert committed.state.revision == 1
    assert Spectre.state(session) == committed.state
  end

  defp contains_unsafe_atom?(value) when value in [nil, true, false], do: false
  defp contains_unsafe_atom?(value) when is_atom(value), do: true

  defp contains_unsafe_atom?(value) when is_list(value),
    do: Enum.any?(value, &contains_unsafe_atom?/1)

  defp contains_unsafe_atom?(value) when is_map(value) do
    Enum.any?(value, fn {key, entry} ->
      contains_unsafe_atom?(key) or contains_unsafe_atom?(entry)
    end)
  end

  defp contains_unsafe_atom?(_value), do: false

  defp complete_ref(%Run{} = run) do
    digest =
      {run.id, run.revision, :complete, nil}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    boundary_id = "complete:" <> binary_part(digest, 0, 32)
    Ref.new(run.id, run.revision, :complete, boundary_id)
  end
end
