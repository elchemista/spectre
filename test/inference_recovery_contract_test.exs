defmodule SpectreInferenceRecoveryContractTest.BlockingModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:recovery_model, :started, self()})

    receive do
      :release_recovery_model -> {:ok, "unexpected late response"}
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.StreamModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:error, :stream_must_not_use_one_shot_completion}
end

defmodule SpectreInferenceRecoveryContractTest.FastModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:recovery_fast_model, :completed, self()})
    end

    {:ok,
     %Spectre.Inference.Response{
       text: "durable provider response",
       usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5}
     }}
  end
end

defmodule SpectreInferenceRecoveryContractTest.PrimaryFailModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:recovery_fallback, :primary_failed})
    {:error, :temporary_provider_failure}
  end
end

defmodule SpectreInferenceRecoveryContractTest.SecondaryModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:recovery_fallback, :secondary_completed})
    {:ok, "fallback response"}
  end
end

defmodule SpectreInferenceRecoveryContractTest.BlockingPlanner do
  @moduledoc false

  @behaviour Spectre.Action.Planner

  @impl Spectre.Action.Planner
  def plan_response(text, _context, opts) do
    blocked? = Keyword.get(opts, :block_recovery_planner?, false)
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:recovery_planner, :called, blocked?, self()})

    if blocked? do
      receive do
        :release_recovery_planner -> :ok
      end
    end

    {:ok, %{reply_text: text, actions: []}}
  end

  @impl Spectre.Action.Planner
  def clean_reply(text, _context, _opts), do: text
end

defmodule SpectreInferenceRecoveryContractTest.PlannerAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  action_planner(SpectreInferenceRecoveryContractTest.BlockingPlanner)
  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :planner_recovery do
    on :ASK, regex: ~r/ask/i do
      ask(:base)
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.QueueAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :queue_recovery do
    on :BLOCK, regex: ~r/^block$/i do
      run(:maybe_block)
    end

    on :PING, regex: ~r/^ping$/i do
      run(:pong)
    end
  end

  def maybe_block(_input, ctx) do
    test_pid = Keyword.fetch!(ctx.opts, :test_pid)
    blocked? = Keyword.get(ctx.opts, :block_recovery_handler?, false)
    send(test_pid, {:recovery_handler, :called, blocked?, self()})

    if blocked? do
      receive do
        :release_recovery_handler -> :ok
      end
    end

    "handler recovered"
  end

  def pong(_input, _ctx), do: "pong"
end

defmodule SpectreInferenceRecoveryContractTest.EffectActions do
  @moduledoc false

  def external(_args, ctx) do
    test_pid = Keyword.fetch!(ctx.opts, :test_pid)
    send(test_pid, {:recovery_effect, :started, self()})

    receive do
      :release_recovery_effect -> {:ok, "late effect response"}
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.EffectAgent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreInferenceRecoveryContractTest.EffectActions)
  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :effect_recovery do
    on :EFFECT, regex: ~r/^effect$/i do
      action(:external)
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.PolicyActions do
  @moduledoc false

  def protected(_args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:recovery_policy, :executed})
    {:ok, "approved"}
  end
end

defmodule SpectreInferenceRecoveryContractTest.PolicyRenderer do
  @moduledoc false

  def render(_prompt, _input, _context), do: "approved"
end

defmodule SpectreInferenceRecoveryContractTest.PolicyAgent do
  @moduledoc false

  use Spectre.Agent

  actions SpectreInferenceRecoveryContractTest.PolicyActions do
    protect(:protected, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :policy_recovery do
    on :PROTECTED, regex: ~r/^protected$/i do
      action(:protected,
        reply: :approval,
        renderer: {SpectreInferenceRecoveryContractTest.PolicyRenderer, :render}
      )
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.ReconcileAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  alias Spectre.Inference.ProviderEvent
  alias Spectre.Inference.Response

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts),
    do: MapSet.new([:stream, :pull_transport, :reconcile, :incremental_usage])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    ref = make_ref()
    send(test_pid, {:recovery_adapter, :opened, self()})
    {:ok, %{ref: ref, requested?: false, test_pid: test_pid}, %{transport: :fixture}}
  end

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{requested?: false} = state) do
    events = [
      ProviderEvent.new(:started,
        provider_sequence: 0,
        provider_request_id: "recovery-provider-request"
      ),
      ProviderEvent.delta("provisional",
        provider_sequence: 1,
        usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3},
        usage_quality: :provider
      )
    ]

    # Delay the transport item long enough for the opening heartbeat and the
    # provider progress heartbeat to be observably distinct canonical commits.
    Process.send_after(self(), {:recovery_transport, state.ref, events}, 10)
    {:ok, %{state | requested?: true}}
  end

  def request_transport_item(%{requested?: true} = state) do
    send(state.test_pid, {:recovery_adapter, :stalled, self()})
    {:ok, state}
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport({:recovery_transport, ref, events}, %{ref: ref} = state),
    do: {:ok, events, state}

  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(state, reason) do
    send(state.test_pid, {:recovery_adapter, :cancelled, reason})
    :ok
  end

  @impl Spectre.Inference.StreamAdapter
  def reconcile(_descriptor, provider_request_id, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:recovery_adapter, :reconciled, provider_request_id})

    case Keyword.get(opts, :reconcile_reply, :success) do
      :success ->
        {:ok,
         %Response{
           text: "reconciled terminal response",
           usage: %{input_tokens: 2, output_tokens: 3, total_tokens: 5},
           metadata: %{provider: :recovery_fixture}
         }}

      reply ->
        reply
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest.ResumeAdapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  alias Spectre.Inference.ProviderEvent

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts),
    do: MapSet.new([:stream, :pull_transport, :resume, :incremental_usage])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, opts), do: opened_state(:initial, opts)

  @impl Spectre.Inference.StreamAdapter
  def resume(_descriptor, cursor, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    send(test_pid, {:resume_adapter, :resumed, cursor})
    opened_state(:resumed, opts)
  end

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(%{requested?: false, mode: :initial} = state) do
    events = [
      ProviderEvent.new(:started,
        provider_sequence: 0,
        provider_request_id: "resumable-provider-request",
        cursor: %{offset: 1}
      ),
      ProviderEvent.delta("before ",
        provider_sequence: 1,
        cursor: %{offset: 2},
        usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3},
        usage_quality: :provider
      )
    ]

    Process.send_after(self(), {:resume_transport, state.ref, events}, 10)
    {:ok, %{state | requested?: true}}
  end

  def request_transport_item(%{requested?: false, mode: :resumed} = state) do
    events = [
      ProviderEvent.delta("restart",
        provider_sequence: 2,
        cursor: %{offset: 3},
        usage: %{input_tokens: 2, output_tokens: 2, total_tokens: 4},
        usage_quality: :provider
      ),
      ProviderEvent.completed("before restart",
        provider_sequence: 3,
        cursor: %{offset: 4},
        usage: %{input_tokens: 2, output_tokens: 2, total_tokens: 4},
        usage_quality: :provider
      )
    ]

    send(self(), {:resume_transport, state.ref, events})
    {:ok, %{state | requested?: true}}
  end

  def request_transport_item(%{requested?: true} = state) do
    send(state.test_pid, {:resume_adapter, :stalled, self()})
    {:ok, state}
  end

  @impl Spectre.Inference.StreamAdapter
  def handle_transport({:resume_transport, ref, events}, %{ref: ref} = state),
    do: {:ok, events, state}

  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(state, reason) do
    send(state.test_pid, {:resume_adapter, :cancelled, reason})
    :ok
  end

  defp opened_state(mode, opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    ref = make_ref()
    send(test_pid, {:resume_adapter, :opened, mode, self()})
    {:ok, %{mode: mode, ref: ref, requested?: false, test_pid: test_pid}, %{}}
  end
end

defmodule SpectreInferenceRecoveryContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :streaming do
    on :STREAM, regex: ~r/stream/i do
      ask(:base)
    end
  end
end

defmodule SpectreInferenceRecoveryContractTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request
  alias Spectre.Inference.Stream, as: InferenceStream
  alias Spectre.Inference.Usage
  alias Spectre.Input
  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Operation.Control.Command
  alias Spectre.Prompt.Plan
  alias Spectre.Run
  alias Spectre.Runtime
  alias Spectre.Subject

  @agent SpectreInferenceRecoveryContractTest.Agent
  @blocking_model SpectreInferenceRecoveryContractTest.BlockingModel
  @stream_model SpectreInferenceRecoveryContractTest.StreamModel
  @fast_model SpectreInferenceRecoveryContractTest.FastModel
  @primary_fail_model SpectreInferenceRecoveryContractTest.PrimaryFailModel
  @secondary_model SpectreInferenceRecoveryContractTest.SecondaryModel
  @adapter SpectreInferenceRecoveryContractTest.ReconcileAdapter
  @resume_adapter SpectreInferenceRecoveryContractTest.ResumeAdapter
  @queue_mailbox SpectreInferenceRecoveryContractTest.QueueMailbox

  test "restart terminalizes an uncertain one-shot invocation instead of redispatching it" do
    subject = unique_subject("one-shot")
    instance = start_instance(subject)
    request = cognitive_request()
    parent = self()

    {_caller, caller_monitor} =
      spawn_monitor(fn ->
        result =
          Instance.infer(instance, request,
            run_id: "uncertain-one-shot-run",
            test_pid: parent
          )

        send(parent, {:uncertain_one_shot_result, result})
      end)

    assert_receive {:recovery_model, :started, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, _caller, _reason}, 1_000

    restored = start_instance(subject, canonical_checkpoint: checkpoint)

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(restored, "uncertain-one-shot-run"))
    end)

    assert {:inference_attempt_failed, 1, {:inference_recovery_ambiguous, :dispatching}} =
             :sys.get_state(restored).runs["uncertain-one-shot-run"].last_error

    # The old provider outcome is unknowable. Recovery records ambiguity and
    # does not execute the nondeterministic boundary for a second time.
    refute_receive {:recovery_model, :started, _replacement_worker}
  end

  test "restart reconciles an interrupted stream from its committed provider identity" do
    subject = unique_subject("stream-reconcile")

    instance =
      start_instance(subject,
        opts: recovery_runtime_opts(),
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1
      )

    assert {:ok, stream} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               inference_heartbeat_interval: 1,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    consumer = Task.async(fn -> Enum.to_list(stream) end)
    assert_receive {:recovery_adapter, :opened, _session}, 1_000
    assert_receive {:recovery_adapter, :stalled, _session}, 1_000

    assert_eventually(fn ->
      case :sys.get_state(instance).runs[stream.run_id] do
        %{inference_continuation: continuation} ->
          continuation.provider_status == :streaming and
            continuation.provider_request_id == "recovery-provider-request"

        _missing ->
          false
      end
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    interrupted_events = Task.await(consumer, 1_000)
    assert List.last(interrupted_events).kind == :interrupted

    restored =
      start_instance(subject,
        canonical_checkpoint: checkpoint,
        opts: recovery_runtime_opts()
      )

    assert_receive {:recovery_adapter, :reconciled, "recovery-provider-request"}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(restored, stream.run_id))
    end)

    refute_receive {:recovery_adapter, :opened, _redispatched_session}
  end

  test "restart exposes a new Enumerable and resumes only from a durable cursor" do
    subject = unique_subject("stream-resume")
    runtime_opts = resume_runtime_opts()

    instance =
      start_instance(subject,
        opts: runtime_opts,
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1
      )

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @resume_adapter,
               stream_adapter_opts: [test_pid: self()],
               inference_heartbeat_interval: 1,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    consumer = Task.async(fn -> Enum.to_list(original) end)
    assert_receive {:resume_adapter, :opened, :initial, _session}, 1_000
    assert_receive {:resume_adapter, :stalled, _session}, 1_000

    assert_eventually(fn ->
      case :sys.get_state(instance).runs[original.run_id] do
        %{inference_continuation: continuation} ->
          continuation.provider_status == :streaming and
            continuation.resume_cursor == %{offset: 2}

        _missing ->
          false
      end
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert List.last(Task.await(consumer, 1_000)).kind == :interrupted

    restored =
      start_instance(subject,
        canonical_checkpoint: checkpoint,
        opts: runtime_opts
      )

    assert {:ok, replacement} = Spectre.resume_stream(restored, original)
    assert replacement.stream_epoch != original.stream_epoch
    assert replacement.invocation_id != original.invocation_id

    events = Enum.to_list(replacement)
    assert_receive {:resume_adapter, :resumed, %{offset: 2}}, 1_000
    assert %{kind: :result, payload: result} = List.last(events)
    assert result.reply_text == "before restart"

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(restored, original.run_id))
    end)
  end

  test "a second restart resumes an already receipted stream restart without replaying selection" do
    subject = unique_subject("stream-resume-receipted")
    runtime_opts = resume_runtime_opts()

    instance =
      start_instance(subject,
        opts: runtime_opts,
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1
      )

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @resume_adapter,
               stream_adapter_opts: [test_pid: self()],
               inference_heartbeat_interval: 1,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    consumer = Task.async(fn -> Enum.to_list(original) end)
    assert_receive {:resume_adapter, :opened, :initial, _session}, 1_000
    assert_receive {:resume_adapter, :stalled, _session}, 1_000

    assert_eventually(fn ->
      continuation = :sys.get_state(instance).runs[original.run_id].inference_continuation
      continuation.provider_status == :streaming and continuation.resume_cursor == %{offset: 2}
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert List.last(Task.await(consumer, 1_000)).kind == :interrupted

    # This is the durable crash window after the restart receipt, but before
    # the replacement provider session has been released. Recovery must use
    # the persisted cursor directly and must not emit another selection edge.
    receipted =
      rewrite_run_checkpoint(checkpoint, original.run_id, fn run ->
        continuation = %{
          run.inference_continuation
          | provider_status: :selected,
            recovery: %{status: :stream_restart_receipted}
        }

        %{run | inference_continuation: continuation}
      end)

    restored =
      start_instance(subject,
        canonical_checkpoint: receipted,
        opts: runtime_opts
      )

    assert_eventually(fn -> map_size(:sys.get_state(restored).stream_sessions) == 1 end)

    {_id, ownership} = Enum.at(:sys.get_state(restored).stream_sessions, 0)
    events = Enum.to_list(ownership.stream)

    assert_receive {:resume_adapter, :resumed, %{offset: 2}}, 1_000
    assert %{kind: :result, payload: %{reply_text: "before restart"}} = List.last(events)
  end

  test "restart reconstructs inference admission and reply continuations from canonical Runs" do
    inference_subject = unique_subject("ready-inference")
    inference_instance = start_instance(inference_subject)
    inference_state = :sys.get_state(inference_instance).state
    assert {:ok, inference_checkpoint} = Instance.checkpoint(inference_instance)
    stop_instance(inference_instance)

    request =
      Request.new(
        id: "recovered-ready-inference",
        purpose: :cognitive_operation,
        plan: %Plan{rendered: "resume admitted inference"},
        constraints: Constraints.new([]),
        metadata: %{
          model: @fast_model,
          llm_opts: [model: @fast_model],
          explicit_model_override?: true
        }
      )

    admission_opts = [run_id: "recovered-ready-inference-run"]

    assert {:ok, ready_inference} =
             Runtime.admit_inference(
               @agent,
               request,
               Input.new("resume admitted inference"),
               inference_state,
               [model: @fast_model, plan_actions?: false],
               admission_opts
             )

    assert ready_inference.start_continuation.recoverable?

    restored_inference =
      start_instance(inference_subject,
        canonical_checkpoint: put_run_checkpoint(inference_checkpoint, ready_inference),
        opts: [model: @fast_model, plan_actions?: false, test_pid: self()]
      )

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :complete}},
        Instance.run(restored_inference, ready_inference.id)
      )
    end)

    reply_subject = unique_subject("reply-boundary")

    reply_instance =
      start_instance(reply_subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        opts: [test_pid: self(), block_recovery_handler?: false]
      )

    reply_state = :sys.get_state(reply_instance).state
    assert {:ok, reply_checkpoint} = Instance.checkpoint(reply_instance)
    stop_instance(reply_instance)

    reply_opts = [
      run_id: "recovered-reply-boundary-run",
      test_pid: self(),
      block_recovery_handler?: false
    ]

    assert {:ok, admitted_reply} =
             Runtime.admit(
               SpectreInferenceRecoveryContractTest.QueueAgent,
               Input.new("ping"),
               reply_state,
               reply_opts,
               reply_opts
             )

    assert {:boundary, _boundary, reply_run} = Runtime.advance(admitted_reply, reply_opts)

    restored_reply =
      start_instance(reply_subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        canonical_checkpoint: put_run_checkpoint(reply_checkpoint, reply_run),
        opts: [test_pid: self(), block_recovery_handler?: false]
      )

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(restored_reply, reply_run.id))
    end)
  end

  test "a non-recoverable ready continuation is terminalized instead of guessed" do
    subject = unique_subject("ready-unrecoverable")

    instance =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        opts: [test_pid: self(), block_recovery_handler?: false]
      )

    state = :sys.get_state(instance).state
    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    admission_opts = [
      run_id: "unrecoverable-ready-run",
      runtime_binding: fn -> :process_local end
    ]

    assert {:ok, run} =
             Runtime.admit(
               SpectreInferenceRecoveryContractTest.QueueAgent,
               Input.new("ping"),
               state,
               admission_opts,
               admission_opts
             )

    refute run.start_continuation.recoverable?

    restored =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        canonical_checkpoint: put_run_checkpoint(checkpoint, run),
        opts: [test_pid: self(), block_recovery_handler?: false]
      )

    assert {:ok, %{status: :failed}} = Instance.run(restored, run.id)

    assert {:run_recovery_unavailable, :nonportable_start_option} =
             :sys.get_state(restored).runs[run.id].last_error
  end

  test "restart reacquires capacity before dispatching a receipted stream selection" do
    subject = unique_subject("selected-capacity")
    runtime_opts = recovery_runtime_opts()

    instance = start_instance(subject, opts: runtime_opts)

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    assert_eventually(fn ->
      match?({:error, :stream_not_found}, InferenceStream.lookup_session(original))
    end)

    # Model the durable crash window after `:inference_selected` is receipted
    # and before the provider dispatch intent is committed. The old capacity
    # lease belonged to the dead process and cannot be present in the snapshot.
    selected_checkpoint = selected_stream_checkpoint(checkpoint, original.run_id)

    restored =
      start_instance(subject,
        canonical_checkpoint: selected_checkpoint,
        opts: runtime_opts
      )

    assert_eventually(fn ->
      restored
      |> :sys.get_state()
      |> Map.fetch!(:stream_sessions)
      |> map_size()
      |> Kernel.==(1)
    end)

    state = :sys.get_state(restored)

    {_invocation_id, ownership} =
      Enum.find(state.stream_sessions, fn {_id, entry} ->
        entry.run_id == original.run_id
      end)

    assert ownership.capacity_reservation == {state.ref.key, original.run_id}
    assert {:ok, session} = InferenceStream.lookup_session(ownership.stream)
    assert Process.alive?(session)
  end

  test "every recovered selection phase reacquires capacity before releasing provider work" do
    subject = unique_subject("selected-phases")
    runtime_opts = recovery_runtime_opts()
    instance = start_instance(subject, opts: runtime_opts)

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    assert_eventually(fn ->
      match?({:error, :stream_not_found}, InferenceStream.lookup_session(original))
    end)

    for recovery_status <- [:not_dispatched, :supersession_receipted, :steer_successor_selected] do
      selected = selected_stream_checkpoint(checkpoint, original.run_id, recovery_status)

      restored =
        start_instance(subject,
          canonical_checkpoint: selected,
          opts: runtime_opts
        )

      assert_eventually(fn -> map_size(:sys.get_state(restored).stream_sessions) == 1 end)

      state = :sys.get_state(restored)

      {_id, ownership} =
        Enum.find(state.stream_sessions, fn {_id, entry} ->
          entry.run_id == original.run_id
        end)

      assert ownership.capacity_reservation == {state.ref.key, original.run_id}
      assert {:ok, session} = InferenceStream.lookup_session(ownership.stream)
      assert Process.alive?(session)

      stop_instance(restored)

      assert_eventually(fn ->
        match?({:error, :stream_not_found}, InferenceStream.lookup_session(ownership.stream))
      end)
    end
  end

  test "recovery terminalizes stream states that cannot be resumed or reconciled" do
    subject = unique_subject("unavailable-matrix")
    runtime_opts = recovery_runtime_opts()
    instance = start_instance(subject, opts: runtime_opts)

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    cases = [
      {:interrupted, false, %{status: :interrupted}},
      {:ambiguous, true, %{status: :dispatch_ambiguous}},
      {:selected, false, %{status: :selection_receipted}}
    ]

    Enum.each(cases, fn {provider_status, recoverable?, recovery} ->
      candidate =
        rewrite_run_checkpoint(checkpoint, original.run_id, fn run ->
          continuation = %{
            run.inference_continuation
            | provider_status: provider_status,
              provider_request_id: nil,
              provider_request_digest: nil,
              resume_cursor: nil,
              consumer_token_digest: nil,
              stream_recovery: nil,
              stream_provider_sequence: nil,
              stream_usage: %Usage{},
              stream_usage_quality: :unavailable,
              stream_output_bytes: 0,
              budget: nil,
              recovery: recovery,
              last_response: nil,
              recoverable?: recoverable?
          }

          %{run | inference_continuation: continuation}
        end)

      restored =
        start_instance(subject,
          canonical_checkpoint: candidate,
          opts: runtime_opts
        )

      assert {:ok, %{status: :failed}} = Instance.run(restored, original.run_id)
      stop_instance(restored)
    end)
  end

  test "recovery resolves canonical inference controls before touching an interrupted provider" do
    subject = unique_subject("control-fences")
    runtime_opts = resume_runtime_opts()

    instance =
      start_instance(subject,
        opts: runtime_opts,
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1
      )

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @resume_adapter,
               stream_adapter_opts: [test_pid: self()],
               inference_heartbeat_interval: 1,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    consumer = Task.async(fn -> Enum.to_list(original) end)
    assert_receive {:resume_adapter, :opened, :initial, _session}, 1_000
    assert_receive {:resume_adapter, :stalled, _session}, 1_000

    assert_eventually(fn ->
      :sys.get_state(instance).runs[original.run_id].inference_continuation.provider_status ==
        :streaming
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert List.last(Task.await(consumer, 1_000)).kind == :interrupted

    run = checkpoint_run(checkpoint, original.run_id)
    invocation = run.waiting

    pending =
      Command.new(invocation.inference_id, :steer,
        id: "recovery-pending-steer",
        payload: %{input: "replacement"},
        correlation_id: run.id,
        causation_id: invocation.id,
        base_revision: invocation.control_revision,
        requested_at: 1,
        provenance: %{source: :test}
      )
      |> Command.committed()

    pending_control = %{
      generation: invocation.control_revision + 1,
      pending: pending,
      last_command: nil,
      history: []
    }

    cancelled_controls =
      Enum.map(
        [
          {"recovery-cancel-atom", %{reason: :host_cancelled}},
          {"recovery-cancel-string", %{"reason" => "host_cancelled"}},
          {"recovery-cancel-missing", %{}}
        ],
        fn {id, payload} ->
          command =
            Command.new(invocation.inference_id, :cancel,
              id: id,
              payload: payload,
              correlation_id: run.id,
              causation_id: invocation.id,
              base_revision: invocation.control_revision,
              requested_at: 1,
              provenance: %{source: :test}
            )
            |> Command.committed()
            |> Command.applied()

          %{
            generation: invocation.control_revision + 1,
            pending: nil,
            last_command: command,
            history: [command]
          }
        end
      )

    Enum.each([pending_control | cancelled_controls], fn control ->
      candidate =
        checkpoint
        |> rewrite_run_checkpoint(original.run_id, fn recovered_run ->
          continuation = %{
            recovered_run.inference_continuation
            | provider_status: :interrupted,
              recovery: %{status: :interrupted}
          }

          %{recovered_run | inference_continuation: continuation}
        end)
        |> put_inference_control_checkpoint(invocation.inference_id, control)

      restored =
        start_instance(subject,
          canonical_checkpoint: candidate,
          opts: runtime_opts
        )

      assert_eventually(fn ->
        match?({:ok, %{status: :failed}}, Instance.run(restored, original.run_id))
      end)

      restored_run = :sys.get_state(restored).runs[original.run_id]

      if control.pending do
        assert {:ok, controls} =
                 Canonical.fetch(:sys.get_state(restored).canonical, :inference_control)

        assert controls[invocation.inference_id].pending == nil
        assert controls[invocation.inference_id].last_command.status == :rejected
      else
        assert {:inference_attempt_failed, 1, _reason} = restored_run.last_error
      end

      refute_receive {:resume_adapter, :resumed, _cursor}, 20
      stop_instance(restored)
    end)
  end

  test "reconciliation preserves confirmed and ambiguous negative provider outcomes" do
    subject = unique_subject("reconcile-outcomes")

    instance =
      start_instance(subject,
        opts: recovery_runtime_opts(),
        inference_observer_lane: true,
        inference_progress_commit_interval: 1,
        inference_stream_checkpoint_interval: 1
      )

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               inference_heartbeat_interval: 1,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    consumer = Task.async(fn -> Enum.to_list(original) end)
    assert_receive {:recovery_adapter, :opened, _session}, 1_000
    assert_receive {:recovery_adapter, :stalled, _session}, 1_000

    assert_eventually(fn ->
      :sys.get_state(instance).runs[original.run_id].inference_continuation.provider_status ==
        :streaming
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert List.last(Task.await(consumer, 1_000)).kind == :interrupted

    Enum.each([:not_found, :pending, {:error, :provider_offline}], fn reconcile_reply ->
      restored =
        start_instance(subject,
          canonical_checkpoint: checkpoint,
          opts: Keyword.put(recovery_runtime_opts(), :reconcile_reply, reconcile_reply)
        )

      assert_receive {:recovery_adapter, :reconciled, "recovery-provider-request"}, 1_000

      assert_eventually(fn ->
        match?({:ok, %{status: :failed}}, Instance.run(restored, original.run_id))
      end)

      stop_instance(restored)
    end)
  end

  test "recovery completes a receipted retry chain without redispatch loops" do
    subject = unique_subject("retry-pending")

    runtime_opts =
      recovery_runtime_opts()
      |> Keyword.put(:fallback, @stream_model)
      |> Keyword.put(:stream_max_attempts, 3)

    instance = start_instance(subject, opts: runtime_opts)

    assert {:ok, original} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               fallback: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               stream_max_attempts: 3,
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 2_000
             )

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    retry_pending =
      rewrite_run_checkpoint(checkpoint, original.run_id, fn run ->
        continuation = %{
          run.inference_continuation
          | provider_status: :terminal,
            provider_request_id: nil,
            provider_request_digest: nil,
            resume_cursor: nil,
            consumer_token_digest: nil,
            stream_recovery: nil,
            stream_provider_sequence: nil,
            stream_usage: %Usage{},
            stream_usage_quality: :unavailable,
            stream_output_bytes: 0,
            budget: nil,
            recovery: %{status: :retry_pending, reason: %{class: :provider_unavailable}},
            last_response: nil
        }

        %{run | inference_continuation: continuation}
      end)

    restored =
      start_instance(subject,
        canonical_checkpoint: retry_pending,
        opts: runtime_opts
      )

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(restored, original.run_id))
    end)

    assert {:inference_retry_selection_failed, 3, _reason} =
             :sys.get_state(restored).runs[original.run_id].last_error
  end

  test "restart resumes post-processing from the receipted response without calling the model again" do
    subject = unique_subject("receipted-response")

    instance =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.PlannerAgent,
        opts: [
          model: @fast_model,
          test_pid: self(),
          block_recovery_planner?: true
        ]
      )

    parent = self()

    {_caller, caller_monitor} =
      spawn_monitor(fn ->
        result = Spectre.turn(instance, "ask", run_id: "receipted-response-run")
        send(parent, {:receipted_response_result, result})
      end)

    assert_receive {:recovery_fast_model, :completed, _worker}, 1_000
    assert_receive {:recovery_planner, :called, true, planner_worker}, 1_000

    assert_eventually(fn ->
      case :sys.get_state(instance).runs["receipted-response-run"] do
        %{inference_continuation: continuation} ->
          continuation.provider_status == :terminal and not is_nil(continuation.last_response)

        _missing ->
          false
      end
    end)

    planner_monitor = Process.monitor(planner_worker)
    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert_receive {:DOWN, ^planner_monitor, :process, ^planner_worker, :killed}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, _caller, _reason}, 1_000

    restored =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.PlannerAgent,
        canonical_checkpoint: checkpoint,
        opts: [
          model: @fast_model,
          test_pid: self(),
          block_recovery_planner?: false
        ]
      )

    assert_receive {:recovery_planner, :called, false, _recovered_worker}, 1_000
    refute_receive {:recovery_fast_model, :completed, _duplicate_provider_call}

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :complete}},
        Instance.run(restored, "receipted-response-run")
      )
    end)
  end

  test "restart re-enqueues admitted ready Runs without leaking their callers" do
    subject = unique_subject("ready-runs")
    true = Process.register(self(), @queue_mailbox)

    on_exit(fn ->
      if Process.whereis(@queue_mailbox) == self(), do: Process.unregister(@queue_mailbox)
    end)

    instance =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        opts: [test_pid: @queue_mailbox, block_recovery_handler?: true]
      )

    parent = self()

    spawn_monitor(fn ->
      result = Spectre.turn(instance, "block", run_id: "ready-block-run")
      send(parent, {:ready_block_result, result})
    end)

    assert_receive {:recovery_handler, :called, true, _worker}, 1_000

    spawn_monitor(fn ->
      result = Spectre.turn(instance, "ping", run_id: "ready-ping-run")
      send(parent, {:ready_ping_result, result})
    end)

    assert_eventually(fn ->
      match?(
        %{status: :ready, cursor: :turn},
        :sys.get_state(instance).runs["ready-ping-run"]
      )
    end)

    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    restored =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.QueueAgent,
        canonical_checkpoint: checkpoint,
        opts: [test_pid: @queue_mailbox, block_recovery_handler?: false]
      )

    # Admission freezes portable runtime options. Recovery therefore preserves
    # the original blocking decision instead of silently substituting the new
    # Instance default; the test releases that reconstructed worker explicitly.
    assert_receive {:recovery_handler, :called, true, recovered_worker}, 1_000
    send(recovered_worker, :release_recovery_handler)

    for run_id <- ["ready-block-run", "ready-ping-run"] do
      assert_eventually(fn ->
        match?(
          {:ok, %{status: status}} when status in [:complete, :failed],
          Instance.run(restored, run_id)
        )
      end)

      assert {:ok, %{status: :complete}} = Instance.run(restored, run_id)
    end
  end

  test "restart terminalizes an in-flight Effect as ambiguous and never executes it twice" do
    subject = unique_subject("effect")

    instance =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.EffectAgent,
        opts: [test_pid: self()]
      )

    parent = self()

    assert {:ok, pending} =
             Spectre.turn(instance, "effect", run_id: "ambiguous-effect-run")

    {_caller, caller_monitor} =
      spawn_monitor(fn ->
        result = Spectre.execute(instance, pending.result, test_pid: parent)
        send(parent, {:ambiguous_effect_result, result})
      end)

    assert_receive {:recovery_effect, :started, effect_worker}, 1_000
    effect_monitor = Process.monitor(effect_worker)
    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)
    assert_receive {:DOWN, ^effect_monitor, :process, ^effect_worker, :killed}, 1_000
    assert_receive {:DOWN, ^caller_monitor, :process, _caller, _reason}, 1_000

    restored =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.EffectAgent,
        canonical_checkpoint: checkpoint,
        opts: [test_pid: self()]
      )

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(restored, "ambiguous-effect-run"))
    end)

    assert {:effect_outcome_ambiguous, :instance_restarted} =
             :sys.get_state(restored).runs["ambiguous-effect-run"].last_error

    refute_receive {:recovery_effect, :started, _duplicate_effect}
  end

  test "restart preserves a policy boundary as a host-resolvable durable wait" do
    subject = unique_subject("policy")

    instance =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.PolicyAgent,
        opts: [test_pid: self()]
      )

    assert {:ok, turn} =
             Spectre.turn(instance, "protected", run_id: "durable-policy-run")

    assert {:needs, _boundary} = turn.observable
    assert {:ok, checkpoint} = Instance.checkpoint(instance)
    stop_instance(instance)

    restored =
      start_instance(subject,
        agent: SpectreInferenceRecoveryContractTest.PolicyAgent,
        canonical_checkpoint: checkpoint,
        opts: [test_pid: self()]
      )

    assert {:ok, %{status: :boundary, cursor: :policy}} =
             Instance.run(restored, "durable-policy-run")

    assert {:ok, approved} =
             Spectre.resolve_policy(restored, turn.result, {:accept, :approved})

    assert {:ok, _completed} = Spectre.execute(restored, approved, test_pid: self())
    assert_receive {:recovery_policy, :executed}, 1_000
  end

  test "a confirmed provider failure is receipted before selecting the fallback attempt" do
    instance = start_instance(unique_subject("fallback"))

    assert {:ok, response} =
             Instance.infer(instance, fallback_request(),
               run_id: "fallback-inference-run",
               model: @primary_fail_model,
               fallback: @secondary_model,
               test_pid: self()
             )

    assert response.text == "fallback response"
    assert response.selection.attempt == 2
    assert response.selection.reason == :provider_fallback
    assert_receive {:recovery_fallback, :primary_failed}
    assert_receive {:recovery_fallback, :secondary_completed}
    assert {:ok, %{status: :complete}} = Instance.run(instance, "fallback-inference-run")
  end

  test "retry selection failure terminalizes the retained Run explicitly" do
    instance = start_instance(unique_subject("fallback-unavailable"))

    request =
      Request.new(
        id: "missing-fallback-inference",
        purpose: :cognitive_operation,
        plan: %Plan{rendered: "attempt a missing fallback"},
        constraints: Constraints.new(max_attempts: 2),
        metadata: %{
          model: @primary_fail_model,
          llm_opts: [model: @primary_fail_model, test_pid: self()],
          explicit_model_override?: true
        }
      )

    assert {:error,
            {:inference_retry_selection_failed, 2, %{class: :inference_fallback_unavailable}}} =
             Instance.infer(instance, request,
               run_id: "fallback-unavailable-run",
               inference_max_attempts: 2,
               model: @primary_fail_model,
               test_pid: self()
             )

    assert_receive {:recovery_fallback, :primary_failed}
    assert {:ok, %{status: :failed}} = Instance.run(instance, "fallback-unavailable-run")
  end

  test "abnormal one-shot worker death becomes an ambiguous terminal receipt" do
    instance = start_instance(unique_subject("worker-down"))
    parent = self()
    request = cognitive_request()

    spawn_monitor(fn ->
      result =
        Instance.infer(instance, request,
          run_id: "worker-down-run",
          test_pid: parent
        )

      send(parent, {:worker_down_result, result})
    end)

    assert_receive {:recovery_model, :started, worker}, 1_000
    Process.exit(worker, :kill)

    assert_receive {:worker_down_result,
                    {:error, {:inference_attempt_failed, 1, %{class: :error}}}},
                   1_000

    assert {:ok, %{status: :failed}} = Instance.run(instance, "worker-down-run")
  end

  test "the immutable one-shot deadline kills a stalled provider worker" do
    instance = start_instance(unique_subject("deadline"))
    parent = self()
    request = cognitive_request()

    spawn_monitor(fn ->
      result =
        Instance.infer(instance, request,
          run_id: "deadline-run",
          test_pid: parent,
          inference_budget: [duration_ms: 200]
        )

      send(parent, {:deadline_result, result})
    end)

    assert_receive {:recovery_model, :started, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    assert_receive {:deadline_result,
                    {:error, {:inference_attempt_failed, 1, :inference_deadline_exceeded}}},
                   2_000

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert {:ok, %{status: :failed}} = Instance.run(instance, "deadline-run")
  end

  test "abnormal stream session death interrupts and terminalizes its Run" do
    instance =
      start_instance(unique_subject("session-down"),
        opts: recovery_runtime_opts()
      )

    assert {:ok, stream} =
             Spectre.stream(instance, "stream this",
               model: @stream_model,
               plan_actions?: false,
               stream_adapter: @adapter,
               stream_adapter_opts: [test_pid: self()],
               stream_provider_stall_timeout: 5_000,
               stream_result_timeout: 1_000
             )

    consumer = Task.async(fn -> Enum.to_list(stream) end)
    assert_receive {:recovery_adapter, :opened, session}, 1_000
    Process.exit(session, :kill)

    events = Task.await(consumer, 1_000)
    assert List.last(events).kind == :interrupted

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Instance.run(instance, stream.run_id))
    end)
  end

  defp cognitive_request do
    Request.new(
      id: "uncertain-cognitive-inference",
      purpose: :cognitive_operation,
      plan: %Plan{rendered: "perform one uncertain cognitive operation"},
      constraints: Constraints.new(strict: true),
      metadata: %{
        model: @blocking_model,
        llm_opts: [model: @blocking_model, test_pid: self()],
        explicit_model_override?: true
      }
    )
  end

  defp fallback_request do
    Request.new(
      id: "fallback-cognitive-inference",
      purpose: :cognitive_operation,
      plan: %Plan{rendered: "exercise a provider fallback"},
      constraints: Constraints.new(max_attempts: 2),
      metadata: %{
        model: @primary_fail_model,
        fallback: @secondary_model,
        llm_opts: [
          model: @primary_fail_model,
          fallback: @secondary_model,
          test_pid: self()
        ],
        explicit_model_override?: true
      }
    )
  end

  defp recovery_runtime_opts do
    [
      model: @stream_model,
      plan_actions?: false,
      stream_adapter: @adapter,
      stream_adapter_opts: [test_pid: self()],
      inference_heartbeat_interval: 1,
      stream_provider_stall_timeout: 5_000,
      stream_result_timeout: 2_000
    ]
  end

  defp resume_runtime_opts do
    [
      model: @stream_model,
      plan_actions?: false,
      stream_adapter: @resume_adapter,
      stream_adapter_opts: [test_pid: self()],
      inference_heartbeat_interval: 1,
      stream_provider_stall_timeout: 5_000,
      stream_result_timeout: 2_000
    ]
  end

  defp selected_stream_checkpoint(checkpoint, run_id, recovery_status \\ :selection_receipted) do
    rewrite_run_checkpoint(checkpoint, run_id, fn run ->
      invocation = run.inference_continuation.invocation

      previous_attempts =
        if recovery_status == :steer_successor_selected do
          [
            %{
              attempt: run.inference_continuation.attempt,
              attempt_id: invocation.attempt_id,
              invocation_id: invocation.id,
              control_revision: invocation.control_revision,
              stream_epoch: invocation.stream_epoch,
              outcome: :superseded,
              reason: :steered,
              usage: %{},
              settlement: :ambiguous
            }
          ]
        else
          run.inference_continuation.previous_attempts
        end

      continuation = %{
        run.inference_continuation
        | provider_status: :selected,
          provider_request_id: nil,
          provider_request_digest: nil,
          resume_cursor: nil,
          consumer_token_digest: nil,
          stream_recovery: nil,
          stream_provider_sequence: nil,
          stream_usage: %Usage{},
          stream_usage_quality: :unavailable,
          stream_output_bytes: 0,
          budget: nil,
          previous_attempts: previous_attempts,
          recovery: %{status: recovery_status},
          last_response: nil
      }

      %{run | inference_continuation: continuation}
    end)
  end

  defp rewrite_run_checkpoint(checkpoint, run_id, mapper) do
    canonical = CanonicalCodec.decode!(checkpoint)
    {:ok, runs} = Canonical.fetch(canonical, :runs)
    {:ok, run} = runs |> Map.fetch!(run_id) |> Run.restore()
    {:ok, run_checkpoint} = run |> mapper.() |> Run.checkpoint()
    {:ok, runs_section} = Sections.fetch(canonical.sections, :runs)
    runs = Map.put(runs, run_id, run_checkpoint)
    sections = Sections.put(canonical.sections, :runs, %{runs_section | value: runs})

    {:ok, encoded} = CanonicalCodec.encode_json(%{canonical | sections: sections})
    encoded
  end

  defp checkpoint_run(checkpoint, run_id) do
    canonical = CanonicalCodec.decode!(checkpoint)
    {:ok, runs} = Canonical.fetch(canonical, :runs)
    {:ok, run} = runs |> Map.fetch!(run_id) |> Run.restore()
    run
  end

  defp put_run_checkpoint(checkpoint, %Run{} = run) do
    canonical = CanonicalCodec.decode!(checkpoint)
    {:ok, runs} = Canonical.fetch(canonical, :runs)
    {:ok, encoded_run} = Run.checkpoint(run)
    {:ok, section} = Sections.fetch(canonical.sections, :runs)

    sections =
      Sections.put(canonical.sections, :runs, %{
        section
        | value: Map.put(runs, run.id, encoded_run)
      })

    {:ok, encoded} = CanonicalCodec.encode_json(%{canonical | sections: sections})
    encoded
  end

  defp put_inference_control_checkpoint(checkpoint, inference_id, control) do
    canonical = CanonicalCodec.decode!(checkpoint)
    {:ok, section} = Sections.fetch(canonical.sections, :inference_control)
    controls = Map.put(section.value, inference_id, control)
    sections = Sections.put(canonical.sections, :inference_control, %{section | value: controls})

    {:ok, encoded} = CanonicalCodec.encode_json(%{canonical | sections: sections})
    encoded
  end

  defp start_instance(subject, extra \\ []) do
    opts =
      [agent: @agent, subject: subject, idle: false]
      |> Keyword.merge(extra)

    {:ok, instance} = Instance.start_link(opts)
    Process.unlink(instance)
    on_exit(fn -> stop_instance(instance) end)
    instance
  end

  defp stop_instance(instance) do
    if Process.alive?(instance), do: GenServer.stop(instance, :normal)
  end

  defp unique_subject(prefix) do
    Subject.new("inference-recovery-#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
