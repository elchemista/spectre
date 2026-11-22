defmodule Spectre.Server.CheckpointBindingMigrationTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.Checkpoint
  alias Spectre.Server.Store.Disk

  @timeout 5_000

  defmodule Root do
    use Spectre.Server

    def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}

    def handle_call(:submit, _from, ctx) do
      {:reply, :queued,
       call_tool(ctx, {:library, :lookup}, "D1", timeout: :infinity, on_result: :lookup)}
    end

    def handle_result(:lookup, result, ctx) do
      send(get_private(ctx, :observer), {:lookup, result})
      no_response(ctx)
    end
  end

  @tag :tmp_dir
  @tag :capture_log
  test "changing only a scoped adapter invokes the migrator and fences its saved command", %{
    tmp_dir: path
  } do
    {store, opts, adapter, _flow} = fixture(path, AdapterUpgrade)
    assert {:ok, root} = Server.start_link(opts)
    assert :queued = GenServer.call(root, :submit)
    assert_receive {:invoked, "v1", command_id}, @timeout
    assert :ok = GenServer.stop(root)
    assert %{outbox: %{^command_id => _}} = before = snapshot(store)
    refute List.keymember?(before.definition_fingerprint.modules, adapter, 0)

    ExUnit.CaptureIO.capture_io(:stderr, fn -> compile_adapter(adapter, "v2") end)

    restored = restore_after_code_change(store, opts, before)
    assert_receive {:lookup, {:error, :tool_contract_changed}}, @timeout
    refute_received {:invoked, "v2", _}
    assert Server.status(restored).outbox_size == 0
    assert :ok = GenServer.stop(restored)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "changing only an exposed Flow Port invokes the migrator before handling a saved reply", %{
    tmp_dir: path
  } do
    {store, opts, _adapter, flow} = fixture(path, FlowUpgrade)
    assert {:ok, root} = Server.start_link(opts)
    assert {:ok, _interaction} = Server.input(root, "ask")
    assert_receive {Server, ^root, {:waiting_input, %{id: id, revision: revision}}}, @timeout

    assert :ok = :sys.suspend(root)
    ExUnit.CaptureIO.capture_io(:stderr, fn -> compile_flow(flow, "v2") end)

    assert {:error, {:error, :checkpoint_binding_changed}} =
             :sys.change_code(root, Spectre.Server.Runtime, :original, nil)

    assert :ok = :sys.resume(root)
    assert :ok = GenServer.stop(root)
    before = snapshot(store)
    refute List.keymember?(before.definition_fingerprint.modules, flow, 0)

    restored = restore_after_code_change(store, opts, before)
    assert {:ok, turn} = Server.input(restored, "answer", pending: {id, revision})
    assert_receive {Server, ^restored, {:response, ^turn, "v2 answer", _}}, @timeout
    assert :ok = GenServer.stop(restored)
  end

  def migrate(saved, %{from: from, to: to}) do
    {:ok, put_in(saved.assigns[:migration], {from, to})}
  end

  defp restore_after_code_change(store, opts, before) do
    assert {:error, {%ArgumentError{message: message}, _}} = Server.start_link(opts)
    assert message == "invalid Server checkpoint: :checkpoint_definition_fingerprint_mismatch"
    assert snapshot(store) == before

    opts = Keyword.put(opts, :checkpoint_migrator, {__MODULE__, :migrate})
    assert {:ok, restored} = Server.start_link(opts)
    assert %{migration: {from, to}} = Server.status(restored).assigns
    assert from == before.definition_fingerprint
    assert <<_::256>> = from.binding_code_digest
    assert <<_::256>> = to.binding_code_digest
    assert from.binding_code_digest != to.binding_code_digest
    assert Map.delete(from, :binding_code_digest) == Map.delete(to, :binding_code_digest)
    restored
  end

  defp snapshot(store) do
    assert {:ok, %{value: bytes}} = Disk.fetch(store, "binding")
    assert {:ok, projection} = Checkpoint.decode_snapshot(bytes)
    projection
  end

  defp fixture(path, namespace) do
    namespace = Module.concat(__MODULE__, namespace)
    adapter = Module.concat(namespace, Adapter)
    flow = Module.concat(namespace, Flow)
    package = Module.concat(namespace, Package)
    stack = Module.concat(namespace, Stack)
    agent = Module.concat(namespace, Agent)

    on_exit(fn ->
      for module <- [agent, stack, package, flow, adapter] do
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end
    end)

    compile_adapter(adapter, "v1")
    compile_flow(flow, "v1")

    Code.compile_quoted(
      quote do
        defmodule unquote(package) do
          use Spectre.Stack.Installable, id: :library, version: "1.0.0"

          @impl true
          def integration(_config) do
            Spectre.Integration.new()
            |> Spectre.Integration.tool(:lookup, unquote(adapter), retry: :safe)
            |> Spectre.Integration.flow(:questions, unquote(flow))
          end
        end

        defmodule unquote(stack) do
          use Spectre.Stack
          install(unquote(package))
        end

        defmodule unquote(agent) do
          use Spectre.Agent, stack: unquote(stack), server: unquote(Root)
          router(strategies: [:regex])
          expose(:library)
        end
      end
    )

    store = start_supervised!({Disk, path: Path.join(path, "checkpoint")})

    opts = [
      agent: agent,
      identity: %{subject: "bindings"},
      init_arg: self(),
      test_pid: self(),
      consumer: self(),
      checkpoint: {store, "binding"},
      gam: [storage: {:disk, Path.join(path, "gam")}]
    ]

    {store, opts, adapter, flow}
  end

  defp compile_adapter(module, revision) do
    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          def prepare(:lookup, input, _context), do: {:ok, input}

          def invoke(:lookup, input, %{service_context: context}) do
            send(context.options[:test_pid], {:invoked, unquote(revision), context.command_id})

            receive do
              :release -> {:ok, input}
            end
          end

          def project(:lookup, result), do: {:ok, result}
        end
      end
    )
  end

  defp compile_flow(module, revision) do
    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Spectre.Flow.Port

          @impl true
          def routes, do: [on(:ask, regex: ~r/^ask$/)]

          @impl true
          def handle_flow(:ask, _input, ctx),
            do: await_input(ctx, :answer, prompt: "Answer?", timeout: :infinity)

          @impl true
          def handle_result(:answer, {:ok, input}, ctx),
            do: respond(ctx, unquote(revision) <> " " <> input.text)
        end
      end
    )
  end
end
