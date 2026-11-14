defmodule Outreach.IntegrationTest do
  use ExUnit.Case, async: false
  alias Spectre.Server

  setup test_context do
    start_supervised!(Outreach.Sink)
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

    memory_options = [namespace: namespace, stack_runtime: Outreach.StackRuntime]
    gam_path = Path.join(System.tmp_dir!(), namespace <> "-gam")
    on_exit(fn -> File.rm_rf(gam_path) end)
    config = Outreach.Configuration.gam(gam_path, store)

    opts = [
      agent: Outreach.Agent,
      consumer: self(),
      init_arg: if(test_context[:pause_model], do: {:pause_model, self()}, else: self()),
      identity: %{conversation: namespace, subject: namespace},
      stack_runtime: Outreach.StackRuntime,
      ledger_server_store: store,
      checkpoint: {Spectre.Ledger.ServerStore, store, :outreach},
      gam: config,
      namespace: namespace,
      max_steps: 64
    ]

    server = start_supervised!({Server, opts}, restart: :temporary)

    %{
      server: server,
      gam_path: gam_path,
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
    acknowledge_presentation(c.server)
    assert effect_count(c.server, "report.save") == 0
    assert [%{to: "dev@example.com"}] = Outreach.Sink.snapshot().email
    assert [%{to: "owner@example.com"}] = Outreach.Sink.snapshot().notice

    assert {:ok, _} = Server.input(c.server, "status")

    wait_until(fn ->
      Enum.any?(:sys.get_state(c.server).pending, fn {_, p} -> p.status == :suspended end)
    end)

    assert {:ok, _} = Server.input(c.server, "resume")
    acknowledge_presentation(c.server)
    wait_until(fn -> :sys.get_state(c.server).foreground != nil end)
    assert {:ok, _} = Server.input(c.server, "yes")

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
    assert {:ok, view} = Server.gam_view(c.server)
    assert Enum.any?(view.outcomes, &(&1.status == :succeeded))
    assert effect_count(c.server, "report.save") == 1
    assert Outreach.Sink.snapshot().attempts == %{email: 1, notice: 1}
    assert {:ok, %{value: encoded}} = Spectre.Ledger.ServerStore.fetch(c.store, :outreach)
    assert {:ok, _} = Spectre.Server.Checkpoint.decode_snapshot(encoded)
  end

  test "checkpoint restart preserves pending consent and refusal never saves or repeats contact",
       c do
    assert {:ok, _} = Server.input(c.server, "start")
    acknowledge_presentation(c.server)
    wait_until(fn -> :sys.get_state(c.server).foreground != nil end)
    assert [%{to: "dev@example.com"}] = Outreach.Sink.snapshot().email
    assert effect_count(c.server, "email.send") == 1
    assert effect_count(c.server, "notice.send") == 1
    assert :ok = stop_supervised(Spectre.Server.Runtime)
    store_monitor = Process.monitor(c.store)
    Process.exit(c.store, :kill)
    assert_receive {:DOWN, ^store_monitor, :process, _, :killed}, 5000
    assert stop_supervised(Spectre.Ledger.ServerStore) in [:ok, {:error, :not_found}]

    recovered_store =
      start_supervised!({Spectre.Ledger.ServerStore, path: c.path}, restart: :temporary)

    gam_config = c.opts[:gam]

    restored_opts =
      c.opts
      |> Keyword.put(:checkpoint, {Spectre.Ledger.ServerStore, recovered_store, :outreach})
      |> Keyword.put(:ledger_server_store, recovered_store)
      |> Keyword.put(
        :gam,
        Keyword.put(gam_config, :store, {Spectre.Ledger.ServerStore, recovered_store})
      )

    restarted = start_supervised!({Server, restored_opts}, restart: :temporary)

    wait_until(fn ->
      Enum.any?(:sys.get_state(restarted).pending, fn {_, p} -> p.status == :suspended end)
    end)

    assert {:ok, _} = Server.input(restarted, "resume")
    acknowledge_presentation(restarted)
    wait_until(fn -> :sys.get_state(restarted).foreground != nil end)
    assert {:ok, _} = Server.input(restarted, "no")
    assert_receive {:outreach_result, :saved, {:consent, :rejected}}, 5000
    assert effect_count(restarted, "report.save") == 0
    assert effect_count(restarted, "email.send") == 1
    assert effect_count(restarted, "notice.send") == 1
    assert Outreach.Sink.snapshot().attempts == %{email: 1, notice: 1}
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
    managed = :sys.get_state(c.server).managed_owner
    assert {:ok, _} = Server.input(c.server, "start")
    assert_receive {:model_callback_waiting, pid}, 5000
    assert pid == c.server
    assert Outreach.Sink.snapshot().model_calls == 1
    monitor = Process.monitor(pid)
    managed_monitor = Process.monitor(managed)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000
    assert_receive {:DOWN, ^managed_monitor, :process, ^managed, _}, 5000
    assert stop_supervised(Spectre.Server.Runtime) in [:ok, {:error, :not_found}]

    restored =
      start_supervised!({Server, Keyword.put(c.opts, :init_arg, self())}, restart: :temporary)

    assert_receive {:outreach_result, :kinetic, {:prepared, %{actions: [_]}}}, 5000
    acknowledge_presentation(restored)
    assert effect_count(restored, "email.send") == 1
    assert Outreach.Sink.snapshot().attempts == %{email: 1, notice: 1}
    assert Outreach.Sink.snapshot().model_calls == 1
    assert length(Outreach.Sink.snapshot().email) == 1
    wait_until(fn -> :sys.get_state(restored).foreground != nil end)
    assert {:ok, _} = Server.input(restored, "no")
    assert_receive {:outreach_result, :saved, {:consent, :rejected}}, 5000
    assert_no_public_al()
  end

  test "all installed helpers run inside a Skill with one shared GAM ledger", c do
    :ok = stop_supervised(Spectre.Server.Runtime)
    skill_path = c.gam_path <> "-skill"
    on_exit(fn -> File.rm_rf(skill_path) end)

    config =
      c.opts[:gam]
      |> Keyword.put(:storage, {:disk, skill_path})
      |> Keyword.update!(:operations, fn operations ->
        {email, operations} = Map.pop!(operations, {:kinetic, :send_email})
        Map.put(operations, {{:skill, :outreach}, :kinetic, :send_email}, email)
      end)

    opts =
      c.opts
      |> Keyword.put(:agent, Outreach.SkillAgent)
      |> Keyword.put(:checkpoint, {Spectre.Ledger.ServerStore, c.store, :skill_agent})
      |> Keyword.put(:skill_options, %{outreach: [init_arg: self()]})
      |> Keyword.put(:gam, config)

    root = start_supervised!({Server, opts}, restart: :temporary)
    assert {:ok, _} = Server.input(root, "start")
    assert_receive {:outreach_result, :kinetic, {:prepared, %{actions: [proposal]}}}, 5000
    assert proposal.metadata.owner == Outreach.Skill
    assert proposal.metadata.scope == {:skill, :outreach}

    for tag <- [
          :directive,
          :prism,
          :recall,
          :opened,
          :looked,
          :model,
          :email,
          :beam,
          :notice,
          :pulse,
          :ledger,
          :lab
        ] do
      assert_receive {:outreach_result, ^tag, result}, 5000

      if tag in [:email, :notice],
        do: assert(match?({:governed, %{outcome: %{status: :succeeded}}}, result))
    end

    acknowledge_presentation(root)
    assert_receive {Server, ^root, {:skill, :outreach, {:pending, _, _}}}, 5000
    assert effect_count(root, "report.save") == 0
    assert {:ok, _} = Server.input(root, "yes", skill: :outreach)

    assert_receive {:outreach_result, :saved, {:governed, %{outcome: %{status: :succeeded}}}},
                   5000

    assert_receive {:outreach_result, :recalled_after_save, {:ok, _}}, 5000
    {:ok, view} = Server.gam_view(root)
    assert Enum.count(view.acts, &(&1.class == "email.send")) == 1
    assert Enum.count(view.acts, &(&1.class == "report.save")) == 1
    assert Enum.any?(view.evidence, &match?({:spectre_skill_invocation, _}, &1.proposition))
  end

  defp acknowledge_presentation(server) do
    assert_receive {Server.GAM.Managed, _managed, {:presentation, material}}, 5000
    assert :ok = Server.presented(server, material["presentation_ref"])
  end

  defp effect_count(server, class) do
    {:ok, view} = Server.gam_view(server)
    Enum.count(view.acts, &(&1.class == class))
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
