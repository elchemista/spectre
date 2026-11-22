defmodule Spectre.Server.ActivityLimitsTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.Activities

  @timeout 5_000

  defmodule Counter do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)

    @impl true
    def init(count), do: {:ok, count}

    @impl true
    def handle_call(:tick, _from, count), do: {:reply, :ok, count + 1}
    def handle_call(:count, _from, count), do: {:reply, count, count}
  end

  defmodule Work do
    use Spectre.Activity

    @observer Spectre.Server.ActivityLimitsTest.ChildObserver

    def handle_start(:loop, ctx), do: tick(ctx, :loop)
    def handle_start(:wait, ctx), do: ctx
    def handle_start(:parent, ctx), do: start_activity(ctx, :work, :child)
    def handle_start(:child, ctx), do: complete(ctx, :child_value)
    def handle_start({:child, :first}, ctx), do: complete(ctx, :first)
    def handle_start({:child, :second}, ctx), do: ctx

    def handle_start(:parent_batch, ctx) do
      ctx
      |> start_activity(:work, {:child, :first}, as: :first)
      |> start_activity(:work, {:child, :second}, as: :second)
    end

    def handle_signal(:tick, ctx), do: tick(ctx, :wait)
    def handle_signal(:finish_child, ctx), do: complete(ctx, :second)
    def handle_signal({:revise, :finish}, ctx), do: tick(ctx, :finish)
    def handle_signal(signal, ctx), do: super(signal, ctx)

    def handle_activity(_identity, {:completed, :first}, ctx) do
      send(@observer, {:handling_first_child, self()})

      receive do
        :acknowledge_child -> assign(ctx, :first_child, :first)
      after
        5_000 -> fail(ctx, :child_ack_timeout)
      end
    end

    def handle_activity(_identity, {:completed, :second}, ctx),
      do: complete(ctx, [Map.fetch!(ctx.assigns, :first_child), :second])

    def handle_activity(
          %{parent: parent},
          {:completed, value},
          %{activity: %{ref: parent}} = ctx
        ),
        do: complete(ctx, {:observed, value})

    def handle_activity(identity, event, ctx), do: super(identity, event, ctx)

    def handle_result(:loop, _value, ctx), do: tick(ctx, :loop)
    def handle_result(:wait, _value, ctx), do: ctx
    def handle_result(:finish, _value, ctx), do: complete(ctx, :finished_revision)

    defp tick(ctx, tag), do: call_actor(ctx, Counter, :tick, on_result: tag)
  end

  defmodule Stack do
    use Spectre.Stack

    activity(:work, Work, allow_children: [:work])
  end

  defmodule Root do
    use Spectre.Server

    def handle_call({:work, args}, {caller, _tag}, ctx),
      do:
        {:reply, :queued,
         ctx |> put_private(:observer, caller) |> start_activity(:work, args, on_result: :started)}

    def handle_result(:started, result, ctx) do
      send(get_private(ctx, :observer), {:start_result, result})
      ctx
    end
  end

  defmodule Definition do
    use Spectre.Agent, stack: Stack, server: Root
  end

  test "an Activity without an interaction exhausts its asynchronous continuation budget" do
    counter = start_supervised!(Counter)
    root = start_root(max_steps: 3)
    ref = start_activity(root, :loop)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, :step_limit}}}, @timeout
    assert GenServer.call(counter, :count) == 3
  end

  test "revision resets the budget before new asynchronous work and its continuation" do
    _counter = start_supervised!(Counter)
    root = start_root(max_steps: 3)
    ref = start_activity(root, :wait)

    assert {:ok, request} = Server.signal_activity(root, ref, :tick)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^request, {:ok, _}}}},
                   @timeout

    assert {:ok, request} = Server.signal_activity(root, ref, {:revise, :finish})

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^request, {:ok, _}}}},
                   @timeout

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, :finished_revision}}},
                   @timeout
  end

  test "host capacity is freed when an Activity ends and can disable starts entirely" do
    root = start_root(max_activities: 1)
    first = start_activity(root, :wait)

    assert :queued = GenServer.call(root, {:work, :wait})
    assert_receive {:start_result, {:error, :activity_limit}}, @timeout

    assert {:ok, _} = Server.cancel_activity(root, first)
    assert_receive {Server, ^root, {:activity, %{ref: ^first}, :cancelled}}, @timeout
    refute start_activity(root, :wait) == first

    disabled = start_root(max_activities: 0)
    assert :queued = GenServer.call(disabled, {:work, :wait})
    assert_receive {:start_result, {:error, :activity_limit}}, @timeout
  end

  test "unadopted starts release capacity and their retained reservation is bounded" do
    owner =
      start_supervised!({Activities, max_activities: 1, registry: __MODULE__.AbsentRegistry})

    child = {Counter, []}

    assert {:ok, first} = Activities.reserve(owner, "first", child, as: :report)
    assert {:error, :server_registry_unavailable} = Activities.resume(owner, first)
    assert {:ok, %{status: :reserved}} = Activities.lookup(owner, first)

    assert {:ok, second} = Activities.reserve(owner, "second", child, as: :report)
    assert {:error, :already_running} = Activities.resume(owner, first)
    assert {:error, :server_registry_unavailable} = Activities.resume(owner, second)

    assert {:error, :unknown_activity} = Activities.lookup(owner, first)
    assert {:ok, %{status: :reserved}} = Activities.lookup(owner, second)
  end

  test "idle Activities notify once and remain addressable unless the host chooses failure" do
    root = start_root()
    ref = start_activity(root, :wait)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref, revision: 0}, :idle}}, @timeout
    assert {:ok, request} = Server.signal_activity(root, ref, :ignored)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^request, {:ok, _}}}},
                   @timeout

    refute_receive {Server, ^root, {:activity, %{ref: ^ref}, :idle}}

    strict = start_root(activity_idle: :fail)
    strict_ref = start_activity(strict, :wait)

    assert_receive {Server, ^strict, {:activity, %{ref: ^strict_ref}, {:failed, :activity_idle}}},
                   @timeout
  end

  test "a parent receives its child's terminal outcome without a Root relay" do
    root = start_root(activity_idle: :fail)
    ref = start_activity(root, :parent)

    assert_receive {Server, ^root, {:activity, %{ref: child, parent: ^ref}, :started}}, @timeout

    assert_receive {Server, ^root, {:activity, %{ref: ^child}, {:completed, :child_value}}},
                   @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:completed, {:observed, :child_value}}}},
                   @timeout
  end

  test "later child results stay at the coordinator until the parent acknowledges the first" do
    Process.register(self(), __MODULE__.ChildObserver)
    root = start_root(activity_idle: :keep)
    parent = start_activity(root, :parent_batch)

    assert_receive {:handling_first_child, parent_pid}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: second, key: :second, parent: ^parent}, :started}},
                   @timeout

    assert {:ok, _} = Server.signal_activity(root, second, :finish_child)
    assert_receive {Server, ^root, {:activity, %{ref: ^second}, {:completed, :second}}}, @timeout
    assert {:ok, %{status: :completed}} = Server.activity(root, second)

    assert {:messages, messages} = Process.info(parent_pid, :messages)
    refute Enum.any?(messages, &match?({Activities, _, :child_lifecycle, %{ref: ^second}, _}, &1))

    send(parent_pid, :acknowledge_child)

    assert_receive {Server, ^root, {:activity, %{ref: ^parent}, {:completed, [:first, :second]}}},
                   @timeout
  end

  defp start_root(opts \\ []) do
    {:ok, pid} = Server.start_link(Keyword.merge([agent: Definition, consumer: self()], opts))
    pid
  end

  defp start_activity(root, args) do
    assert :queued = GenServer.call(root, {:work, args})
    assert_receive {:start_result, {:ok, %{ref: ref}}}, @timeout
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, :started}}, @timeout
    ref
  end
end
