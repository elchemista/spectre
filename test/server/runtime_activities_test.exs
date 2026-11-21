defmodule Spectre.Server.RuntimeActivitiesTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.{Activities, Runtime}

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
    def execute_effect(:publish, %{id: "held"}, _context) do
      send(Spectre.Server.RuntimeActivitiesTest, {:publication_started, self()})

      receive do
        :release_publication -> {:ok, %{published: "held"}}
      after
        5_000 -> {:error, :ambiguous, :publication_wait_expired}
      end
    end

    def execute_effect(:publish, %{id: id}, _context), do: {:ok, %{published: id}}
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

    assert_receive {Server, ^root, {:activity, %{ref: ^parent}, {:failed, :inactive_activity}}},
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

  test "the revised Activity observes the effect admitted before a revision" do
    Process.register(self(), __MODULE__)
    root = start_publication_root()
    ref = start_activity(root, {:publish, "held"})
    presentation = presentation_ref()
    present(root, ref, presentation)

    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:publication_started, executor}, @timeout
    on_exit(fn -> send(executor, :release_publication) end)

    revise_activity(root, ref)
    send(executor, :release_publication)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:effect, {:governed, _}}}}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:completed, :observed_publication}}},
                   @timeout

    refute_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, :ordinary_publication}}}
    assert [%{status: :succeeded}] = publication_outcomes(root)
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
    %{activity_connection: {coordinator, _control}} = :sys.get_state(root)
    assert {:ok, %{status: :running, pid: pid}} = Activities.lookup(coordinator, ref)
    pid
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
