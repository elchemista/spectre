defmodule Spectre.Server.RuntimeActivitiesTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.{Activities, Runtime}
  alias Spectre.Server.Store.Port, as: Store

  @timeout 5_000
  @publication_class "test.activity.publish"

  defmodule DocumentAdapter do
    @behaviour Spectre.Server.GAM.EffectAdapter

    def prepare(:read, :reject, _context), do: {:error, :document_missing}
    def prepare(:read, document, _context), do: {:ok, document}
    def prepare(:publish, document, _context), do: {:ok, %{id: document}}

    def invoke(:read, document, _context), do: {:ok, document}
    def project(_operation, result), do: {:ok, result}

    @impl true
    def execute_effect(:publish, %{id: "held"}, _context), do: held_publication("held")

    def execute_effect(:publish, %{id: "held_external"}, _context) do
      Spectre.Server.TaskSupervisor
      |> Task.Supervisor.async_nolink(fn -> held_publication("held_external") end)
      |> Task.await()
    end

    def execute_effect(:publish, %{id: id}, _context), do: {:ok, %{published: id}}

    defp held_publication(id) do
      send(Spectre.Server.RuntimeActivitiesTest, {:publication_started, self()})

      receive do
        :release_publication -> {:ok, %{published: id}}
      after
        5_000 -> {:error, :ambiguous, :publication_wait_expired}
      end
    end
  end

  defmodule Documents do
    use Spectre.Stack.Installable, id: :documents, version: "0.1.0"

    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.tool(:read, DocumentAdapter)
      |> Spectre.Integration.tool(:publish, DocumentAdapter, governed: :publish)
    end

    def effects(_config) do
      %{
        publish: %{
          contract: 1,
          adapter: DocumentAdapter,
          operation: :publish,
          side_effect: :idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
        }
      }
    end
  end

  defmodule Research do
    use Spectre.Activity

    def handle_start({:read, document}, ctx), do: call_tool(ctx, {:documents, :read}, document)

    def handle_start(:spawn, ctx),
      do: start_activity(ctx, :subtask, :waiting, on_result: :subtask)

    def handle_start(:invalid_completion, ctx),
      do: ctx |> respond("uncommitted response") |> complete(:invalid)

    def handle_start({:publish, document}, ctx) do
      ctx
      |> assign(:publishing, true)
      |> call_tool({:documents, :publish}, document)
    end

    def handle_start(:waiting, ctx), do: ctx

    def handle_start(:announce, ctx), do: respond(ctx, "Activity response")

    def handle_result(:read, {:ok, document}, ctx), do: complete(ctx, document)

    def handle_result(:publish, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
      do: complete(ctx, :ordinary_publication)

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_signal({:revise, :crash}, _ctx), do: Process.exit(self(), :kill)
    def handle_signal({:revise, _value}, %{assigns: %{publishing: true}} = ctx), do: ctx
    def handle_signal({:revise, value}, ctx), do: complete(ctx, value)

    def handle_signal({:effect, {:governed, %{outcome: %{status: :succeeded}}}}, ctx),
      do: complete(ctx, :observed_publication)

    def handle_signal({:cancel_child, target}, ctx),
      do: cancel_activity(ctx, target, on_result: :child_control)

    def handle_signal(:output_burst, ctx) do
      ctx = respond(ctx, String.duplicate("x", 129 * 1024))
      Enum.reduce(1..300, ctx, &respond(&2, "output #{&1}"))
    end

    def handle_signal({:hold_completion, result}, ctx) do
      send(Spectre.Server.RuntimeActivitiesTest, {:completion_ready, self()})

      receive do
        :complete_activity -> complete(ctx, result)
      after
        5_000 -> fail(ctx, :completion_wait_expired)
      end
    end

    def handle_signal(signal, ctx), do: super(signal, ctx)
  end

  defmodule Stack do
    use Spectre.Stack

    install(Documents)
    activity(:research, Research, allow_children: [:subtask])
    activity(:subtask, Research)
    activity(:all_children, Research, allow_children: true)
  end

  defmodule Root do
    use Spectre.Server

    def init(observer, ctx) do
      send(observer, {:root_ready, self()})
      {:ok, put_private(ctx, :observer, observer)}
    end

    def handle_call({:work, args, opts}, _from, ctx),
      do: {:reply, :queued, start_activity(ctx, :research, args, opts)}

    def handle_call({:work, type, args, opts}, _from, ctx),
      do: {:reply, :queued, start_activity(ctx, type, args, opts)}

    def handle_call({:signal, target, signal, opts}, _from, ctx),
      do: {:reply, :queued, signal_activity(ctx, target, signal, opts)}

    def handle_call({:cancel, target, opts}, _from, ctx),
      do: {:reply, :queued, cancel_activity(ctx, target, opts)}

    def handle_call({:incorrect_control, target}, _from, ctx),
      do: {:reply, {signal_activity(self(), target, :wake), cancel_activity(self(), target)}, ctx}

    def handle_call(message, from, ctx), do: super(message, from, ctx)

    def handle_flow({:test, :ping}, _input, ctx), do: respond(ctx, "pong")

    def handle_result(:started, result, ctx) do
      send(get_private(ctx, :observer), {:start_result, result})
      ctx
    end

    def handle_result(:control, result, ctx) do
      send(get_private(ctx, :observer), {:control_result, result})
      ctx
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_activity(%{ref: ref, key: key}, event, ctx) do
      send(get_private(ctx, :observer), {:handled_activity, ref, key, event})
      ctx
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])

    flow :test do
      on(:ping, regex: ~r/^ping$/)
    end
  end

  test "Activity output uses the Root consumer envelope and the execution reference" do
    root = start_root()
    ref = start_activity(root, :announce)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref, event_id: event_id},
                     {:output, {:response, nil, "Activity response", _}}}},
                   @timeout

    assert is_binary(event_id)
    assert {:ok, _} = Server.signal_activity(root, ref, {:revise, :announced})
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, :announced}}}, @timeout
    refute_received {:handled_activity, ^ref, _, {:output, _}}
    refute_received {Server, _child, {:response, _, "Activity response", _}}
  end

  test "a paused Root receives one notification in flight and retains the terminal event" do
    root = start_root()
    ref = start_activity(root)
    coordinator = activity_coordinator(root)
    child = activity_pid(root, ref)

    :ok = :sys.suspend(root)

    try do
      assert {:ok, _} =
               Activities.control(
                 coordinator,
                 ref,
                 Spectre.Identity.uuid7(),
                 {:signal, :output_burst},
                 []
               )

      assert eventually(fn -> :queue.len(:sys.get_state(coordinator).events) == 32 end)
      assert map_size(:sys.get_state(child).outbox) == 0

      assert {:ok, _} =
               Activities.control(
                 coordinator,
                 ref,
                 Spectre.Identity.uuid7(),
                 {:signal, {:revise, :drained}},
                 []
               )

      assert eventually(fn ->
               match?({:ok, %{status: :completed}}, Activities.view(coordinator, ref))
             end)

      assert {:messages, messages} = Process.info(root, :messages)
      assert [_] = Enum.filter(messages, &match?({Activities, _, :lifecycle, _, _, _, _}, &1))

      queued = :sys.get_state(coordinator).events |> :queue.to_list()
      output = for {_, _, {:output, {:response, _, text, _}}} <- queued, do: text
      assert length(output) in 1..32
      assert Enum.all?(output, &(byte_size(&1) < 40))
    after
      :sys.resume(root)
    end

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, :drained}}}, @timeout
    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout
  end

  test "coordinator loss is visible and the same Root can start a new Activity" do
    root = start_root()
    ref = start_activity(root, :waiting, as: :report)
    Process.exit(activity_coordinator(root), :kill)

    assert_receive {Server, ^root, {:activities_unavailable, :coordinator_stopped}}, @timeout
    assert {:error, :unknown_activity} = Server.activity(root, ref)
    refute start_activity(root, :waiting, as: :report) == ref
  end

  test "Activity output is shed when the application consumer is behind" do
    consumer = spawn_link(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(consumer, :kill) end)
    root = start_root(consumer: consumer)
    Enum.each(1..256, &send(consumer, {:waiting, &1}))

    assert :queued = GenServer.call(root, {:work, :announce, [on_result: :started]})
    assert_receive {:start_result, {:ok, %{ref: ref}}}, @timeout
    assert_receive {:handled_activity, ^ref, nil, :idle}, @timeout
    assert {:messages, messages} = Process.info(consumer, :messages)
    assert Enum.any?(messages, &match?({Server, ^root, {:activity, %{ref: ^ref}, :idle}}, &1))

    refute Enum.any?(messages, fn message ->
             match?({Server, ^root, {:activity, %{ref: ^ref}, {:output, _}}}, message)
           end)
  end

  for coordinator_loss <- [false, true] do
    @coordinator_loss coordinator_loss
    @tag :tmp_dir
    test "a submitted start recovers by command ID with coordinator loss #{@coordinator_loss}", %{
      tmp_dir: path
    } do
      assert_interrupted_start_recovery(path, @coordinator_loss)
    end
  end

  defp assert_interrupted_start_recovery(path, coordinator_loss?) do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    subject = Spectre.Identity.uuid7()

    options = [
      subject: subject,
      identity: %{subject: subject},
      consumer: self(),
      init_arg: self(),
      gam: [storage: {:disk, path}]
    ]

    assert {:ok, original} = Spectre.Supervisor.summon(supervisor, Agent, options)
    assert_receive {:root_ready, ^original}, @timeout
    start_activity(original)
    coordinator = activity_coordinator(original)

    :ok = :sys.suspend(supervisor)
    :ok = :sys.suspend(coordinator)

    try do
      assert :queued =
               GenServer.call(original, {:work, :waiting, [as: :queued, on_result: :started]})

      assert eventually(fn ->
               {:messages, messages} = Process.info(coordinator, :messages)

               Enum.any?(messages, fn
                 {:"$gen_call", _, {:start, _, _, _}} -> true
                 _ -> false
               end)
             end)

      crash_root(original, :after_submit, :after_submit)
      if coordinator_loss?, do: Process.exit(coordinator, :kill)
    after
      if Process.alive?(coordinator), do: :sys.resume(coordinator)
      :sys.resume(supervisor)
    end

    assert_receive {:root_ready, replacement}, @timeout
    refute original == replacement
    assert_recovered_start(replacement, coordinator_loss?)

    assert {:ok, turn} = Server.input(replacement, "ping")
    assert_receive {Server, ^replacement, {:response, ^turn, "pong", _}}, @timeout
  end

  defp assert_recovered_start(root, true) do
    assert_receive {:start_result, {:error, :activity_start_outcome_unknown}}, @timeout
    assert {:ok, []} = Server.activities(root)
  end

  defp assert_recovered_start(root, false) do
    assert_receive {:start_result, {:ok, %{ref: ref, key: :queued}}}, @timeout
    assert {:ok, %{ref: ^ref, status: :running}} = Server.activity(root, :queued)
    assert {:ok, [_, _]} = Server.activities(root)
  end

  test "two unnamed Activities run independently and the Root survives a child crash" do
    root = start_root()
    assert {:ok, []} = Server.activities(root)

    first = start_activity(root)
    second = start_activity(root)
    refute first == second

    assert {:ok, entries} = Server.activities(root)

    assert Enum.sort(for %{ref: ref, status: :running, key: nil} <- entries, do: ref) ==
             Enum.sort([first, second])

    assert {:ok, _} = Server.signal_activity(root, first, {:revise, :crash})
    assert_receive {Server, ^root, {:activity, %{ref: ^first}, {:failed, _}}}, @timeout
    assert {:ok, %{status: :running, revision: revision}} = Server.activity(root, second)

    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout

    assert {:ok, signal} =
             Server.signal_activity(root, second, {:revise, "report"}, if_revision: revision)

    revised = revision + 1

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^second, revision: ^revised},
                     {:signalled, ^signal, {:ok, _}}}},
                   @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^second, status: :completed}, {:completed, "report"}}},
                   @timeout

    assert_receive {:handled_activity, ^second, nil, {:completed, "report"}}, @timeout
    assert {:ok, %{status: :completed}} = Server.activity(root, second)
  end

  test "names can be reused after cancellation and previous references remain distinct" do
    root = start_root()
    first = start_activity(root, :waiting, as: :a_report)
    assert {:ok, %{ref: ^first}} = Server.activity(root, :a_report)

    assert :queued =
             GenServer.call(root, {:work, :waiting, [as: :a_report, on_result: :started]})

    assert_receive {:start_result, {:error, :already_running}}, @timeout
    assert {:ok, _} = Server.cancel_activity(root, :a_report)

    assert_receive {Server, ^root, {:activity, %{ref: ^first, key: :a_report}, :cancelled}},
                   @timeout

    second = start_activity(root, :waiting, as: :a_report)
    refute first == second
    assert {:ok, %{ref: ^second, status: :running}} = Server.activity(root, :a_report)
    assert {:ok, %{ref: ^first, status: :cancelled}} = Server.activity(root, first)
  end

  test "callback controls resolve a running name, fence stale revisions and deliver results" do
    root = start_root()
    ref = start_activity(root, :waiting, as: :monthly_report)
    sibling = start_activity(root)
    assert {:ok, %{revision: revision}} = Server.activity(root, ref)

    assert :queued =
             GenServer.call(root, {:signal, :monthly_report, :wake, [on_result: :control]})

    assert_receive {:control_result, {:ok, %{ref: ^ref, revision: ^revision}}}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:signalled, _id, {:ok, %{ref: ^ref, revision: ^revision}}}}},
                   @timeout

    stale = [if_revision: revision + 1, on_result: :control]
    assert :queued = GenServer.call(root, {:cancel, ref, stale})
    assert_receive {:control_result, {:error, :superseded}}, @timeout

    assert :queued = GenServer.call(root, {:cancel, :monthly_report, [on_result: :control]})
    assert_receive {:control_result, {:ok, %{ref: ^ref, status: :cancelled}}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :cancelled}}, @timeout

    assert {:ok, request} = Server.cancel_activity(root, ref)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:signalled, ^request, {:error, :inactive_activity}}}},
                   @timeout

    assert {:ok, %{status: :running}} = Server.activity(root, sibling)
  end

  test "missing Activity targets and types produce controlled command failures" do
    root = start_root()
    assert :queued = GenServer.call(root, {:signal, :missing, :wake, []})

    assert_receive {Server, ^root,
                    {:activity_command_failed, nil, :signal_activity, {:error, :unknown_activity}}},
                   @timeout

    unknown = {:documents, :missing}
    assert :queued = GenServer.call(root, {:work, unknown, :waiting, [on_result: :started]})
    assert_receive {:start_result, {:error, {:unknown_stack_activity, ^unknown}}}, @timeout
    assert {:ok, []} = Server.activities(root)
  end

  test "invalid host control options are distinct from authorization and missing work" do
    root = start_root()
    ref = start_activity(root)

    assert {:error, :invalid_activity_options} =
             Server.signal_activity(root, ref, :wake, timeout: 1_000)

    assert {:error, :invalid_activity_revision} =
             Server.cancel_activity(root, ref, if_revision: -1)

    assert {:error, :unknown_activity} = Server.cancel_activity(root, :missing)

    assert {{:error, :activity_control_requires_context},
            {:error, :activity_control_requires_context}} =
             GenServer.call(root, {:incorrect_control, ref})

    caller = Task.async(fn -> Server.signal_activity(root, ref, :wake) end)
    assert {:error, :activity_not_authorized} = Task.await(caller)

    assert :queued = GenServer.call(root, {:signal, :missing, :wake, [on_result: :control]})
    assert_receive {:control_result, {:error, :unknown_activity}}, @timeout
  end

  test "start timeout preserves the later readiness event without promising rejection" do
    root = start_root(worker_timeout: 400)
    existing = start_activity(root)
    coordinator = activity_coordinator(root)
    assert :ok = :sys.suspend(coordinator)

    try do
      assert :queued =
               GenServer.call(root, {:work, :waiting, [as: :slow, on_result: :started]})

      assert_receive {:start_result, {:error, :activity_start_outcome_unknown}}, @timeout
    after
      :sys.resume(coordinator)
    end

    assert_receive {Server, ^root, {:activity, %{ref: ref, key: :slow}, :started}}, @timeout
    assert {:ok, %{ref: ^ref, status: :running}} = Server.activity(root, :slow)
    assert {:ok, activities} = Server.activities(root)
    assert Enum.sort(Enum.map(activities, & &1.ref)) == Enum.sort([existing, ref])
  end

  test "a callback control can finish after its worker deadline" do
    root = start_root(worker_timeout: 500)
    ref = start_activity(root)
    %{managed_owner: managed} = :sys.get_state(root)
    %{domain: domain} = :sys.get_state(managed)
    assert :ok = :sys.suspend(domain)

    try do
      assert :queued = GenServer.call(root, {:cancel, ref, [on_result: :control]})
      assert_receive {:control_result, {:error, :activity_control_outcome_unknown}}, @timeout
    after
      :sys.resume(domain)
    end

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :cancelled}}, @timeout
    assert {:ok, %{status: :cancelled}} = Server.activity(root, ref)
  end

  test "a coordinator that cannot answer is distinguishable from one with no work" do
    root = start_root()
    ref = start_activity(root)
    coordinator = activity_coordinator(root)
    assert :ok = :sys.suspend(coordinator)

    try do
      assert {:error, :activity_owner_unavailable} = Server.activities(root)
      assert :queued = GenServer.call(root, {:signal, ref, :wake, [on_result: :control]})
      assert_receive {:control_result, {:error, :activity_owner_unavailable}}, @timeout
    after
      :sys.resume(coordinator)
    end

    assert {:ok, [%{ref: ^ref, status: :running}]} = Server.activities(root)
  end

  test "an invalid terminal callback fails its Activity before executing a queued response" do
    root = start_root()
    ref = start_activity(root, :invalid_completion)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:failed, :activity_callback_failed}}},
                   @timeout

    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout
    refute_receive {Server, _, {:response, _, "uncommitted response", _}}
  end

  test "a supervised Root restarts and completes its existing Activity by the same reference" do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    options = [subject: Spectre.Identity.uuid7(), consumer: self(), init_arg: self()]
    assert {:ok, original} = Spectre.Supervisor.summon(supervisor, Agent, options)
    assert_receive {:root_ready, ^original}, @timeout
    ref = start_activity(original)

    monitor = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^original, :killed}, @timeout
    assert_receive {:root_ready, replacement}, @timeout
    refute original == replacement

    assert {:ok, %{ref: ^ref, status: :running}} = Server.activity(replacement, ref)
    assert {:ok, _} = Server.signal_activity(replacement, ref, {:revise, :recovered})

    assert_receive {Server, ^replacement, {:activity, %{ref: ^ref}, {:completed, :recovered}}},
                   @timeout

    refute_receive {Server, ^replacement, {:activity, %{ref: ^ref}, :started}}
  end

  for timing <- [:before_completion, :before_acknowledgement] do
    @timing timing
    test "a completion is replayed once when the Root crashes #{@timing}" do
      Process.register(self(), __MODULE__)
      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      options = [subject: Spectre.Identity.uuid7(), consumer: self(), init_arg: self()]
      assert {:ok, original} = Spectre.Supervisor.summon(supervisor, Agent, options)
      assert_receive {:root_ready, ^original}, @timeout
      ref = start_activity(original, :waiting, as: :report)
      coordinator = activity_coordinator(original)
      child = hold_completion(original, ref, "completed offline")

      assert :ok = :sys.suspend(supervisor)

      try do
        if @timing == :before_acknowledgement, do: :ok = :sys.suspend(original)
        crash_root(original, @timing, :before_completion)
        send(child, :complete_activity)

        assert eventually(fn ->
                 match?({:ok, %{status: :completed}}, Activities.view(coordinator, ref))
               end)

        crash_root(original, @timing, :before_acknowledgement)
      after
        :sys.resume(supervisor)
      end

      assert_receive {:root_ready, replacement}, @timeout
      refute original == replacement

      assert_receive {Server, ^replacement,
                      {:activity, %{ref: ^ref, status: :completed},
                       {:completed, "completed offline"}}},
                     @timeout

      assert_receive {:handled_activity, ^ref, :report, {:completed, "completed offline"}},
                     @timeout

      refute_receive {:handled_activity, ^ref, :report, {:completed, _}}
      refute_received {Server, _, {:activity, %{ref: ^ref}, {:completed, _}}}
    end
  end

  test "a completion while a revision fence is pending retains the terminal report" do
    Process.register(self(), __MODULE__)
    root = start_root()
    ref = start_activity(root)
    coordinator = activity_coordinator(root)
    child = hold_completion(root, ref, "report before the fence")
    child_monitor = Process.monitor(child)
    %{managed_owner: managed} = :sys.get_state(root)
    %{domain: domain} = :sys.get_state(managed)

    assert :ok = :sys.suspend(domain)

    request =
      try do
        assert {:ok, request} = Server.signal_activity(root, ref, {:revise, "new instructions"})

        assert eventually(fn ->
                 :sys.get_state(coordinator).entries[ref].transition == request
               end)

        send(child, :complete_activity)
        assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, @timeout

        assert eventually(fn ->
                 match?({:ok, %{pid: nil}}, Activities.lookup(coordinator, ref))
               end)

        request
      after
        :sys.resume(domain)
      end

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref, status: :completed},
                     {:completed, "report before the fence"}}},
                   @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:signalled, ^request, {:error, :inactive_activity}}}},
                   @timeout

    refute_received {Server, ^root, {:activity, %{ref: ^ref}, {:failed, :normal}}}
  end

  test "a completion from before a committed revision is reported as superseded" do
    Process.register(self(), __MODULE__)
    root = start_root()
    ref = start_activity(root)
    assert {:ok, %{revision: previous}} = Server.activity(root, ref)
    revision = previous + 1
    child = hold_completion(root, ref, "obsolete report")

    assert {:ok, request} = Server.signal_activity(root, ref, {:revise, "revised report"})

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref, revision: ^revision},
                     {:signalled, ^request, {:ok, _}}}},
                   @timeout

    send(child, :complete_activity)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref, revision: ^revision, status: :running},
                     {:superseded, ^previous, {:completed, "obsolete report"}}}},
                   @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref, status: :completed}, {:completed, "revised report"}}},
                   @timeout

    refute_received {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "obsolete report"}}}
  end

  test "an Activity uses its Agent's compiled tool and handles failures by default" do
    root = start_root()
    assert :queued = GenServer.call(root, {:work, {:read, "D12"}, []})
    assert_receive {Server, ^root, {:activity, %{ref: first}, :started}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^first}, {:completed, "D12"}}}, @timeout

    assert :queued = GenServer.call(root, {:work, {:read, :reject}, []})
    assert_receive {Server, ^root, {:activity, %{ref: second}, :started}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^second}, {:failed, _}}}, @timeout
  end

  test "an Activity cannot widen the host's tool scope" do
    root = start_root(activity_tools: [])
    assert :queued = GenServer.call(root, {:work, {:read, "D12"}, [scope: :all]})
    assert_receive {Server, ^root, {:activity, %{ref: ref}, :started}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, _}}}, @timeout
  end

  test "a parent's child permission is restricted by the host's Activity allowlist" do
    root = start_root(activities: [:research])
    parent = start_activity(root, :spawn)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^parent}, {:failed, :activity_not_allowed}}},
                   @timeout

    assert {:ok, [%{ref: ^parent, status: :failed}]} = Server.activities(root)
  end

  test "an Activity can control its child while sibling references remain outside its scope" do
    root = start_root()
    sibling = start_activity(root)
    parent = start_activity(root, :spawn)

    assert_receive {Server, ^root, {:activity, %{ref: child, parent: ^parent}, :started}},
                   @timeout

    assert {:ok, _} = Server.signal_activity(root, parent, {:cancel_child, child})
    assert_receive {Server, ^root, {:activity, %{ref: ^child}, :cancelled}}, @timeout

    assert {:ok, _} = Server.signal_activity(root, parent, {:cancel_child, sibling})

    assert_receive {Server, ^root, {:activity, %{ref: ^parent}, {:failed, :unknown_activity}}},
                   @timeout

    assert {:ok, %{status: :running}} = Server.activity(root, sibling)
  end

  test "a declaration can opt into children while an ordinary Activity cannot spawn one" do
    root = start_root()
    assert :queued = GenServer.call(root, {:work, :subtask, :spawn, [on_result: :started]})
    assert_receive {:start_result, {:ok, %{ref: restricted}}}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^restricted}, {:failed, :activity_children_not_allowed}}},
                   @timeout

    assert :queued = GenServer.call(root, {:work, :all_children, :spawn, [on_result: :started]})
    assert_receive {:start_result, {:ok, %{ref: parent}}}, @timeout
    assert_receive {Server, ^root, {:activity, %{parent: ^parent}, :started}}, @timeout
  end

  test "a request scope can only narrow the host tool scope" do
    root = start_root(activity_tools: [{:documents, :read}])
    ref = start_activity(root, {:read, "D12"}, scope: [{:documents, :publish}])

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:failed,
                      {:tool_rejected, {:documents, :read}, :read, :activity_tool_not_allowed}}}},
                   @timeout
  end

  test "an invalid host activity allowlist refuses startup without creating work" do
    root = start_root(activities: :unrestricted)
    assert :queued = GenServer.call(root, {:work, :waiting, [on_result: :started]})
    assert_receive {:start_result, {:error, :activity_not_allowed}}, @timeout
    assert {:ok, []} = Server.activities(root)
  end

  test "an Activity's pending approval cannot admit an effect after revision" do
    root = start_publication_root()
    ref = start_activity(root, {:publish, "D12"})
    presentation = presentation_ref()

    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout

    present(root, ref, presentation)
    revise_activity(root, ref)

    assert {:error, :superseded} = Server.decide(root, nil, presentation, :confirm)
    child = activity_pid(root, ref)
    monitor = Process.monitor(child)
    assert {:ok, _} = Server.cancel_activity(root, ref)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :cancelled}}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^child, :normal}, @timeout
    assert [] = publication_outcomes(root)
  end

  test "a timed out Activity consent decision can still be applied" do
    root = start_publication_root()
    ref = start_activity(root, {:publish, "D12"})
    presentation = presentation_ref()
    present(root, ref, presentation)

    child = activity_pid(root, ref)
    assert :ok = :sys.suspend(child)

    try do
      assert {:error, :decision_outcome_unknown} =
               Server.decide(root, nil, presentation, :confirm)
    after
      :sys.resume(child)
    end

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:completed, :ordinary_publication}}},
                   @timeout

    assert [%{status: :succeeded}] = publication_outcomes(root)
  end

  test "the revised Activity observes the effect admitted before a revision" do
    Process.register(self(), __MODULE__)
    root = start_publication_root()
    ref = start_activity(root, {:publish, "held"})
    presentation = presentation_ref()
    present(root, ref, presentation)

    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:publication_started, executor}, @timeout
    on_exit(fn -> send(executor, :release_publication) end)

    %{workers: workers} = :sys.get_state(activity_pid(root, ref))

    assert [%{command_id: id}] =
             for({_, %{kind: :confirm_pending} = worker} <- workers, do: worker)

    %{managed_owner: managed} = :sys.get_state(root)
    %{journal: journal} = :sys.get_state(managed)
    key = {:spectre_gam_command, id}
    assert {:ok, _} = Store.fetch(journal, key)

    revise_activity(root, ref)
    send(executor, :release_publication)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:effect, {:governed, _}}}}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:completed, :observed_publication}}},
                   @timeout

    refute_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, :ordinary_publication}}}
    assert [%{status: :succeeded}] = publication_outcomes(root)
    assert eventually(fn -> Store.fetch(journal, key) == :not_found end)
  end

  for termination <- [:cancel, :crash, :unaccepted_result] do
    @termination termination
    test "the Root receives an admitted outcome after Activity #{@termination}" do
      Process.register(self(), __MODULE__)
      root = start_publication_root()
      ref = start_activity(root, {:publish, "held"})
      presentation = presentation_ref()
      present(root, ref, presentation)
      assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
      assert_receive {:publication_started, executor}, @timeout
      on_exit(fn -> send(executor, :release_publication) end)

      child = activity_pid(root, ref)
      child_monitor = Process.monitor(child)
      terminal = terminate_activity(@termination, root, ref, child, executor)
      assert_receive {Server, ^root, {:activity, %{ref: ^ref}, ^terminal}}, @timeout

      send(executor, :release_publication)

      assert_receive {Server, ^root,
                      {:activity, %{ref: ^ref},
                       {:effect, {:governed, %{outcome: %{ref: outcome_ref, status: :succeeded}}}}}},
                     @timeout

      assert_receive {:DOWN, ^child_monitor, :process, ^child, _}, @timeout
      assert [%{ref: ^outcome_ref, status: :succeeded}] = publication_outcomes(root)
      refute_receive {Server, ^root, {:activity, %{ref: ^ref}, {:effect, {:governed, _}}}}
      refute_received {:publication_started, _}
    end
  end

  test "a lost bridge outcome preserves the cancelled Activity checkpoint" do
    Process.register(self(), __MODULE__)
    root = start_publication_root()
    ref = start_activity(root, {:publish, "held_external"})
    presentation = presentation_ref()
    present(root, ref, presentation)
    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:publication_started, executor}, @timeout
    on_exit(fn -> send(executor, :release_publication) end)

    child = activity_pid(root, ref)
    %{opts: opts, workers: workers} = :sys.get_state(child)

    assert [%{pid: bridge, command_id: command_id}] =
             for({_, %{kind: :confirm_pending} = worker} <- workers, do: worker)

    {store, owner, key} = Keyword.fetch!(opts, :checkpoint)
    assert {:ok, _} = store.fetch(owner, key)
    refute executor == bridge
    Process.exit(bridge, :kill)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:effect, {:governed_unknown, %{command_id: ^command_id}}}}},
                   @timeout

    assert Process.alive?(executor)
    send(executor, :release_publication)
    child_monitor = Process.monitor(child)
    assert {:ok, _} = Server.cancel_activity(root, ref)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :cancelled}}, @timeout
    assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, @timeout

    # Retirement runs asynchronously after the Coordinator sees the child exit.
    refute eventually(
             fn -> store.fetch(owner, key) == :not_found end,
             System.monotonic_time(:millisecond) + 150
           )

    assert {:ok, _} = store.fetch(owner, key)
  end

  @tag :tmp_dir
  test "terminal eviction retires the old Activity fence from durable storage", %{tmp_dir: path} do
    root =
      start_root(identity: %{subject: Spectre.Identity.uuid7()}, gam: [storage: {:disk, path}])

    first = start_activity(root)
    :sys.replace_state(activity_coordinator(root), &%{&1 | terminal_limit: 1})

    %{managed_owner: owner} = :sys.get_state(root)
    %{domain: domain, refs: %{domain: domain_ref}} = :sys.get_state(owner)
    %{activity_fence: {_token, store}} = :sys.get_state(domain)
    first_fence = {:spectre_activity_fence, domain_ref, first}

    assert {:ok, _} = Server.cancel_activity(root, first)
    assert_receive {Server, ^root, {:activity, %{ref: ^first}, :cancelled}}, @timeout
    assert {:ok, _} = Store.fetch(store, first_fence)

    second = start_activity(root)
    assert {:ok, _} = Server.cancel_activity(root, second)
    assert_receive {Server, ^root, {:activity, %{ref: ^second}, :cancelled}}, @timeout

    assert {:error, :unknown_activity} = Server.activity(root, first)
    assert eventually(fn -> Store.fetch(store, first_fence) == :not_found end)
    assert {:ok, _} = Store.fetch(store, {:spectre_activity_fence, domain_ref, second})
  end

  for mode <- [:retry, :memory] do
    @mode mode
    @tag :tmp_dir
    test "#{mode} storage recovery reports running Activities that it closes", %{tmp_dir: path} do
      root =
        start_root(
          identity: %{subject: Spectre.Identity.uuid7()},
          gam: [storage: {:disk, path}]
        )

      first = start_activity(root, :waiting, as: :monthly_report)
      second = start_activity(root)
      children = for ref <- [first, second], do: activity_pid(root, ref)
      monitors = for child <- children, do: Process.monitor(child)

      assert :ok = Server.recover_storage(root, @mode)
      assert_receive {Server, ^root, {:storage_recovered, _}}, @timeout

      for ref <- [first, second] do
        assert_receive {Server, ^root,
                        {:activity, %{ref: ^ref, status: :failed},
                         {:failed, :gam_storage_recovered}}},
                       @timeout

        assert {:ok, %{status: :failed}} = Server.activity(root, ref)
      end

      for monitor <- monitors do
        assert_receive {:DOWN, ^monitor, :process, _, _}, @timeout
      end

      replacement = start_activity(root, :waiting, as: :monthly_report)
      refute replacement == first
      assert {:ok, %{status: :running}} = Server.activity(root, replacement)

      assert {:ok, request} =
               Server.signal_activity(root, replacement, {:revise, "recovered report"})

      assert_receive {Server, ^root,
                      {:activity, %{ref: ^replacement}, {:signalled, ^request, {:ok, _}}}},
                     @timeout

      assert_receive {Server, ^root,
                      {:activity, %{ref: ^replacement, status: :completed},
                       {:completed, "recovered report"}}},
                     @timeout
    end
  end

  test "the Root serves ordinary turns during consent relay and reports child loss" do
    root = start_publication_root()
    ref = start_activity(root, {:publish, "D12"})
    presentation = presentation_ref()
    present(root, ref, presentation)

    child = activity_pid(root, ref)
    monitor = Process.monitor(child)
    assert :ok = :sys.suspend(child)

    request =
      try do
        request =
          :gen_server.send_request(root, {Runtime, :decide, nil, presentation, :confirm})

        assert {:ok, turn} = Server.input(root, "ping")
        assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout
        request
      after
        Process.exit(child, :kill)
      end

    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}, @timeout

    assert {:reply, {:error, :activity_unavailable}} =
             :gen_server.wait_response(request, @timeout)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, :killed}}}, @timeout
    assert [] = publication_outcomes(root)
  end

  test "reset closes an old Activity's pending presentation and releases its name" do
    root = start_publication_root()
    assert %{session: previous_session} = Server.status(root)
    ref = start_activity(root, {:publish, "D12"}, as: :monthly_report)
    presentation = presentation_ref()
    present(root, ref, presentation)

    child = activity_pid(root, ref)
    monitor = Process.monitor(child)

    assert :ok = reset_when_idle(root, System.monotonic_time(:millisecond) + @timeout)
    assert_receive {:DOWN, ^monitor, :process, ^child, _}, @timeout
    assert %{session: session} = Server.status(root)
    refute session == previous_session

    assert {:error, :stale_presentation} = Server.decide(root, nil, presentation, :confirm)
    assert {:error, :unknown_activity} = Server.activity(root, ref)
    assert [] = publication_outcomes(root)

    replacement = start_activity(root, :waiting, as: :monthly_report)
    refute replacement == ref
    assert {:ok, %{ref: ^replacement, status: :running}} = Server.activity(root, :monthly_report)
  end

  test "activity inspection and control use the authenticated caller boundary" do
    root = start_root()
    ref = start_activity(root)

    assert [{:error, _}, {:error, _}, {:error, _}, {:error, _}] =
             Task.async(fn ->
               [
                 Server.activities(root),
                 Server.activity(root, ref),
                 Server.signal_activity(root, ref, {:revise, "untrusted"}),
                 Server.cancel_activity(root, ref)
               ]
             end)
             |> Task.await(@timeout)

    assert {:ok, %{status: :running}} = Server.activity(root, ref)
  end

  defp start_root(overrides \\ []) do
    options = Keyword.merge([agent: Agent, init_arg: self(), consumer: self()], overrides)
    start_supervised!({Server, options})
  end

  defp start_publication_root do
    start_root(
      identity: %{subject: Spectre.Identity.uuid7()},
      gam: [operations: %{publish: [class: @publication_class, confirm: true]}]
    )
  end

  defp activity_pid(root, ref) do
    coordinator = activity_coordinator(root)
    assert {:ok, %{status: :running, pid: pid}} = Activities.lookup(coordinator, ref)
    pid
  end

  defp activity_coordinator(root) do
    %{activity_connection: {coordinator, _control}} = :sys.get_state(root)
    coordinator
  end

  defp hold_completion(root, ref, report) do
    assert {:ok, _} = Server.signal_activity(root, ref, {:hold_completion, report})
    assert_receive {:completion_ready, child}, @timeout
    child
  end

  defp crash_root(root, timing, timing) do
    monitor = Process.monitor(root)
    Process.exit(root, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^root, :killed}, @timeout
  end

  defp crash_root(_root, _timing, _phase), do: :ok

  defp terminate_activity(:cancel, root, ref, _child, _executor) do
    assert {:ok, _} = Server.cancel_activity(root, ref)
    :cancelled
  end

  defp terminate_activity(:crash, _root, _ref, child, _executor) do
    Process.exit(child, :kill)
    {:failed, :killed}
  end

  defp terminate_activity(:unaccepted_result, _root, _ref, child, executor) do
    assert :ok = :sys.suspend(child)

    try do
      send(executor, :release_publication)

      assert eventually(fn ->
               {:messages, messages} = Process.info(child, :messages)
               Enum.any?(messages, &match?({Runtime, _, :result, {:governed, _}}, &1))
             end)
    after
      Process.exit(child, :kill)
    end

    {:failed, :killed}
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + @timeout) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, deadline)
    end
  end

  defp reset_when_idle(root, deadline) do
    case Server.reset(root, timeout: @timeout) do
      {:error, :reset_busy} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          reset_when_idle(root, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  defp publication_outcomes(root) do
    assert {:ok, %{acts: acts, outcomes: outcomes}} = Server.gam_view(root)
    act_refs = for %{class: @publication_class, ref: ref} <- acts, do: ref
    Enum.filter(outcomes, &(&1.act_ref in act_refs))
  end

  defp presentation_ref do
    assert_receive {Server.GAM.Managed, _owner, {:presentation, material}}, @timeout
    Map.fetch!(material, "presentation_ref")
  end

  defp present(root, activity, presentation) do
    assert :ok = Server.presented(root, presentation)

    assert_receive {Server, ^root, {:activity, %{ref: ^activity}, {:pending, ^presentation}}},
                   @timeout
  end

  defp revise_activity(root, ref) do
    assert {:ok, request} = Server.signal_activity(root, ref, {:revise, "updated"})

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^request, {:ok, _}}}},
                   @timeout
  end

  defp start_activity(root, args \\ :waiting, opts \\ []) do
    assert :queued = GenServer.call(root, {:work, args, Keyword.put(opts, :on_result, :started)})

    assert_receive {:start_result, {:ok, %{ref: ref}}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :started}}, @timeout
    ref
  end
end
