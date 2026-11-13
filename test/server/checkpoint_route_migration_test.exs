defmodule Spectre.Server.CheckpointRouteMigrationTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.{Checkpoint, Command, Router}

  @old_key {:support, :pricing}
  @new_key {[:support, :billing], :quote}

  defmodule App do
    use Spectre.Server
  end

  def migrate_routes(saved, _metadata) do
    migrated = %{saved | current_flow: :billing, current_scope: :agent}
    {:ok, migrated, %{@old_key => @new_key}}
  end

  def migrate_without_mapping(saved, _metadata), do: {:ok, saved}
  def missing_target(saved, _metadata), do: {:ok, saved, %{@old_key => {:missing, :quote}}}

  def change_fact(saved, _metadata) do
    migrated = put_in(saved, [:operations, "effect", :material_digest], "changed")
    {:ok, migrated, %{@old_key => @new_key}}
  end

  def change_active_input(saved, _metadata) do
    migrated = put_in(saved, [:current, :input], Spectre.Input.new("different request"))
    {:ok, migrated, %{@old_key => @new_key}}
  end

  def rollback_sequence(saved, _metadata),
    do: {:ok, %{saved | sequence: saved.sequence - 1}, %{@old_key => @new_key}}

  def invalid_mapping(saved, _metadata), do: {:ok, saved, [@old_key, @new_key]}

  test "an explicit mapping moves every durable routing hint while preserving governed facts" do
    {store, agent, saved} = saved_conversation()
    recompile(agent, :renamed)
    restored = restore(store, agent, :migrate_routes)

    {:ok, @new_key, routed} = restored.inbox["route"].result
    {:interrupt, @new_key, interrupted} = restored.inbox["interrupt"].result

    locations = [
      restored.current.routing,
      hd(:queue.to_list(restored.queue)).routing,
      restored.pending["consent"].origin.routing,
      restored.outbox["effect"].event.routing,
      restored.inbox["route"].worker.event.routing,
      restored.operations["effect"].event.routing,
      routed,
      interrupted
    ]

    Enum.each(locations, fn routing ->
      assert routing.route_key == @new_key
      assert routing.previous_route_keys == [@old_key]
      assert routing.route.label == :quote
      assert routing.route.rule.flow_path == [:support, :billing]
      assert routing.route.owner == agent
      assert routing.scope == :agent
      assert routing.protected
    end)

    assert restored.current_flow == :billing
    assert restored.current_scope == :agent
    assert restored.foreground == nil
    assert restored.pending["consent"].status == :suspended
    assert restored.current.input == saved.current.input
    assert restored.current.id == saved.current.id
    assert restored.identity == saved.identity

    assert Map.drop(restored.pending["consent"], [:origin, :status]) ==
             Map.drop(saved.pending["consent"], [:origin, :status])

    assert Map.drop(restored.outbox["effect"], [:event]) ==
             Map.drop(saved.outbox["effect"], [:event])

    assert Map.drop(restored.operations["effect"], [:event]) ==
             Map.drop(saved.operations["effect"], [:event])

    assert restored.inbox["governed"].result == saved.inbox["governed"].result

    assert Map.drop(restored.inbox["governed"].worker, [:event]) ==
             Map.drop(saved.inbox["governed"].worker, [:event])

    acquired = Checkpoint.save(restored)
    again = Checkpoint.load(state(store, agent))
    assert again.current.routing.previous_route_keys == [@old_key]

    assert Map.drop(again.operations["effect"], [:event]) ==
             Map.drop(acquired.operations["effect"], [:event])

    assert Checkpoint.project_event(again.operations["effect"].event) ==
             Checkpoint.project_event(acquired.operations["effect"].event)
  end

  test "a renamed route remains fail closed without an explicit mapping" do
    {store, agent, _saved} = saved_conversation()
    recompile(agent, :renamed)

    assert_raise ArgumentError, ~r/checkpoint_route_not_found/, fn ->
      restore(store, agent, :migrate_without_mapping)
    end
  end

  test "all mapping targets must identify exactly one currently declared route" do
    {store, agent, _saved} = saved_conversation()
    recompile(agent, :renamed)

    assert_raise ArgumentError, ~r/checkpoint_route_not_found/, fn ->
      restore(store, agent, :missing_target)
    end

    recompile(agent, :ambiguous)

    assert_raise ArgumentError, ~r/checkpoint_route_ambiguous/, fn ->
      restore(store, agent, :migrate_routes)
    end

    assert_raise ArgumentError, ~r/invalid_checkpoint_migration/, fn ->
      restore(store, agent, :invalid_mapping)
    end
  end

  test "mappings preserve governed facts, original input and the consent sequence watermark" do
    {store, agent, _saved} = saved_conversation()
    recompile(agent, :renamed)

    for migrator <- [:change_fact, :change_active_input, :rollback_sequence] do
      assert_raise ArgumentError, ~r/checkpoint_migration_changed_reconciliation/, fn ->
        restore(store, agent, migrator)
      end
    end

    assert restore(store, agent, :migrate_routes).operations["effect"].material_digest ==
             "material:original"
  end

  test "restored pending commands stay uncertain until governed recovery releases their lock" do
    {store, agent, _saved} = saved_conversation()
    restored = Checkpoint.load(state(store, agent))
    event = restored.current

    commands = [
      {"confirm", :confirm_pending, ["confirm"]},
      {"explain", :explain_pending, ["explain"]},
      {"resume", :resume_pending, ["resume"]},
      {"generate", :generate, ["generate"]},
      {"propose", :propose, [:refund, %{pending_id: "propose"}]}
    ]

    pending =
      Map.new(commands, fn {id, _kind, _args} ->
        {id, %{id: id, kind: :consent, status: :resolving, origin: event}}
      end)
      |> Map.put("unrelated", %{
        id: "unrelated",
        kind: :consent,
        status: :foreground,
        origin: event
      })

    outbox =
      Map.new(commands, fn {id, kind, args} ->
        {id, %{command: %Command{kind: kind, args: args}, event: event}}
      end)

    Checkpoint.save(%{restored | pending: pending, outbox: outbox})
    recovered = Checkpoint.load(state(store, agent))

    for id <- ["confirm", "explain", "resume"] do
      assert recovered.pending[id].status == :uncertain
    end

    for id <- ["generate", "propose", "unrelated"] do
      assert recovered.pending[id].status == :suspended
    end

    assert recovered.foreground == nil
    assert Enum.sort(Map.keys(recovered.outbox)) == Enum.sort(Map.keys(outbox))
  end

  defp saved_conversation do
    agent = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")
    compile_agent(agent, :original)
    store = store()
    {:ok, @old_key, routing} = Router.route(agent, "price")

    event = %{
      id: "request",
      input: %{Spectre.Input.new("price") | raw: nil},
      routing: Map.put(routing, :route_key, @old_key),
      sequence: 10,
      steps: 2,
      phase: :commands
    }

    proof = %{candidate_identity_key: "candidate:original", material_digest: "material:original"}
    facts = %{act: Map.put(proof, :ref, "act:original"), outcome: nil}
    worker = %{kind: :propose, event: event, command_id: "effect", tag: :original_result}

    saved =
      state(store, agent)
      |> Map.merge(%{
        sequence: 10,
        current: event,
        queue: :queue.from_list([%{event | id: "queued"}]),
        pending: %{
          "consent" => %{
            kind: :consent,
            status: :foreground,
            origin: event,
            command_id: "effect",
            on_result: :original_result,
            candidate: proof,
            evidence_refs: ["evidence:original"],
            presentation_ref: "presentation:original"
          }
        },
        outbox: %{
          "effect" => %{
            command: %Command{kind: :propose, args: [:refund, %{amount: 500}]},
            event: event,
            tag: :original_result
          }
        },
        inbox: %{
          "route" => %{worker: %{kind: :route, event: event}, result: {:ok, @old_key, routing}},
          "interrupt" => %{
            worker: %{kind: :interrupt, event: event},
            result: {:interrupt, @old_key, routing}
          },
          "governed" => %{worker: worker, result: {:governed, facts}}
        },
        operations: %{
          "effect" =>
            Map.merge(proof, %{
              act_ref: "act:original",
              scope_ref: "scope:original",
              event: event,
              tag: :original_result,
              result_keys: ["result:original"]
            })
        }
      })

    Checkpoint.save(saved)
    {store, agent, saved}
  end

  defp restore(store, agent, migrator) do
    initial = state(store, agent)
    opts = Keyword.put(initial.opts, :checkpoint_migrator, {__MODULE__, migrator})
    Checkpoint.load(%{initial | opts: opts})
  end

  defp state(store, agent) do
    %{
      agent: agent,
      server: App,
      identity: %{account_id: "one"},
      assigns: %{},
      opts: [checkpoint: {store, "migration"}],
      pending: %{},
      outbox: %{},
      inbox: %{},
      operations: %{},
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
        "spectre-route-migration-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    start_supervised!({Spectre.Server.Store.Disk, path: path})
  end

  defp recompile(agent, version) do
    ExUnit.CaptureIO.capture_io(:stderr, fn -> compile_agent(agent, version) end)
  end

  defp compile_agent(agent, :ambiguous) do
    Code.compile_string("""
    defmodule #{inspect(agent)} do
      def __spectre_definition__ do
        rule = %Spectre.Rule{label: :quote, flow: :billing, flow_path: [:support, :billing],
          handler: {:server, {[:support, :billing], :quote}, []}, opts: [protected: true]}
        Spectre.Definition.new(owner: __MODULE__, rules: [rule, rule])
      end
    end
    """)
  end

  defp compile_agent(agent, version) do
    routes =
      if version == :original do
        "on :pricing, regex: ~r/^price$/"
      else
        "flow :billing do\n on :quote, regex: ~r/^quote$/, protected: true\n end"
      end

    Code.compile_string("""
    defmodule #{inspect(agent)} do
      use Spectre.Agent, server: #{inspect(App)}
      router strategies: [:regex], log_decisions: false
      flow :support do
        #{routes}
      end
    end
    """)
  end
end
