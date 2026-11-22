defmodule Spectre.Server.ActivityAPIDefaultsTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.ActivityBinding

  @timeout 5_000
  @unavailable {:tool_rejected, {:documents, :read}, :read, :source_unavailable}

  defmodule Reader do
    def prepare(:read, :unavailable, _context), do: {:error, :source_unavailable}
    def prepare(:read, value, _context), do: {:ok, value}
    def invoke(:read, value, _context), do: value
    def project(:read, value), do: {:ok, {:ok, value}}
  end

  defmodule Documents do
    use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.tool(:read, Reader)
    end
  end

  defmodule Partial do
    use Spectre.Activity

    def handle_start(:waiting, ctx), do: ctx
    def handle_start(value, ctx), do: call_tool(ctx, {:documents, :read}, value)

    def handle_result(:read, {:ok, value}, ctx), do: complete(ctx, document_id(value))

    defp document_id(%{id: id}), do: id
  end

  defmodule Custom do
    use Spectre.Activity

    def handle_start(value, ctx), do: call_tool(ctx, {:documents, :read}, value)
    def handle_result(_tag, result, ctx), do: complete(ctx, {:handled, result})
  end

  defmodule Stack do
    use Spectre.Stack

    install(Documents)
    activity(:partial, Partial)
    activity(:custom, Custom)
  end

  defmodule Root do
    use Spectre.Server

    def handle_call({:start, type, args}, _from, ctx),
      do: {:reply, :accepted, start_activity(ctx, type, args, as: :work)}
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root
  end

  test "a partial result handler uses the default failure for an unmatched error" do
    root = start_root()
    ref = launch(root, :partial, :unavailable)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, @unavailable}}}, @timeout
  end

  test "an explicit application handler keeps precedence over the default" do
    root = start_root()
    ref = launch(root, :custom, :unavailable)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:completed, {:handled, {:error, @unavailable}}}}},
                   @timeout
  end

  test "a function clause error inside a matched handler remains a callback failure" do
    root = start_root()
    ref = launch(root, :partial, :malformed_document)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:failed, :activity_callback_failed}}},
                   @timeout
  end

  test "replaying a running Activity start tolerates changed runtime options" do
    root = start_root()
    ref = launch(root, :partial, :waiting)

    %{activity_connection: {owner, _token}} = state = :sys.get_state(root)
    %{command_id: command_id} = :sys.get_state(owner).entries[ref]

    replay_state = %{state | active_command: command_id, consumer: root}
    replay_state = put_in(replay_state.opts[:worker_timeout], 60_000)

    assert {:ok, %{ref: ^ref, key: :work}} =
             ActivityBinding.start(replay_state, :partial, :waiting, as: :work)

    assert {:error, :activity_command_conflict} =
             ActivityBinding.start(replay_state, :partial, %{id: "different"}, as: :work)

    assert {:error, :activity_command_conflict} =
             ActivityBinding.start(replay_state, :partial, :waiting,
               as: :work,
               scope: [{:documents, :read}]
             )

    assert {:ok, [%{ref: ^ref, status: :running}]} = Server.activities(root)
  end

  defp start_root, do: start_supervised!({Server, agent: Agent, consumer: self()})

  defp launch(root, type, args) do
    assert :accepted = GenServer.call(root, {:start, type, args})
    assert_receive {Server, ^root, {:activity, %{ref: ref, key: :work}, :started}}, @timeout
    ref
  end
end
