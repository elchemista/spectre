defmodule Spectre.Server.SkillsTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule SkillServer do
    use Spectre.Server

    def init(_, ctx) do
      send(ctx.identity.observer, {:skill_started, ctx.skill.id, self()})
      {:ok, assign(ctx, :count, 0)}
    end

    def handle_flow({:work, :run}, input, ctx) do
      send(ctx.identity.observer, {:skill_flow, ctx.skill.id, self(), ctx.routing.route.scope})
      generate(assign(ctx, :count, ctx.assigns.count + 1), input.text, on_result: :done)
    end

    def handle_flow(:unmatched, _, ctx), do: respond(ctx, "skill unmatched")
    def handle_result(:done, {:generated, %{text: text}}, ctx), do: respond(ctx, text)
    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
    def handle_call(:context, _, ctx), do: {:reply, ctx, ctx}

    def handle_call(:block, _, ctx) do
      send(ctx.identity.observer, {:blocked, self()})
      receive do: (:release -> :ok)
      {:reply, :ok, ctx}
    end

    def handle_cast(:tick, ctx), do: {:noreply, assign(ctx, :ticks, 1)}
    def handle_info(:tick, ctx), do: {:noreply, assign(ctx, :ticks, 2)}
  end

  defmodule Work do
    use Spectre.Skill, id: :work, server: SkillServer

    flow :work do
      on(:run, regex: ~r/^work/)
    end
  end

  defmodule Other do
    use Spectre.Skill, id: :other, server: SkillServer

    flow :work do
      on(:run, regex: ~r/^other/)
    end
  end

  defmodule RootServer do
    use Spectre.Server
    def handle_flow({:root, :ping}, _, ctx), do: respond(ctx, "pong")

    def handle_flow({:root, :bad_delegate}, _, ctx),
      do: delegate(ctx, :work, %{text: "work", meta: %{nonportable: self()}})

    def handle_flow({:root, :delegate}, _, ctx), do: delegate(ctx, :work, "work delegated")

    def handle_result(:delegate, result, ctx) do
      send(ctx.identity.observer, {:delegation, result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_info(message, ctx) do
      send(ctx.identity.observer, {:application_message, message})
      {:noreply, ctx}
    end

    def handle_skill(skill, event, ctx) do
      send(ctx.identity.observer, {:skill_event, skill, event})
      no_response(ctx)
    end
  end

  defmodule Root do
    use Spectre.Agent, server: RootServer
    router(strategies: [:regex])

    flow :root do
      on(:ping, regex: ~r/^ping$/)
      on(:bad_delegate, regex: ~r/^bad delegate$/)
      on(:delegate, regex: ~r/^delegate$/)
    end

    skill(Work, as: :work)
    skill(Other, as: :other)
  end

  defmodule Transport do
    def capabilities(_, _), do: MapSet.new([:stream, :pull_transport])

    def open(_, opts) do
      send(opts[:observer], {:stream_opened, self()})
      receive do: (:stream_ready -> :ok)
      {:ok, %{observer: opts[:observer], phase: 0}, %{}}
    end

    def request_transport_item(%{phase: 0} = state) do
      send(self(), {:chunk, Spectre.Inference.ProviderEvent.delta("preview")})
      {:ok, %{state | phase: 1}}
    end

    def request_transport_item(state), do: {:ok, state}
    def handle_transport({:chunk, event}, state), do: {:ok, [event], state}
    def handle_transport(_, state), do: {:ignore, state}
    def cancel(state, _), do: send(state.observer, :stream_cancelled)
  end

  defmodule Model do
    def generate(%{prompt: "work stream"}, context, _) do
      Spectre.Server.Stream.run(
        %{
          selection: %{level: :test, model: Transport},
          descriptor: %{id: "skill-generation"},
          provider_opts: []
        },
        %{planning: false, preview: :auto},
        context,
        stream_adapter: {Transport, observer: context.identity.observer}
      )
    end

    def generate(request, context, _) do
      send(
        context.identity.observer,
        {:generation, context.skill.id, self(), context.routing.scope}
      )

      receive do
        :finish -> {:generated, %{text: request.prompt}}
      end
    end
  end

  # Protocol fixture injects a fake model and process identities into the internal runtime.
  # Public automatic startup is exercised by managed Skill integration tests.
  defp start do
    start_supervised!(
      {Spectre.Server.Runtime,
       agent: Root, consumer: self(), identity: %{observer: self()}, services: [generate: Model]}
    )
  end

  test "mounted callbacks use independent runtimes, parallel workers and scoped events" do
    root = start()
    assert_receive {:skill_started, :work, first}
    assert_receive {:skill_started, :other, second}
    assert first != second and first != root
    assert {:ok, ^first} = Server.skill_server(root, :work)
    assert {:ok, _} = Server.input(root, "work now")
    assert_receive {:skill_flow, :work, ^first, {:skill, :work}}, 2000
    assert_receive {:generation, :work, worker_a, {:skill, :work}}, 2000
    assert {:ok, _} = Server.input(root, "other now")
    assert_receive {:generation, :other, worker_b, {:skill, :other}}, 2000
    assert {:ok, ping} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^ping, "pong", []}}, 2000
    send(worker_b, :finish)
    send(worker_a, :finish)
    assert_receive {Server, ^root, {:skill, :other, {:response, _, "other now", []}}}, 2000
    assert_receive {Server, ^root, {:skill, :work, {:response, _, "work now", []}}}, 2000
    assert Server.status(first).assigns.count == 1
    assert Server.status(second).assigns.count == 1
    assert Server.status(root).assigns == %{}
  end

  test "targeted routing cannot select root or sibling flows" do
    root = start()
    assert {:ok, _} = Server.input(root, "ping", skill: :work)
    assert_receive {Server, ^root, {:skill, :work, {:response, _, "skill unmatched", []}}}, 2000
    assert {:ok, _} = Server.input(root, "other", skill: :work)
    assert_receive {Server, ^root, {:skill, :work, {:response, _, "skill unmatched", []}}}, 2000
    assert {:error, :unknown_skill} = Server.input(root, "x", skill: :missing)
  end

  test "helper delegates and returns acceptance; native OTP callbacks preserve mount context" do
    root = start()
    {:ok, skill} = Server.skill_server(root, :work)
    assert {:ok, _} = Server.input(root, "delegate")
    assert_receive {:delegation, {:delegated, %{skill: :work, interaction: _}}}, 2000
    assert_receive {:generation, :work, worker, _}, 2000
    send(worker, :finish)
    GenServer.cast(skill, :tick)
    assert GenServer.call(skill, :context).assigns.ticks == 1
    send(skill, :tick)
    ctx = GenServer.call(skill, :context)
    assert ctx.assigns.ticks == 2
    assert ctx.routing.scope == {:skill, :work}
    assert ctx.routing.route.owner == Work
  end

  test "stopping the agent stops its Skill subtree" do
    root = start()
    {:ok, skill} = Server.skill_server(root, :work)
    monitor = Process.monitor(skill)
    GenServer.stop(root)
    assert_receive {:DOWN, ^monitor, :process, ^skill, _}, 2000
  end

  test "skill stream previews bypass callbacks and still close after owner death" do
    root = start()
    {:ok, child} = Server.skill_server(root, :work)
    assert_receive {:skill_started, :work, ^child}
    {:ok, input} = Server.input(root, "work stream", skill: :work)
    assert_receive {:stream_opened, worker}, 2000
    monitor = Process.monitor(worker)
    send(worker, :stream_ready)

    assert_receive {Server, ^root,
                    {:skill, :work, {:preview, ^input, "skill-generation", "preview"}}},
                   2000

    refute_receive {:skill_event, :work, {:preview, _, _, _}}
    assert Process.alive?(worker)
    Process.exit(child, :kill)
    assert_receive {:skill_started, :work, new_child}, 2000
    assert new_child != child

    assert_receive {Server, ^root,
                    {:skill, :work,
                     {:preview_end, ^input, "skill-generation", {:error, :stream_interrupted}}}},
                   2000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2000
    assert_receive :stream_cancelled, 2000
    refute_receive {:skill_event, :work, {:preview_end, _, _, _}}
  end

  test "targeted input to a blocked skill does not block its root or sibling" do
    root = start()
    {:ok, child} = Server.skill_server(root, :work)
    blocked = Task.async(fn -> GenServer.call(child, :block) end)
    assert_receive {:blocked, ^child}
    input = Task.async(fn -> Server.input(root, "work", skill: :work) end)
    assert Server.status(root).busy == false
    {:ok, ping} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^ping, "pong", []}}, 2000
    {:ok, _} = Server.input(root, "other", skill: :other)
    assert_receive {:generation, :other, other_worker, _}, 2000
    send(other_worker, :finish)
    send(child, :release)
    assert Task.await(blocked) == :ok
    assert {:ok, _} = Task.await(input)
    assert_receive {:generation, :work, worker, _}, 2000
    send(worker, :finish)
  end

  test "unrelated Server messages still reach native callbacks" do
    root = start()
    event = {Server, self(), {:response, "foreign", "text", []}}
    send(root, event)
    assert_receive {:application_message, ^event}, 2000
  end

  test "nonportable delegation is rejected before acquisition without crashing the root" do
    root = start()
    {:ok, id} = Server.input(root, "bad delegate")
    assert_receive {Server, ^root, {:callback_error, ^id, :handle_flow, _}}, 2000
    assert Process.alive?(root)
    refute_receive {:generation, :work, _, _}
  end

  test "invalid shared GAM configuration reports a structured startup failure" do
    Process.flag(:trap_exit, true)

    assert {:error, :gam_requires_configuration_not_bridge} =
             Server.start_link(agent: Root, gam: {Server.GAM, []})
  end

  test "Skill pre-route does not execute Agent turn handlers" do
    assert :cont =
             Spectre.Server.PreRoute.handle(Root, Spectre.Input.new("ping"), %{
               skill: %{id: :work}
             })
  end
end
