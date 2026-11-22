defmodule Spectre.Server.ToolRuntimeTest do
  use ExUnit.Case, async: true

  alias Spectre.Server

  # Component fixtures start Runtime directly: they exercise OTP/checkpoint
  # behavior independently of the public Server automatic GAM bootstrap.
  alias Spectre.Server.{Checkpoint, Command}
  alias Spectre.Server.Store.Disk

  defmodule Adapter do
    def prepare(:trusted, _input, trusted), do: {:ok, trusted.agent}
    def prepare(:echo, [:reject], _trusted), do: {:error, :rejected_input}
    def prepare(:echo, [:explode], _trusted), do: raise("bad input")
    def prepare(:echo, [value], _trusted), do: {:ok, value}
    def prepare(_operation, value, _trusted), do: {:ok, value}

    def invoke(:headroom, _value, %{service_context: context}) do
      send(context.options[:test_pid], {:invoked, :headroom, nil, context.command_id, self()})
      {:ok, String.duplicate("h", 1024 * 1024)}
    end

    def invoke(operation, value, %{service_context: context}) do
      send(context.options[:test_pid], {:invoked, operation, value, context.command_id, self()})

      if operation in [:large, :never_large] do
        {:ok, String.duplicate("r", 2 * 1024 * 1024)}
      else
        result(operation, value)
      end
    end

    defp result(operation, value) do
      if operation in [:safe_wait, :never_wait] do
        receive do
          :release -> {:ok, value}
        end
      else
        {:ok, value}
      end
    end

    def project(:echo, {:ok, :bad_result}), do: {:ok, self()}
    def project(:never_project, {:ok, [:failure]}), do: {:error, :lost_receipt}
    def project(:never_project, {:ok, [:malformed]}), do: :malformed
    def project(:never_project, {:ok, [:oversize]}), do: {:ok, String.duplicate("x", 2048)}
    def project(:never_project, {:ok, [:pid]}), do: {:ok, self()}
    def project(_operation, result), do: {:ok, result}
  end

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :runtime_probe,
      version: "0.1.0",
      spectre: "~> 0.4.0"

    @impl true
    def tools(_config) do
      %{
        probe: %{
          contract: 1,
          adapter: Adapter,
          default: :echo,
          operations: %{
            echo: %{path: :cognitive, retry: :safe, max_bytes: 1024},
            trusted: %{path: :cognitive, retry: :safe, max_bytes: 1024},
            large: %{path: :cognitive, retry: :safe, max_bytes: 3 * 1024 * 1024},
            headroom: %{path: :cognitive, retry: :safe, max_bytes: 2 * 1024 * 1024},
            never_large: %{path: :cognitive, retry: :never, max_bytes: 3 * 1024 * 1024},
            never_project: %{path: :cognitive, retry: :never, max_bytes: 1024},
            safe_wait: %{path: :cognitive, retry: :safe, max_bytes: 1024},
            never_wait: %{path: :cognitive, retry: :never, max_bytes: 1024}
          }
        }
      }
    end
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule App do
    use Spectre.Server, tools: Stack

    def init({observer, {:submit, input, opts}}, ctx) do
      {:ok, ctx |> put_private(:observer, observer) |> probe(input, opts)}
    end

    def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}

    def handle_flow(_route, %{text: text}, ctx) do
      send(get_private(ctx, :observer), :flow_callback)

      case text do
        "reject" -> probe(ctx, {:echo, :reject}, on_result: :flow)
        "hold_never" -> probe(ctx, {:never_wait, :resource}, timeout: :infinity, on_result: :wait)
        "bad_options" -> probe(ctx, :ok, unknown: true)
        "bad_assign" -> ctx |> assign(:bad, self()) |> probe(:ok)
        "big_assign" -> ctx |> assign(:big, String.duplicate("x", 16 * 1024 * 1024)) |> probe(:ok)
        _ -> probe(ctx, text, on_result: :flow)
      end
    end

    def code_change(_old, ctx, :bad_assign), do: {:ok, assign(ctx, :bad, self())}
    def code_change(old, ctx, extra), do: super(old, ctx, extra)

    def handle_call(:spoof_context, _from, ctx),
      do:
        {:reply, :queued,
         probe(%{ctx | agent: :untrusted_agent}, {:trusted, nil}, on_result: :trusted)}

    def handle_call({:prime, size}, _from, ctx),
      do: {:reply, :ok, assign(ctx, :padding, String.duplicate("p", size))}

    def handle_call({:submit, input, opts}, _from, ctx),
      do: {:reply, :queued, probe(ctx, input, opts)}

    def handle_call({:continue, input, opts}, _from, ctx),
      do: {:reply, :queued, ctx, {:continue, {input, opts}}}

    def handle_call(request, from, ctx), do: super(request, from, ctx)
    def handle_cast({:submit, input, opts}, ctx), do: {:noreply, probe(ctx, input, opts)}
    def handle_info({:submit, input, opts}, ctx), do: {:noreply, probe(ctx, input, opts)}
    def handle_info(message, ctx), do: super(message, ctx)
    def handle_continue({input, opts}, ctx), do: {:noreply, probe(ctx, input, opts)}

    def recover(_failure, ctx), do: probe(ctx, {:echo, :reject}, on_result: :recovered)

    def handle_result(tag, result, ctx) do
      send(get_private(ctx, :observer), {:completed, tag, result})
      ctx |> assign(:last_result, {tag, result}) |> no_response()
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App

    flow :test do
      on(:echo, regex: ~r/.*/)
    end
  end

  defmodule OtherStack do
    use Spectre.Stack
    install(Package, as: :other)
  end

  defmodule OtherAgent do
    use Spectre.Agent, stack: OtherStack, server: App
  end

  defmodule StoreAdapter do
    @behaviour Spectre.Server.Store
    defdelegate fetch(store, key), to: Disk
    defdelegate put_new(store, key, value), to: Disk
    defdelegate compare_and_swap(store, key, revision, value), to: Disk
    defdelegate delete(store, key, revision), to: Disk
  end

  def migrate(projection, _metadata), do: {:ok, projection}
  def tamper_migration(projection, _metadata), do: {:ok, %{projection | outbox: %{}}}

  setup context do
    path = Path.join(System.tmp_dir!(), "spectre-tools-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    store = start_supervised!({Disk, path: path})
    {:ok, store: store, key: Atom.to_string(context.test)}
  end

  test "cognitive tool execution starts after callback and carries a stable command id", c do
    server = start_server(c)
    assert {:ok, _} = Server.input(server, "hello")
    assert_receive :flow_callback, 2000
    assert_receive {:invoked, :echo, "hello", command_id, worker}, 2000
    assert is_binary(command_id)
    refute worker == server
    assert_receive {:completed, :flow, {:ok, "hello"}}, 2000
    assert Server.status(server).outbox_size == 0
  end

  for mode <- [:call, :cast, :info, :continue] do
    test "domain rejection is delivered from #{mode} without invocation", c do
      server = start_server(c)
      submit(server, unquote(mode), {:echo, :reject}, on_result: :rejected)

      assert_receive {:completed, :rejected,
                      {:error, {:tool_rejected, :probe, :echo, :rejected_input}}},
                     2000

      refute_receive {:invoked, _, _, _, _}
      assert Process.alive?(server)
    end

    test "programming error in #{mode} stops the OTP callback before acquisition", c do
      server = start_server(c)
      monitor = Process.monitor(server)
      submit_invalid(server, unquote(mode))
      assert_receive {:DOWN, ^monitor, :process, ^server, _}, 2000
      refute_receive {:invoked, _, _, _, _}
    end
  end

  test "init supports durable rejected completions and explicit programming failure", c do
    Process.flag(:trap_exit, true)
    server = start_server(c, init_arg: {self(), {:submit, {:echo, :reject}, [on_result: :init]}})
    assert_receive {:completed, :init, {:error, {:tool_rejected, :probe, :echo, :rejected_input}}}
    assert Process.alive?(server)
    refute_receive {:invoked, _, _, _, _}

    assert {:error, _} =
             Spectre.Server.Runtime.start_link(
               options(c, init_arg: {self(), {:submit, :ok, [bad: true]}})
             )
  end

  test "unknown operations, invalid prepared data and adapter exceptions become typed results",
       c do
    server = start_server(c)

    for {input, operation} <- [
          {{:unknown, 1}, :unknown},
          {{:echo, self()}, :echo},
          {{:echo, :explode}, :echo}
        ] do
      assert :queued = GenServer.call(server, {:submit, input, [on_result: :rejected]})

      assert_receive {:completed, :rejected, {:error, {:tool_rejected, :probe, ^operation, _}}},
                     2000
    end

    refute_receive {:invoked, _, _, _, _}
  end

  test "unportable output is replaced before durable inbox acquisition", c do
    server = start_server(c)
    :queued = GenServer.call(server, {:submit, :bad_result, [on_result: :bad]})
    assert_receive {:completed, :bad, {:error, {:tool_result_not_portable, _}}}, 2000
    assert Process.alive?(server)
    assert Server.status(server).assigns.last_result |> elem(0) == :bad
    {:ok, %{value: bytes}} = Disk.fetch(c.store, c.key)
    assert {:ok, projection} = Checkpoint.decode_snapshot(bytes)
    assert projection.assigns.last_result |> elem(0) == :bad
  end

  test "a portable result exceeding the aggregate checkpoint budget becomes a bounded error", c do
    server = start_server(c)
    :ok = GenServer.call(server, {:prime, 15 * 1024 * 1024}, :infinity)
    :queued = GenServer.call(server, {:submit, {:large, nil}, [on_result: :large]}, :infinity)
    assert_receive {:completed, :large, {:error, {:tool_result_not_portable, _}}}, 5000
    assert Process.alive?(server)
    assert Server.status(server).outbox_size == 0
  end

  test "nonrepeatable post-invoke projection failures preserve uncertainty", c do
    server = start_server(c)

    for input <- [:failure, :malformed, :oversize, :pid] do
      :queued =
        GenServer.call(server, {:submit, {:never_project, input}, [on_result: :uncertain]})

      assert_receive {:invoked, :never_project, [^input], id, _}, 2000
      assert_receive {:completed, :uncertain, {:tool_unknown, %{command_id: ^id}}}, 2000
    end

    GenServer.stop(server)
    _restored = start_server(c)
    refute_receive {:invoked, :never_project, _, _, _}
  end

  test "nonrepeatable aggregate result overflow preserves uncertainty", c do
    server = start_server(c)
    :ok = GenServer.call(server, {:prime, 15 * 1024 * 1024}, :infinity)

    :queued =
      GenServer.call(server, {:submit, {:never_large, nil}, [on_result: :large]}, :infinity)

    assert_receive {:invoked, :never_large, _, id, _}, 5000
    assert_receive {:completed, :large, {:tool_unknown, %{command_id: ^id}}}, 5000
    assert Process.alive?(server)
  end

  test "bad and oversized assigns in conversational callbacks are quarantined before commit", c do
    server = start_server(c)

    for input <- ["bad_options", "bad_assign", "big_assign"] do
      {:ok, id} = Server.input(server, input)
      assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2000
      assert Process.alive?(server)
      refute Map.has_key?(Server.status(server).assigns, :bad)
      refute Map.has_key?(Server.status(server).assigns, :big)
    end

    refute_receive {:invoked, _, _, _, _}
  end

  test "the callback error handler uses the same durable domain rejection path", c do
    server = start_server(c, on_callback_error: {App, :recover})
    {:ok, id} = Server.input(server, "bad_options")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, _}}, 2000

    assert_receive {:completed, :recovered,
                    {:error, {:tool_rejected, :probe, :echo, :rejected_input}}},
                   2000

    refute_receive {:invoked, _, _, _, _}
  end

  test "a recovered tool cannot change its declared retry policy", c do
    server = start_server(c)
    :queued = GenServer.call(server, {:submit, {:never_wait, :resource}, [timeout: :infinity]})
    assert_receive {:invoked, :never_wait, _, id, _}, 2000
    state = :sys.get_state(server)
    entry = Map.fetch!(state.outbox, id)
    [identity, args] = entry.command.args
    command = %{entry.command | args: [%{identity | retry: :safe}, args]}
    forged = %{state | outbox: Map.put(state.outbox, id, %{entry | command: command})}

    assert_raise ArgumentError, ~r/tool_contract_mismatch/, fn ->
      Spectre.Server.Tool.validate_persisted!(forged)
    end
  end

  test "nonrepeatable tool timeout reports uncertainty once", c do
    server = start_server(c)

    :queued =
      GenServer.call(server, {:submit, {:never_wait, :resource}, [timeout: 30, on_result: :wait]})

    assert_receive {:invoked, :never_wait, _, id, _}, 2000

    assert_receive {:completed, :wait, {:tool_unknown, %{command_id: ^id, reason: :timeout}}},
                   2000

    refute_receive {:completed, :wait, _}
  end

  test "restart never reexecutes a started nonrepeatable tool", c do
    server = start_server(c)

    :queued =
      GenServer.call(
        server,
        {:submit, {:never_wait, :resource}, [timeout: :infinity, on_result: :wait]}
      )

    assert_receive {:invoked, :never_wait, _, id, _}, 2000
    GenServer.stop(server)
    restored = start_server(c)

    assert_receive {:completed, :wait, {:tool_unknown, %{command_id: ^id, reason: :interrupted}}},
                   2000

    refute_receive {:invoked, :never_wait, _, _, _}
    assert Server.status(restored).outbox_size == 0
  end

  test "safe cognitive recovery repeats the request with the same command identity", c do
    server = start_server(c)

    :queued =
      GenServer.call(
        server,
        {:submit, {:safe_wait, :resource}, [timeout: :infinity, on_result: :wait]}
      )

    assert_receive {:invoked, :safe_wait, _, id, _}, 2000
    GenServer.stop(server)
    _restored = start_server(c)
    assert_receive {:invoked, :safe_wait, _, ^id, worker}, 2000
    send(worker, :release)
    assert_receive {:completed, :wait, {:ok, [:resource]}}, 2000
  end

  test "a 0.4.0 checkpoint replays its acquired generated helper after explicit migration", c do
    bytes =
      __DIR__
      |> Path.join("../fixtures/compatibility/0.4.0/server-v1.checkpoint.base64")
      |> File.read!()
      |> Base.decode64!(ignore: :whitespace)

    assert {:ok, _} = Disk.put_new(c.store, c.key, bytes)

    restored = start_server(c, checkpoint_migrator: {__MODULE__, :migrate})
    id = "01a2036b-ea94-7024-8a65-97ed94509c42"
    assert_receive {:invoked, :safe_wait, [:resource], ^id, worker}, 2000
    send(worker, :release)

    assert_receive {:completed, :wait, {:ok, [:resource]}}, 2000
    assert Server.status(restored).outbox_size == 0
  end

  test "explicit cancellation records uncertainty for a nonrepeatable tool", c do
    server = start_server(c)
    {:ok, _} = Server.input(server, "hold_never")
    assert_receive {:invoked, :never_wait, _, id, _}, 2000
    assert :ok = Server.cancel(server)

    assert_receive {:completed, :wait, {:tool_unknown, %{command_id: ^id, reason: :cancelled}}},
                   2000
  end

  test "mismatched runtime Stack fails startup and direct reserved metadata is rejected", c do
    Process.flag(:trap_exit, true)
    assert {:error, _} = Spectre.Server.Runtime.start_link(options(c, agent: OtherAgent))

    assert {:error, :reserved_tool_options} =
             Command.validate(%Command{
               kind: :propose,
               args: [:save, %{}],
               opts: [tool_origin: %{}]
             })
  end

  test "tool preparation uses runtime identity despite mutable context fields", c do
    server = start_server(c)
    assert :queued = GenServer.call(server, :spoof_context)
    assert_receive {:completed, :trusted, {:ok, Agent}}, 2000
  end

  test "code changes reject nonportable assigns before adopting them", c do
    server = start_server(c)
    :ok = :sys.suspend(server)
    assert {:error, _} = :sys.change_code(server, Spectre.Server.Runtime, :old, :bad_assign)
    :ok = :sys.resume(server)
    refute Map.has_key?(Server.status(server).assigns, :bad)
  end

  test "result staging reserves the same Store envelope headroom as callback acquisition", c do
    server = start_server(c)
    :ok = GenServer.call(server, {:prime, 15 * 1024 * 1024 - 8192}, :infinity)

    :queued =
      GenServer.call(server, {:submit, {:headroom, nil}, [on_result: :headroom]}, :infinity)

    assert_receive {:completed, :headroom, {:error, {:tool_result_not_portable, _}}}, 5000
    assert Server.status(server).outbox_size == 0
  end

  for operation <- [:safe_wait, :never_wait] do
    test "changed #{operation} contract requires explicit migration and never reinvokes old arguments",
         c do
      Process.flag(:trap_exit, true)
      server = start_server(c)

      :queued =
        GenServer.call(
          server,
          {:submit, {unquote(operation), :resource}, [timeout: :infinity, on_result: :migrated]}
        )

      assert_receive {:invoked, unquote(operation), _, id, _}, 2000
      GenServer.stop(server)
      rewrite_old_tool_origin(c, id)

      assert {:error, _} = Spectre.Server.Runtime.start_link(options(c, checkpoint_version: 2))

      assert {:error, _} =
               Spectre.Server.Runtime.start_link(
                 options(c,
                   checkpoint_version: 2,
                   checkpoint_migrator: {__MODULE__, :tamper_migration}
                 )
               )

      restored =
        start_server(c, checkpoint_version: 2, checkpoint_migrator: {__MODULE__, :migrate})

      if unquote(operation) == :never_wait do
        assert_receive {:completed, :migrated,
                        {:tool_unknown, %{command_id: ^id, reason: :tool_contract_changed}}},
                       2000
      else
        assert_receive {:completed, :migrated, {:error, :tool_contract_changed}}, 2000
      end

      assert Server.status(restored).outbox_size == 0
      refute_receive {:invoked, unquote(operation), _, _, _}
      GenServer.stop(restored)
      _again = start_server(c, checkpoint_version: 2)
      refute_receive {:completed, :migrated, _}
    end
  end

  test "migration marks old tool provenance without rewriting reconciliation facts", c do
    server = start_server(c)
    :queued = GenServer.call(server, {:submit, {:never_wait, :resource}, [timeout: :infinity]})
    assert_receive {:invoked, :never_wait, _, id, _}, 2000
    state = :sys.get_state(server)
    GenServer.stop(server)
    original = rewrite_old_tool_origin(c, id)

    opts =
      Keyword.merge(state.opts,
        checkpoint_version: 2,
        checkpoint_migrator: {__MODULE__, :migrate}
      )

    fresh = %{state | opts: opts} |> Checkpoint.refresh_fingerprint()
    loaded = fresh |> Checkpoint.load() |> Spectre.Server.Tool.validate_persisted!()
    assert Map.delete(loaded.outbox[id], :tool_contract_changed) == original.outbox[id]
    assert loaded.outbox[id].tool_contract_changed

    assert Spectre.Server.Tool.validate_persisted!(%{loaded | tool_bindings: %{}}).outbox ==
             loaded.outbox

    saved = Checkpoint.save(loaded)

    # A crash after marking but before completion must remain recoverable without running the migrator again.
    restored =
      %{saved | opts: Keyword.delete(opts, :checkpoint_migrator)}
      |> Checkpoint.load()
      |> Spectre.Server.Tool.validate_persisted!()

    assert restored.outbox == loaded.outbox
    refute Map.has_key?(restored, :checkpoint_migrated)
  end

  test "custom Store triple uses the existing checkpoint protocol", c do
    server = start_server(c, checkpoint: {StoreAdapter, c.store, c.key})
    :queued = GenServer.call(server, {:submit, "stored", [on_result: :stored]})
    assert_receive {:completed, :stored, {:ok, "stored"}}, 2000
    GenServer.stop(server)
    restored = start_server(c, checkpoint: {StoreAdapter, c.store, c.key})
    assert Server.status(restored).assigns.last_result == {:stored, {:ok, "stored"}}
  end

  defp rewrite_old_tool_origin(c, id) do
    {:ok, %{revision: revision, value: bytes}} = Disk.fetch(c.store, c.key)
    {:ok, projection} = Checkpoint.decode_snapshot(bytes)
    entry = projection.outbox[id]
    [identity, args] = entry.command.args
    identity = %{identity | descriptor_digest: "previous-deployment-descriptor"}
    command = %{entry.command | args: [identity, args]}
    entry = %{entry | command: command, tool_origin: Map.delete(identity, :retry)}
    projection = %{projection | outbox: Map.put(projection.outbox, id, entry)}
    {:ok, encoded} = Checkpoint.encode_value(projection)
    {:ok, _} = Disk.compare_and_swap(c.store, c.key, revision, encoded)
    projection
  end

  defp start_server(context, extra \\ []) do
    start_supervised!({Spectre.Server.Runtime, options(context, extra)},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp options(context, extra) do
    Keyword.merge(
      [
        agent: Agent,
        checkpoint: {context.store, context.key},
        init_arg: self(),
        test_pid: self(),
        consumer: self()
      ],
      extra
    )
  end

  defp submit(server, :call, input, opts), do: GenServer.call(server, {:submit, input, opts})
  defp submit(server, :cast, input, opts), do: GenServer.cast(server, {:submit, input, opts})
  defp submit(server, :info, input, opts), do: send(server, {:submit, input, opts})

  defp submit(server, :continue, input, opts),
    do: GenServer.call(server, {:continue, input, opts})

  defp submit_invalid(server, :call),
    do: catch_exit(submit(server, :call, :ok, bad: true))

  defp submit_invalid(server, mode), do: submit(server, mode, :ok, bad: true)
end
