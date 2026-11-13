defmodule Outreach.IntegrationTest do
  use ExUnit.Case, async: false
  alias Spectre.GAM
  alias GAM.V04Test.{Fixture, Runtime}
  alias Spectre.Server

  setup test_context do
    start_supervised!(Outreach.Sink)
    Runtime.reset(System.system_time(:millisecond))
    namespace = "outreach-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), namespace <> ".ledger")
    on_exit(fn -> File.rm(path) end)
    memory_root = Path.join(System.tmp_dir!(), namespace <> "-memory")
    on_exit(fn -> File.rm_rf(memory_root) end)
    store = start_supervised!({Spectre.Ledger.ServerStore, path: path}, restart: :temporary)

    start_supervised!(
      {Spectre.Stack.Runtime,
       stack: Outreach.AI,
       name: Outreach.StackRuntime,
       packages: [
         lens: [test_pid: self()],
         mnemonic: [data_root: memory_root, namespace: namespace]
       ]}
    )

    {:ok, row} = GAM.Row.new(%{attempt: true, disclose: true, spend: true})
    classes = ["email.send", "notice.send", "report.save"]
    memory_options = [namespace: namespace, stack_runtime: Outreach.StackRuntime]

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {GAM.Domain.Registry, "v0.4:#{namespace}:domain"}},
        consent: true,
        mind: Outreach.Mind,
        ingress: Outreach.Ingress,
        declarations: Map.new(classes, &{&1, row}),
        consequence_contracts: Map.new(classes, &{&1, Outreach.Host.contract()}),
        classes: classes ++ ["presentation.show"],
        executors: [{Outreach.Executor, observer: self(), memory_options: memory_options}]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, _} = Fixture.observe_payment(fixture, Fixture.paid_evidence(fixture))

    {:ok, scope} =
      GAM.Scope.new(
        GAM.Domain.handle(fixture.server, fixture.refs.domain),
        Fixture.context(fixture)
      )

    config = [
      scope: scope,
      lifecycle: true,
      store: {Spectre.Ledger.ServerStore, store},
      bindings: %{
        {:kinetic, :send_email} => %{candidate: {Outreach.Host, :email}},
        send_notice: %{candidate: {Outreach.Host, :notice}},
        save_report: %{
          candidate: {Outreach.Host, :report},
          presentation: {Outreach.Host, :presentation},
          interpreter: {Outreach.Host, :interpret}
        }
      }
    ]

    opts = [
      agent: Outreach.Agent,
      consumer: self(),
      init_arg: if(test_context[:pause_model], do: {:pause_model, self()}, else: self()),
      identity: %{conversation: namespace, subject: namespace},
      host_fixture: fixture,
      stack_runtime: Outreach.StackRuntime,
      ledger_server_store: store,
      checkpoint: {Spectre.Ledger.ServerStore, store, :outreach},
      gam: {Spectre.Server.GAM, config},
      namespace: namespace,
      max_steps: 64
    ]

    server = start_supervised!({Server, opts}, restart: :temporary)

    %{
      server: server,
      scope: scope,
      store: store,
      path: path,
      opts: opts,
      memory_options: memory_options
    }
  end

  test "all nine installed tools participate in one real Server/GAM loop; only confirmed report is saved",
       c do
    assert map_size(Outreach.Server.__spectre_server_tools__()) == 9
    assert {:ok, _} = Server.input(c.server, "start")
    assert_receive {:outreach_result, :directive, {:directive, _}}, 5000
    assert_receive {:outreach_result, :prism, {:selected, _}}, 5000
    assert_receive {:outreach_result, :recall, {:ok, before_memory}}, 5000
    assert_receive {:outreach_result, :opened, {:ok, _}}, 5000
    assert_receive {:outreach_result, :looked, {:ok, %{trust: :untrusted}}}, 5000

    assert_receive {:outreach_result, :model,
                    {:generated, %{planning: false, model_output: raw}}},
                   5000

    assert raw =~ "<al>"
    assert_receive {:outreach_result, :kinetic, {:prepared, %{actions: [proposal]}}}, 5000
    assert proposal.metadata.owner == Outreach.Agent

    assert_receive {:outreach_result, :email, {:governed, %{outcome: %{status: :succeeded}}}},
                   5000

    assert_receive {:outreach_result, :beam, {:ok, [_]}}, 5000

    assert_receive {:outreach_result, :notice, {:governed, %{outcome: %{status: :succeeded}}}},
                   5000

    assert_receive {:outreach_result, :pulse, {:ok, _}}, 5000
    assert_receive {:outreach_result, :ledger, {:ok, _}}, 5000
    assert_receive {:outreach_result, :lab, {:ok, %{codec_valid: true}}}, 5000
    assert_receive {:admitted_effect, "presentation.show"}, 5000
    refute_receive {:admitted_effect, "report.save"}, 50
    assert [%{to: "dev@example.com"}] = Outreach.Sink.snapshot().email
    assert [%{to: "owner@example.com"}] = Outreach.Sink.snapshot().notice

    assert {:ok, _} = Server.input(c.server, "status")

    wait_until(fn ->
      Enum.any?(:sys.get_state(c.server).pending, fn {_, p} -> p.status == :suspended end)
    end)

    assert {:ok, _} = Server.input(c.server, "resume")
    assert_receive {:admitted_effect, "presentation.show"}, 5000
    wait_until(fn -> :sys.get_state(c.server).foreground != nil end)
    assert {:ok, _} = Server.input(c.server, "yes")
    assert_receive {:admitted_effect, "report.save"}, 5000

    assert_receive {:outreach_result, :saved, {:governed, %{outcome: %{status: :succeeded}}}},
                   5000

    assert_receive {:outreach_result, :recalled_after_save, {:ok, after_memory}}, 5000
    refute before_memory == after_memory
    assert inspect(after_memory) =~ "Luca was contacted about his Shopify site."
    refute inspect(before_memory) =~ "Luca was contacted"

    assert {:ok, other_subject} =
             Spectre.Mnemonic.ServerTool.invoke(:recall, %{cue: "Luca Shopify"}, %{
               service_context: %{
                 agent: Outreach.Agent,
                 identity: %{subject: c.opts[:identity].subject <> "-other"},
                 options: c.memory_options
               }
             })

    refute inspect(other_subject) =~ "Luca was contacted"
    assert {:ok, view} = GAM.view(c.scope)
    assert Enum.any?(view.outcomes, &(&1.status == :succeeded))
    assert {:ok, %{value: encoded}} = Spectre.Ledger.ServerStore.fetch(c.store, :outreach)
    assert {:ok, _} = Spectre.Server.Checkpoint.decode_snapshot(encoded)
  end

  test "checkpoint restart preserves pending consent and refusal never saves or repeats contact",
       c do
    assert {:ok, _} = Server.input(c.server, "start")
    assert_receive {:admitted_effect, "presentation.show"}, 5000
    wait_until(fn -> :sys.get_state(c.server).foreground != nil end)
    assert [%{to: "dev@example.com"}] = Outreach.Sink.snapshot().email
    assert_receive {:admitted_effect, "email.send"}, 100
    assert_receive {:admitted_effect, "notice.send"}, 100
    assert :ok = stop_supervised(Spectre.Server.Runtime)
    store_monitor = Process.monitor(c.store)
    Process.exit(c.store, :kill)
    assert_receive {:DOWN, ^store_monitor, :process, _, :killed}, 5000
    assert stop_supervised(Spectre.Ledger.ServerStore) in [:ok, {:error, :not_found}]

    recovered_store =
      start_supervised!({Spectre.Ledger.ServerStore, path: c.path}, restart: :temporary)

    {bridge, gam_config} = c.opts[:gam]

    restored_opts =
      c.opts
      |> Keyword.put(:checkpoint, {Spectre.Ledger.ServerStore, recovered_store, :outreach})
      |> Keyword.put(:ledger_server_store, recovered_store)
      |> Keyword.put(
        :gam,
        {bridge, Keyword.put(gam_config, :store, {Spectre.Ledger.ServerStore, recovered_store})}
      )

    restarted = start_supervised!({Server, restored_opts}, restart: :temporary)

    wait_until(fn ->
      Enum.any?(:sys.get_state(restarted).pending, fn {_, p} -> p.status == :suspended end)
    end)

    assert {:ok, _} = Server.input(restarted, "resume")
    assert_receive {:admitted_effect, "presentation.show"}, 5000
    wait_until(fn -> :sys.get_state(restarted).foreground != nil end)
    assert {:ok, _} = Server.input(restarted, "no")
    assert_receive {:outreach_result, :saved, {:consent, :rejected}}, 5000
    refute_receive {:admitted_effect, "report.save"}, 100
    refute_receive {:admitted_effect, "email.send"}, 100
    refute_receive {:admitted_effect, "notice.send"}, 100
    assert length(Outreach.Sink.snapshot().email) == 1
    assert length(Outreach.Sink.snapshot().notice) == 1

    assert {:ok, recalled} =
             Spectre.Mnemonic.ServerTool.invoke(:recall, %{cue: "Luca Shopify"}, %{
               service_context: %{
                 agent: Outreach.Agent,
                 identity: c.opts[:identity],
                 options: c.memory_options
               }
             })

    refute inspect(recalled) =~ "Luca was contacted"
  end

  @tag pause_model: true
  test "kill after generation replays consolidated AL from durable inbox without a second model call",
       c do
    assert {:ok, _} = Server.input(c.server, "start")
    assert_receive {:model_callback_waiting, pid}, 5000
    assert pid == c.server
    assert Outreach.Sink.snapshot().model_calls == 1
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000
    assert stop_supervised(Spectre.Server.Runtime) in [:ok, {:error, :not_found}]

    restored =
      start_supervised!({Server, Keyword.put(c.opts, :init_arg, self())}, restart: :temporary)

    assert_receive {:outreach_result, :kinetic, {:prepared, %{actions: [_]}}}, 5000
    assert_receive {:admitted_effect, "email.send"}, 5000
    assert_receive {:admitted_effect, "presentation.show"}, 5000
    assert Outreach.Sink.snapshot().model_calls == 1
    assert length(Outreach.Sink.snapshot().email) == 1
    wait_until(fn -> :sys.get_state(restored).foreground != nil end)
    assert {:ok, _} = Server.input(restored, "no")
    assert_receive {:outreach_result, :saved, {:consent, :rejected}}, 5000
    assert_no_public_al()
  end

  defp assert_no_public_al do
    receive do
      {Spectre.Server, _pid, event} ->
        refute inspect(event) =~ "SEND EMAIL"
        refute inspect(event) =~ "<al>"
        assert_no_public_al()
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
