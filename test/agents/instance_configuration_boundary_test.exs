defmodule Spectre.Agents.InstanceConfigurationBoundaryTest do
  use Spectre.Test.HandlerAgentCase, async: false

  alias Spectre.Instance
  alias Spectre.Instance.Checkpoint
  alias Spectre.Store.Memory

  test "startup rejects absent scopes, missing Definitions and contradictory pins", c do
    assert {:error, :invalid_instance_options} = Instance.start_link(nil)
    assert {:error, :missing_instance_options} = Instance.start_link([])

    assert {:error, :invalid_instance_scope} =
             Instance.start_link(scope: nil, definition_ref: c.definition.ref)

    assert {:error, :agent_definition_required} =
             Instance.start_link(Keyword.delete(c.instance_options, :definition))

    assert {:error, :instance_definition_binding_mismatch} =
             Instance.start_link(Keyword.put(c.instance_options, :definition_ref, "different"))

    opts = Keyword.put(c.instance_options, :definition_ref, c.definition.ref)
    name = __MODULE__.NamedInstance
    pid = start_supervised!({Instance, Keyword.put(opts, :name, name)}, id: :named)
    assert Process.whereis(name) == pid
    assert Instance.info(name).definition_ref == c.definition.ref
    assert Instance.child_spec([]).id == Instance
    GenServer.cast(pid, :unknown_notification)
    assert Instance.info(pid).definition_ref == c.definition.ref
  end

  test "malformed operational options are rejected without contacting a server" do
    for invalid <- [%{}, [:invalid]] do
      assert {:error, :invalid_instance_turn_options} =
               Instance.turn(:no_server, "hello", invalid)

      assert {:error, :invalid_instance_proposal_options} =
               Instance.propose(:no_server, %{}, invalid)
    end

    for opts <- [[wait: -1], [wait: 1.0], [proposal_opts: %{}]] do
      assert {:error, :invalid_instance_advance_options} = Instance.advance(:no_server, nil, opts)
    end

    assert {:error, _} = Instance.advance(:no_server, nil, unknown: true)
  end

  test "a checkpoint cannot be combined with a new local value or component state", c do
    config = c.instance_options |> Map.new() |> Map.put(:definition_ref, c.definition.ref)

    for changed <- [
          Map.put(config, :checkpoint, :invalid),
          config
          |> Map.delete(:state)
          |> Map.put(:checkpoint, :invalid)
          |> Map.put(:component_states, %{})
        ] do
      assert {:error, :instance_state_checkpoint_collision} = GenServer.start(Instance, changed)
    end

    assert {:error, :invalid_instance_checkpoint} =
             GenServer.start(
               Instance,
               config |> Map.drop([:state, :component_states]) |> Map.put(:checkpoint, :invalid)
             )
  end

  test "checkpoint serialization rejects invalid component revisions and missing values before CAS",
       c do
    server = start_supervised!(Memory)
    store = {Memory, server: server}
    domain = Spectre.Scope.domain_ref(c.scope)

    for {state, reason} <- [
          {%{revision: 0}, :invalid_instance_checkpoint},
          {%{revision: 0, value: %{}, components: []}, :invalid_checkpoint_components},
          {%{revision: 0, value: %{}, components: %{"skill" => %{revision: -1, value: nil}}},
           :invalid_checkpoint_component},
          {%{revision: 0, value: %{}, components: %{42 => %{revision: 0, value: nil}}},
           :invalid_checkpoint_component}
        ] do
      assert {:error, ^reason} =
               Checkpoint.save(store, "agent", 0, domain, c.definition.ref, state)

      assert :not_found = Spectre.Store.get(store, "agent")
    end

    assert {:error, _} =
             Checkpoint.save(store, "agent", 0, domain, c.definition.ref, unknown: true)

    assert {:error, _} = Checkpoint.load({String, []}, "agent", domain, c.definition.ref)

    valid = %{
      revision: 3,
      value: %{"greeting" => "hello"},
      components: %{"orders" => %{revision: 2, value: %{"seen" => 1}}}
    }

    assert {:ok, 1} = Checkpoint.save(store, "agent", 0, domain, c.definition.ref, valid)
    assert {:ok, ^valid} = Checkpoint.load(store, "agent", domain, c.definition.ref)
  end
end
