defmodule SpectreInstanceContractTest.Renderer do
  @moduledoc false

  def render(prompt, input, ctx) do
    test_pid = Keyword.get(ctx.opts, :test_pid)

    if test_pid do
      send(test_pid, {:instance_render_started, input.text, self()})
    end

    if input.text == "slow reply" or Keyword.get(ctx.opts, :block_renderer?, false) do
      receive do
        :finish_render -> :ok
      end
    end

    "#{prompt}:#{input.text}"
  end
end

defmodule SpectreInstanceContractTest.InputPlug do
  @moduledoc false
  @behaviour Spectre.Input.Plug

  @impl Spectre.Input.Plug
  def init(opts), do: opts

  @impl Spectre.Input.Plug
  def call(input, %{opts: opts}, _state) do
    test_pid = Keyword.get(opts, :test_pid)

    if test_pid && Keyword.get(opts, :block_input?, false) do
      send(test_pid, {:instance_input_blocked, input.text, self()})

      receive do
        :finish_input -> :ok
      end
    end

    if test_pid && Keyword.get(opts, :report_state?, false) do
      state = Keyword.fetch!(opts, :state)
      send(test_pid, {:instance_input_state_seen, input.text, state.revision})
    end

    {:cont, input}
  end
end

defmodule SpectreInstanceContractTest.TurnHandler do
  @moduledoc false
  @behaviour Spectre.Turn.Handler

  alias Spectre.Turn.Handler.Reply

  @impl Spectre.Turn.Handler
  def handle_turn(%{input: %{text: "silent"}}, _opts), do: {:reply, Reply.new("")}
  def handle_turn(_request, _opts), do: :cont
end

defmodule SpectreInstanceContractTest.Actions do
  @moduledoc false

  def work(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:instance_action, :work, args})
    {:ok, "worked"}
  end

  def slow(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:instance_slow_action_started, self()})
    end

    receive do
      :finish_action -> {:ok, args}
    end
  end
end

defmodule SpectreInstanceContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  input_pipeline([{SpectreInstanceContractTest.InputPlug, []}])
  turn_handler(SpectreInstanceContractTest.TurnHandler)

  actions SpectreInstanceContractTest.Actions do
    protect(:work, with: :confirmation)
  end

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :instance_contract do
    on :HELLO, regex: ~r/^hello$/i do
      reply(:hello, renderer: {SpectreInstanceContractTest.Renderer, :render})
    end

    on :SLOW_REPLY, regex: ~r/^slow reply$/i do
      reply(:slow_reply, renderer: {SpectreInstanceContractTest.Renderer, :render})
    end

    on :SLOW_ACTION, regex: ~r/^slow action$/i do
      action(:slow, args: %{source: :instance})
    end

    on :WORK, regex: ~r/^work$/i do
      action(:work,
        args: %{source: :instance},
        reply: :approval,
        renderer: {SpectreInstanceContractTest.Renderer, :render}
      )
    end
  end
end

defmodule SpectreInstanceContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Instance
  alias Spectre.Invocation.Receipt
  alias Spectre.Run.Ref
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn

  @agent SpectreInstanceContractTest.Agent

  test "concurrent ensure_started is atomic for AgentRef + Subject and isolates Subjects" do
    supervisor_name = SpectreInstanceContractTest.RaceSupervisor

    supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor_name})

    subject = Subject.new("race-subject-#{System.unique_integer([:positive])}")

    results =
      1..64
      |> Task.async_stream(
        fn _index ->
          Spectre.instance(supervisor, @agent, subject, idle: false)
        end,
        max_concurrency: 64,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, pid} when is_pid(pid), &1))
    pids = results |> Enum.map(fn {:ok, pid} -> pid end) |> Enum.uniq()
    assert [instance] = pids

    assert {:ok, ^instance} = Spectre.lookup_instance(@agent, subject)

    assert {:ok, ^instance} =
             Spectre.instance(supervisor, @agent, subject,
               id: {:ordinary_child_option, System.unique_integer([:positive])},
               idle: false
             )

    other_subject = Subject.new("other-subject-#{System.unique_integer([:positive])}")

    assert {:ok, other_instance} =
             Spectre.instance(supervisor, @agent, other_subject, idle: false)

    assert other_instance != instance
    assert Instance.ref(instance).subject == subject
    assert Instance.ref(other_instance).subject == other_subject
  end

  test "public turns stop at their boundary while the Instance retains and completes each Run" do
    instance = start_instance()

    assert {:ok, %Turn{} = turn} =
             Spectre.turn(instance, "hello", test_pid: self())

    assert {:reply, "hello:hello", %Ref{} = ref} = turn.observable
    assert turn.ref == ref
    assert turn.agent == instance
    refute Map.has_key?(Map.from_struct(turn), :run)
    assert_receive {:instance_render_started, "hello", _worker}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, ref.run_id))
    end)

    assert {:error, {:instance_run_terminal, _, :complete}} =
             Spectre.resume(instance, ref, {:policy, ref, :ignored})

    assert %State{revision: 1, conversation_id: conversation_id} =
             Spectre.state(instance)

    assert conversation_id == Instance.ref(instance).key
  end

  test "one Subject keeps a stable state scope while tracking several channel conversations" do
    instance = start_instance()

    first =
      Input.new(%{
        text: "hello",
        source:
          Source.new(
            kind: :telegram,
            mount: "primary",
            conversation_id: "telegram-chat-42"
          )
      })

    second =
      Input.new(%{
        text: "hello",
        source:
          Source.new(
            kind: :web,
            mount: "primary",
            conversation_id: "browser-session-99"
          )
      })

    same_provider_id_on_another_mount =
      Input.new(%{
        text: "hello",
        source:
          Source.new(
            kind: :telegram,
            mount: "secondary",
            conversation_id: "telegram-chat-42"
          )
      })

    assert {:ok, %Turn{}} = Spectre.turn(instance, first)
    assert {:ok, %Turn{}} = Spectre.turn(instance, second)
    assert {:ok, %Turn{}} = Spectre.turn(instance, same_provider_id_on_another_mount)

    info = Instance.info(instance)
    assert map_size(info.conversations) == 3

    assert Enum.sort(Enum.map(info.conversations, fn {_key, value} -> value.channel end)) ==
             [:telegram, :telegram, :web]

    assert info.conversations
           |> Enum.map(fn {_key, value} -> value.mount end)
           |> Enum.sort() == ["primary", "primary", "secondary"]

    assert Enum.all?(info.conversations, fn {key, value} ->
             String.starts_with?(key, "conversation:") and value.key == key and value.count == 1
           end)

    state_scope = Instance.ref(instance).key
    assert %State{conversation_id: ^state_scope, revision: 3} = Spectre.state(instance)
  end

  test "logical AgentRefs sharing one definition retain independent state scopes" do
    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: SpectreInstanceContractTest.AgentRefScopeSupervisor}
      )

    subject = Subject.new("shared-agent-ref-subject")
    first_ref = Spectre.AgentRef.new(@agent, id: "logical-agent-a")
    second_ref = Spectre.AgentRef.new(@agent, id: "logical-agent-b")

    assert {:ok, first} =
             Spectre.instance(supervisor, first_ref, subject, idle: false)

    assert {:ok, second} =
             Spectre.instance(supervisor, second_ref, subject, idle: false)

    assert first != second
    assert Spectre.state(first).conversation_id == Instance.ref(first).key
    assert Spectre.state(second).conversation_id == Instance.ref(second).key
    refute Spectre.state(first).conversation_id == Spectre.state(second).conversation_id
  end

  test "custom process names cannot bypass AgentRef + Subject uniqueness" do
    subject = Subject.new("custom-name-subject")

    assert_raise ArgumentError, ~r/custom :name is not supported/, fn ->
      Instance.start_link(agent: @agent, subject: subject, name: :bypass)
    end
  end

  test "Run start is reserved before normalization and never blocks the Instance mailbox" do
    instance = start_instance()
    test_pid = self()

    request =
      Task.async(fn ->
        Spectre.turn(instance, "hello",
          run_id: "reserved-start",
          block_input?: true,
          test_pid: test_pid
        )
      end)

    assert_receive {:instance_input_blocked, "hello", input_worker}, 1_000

    assert %{active_run: "reserved-start", state_revision: 0} = Instance.info(instance)

    assert {:error, {:duplicate_instance_run, "reserved-start"}} =
             Spectre.turn(instance, "hello", run_id: "reserved-start")

    send(input_worker, :finish_input)

    assert {:ok, %Turn{observable: {:reply, "hello:hello", _ref}}} =
             Task.await(request, 5_000)

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, "reserved-start"))
    end)
  end

  test "a failed start is terminal and cannot exhaust bounded Run capacity" do
    subject = Subject.new("failed-start-capacity")

    instance =
      start_supervised!(
        {Instance,
         agent: @agent,
         subject: subject,
         id: {:failed_start_capacity, System.unique_integer([:positive])},
         idle: false,
         max_runs: 1,
         max_tombstones: 1}
      )

    assert {:error, {:invalid_input_pipeline, :invalid}} =
             Spectre.turn(instance, "hello",
               run_id: "invalid-start",
               input_pipeline: :invalid
             )

    assert {:ok, %{status: :failed}} = Instance.run(instance, "invalid-start")
    assert {:ok, %Turn{}} = Spectre.turn(instance, "hello", run_id: "valid-after-failure")
  end

  test "terminal Runs are compacted into bounded tombstones at capacity" do
    subject = Subject.new("bounded-history-subject")

    instance =
      start_supervised!(
        {Instance,
         agent: @agent,
         subject: subject,
         id: {:bounded_history, System.unique_integer([:positive])},
         idle: false,
         max_runs: 1,
         max_tombstones: 1}
      )

    assert {:ok, %Turn{ref: first_ref}} = Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, first_ref))
    end)

    assert {:ok, %Turn{ref: second_ref}} = Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, second_ref))
    end)

    assert {:ok, %{status: :complete}} = Instance.run(instance, first_ref)

    assert {:ok, %Turn{ref: third_ref}} = Spectre.turn(instance, "hello")

    assert_eventually(fn ->
      match?({:ok, %{status: :complete}}, Instance.run(instance, third_ref))
    end)

    info = Instance.info(instance)
    assert map_size(info.runs) == 1
    assert map_size(info.tombstones) == 1
    assert {:error, :instance_run_not_found} = Instance.run(instance, first_ref)
    assert {:ok, %{status: :complete}} = Instance.run(instance, second_ref)
  end

  test "ready Runs are FIFO and the mailbox stays responsive during a slow Move" do
    instance = start_instance()
    test_pid = self()

    slow =
      Task.async(fn ->
        Spectre.turn(instance, "slow reply", test_pid: test_pid)
      end)

    assert_receive {:instance_render_started, "slow reply", slow_worker}, 1_000

    fast =
      Task.async(fn ->
        Spectre.turn(instance, "hello",
          test_pid: test_pid,
          report_state?: true
        )
      end)

    assert_eventually(fn ->
      info = Instance.info(instance)
      not is_nil(info.active_run) and length(info.ready) == 1
    end)

    info = Instance.info(instance)
    assert is_binary(info.active_run)
    assert length(info.ready) == 1
    refute Task.yield(fast, 0)

    send(slow_worker, :finish_render)

    assert {:ok, %Turn{observable: {:reply, "slow_reply:slow reply", _ref}}} =
             Task.await(slow, 5_000)

    assert_receive {:instance_render_started, "hello", _fast_worker}, 1_000
    assert_receive {:instance_input_state_seen, "hello", 1}

    assert {:ok, %Turn{observable: {:reply, "hello:hello", _ref}}} =
             Task.await(fast, 5_000)

    assert_eventually(fn ->
      info = Instance.info(instance)
      Enum.all?(info.runs, fn {_id, run} -> run.status == :complete end)
    end)

    assert Spectre.state(instance).revision == 2
  end

  test "internal reply completion never rolls shared State back" do
    instance = start_instance()
    test_pid = self()

    visible =
      Task.async(fn ->
        Spectre.turn(instance, "slow reply", test_pid: test_pid)
      end)

    assert_receive {:instance_render_started, "slow reply", renderer_worker}, 1_000

    silent = Task.async(fn -> Spectre.turn(instance, "silent") end)

    assert_eventually(fn ->
      Instance.info(instance).ready != []
    end)

    send(renderer_worker, :finish_render)

    assert {:ok, %Turn{observable: {:reply, "slow_reply:slow reply", _ref}}} =
             Task.await(visible, 5_000)

    assert {:ok, %Turn{observable: {:reply, nil, _ref}}} =
             Task.await(silent, 5_000)

    assert_eventually(fn ->
      Spectre.state(instance).revision == 2 and
        Enum.all?(Instance.info(instance).runs, fn {_id, run} ->
          run.status == :complete
        end)
    end)
  end

  test "a queued caller proceeds when another Run opens an Effect boundary" do
    instance = start_instance()
    test_pid = self()

    owner =
      Task.async(fn ->
        Spectre.turn(instance, "work",
          block_renderer?: true,
          test_pid: test_pid
        )
      end)

    assert_receive {:instance_render_started, "work", renderer_worker}, 1_000

    blocked = Task.async(fn -> Spectre.turn(instance, "hello") end)

    assert_eventually(fn ->
      Instance.info(instance).ready != []
    end)

    send(renderer_worker, :finish_render)

    assert {:ok, %Turn{observable: {:needs, _boundary}} = needs} =
             Task.await(owner, 5_000)

    assert {:ok, %Turn{observable: {:reply, "hello:hello", blocked_ref}}} =
             Task.await(blocked, 5_000)

    refute blocked_ref.run_id == needs.ref.run_id
  end

  test "an abnormally terminated worker fences and terminalizes its Run" do
    instance = start_instance()
    test_pid = self()

    request =
      Task.async(fn ->
        Spectre.turn(instance, "slow reply", test_pid: test_pid)
      end)

    assert_receive {:instance_render_started, "slow reply", renderer_worker}, 1_000
    %{active_run: run_id} = Instance.info(instance)
    move_worker = :sys.get_state(instance).active.pid
    Process.exit(move_worker, :kill)
    send(renderer_worker, :finish_render)

    assert {:error, {:instance_worker_down, :advance, :killed}} =
             Task.await(request, 5_000)

    assert {:ok,
            %{
              status: :failed,
              cursor: :complete,
              revision: revision,
              waiting: nil
            }} = Instance.run(instance, run_id)

    assert revision > 0
  end

  test "Invocation work is correlated, non-blocking, fenced, and repeat-safe" do
    instance = start_instance()

    assert {:ok, %Turn{observable: {:awaiting, %Ref{} = invocation_ref}} = awaiting} =
             Spectre.turn(instance, "slow action", test_pid: self())

    assert {:error, :instance_busy} = Spectre.reset(instance, %State{})

    stale_ref = %{invocation_ref | revision: invocation_ref.revision + 1}

    assert {:error, {:stale_instance_run_reference, _, _, _}} =
             Spectre.resume(instance, stale_ref, {:execute, stale_ref}, test_pid: self())

    test_pid = self()

    execution =
      Task.async(fn ->
        Spectre.resume(
          instance,
          awaiting.ref,
          {:execute, awaiting.ref},
          test_pid: test_pid
        )
      end)

    assert_receive {:instance_slow_action_started, action_worker}

    info = Instance.info(instance)
    assert map_size(info.invocations) == 1
    [{invocation_id, ownership}] = Map.to_list(info.invocations)
    assert ownership.run_id == invocation_ref.run_id
    refute Map.has_key?(ownership, :dispatch_id)

    forged = %Receipt{
      invocation_id: invocation_id,
      run_id: ownership.run_id,
      run_revision: ownership.run_revision,
      generation: info.generation,
      dispatch_id: "foreign-dispatch",
      capability: make_ref(),
      outcome: :forged
    }

    send(instance, {:spectre, :invocation_result, invocation_id, forged})
    assert map_size(Instance.info(instance).invocations) == 1

    queued = Task.async(fn -> Spectre.turn(instance, "hello") end)

    assert_eventually(fn -> Instance.info(instance).ready != [] end)
    refute Task.yield(queued, 0)

    send(action_worker, :finish_action)

    assert {:ok, %Turn{observable: {:reply, "%{source: :instance}", reply_ref}}} =
             Task.await(execution, 5_000)

    assert reply_ref.run_id == invocation_ref.run_id
    assert reply_ref.revision > invocation_ref.revision

    assert {:ok, %Turn{observable: {:reply, "hello:hello", queued_ref}}} =
             Task.await(queued, 5_000)

    refute queued_ref.run_id == invocation_ref.run_id

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :complete}},
        Instance.run(instance, invocation_ref.run_id)
      )
    end)

    revision = Spectre.state(instance).revision
    send(instance, {:spectre, :invocation_result, invocation_id, forged})
    Process.sleep(10)
    assert Spectre.state(instance).revision == revision

    assert {:error, {:instance_run_terminal, _, :complete}} =
             Spectre.resume(
               instance,
               invocation_ref,
               {:execute, invocation_ref},
               test_pid: self()
             )

    assert Spectre.reset(instance, %State{data: %{reset: true}}) == :ok
    assert Spectre.state(instance).data == %{reset: true}
  end

  test "legacy policy and execute calls target the exact retained Run" do
    instance = start_instance()

    assert {:ok, %Turn{observable: {:needs, _request}} = needs} =
             Spectre.turn(instance, "work")

    forged_result = %{
      needs.result
      | metadata: put_in(needs.result.metadata, [:run, :ref], nil)
    }

    assert {:error, :result_has_no_run_reference} =
             Spectre.resolve_policy(instance, forged_result, {:accept, :approved})

    resolutions =
      1..16
      |> Task.async_stream(
        fn _index ->
          Spectre.resolve_policy(instance, needs.result, {:accept, :approved})
        end,
        max_concurrency: 16,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    approved_results = for {:ok, result} <- resolutions, do: result
    rejected = for {:error, reason} <- resolutions, do: reason

    assert [approved] = approved_results
    assert length(rejected) == 15

    assert Enum.all?(rejected, fn reason ->
             reason == :run_already_active or
               match?({:stale_instance_run_reference, _}, reason)
           end)

    assert %Ref{kind: :invocation} = get_in(approved.metadata, [:run, :ref])

    assert {:ok, completed} =
             Spectre.execute(instance, approved, test_pid: self())

    assert_receive {:instance_action, :work, %{source: :instance}}
    assert completed.state.pending_effects == []

    assert {:ok, replayed} = Spectre.execute(instance, completed, test_pid: self())
    assert replayed.state == completed.state

    assert Enum.map(replayed.effects, &{&1.id, &1.status}) ==
             Enum.map(completed.effects, &{&1.id, &1.status})

    refute_receive {:instance_action, :work, _args}
  end

  test "execute does not stale a waiting Run while another ask is advancing" do
    instance = start_instance()

    assert {:ok, %Turn{decision: {:needs, _effect, _result}} = pending} =
             Spectre.turn(instance, "slow action")

    parent = self()

    advancing =
      Task.async(fn ->
        Spectre.turn(instance, "slow reply", test_pid: parent)
      end)

    assert_receive {:instance_render_started, "slow reply", renderer}, 1_000

    assert {:error, {:instance_busy, active_run_id}} =
             Spectre.execute(instance, pending.result, test_pid: self())

    assert active_run_id != pending.ref.run_id

    assert {:ok,
            %{
              status: :awaiting,
              waiting: :invocation,
              ref: %Ref{run_id: pending_run_id}
            }} = Instance.run(instance, pending.ref.run_id)

    assert pending_run_id == pending.ref.run_id

    send(renderer, :finish_render)
    assert {:ok, %Turn{decision: {:reply, _result}}} = Task.await(advancing, 5_000)

    # The caller reply and the Instance's scheduler bookkeeping are separate
    # messages. Wait until the completed advance has released the active slot
    # before asserting that the retained invocation can execute.
    assert_eventually(fn -> Instance.info(instance).active_run == nil end)

    execution =
      Task.async(fn ->
        Spectre.execute(instance, pending.result, test_pid: parent)
      end)

    assert_receive {:instance_slow_action_started, worker}, 1_000
    send(worker, :finish_action)

    assert {:ok, %Spectre.Result{state: %State{pending_effects: []}}} =
             Task.await(execution, 5_000)
  end

  test "ordinary turn input resumes the policy owner Run without opening a new Run" do
    instance = start_instance()

    assert {:ok, %Turn{observable: {:needs, _boundary}} = needs} =
             Spectre.turn(instance, "work")

    assert {:ok, %Turn{observable: {:awaiting, execution_ref}} = approved} =
             Spectre.turn(instance, "yes")

    assert approved.ref.run_id == needs.ref.run_id
    assert execution_ref.run_id == needs.ref.run_id
    assert map_size(Instance.info(instance).runs) == 1

    assert {:ok, %Turn{observable: {:reply, "worked", _reply_ref}}} =
             Spectre.resume(
               instance,
               execution_ref,
               {:execute, execution_ref},
               test_pid: self()
             )

    assert_receive {:instance_action, :work, %{source: :instance}}
  end

  test "policy and Effect lifecycle is owned independently by each conversation Run" do
    instance = start_instance()

    first =
      Input.new(%{
        text: "work",
        source:
          Source.new(
            kind: :telegram,
            mount: "primary",
            conversation_id: "shared-provider-id"
          )
      })

    second =
      Input.new(%{
        text: "work",
        source:
          Source.new(
            kind: :web,
            mount: "primary",
            conversation_id: "shared-provider-id"
          )
      })

    assert {:ok, %Turn{observable: {:needs, _}} = first_needs} =
             Spectre.turn(instance, first)

    assert {:ok, %Turn{observable: {:needs, _}} = second_needs} =
             Spectre.turn(instance, second)

    refute first_needs.ref.run_id == second_needs.ref.run_id

    state = Spectre.state(instance)

    assert state.pending_effects
           |> Enum.map(& &1.run_id)
           |> Enum.sort() ==
             Enum.sort([first_needs.ref.run_id, second_needs.ref.run_id])

    assert state.awaitables
           |> Enum.filter(&(&1.status == :open))
           |> Enum.map(& &1.run_id)
           |> Enum.sort() ==
             Enum.sort([first_needs.ref.run_id, second_needs.ref.run_id])

    assert {:error, {:ambiguous_instance_policy, ambiguous_runs}} =
             Spectre.turn(instance, "yes")

    assert Enum.sort(ambiguous_runs) ==
             Enum.sort([first_needs.ref.run_id, second_needs.ref.run_id])

    approve_first = %{first | text: "yes"}
    approve_second = %{second | text: "yes"}

    assert {:ok, %Turn{observable: {:awaiting, first_invocation}}} =
             Spectre.turn(instance, approve_first)

    assert first_invocation.run_id == first_needs.ref.run_id

    assert {:ok, %Turn{observable: {:awaiting, second_invocation}}} =
             Spectre.turn(instance, approve_second)

    assert second_invocation.run_id == second_needs.ref.run_id

    assert {:ok, %Turn{observable: {:reply, "worked", _}}} =
             Spectre.resume(
               instance,
               first_invocation,
               {:execute, first_invocation},
               test_pid: self()
             )

    assert_receive {:instance_action, :work, %{source: :instance}}

    assert Enum.map(Spectre.state(instance).pending_effects, & &1.run_id) == [
             second_invocation.run_id
           ]

    assert_eventually(fn -> Instance.info(instance).active_run == nil end)

    assert {:ok, %Turn{observable: {:reply, "worked", _}}} =
             Spectre.resume(
               instance,
               second_invocation,
               {:execute, second_invocation},
               test_pid: self()
             )

    assert_receive {:instance_action, :work, %{source: :instance}}
    assert Spectre.state(instance).pending_effects == []
  end

  test "an Instance terminates when its custom Registry disappears" do
    registry_name = SpectreInstanceContractTest.EphemeralRegistry

    registry =
      start_supervised!(%{
        id: {:registry, registry_name},
        start: {Registry, :start_link, [[keys: :unique, name: registry_name]]},
        restart: :temporary
      })

    supervisor =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: SpectreInstanceContractTest.RegistryCrashSupervisor}
      )

    subject = Subject.new("registry-crash-#{System.unique_integer([:positive])}")

    assert {:ok, instance} =
             Spectre.instance(supervisor, @agent, subject,
               registry: registry_name,
               idle: false
             )

    monitor = Process.monitor(instance)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(registry, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^instance, :normal}, 2_000
    end)
  end

  defp start_instance do
    subject = Subject.new("instance-subject")

    start_supervised!(
      {Instance,
       agent: @agent,
       subject: subject,
       id: {:instance_contract, System.unique_integer([:positive])},
       idle: false}
    )
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

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
