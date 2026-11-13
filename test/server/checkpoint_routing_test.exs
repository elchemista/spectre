defmodule Spectre.Server.CheckpointRoutingTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.{Checkpoint, Command, Router}

  # Public data-driven Skill definitions use the same mount/materialization
  # contract as the DSL and can carry inference constraints from an adapter.
  defmodule BillingSkill do
    def __spectre_definition__ do
      Spectre.Definition.new(
        kind: :skill,
        id: __MODULE__,
        owner: __MODULE__,
        rules: [
          %Spectre.Rule{
            label: :pricing,
            flow: :billing,
            flow_path: [:support, :billing],
            handler: {:reason, :pricing, []},
            regex: [~r/^skill price$/],
            constraints: [
              %Spectre.Flow.Constraint{
                namespace: :model,
                kind: :inference,
                values: [:balanced],
                mode: :all
              }
            ]
          }
        ]
      )
    end
  end

  defmodule App do
    use Spectre.Server
  end

  defmodule Agent do
    use Spectre.Agent, server: App
    router(strategies: [:regex])
    skill(BillingSkill, as: :accounts)

    flow :support do
      on(:pricing, regex: ~r/^own price$/)
    end
  end

  defp state(store, agent \\ Agent) do
    %{
      agent: agent,
      server: App,
      identity: %{account_id: "one"},
      assigns: %{},
      opts: [checkpoint: {store, "routing"}],
      pending: %{},
      outbox: %{},
      inbox: %{},
      seen_events: %{},
      sequence: 1,
      history: [],
      current_flow: nil,
      current_scope: nil,
      current: nil,
      queue: :queue.new(),
      foreground: nil,
      checkpoint_revision: nil
    }
  end

  defp store do
    path =
      Path.join(
        System.tmp_dir!(),
        "spectre-checkpoint-routing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  test "exact nested Skill ownership and inference constraints survive every durable routing location" do
    store = store()
    assert {:ok, key, routing} = Router.route(Agent, "skill price")
    assert key == {{{:skill, :accounts}, [:support, :billing]}, :pricing}

    event = %{
      id: "event",
      input: Spectre.Input.new("skill price"),
      routing: Map.put(routing, :route_key, key),
      steps: 1,
      phase: :commands
    }

    state = %{
      state(store)
      | current: event,
        queue: :queue.from_list([%{event | id: "queued"}]),
        pending: %{"pending" => %{kind: :consent, status: :foreground, origin: event}},
        outbox: %{
          "command" => %{command: %Command{kind: :generate, args: [:pricing]}, event: event}
        },
        inbox: %{
          "route" => %{worker: %{kind: :route, event: event}, result: {:ok, key, routing}},
          "interrupt" => %{
            worker: %{kind: :interrupt, event: event},
            result: {:interrupt, key, routing}
          }
        }
    }

    Checkpoint.save(state)
    restored = Checkpoint.load(state(store))
    {:ok, ^key, route_result} = restored.inbox["route"].result
    {:interrupt, ^key, interrupt_result} = restored.inbox["interrupt"].result

    locations = [
      restored.current.routing,
      hd(:queue.to_list(restored.queue)).routing,
      restored.pending["pending"].origin.routing,
      restored.outbox["command"].event.routing,
      restored.inbox["route"].worker.event.routing,
      route_result,
      interrupt_result
    ]

    Enum.each(locations, fn routing ->
      assert routing.route.owner == BillingSkill
      assert routing.route.scope == {:skill, :accounts}
      assert routing.route.rule.flow_path == [:support, :billing]

      assert [%{namespace: :model, kind: :inference, values: [:balanced]}] =
               routing.route.rule.constraints

      assert routing.route.rule.handler == {:reason, :pricing, []}
    end)
  end

  test "recompiled declaration with the same module and version is rejected" do
    module = Module.concat(__MODULE__, "Mutable#{System.unique_integer([:positive])}")

    compile = fn version ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Spectre.Agent, server: #{inspect(App)}
        router strategies: [:regex]
        flow :support do
          on :pricing, regex: ~r/^#{version}$/
        end
      end
      """)
    end

    compile.("first")
    store = store()
    Checkpoint.save(state(store, module))
    ExUnit.CaptureIO.capture_io(:stderr, fn -> compile.("second") end)

    assert_raise ArgumentError, ~r/checkpoint_definition_fingerprint_mismatch/, fn ->
      Checkpoint.load(state(store, module))
    end
  end

  def migrate_assigns(saved, _metadata),
    do: {:ok, Map.update!(saved, :assigns, &Map.put(&1, :schema, 2))}

  def discard_reconciliation(saved, _metadata), do: {:ok, %{saved | outbox: %{}}}

  test "an explicit code migration preserves governed reconciliation and keeps consent suspended" do
    store = store()
    before = state(store)
    pending = %{"consent" => %{kind: :consent, status: :foreground, origin: nil}}
    outbox = %{"effect" => %{command: %Command{kind: :propose, args: [:refund, %{}]}, event: nil}}

    before = %{
      before
      | opts: Keyword.put(before.opts, :checkpoint_version, 1),
        pending: pending,
        outbox: outbox
    }

    Checkpoint.save(before)
    after_state = state(store)

    opts =
      after_state.opts
      |> Keyword.put(:checkpoint_version, 2)
      |> Keyword.put(:checkpoint_migrator, {__MODULE__, :migrate_assigns})

    migrated = Checkpoint.load(%{after_state | opts: opts})
    assert migrated.assigns.schema == 2
    assert migrated.outbox == outbox
    assert migrated.pending["consent"].status == :suspended
    assert migrated.foreground == nil
    assert migrated.definition_fingerprint_cache.checkpoint_version == 2
  end

  test "a migrator cannot discard uncertain operations" do
    store = store()
    before = state(store)
    outbox = %{"effect" => %{command: %Command{kind: :propose, args: [:refund, %{}]}, event: nil}}
    Checkpoint.save(%{before | outbox: outbox})
    after_state = state(store)

    opts =
      after_state.opts
      |> Keyword.put(:checkpoint_version, 2)
      |> Keyword.put(:checkpoint_migrator, {__MODULE__, :discard_reconciliation})

    assert_raise ArgumentError, ~r/checkpoint_migration_changed_reconciliation/, fn ->
      Checkpoint.load(%{after_state | opts: opts})
    end

    assert Checkpoint.load(state(store)).outbox == outbox
  end

  test "a selected custom route without declared portable metadata fails closed" do
    store = store()

    event = %{
      id: "custom",
      input: Spectre.Input.new("price"),
      routing: %{route_key: {:custom, :pricing}},
      steps: 1
    }

    Checkpoint.save(%{state(store) | current: event})

    assert_raise ArgumentError, ~r/checkpoint_route_metadata_missing/, fn ->
      Checkpoint.load(state(store))
    end
  end
end
