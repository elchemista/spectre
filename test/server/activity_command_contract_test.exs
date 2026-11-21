defmodule Spectre.Server.ActivityCommandContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.{ActivityBinding, Checkpoint, Command}
  alias Spectre.Server.Store.Disk

  defmodule UnavailableStore do
    def fetch(:offline, _key), do: {:error, :backend_offline}
    def fetch(:crashing, _key), do: raise("unavailable")
  end

  test "start declarations accept qualified types and validate portable names and scope" do
    command = %Command{kind: :start_activity, args: [{:research, :mission}, %{term: "OTP"}]}
    assert :ok = Command.validate(%{command | opts: [as: :report, scope: [{:docs, :read}]]})

    assert {:error, :invalid_activity_type} =
             Command.validate(%{command | args: [{make_ref(), :mission}, %{}]})

    assert {:error, :invalid_activity_name} =
             Command.validate(%{command | opts: [as: "report"]})

    for scope <- [:unrestricted, [:read]] do
      assert {:error, :invalid_activity_scope} =
               Command.validate(%{command | opts: [scope: scope]})
    end

    for opts <- [[as: :first, as: :second], [worker: self()]] do
      assert {:error, :invalid_activity_options} = Command.validate(%{command | opts: opts})
    end

    assert {:error, _} = Command.validate(%{command | args: [:research, self()]})
    assert {:error, :invalid_options} = Command.validate(%{command | opts: [:unqualified]})
  end

  test "controls and terminal commands validate references, revisions and portable results" do
    signal = %Command{kind: :signal_activity, args: ["activity-ref", {:revise, "new goal"}]}
    assert :ok = Command.validate(%{signal | opts: [if_revision: 0, on_result: :revised]})

    assert {:error, :invalid_activity_revision} =
             Command.validate(%{signal | opts: [if_revision: -1]})

    cancel = %Command{kind: :cancel_activity, args: [:report]}
    assert :ok = Command.validate(cancel)
    assert {:error, :invalid_activity_name} = Command.validate(%{cancel | args: [""]})

    assert {:error, _} = Command.validate(%{signal | args: ["activity-ref", self()]})
    assert {:error, _} = Command.validate(%Command{kind: :complete_activity, args: [make_ref()]})

    lookup = %Command{kind: :call_tool, args: [{:documents, :read}, %{id: "D1"}]}
    assert {:error, :invalid_tool_ref} = Command.validate(%{lookup | args: [:read, %{}]})

    assert {:error, :invalid_tool_ref} =
             Command.validate_internal(%Command{
               kind: :tool_call,
               args: [%{tool: {:documents, nil}}, %{}]
             })
  end

  test "a restricted Activity cannot bypass its installed tool scope with a raw proposal" do
    proposal = %Command{kind: :propose, args: [:publish, %{}], opts: [on_result: :publication]}
    scoped = %{activity: %{scope: [{:documents, :read}]}}

    assert {%Command{
              kind: :tool_rejected,
              args: [{:error, :activity_tool_not_allowed}],
              opts: [on_result: :publication]
            }, nil} = ActivityBinding.authorize(scoped, {proposal, nil})

    origin = %{tool: {:documents, :read}}
    assert {^proposal, ^origin} = ActivityBinding.authorize(scoped, {proposal, origin})

    assert {^proposal, nil} =
             ActivityBinding.authorize(%{activity: %{scope: :all}}, {proposal, nil})
  end

  @tag :tmp_dir
  test "retiring a disk Activity snapshot preserves the Root snapshot and is idempotent", %{
    tmp_dir: path
  } do
    store = start_supervised!({Disk, path: Path.join(path, "agent.store")})
    assert {:ok, _} = Disk.put_new(store, :root, "root snapshot")
    assert {:ok, _} = Disk.put_new(store, {:activity, "one"}, "activity snapshot")

    assert :ok = Checkpoint.retire({store, {:activity, "one"}})
    assert :ok = Checkpoint.retire({store, {:activity, "one"}})
    assert :ok = Checkpoint.retire(nil)
    assert {:ok, %{value: "root snapshot"}} = Disk.fetch(store, :root)

    assert :ok = stop_supervised(Disk)

    assert {:error, :checkpoint_store_unavailable} =
             Checkpoint.retire({store, {:activity, "one"}})
  end

  test "checkpoint retirement reports provider errors without presuming deletion" do
    assert {:error, :backend_offline} = Checkpoint.retire({UnavailableStore, :offline, :work})

    assert {:error, :checkpoint_store_unavailable} =
             Checkpoint.retire({UnavailableStore, :crashing, :work})
  end
end
