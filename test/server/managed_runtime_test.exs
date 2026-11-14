defmodule Spectre.Server.ManagedRuntimeTest do
  use ExUnit.Case, async: false
  alias Spectre.Server

  defmodule Effect do
    @behaviour Spectre.Server.GAM.EffectAdapter
    @impl true
    def execute_effect(:deliver, %{body: "hold-during-restart"} = args, context) do
      send(Spectre.Server.ManagedRuntimeTest, {:effect_started, self()})

      receive do
        :release_effect ->
          send(Spectre.Server.ManagedRuntimeTest, {:effect, args, context})
          {:ok, %{accepted: true}}
      after
        10_000 -> {:error, :ambiguous, :test_effect_wait_expired}
      end
    end

    def execute_effect(:deliver, %{body: "provider-error"}, _context),
      do: {:error, :failed, %{authorization: "Bearer private-provider-secret"}}

    def execute_effect(:deliver, args, context) do
      send(Spectre.Server.ManagedRuntimeTest, {:effect, args, context})
      {:ok, %{accepted: true}}
    end

    def prepare(:deliver, args, _context), do: {:ok, args}
    def project(:deliver, result), do: {:ok, result}
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :managed_test, version: "0.1.0", spectre: "~> 0.4.0"
    @impl true
    def tools(_) do
      %{
        deliver: %{
          contract: 1,
          adapter: Effect,
          default: :deliver,
          operations: %{deliver: %{path: :governed, operation: :deliver, max_bytes: 1024}}
        }
      }
    end

    @impl true
    def effects(_) do
      %{
        deliver: %{
          contract: 1,
          adapter: Effect,
          operation: :deliver,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
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

    def handle_flow({:test, :send}, %{text: "helper"}, ctx),
      do: deliver(ctx, %{body: "helper"}, on_result: :sent)

    def handle_flow({:test, :send}, %{text: "protect"} = input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, confirmation: [], on_result: :sent)

    def handle_flow({:test, :send}, input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, on_result: :sent)

    def handle_flow({:test, :protected}, input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, on_result: :sent)

    def handle_pending(%{kind: :consent} = pending, %{text: "procedi pure"}, ctx),
      do: confirm_pending(ctx, pending.id)

    def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

    def handle_action(%{args: %{body: "reject"}}, _ctx), do: {:reject, :business_rule}
    def handle_action(%{args: %{body: "short"}}, _ctx), do: {:confirm, %{expires_in: 60_000}}
    def handle_action(%{args: %{body: "invalid-message"}}, _ctx), do: {:confirm, %{message: 42}}
    def handle_action(%{args: %{body: "invalid-expiry"}}, _ctx), do: {:confirm, %{expires_in: -1}}
    def handle_action(%{args: %{body: "invalid-option"}}, _ctx), do: {:confirm, %{unknown: true}}
    def handle_action(action, ctx), do: super(action, ctx)

    def handle_result(:sent, result, ctx) do
      send(Spectre.Server.ManagedRuntimeTest, {:completed, result})
      no_response(ctx)
    end

    def handle_result(:closed, result, ctx) do
      send(Spectre.Server.ManagedRuntimeTest, {:closed, result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_info(:deliver, ctx),
      do: {:noreply, propose(ctx, :deliver, %{body: "from OTP"}, on_result: :sent)}

    def handle_info(:resume_waits, ctx) do
      case Map.values(ctx.pending_by_id) do
        [pending] -> {:noreply, resume_pending(ctx, pending.id)}
        [] -> {:noreply, no_response(ctx)}
      end
    end

    def handle_info(:close_waits, ctx) do
      case Map.values(ctx.pending_by_id) do
        [pending] -> {:noreply, close_pending(ctx, pending.id, on_result: :closed)}
        [] -> {:noreply, no_response(ctx)}
      end
    end

    def handle_info(message, ctx), do: super(message, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App

    flow :test do
      on(:protected, regex: ~r/^protected_route$/, protected: true)
      on(:send, regex: ~r/^(?!protected_route$).*$/)
    end
  end

  defmodule ContractApp do
    use Spectre.Server

    def continuation_contracts, do: %{sent: {:tuple, [{:enum, [:ok]}, :integer]}}

    def handle_flow({:test, :send}, input, ctx),
      do: propose(ctx, :deliver, %{body: input.text}, on_result: :sent)

    def handle_result(:sent, _result, ctx) do
      send(Spectre.Server.ManagedRuntimeTest, :invalid_continuation_entered)
      no_response(ctx)
    end
  end

  @doc false
  @spec custom_interpret(Spectre.Input.t(), Spectre.GAM.Presentation.t()) ::
          :confirm | :reject | :unclear
  def custom_interpret(%Spectre.Input{text: "procedi pure"}, _presentation), do: :confirm

  def custom_interpret(input, presentation),
    do: Server.GAM.Managed.Binding.interpret(input, presentation)

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  defp start(options \\ []) do
    gam =
      Keyword.merge(
        [storage: :ephemeral, operations: %{deliver: [confirm: true]}],
        options
      )

    id = "managed-test-#{System.unique_integer([:positive])}"

    server =
      start_supervised!(
        {Server, agent: Agent, consumer: self(), identity: %{subject: id}, gam: gam}
      )

    {server, id}
  end

  defp presentation do
    assert_receive {Server.GAM.Managed, _managed, {:presentation, material}}, 5_000
    material["presentation_ref"]
  end

  test "public startup always owns GAM and anonymous agents do not collide" do
    {:ok, first} = Server.start_link(agent: Agent, consumer: self())
    {:ok, second} = Server.start_link(agent: Agent, consumer: self())

    on_exit(fn ->
      for pid <- [first, second], Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert {:ok, first_view} = Server.gam_view(first)
    assert {:ok, second_view} = Server.gam_view(second)
    refute first_view == second_view
    assert {:ok, _} = Server.input(first, "send")
    assert_receive {:completed, {:error, _}}, 5_000
    refute_receive {:effect, _, _}
    assert {:ok, _} = Server.input(first, "helper")
    assert_receive {:completed, {:error, {:action_rejected, :operation_not_allowed}}}, 5_000
    refute_receive {:effect, _, _}
    assert {:ok, refused} = Server.gam_view(first)

    assert Enum.any?(refused.evidence, fn evidence ->
             match?({:spectre_action_preparation_rejected, _}, evidence.proposition)
           end)
  end

  test "public startup rejects replacing GAM and malformed app configuration" do
    for replacement <- [nil, false, Server.GAM, {Server.GAM, []}] do
      assert {:error, :gam_requires_configuration_not_bridge} =
               Server.start_link(agent: Agent, gam: replacement)
    end

    assert {:error, :reserved_server_options} = Server.start_link(agent: Agent, skill: %{})
    assert {:error, :invalid_server_identity} = Server.start_link(agent: Agent, identity: "user")

    assert {:error, :invalid_server_submitters} =
             Server.start_link(agent: Agent, submitters: [:any])

    assert {:error, :managed_identity_required_for_durable_storage} =
             Server.start_link(agent: Agent, gam: [storage: {:disk, "/unused"}])
  end

  test "external submissions use the same consent, policy and authoritative record" do
    {server, _} = start()

    assert {:ok, id} =
             Spectre.GAM.submit(server, :deliver, %{body: "external"},
               on_result: :sent,
               confirmation: false
             )

    assert is_binary(id)
    ref = presentation()
    refute_receive {:effect, _, _}
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:effect, %{body: "external"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    assert {:ok, view} = Server.gam_view(server)

    assert Enum.any?(view.evidence, fn evidence ->
             match?({:spectre_external_invocation, ^id}, evidence.proposition)
           end)
  end

  test "external submission cannot forge policy, identity or authenticated consent" do
    {server, _} = start()

    assert {:error, :untrusted_submitter} =
             Task.async(fn -> Spectre.GAM.submit(server, :deliver, %{}) end) |> Task.await()

    for opts <- [
          [action_policy: %{confirm: false}],
          [identity: %{subject: "other"}],
          [external_submission: %{}],
          [bridge_config: []],
          [consent_proof: "fake"],
          [on_result: :sent, on_result: :other]
        ] do
      assert {:error, :invalid_submission_options} =
               Spectre.GAM.submit(server, :deliver, %{}, opts)
    end

    assert {:ok, _} = Spectre.GAM.submit(server, :deliver, %{body: "reject"}, on_result: :sent)
    assert_receive {:completed, {:error, {:action_rejected, :business_rule}}}, 5_000
    refute_receive {:effect, _, _}
    refute_receive {Server.GAM.Managed, _, {:presentation, _}}
  end

  test "an explicitly registered actor may propose but cannot supply consent" do
    parent = self()

    actor =
      spawn(fn ->
        receive do
          {:submit, server} ->
            send(
              parent,
              {:actor_submission,
               Spectre.GAM.submit(server, :deliver, %{body: "actor"}, on_result: :sent)}
            )

            receive do
              {:confirm, ref} ->
                send(parent, {:actor_confirmation, Server.decide(server, nil, ref, :confirm)})
            end
        end
      end)

    on_exit(fn -> if Process.alive?(actor), do: Process.exit(actor, :kill) end)

    {:ok, server} =
      Server.start_link(
        agent: Agent,
        consumer: self(),
        submitters: [actor],
        gam: [operations: %{deliver: [confirm: true]}]
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    send(actor, {:submit, server})
    assert_receive {:actor_submission, {:ok, _}}, 5_000
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    send(actor, {:confirm, ref})
    assert_receive {:actor_confirmation, {:error, :untrusted_consent_transport}}, 5_000
    refute_receive {:effect, _, _}
    assert {:ok, _} = Server.decide(server, nil, ref, :reject)
  end

  @tag :tmp_dir
  test "external request keys survive restart without repeating the effect", %{tmp_dir: path} do
    opts = [
      agent: Agent,
      consumer: self(),
      identity: %{subject: "keyed-subject"},
      gam: [storage: {:disk, path}, operations: %{deliver: [confirm: false]}]
    ]

    {:ok, first} = Server.start_link(opts)

    assert {:ok, id} =
             Spectre.GAM.submit(first, :deliver, %{body: "once"}, key: "job-1", on_result: :sent)

    assert_receive {:effect, %{body: "once"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000

    assert {:ok, ^id} =
             Spectre.GAM.submit(first, :deliver, %{body: "once"}, key: "job-1", on_result: :sent)

    assert {:error, :submission_key_conflict} =
             Spectre.GAM.submit(first, :deliver, %{body: "changed"},
               key: "job-1",
               on_result: :sent
             )

    assert :ok = GenServer.stop(first, :normal, 35_000)
    {:ok, second} = Server.start_link(opts)

    assert {:ok, ^id} =
             Spectre.GAM.submit(second, :deliver, %{body: "once"}, key: "job-1", on_result: :sent)

    refute_receive {:effect, _, _}
    assert :ok = GenServer.stop(second, :normal, 35_000)
  end

  @tag :tmp_dir
  test "supervised disk restart waits for the dead runtime's in-flight effect to drain", %{
    tmp_dir: path
  } do
    opts = [
      agent: Agent,
      consumer: self(),
      identity: %{subject: "draining-restart"},
      gam: [
        storage: {:disk, path},
        shutdown_timeout: 10_000,
        operations: %{deliver: [confirm: false, class: "test.deliver"]}
      ]
    ]

    spec = Server.child_spec(opts)
    assert spec.shutdown == 15_000

    supervisor =
      start_supervised!(%{
        id: :draining_supervisor,
        start: {Supervisor, :start_link, [[spec], [strategy: :one_for_one, max_restarts: 1]]}
      })

    [{_, first, _, _}] = Supervisor.which_children(supervisor)
    assert {:ok, _} = Server.input(first, "hold-during-restart")
    assert_receive {:effect_started, executor}, 5_000
    {_, bridge} = :sys.get_state(first).gam
    managed = bridge[:server]
    managed_monitor = Process.monitor(managed)
    runtime_monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^runtime_monitor, :process, ^first, :killed}

    # The supervisor is waiting for storage; it must not exhaust restart intensity.
    restart = Task.async(fn -> Supervisor.which_children(supervisor) end)
    assert Task.yield(restart, 100) == nil
    send(executor, :release_effect)
    assert_receive {:effect, %{body: "hold-during-restart"}, _}, 5_000
    assert_receive {:DOWN, ^managed_monitor, :process, ^managed, _}, 5_000
    [{_, second, _, _}] = Task.await(restart, 5_000)
    assert is_pid(second) and second != first
    assert Process.alive?(supervisor)
    assert {:ok, view} = Server.gam_view(second)
    assert Enum.count(view.acts, &(&1.class == "test.deliver")) == 1
    refute_receive {:effect_started, _}
  end

  test "tenant identity is normalized and frozen consistently through execution" do
    {:ok, server} =
      Server.start_link(
        agent: Agent,
        consumer: self(),
        identity: %{"subject" => "shared-id", "tenant" => "north", "org" => "agency"},
        gam: [operations: %{deliver: [confirm: false]}]
      )

    assert {:ok, _} = Server.input(server, "send")

    assert_receive {:effect, _,
                    %{identity: %{subject: "shared-id", tenant: "north", org: "agency"}}},
                   5_000

    assert_receive {:completed, {:governed, %{act: act, outcome: %{status: :succeeded}}}}, 5_000

    assert act.consequence["execution_identity"] == %{
             "subject" => "shared-id",
             "tenant" => "north",
             "org" => "agency"
           }

    GenServer.stop(server)
  end

  test "audit is consumer-bound and public commands cannot forge external provenance" do
    {server, _} = start()

    assert {:error, :untrusted_audit_transport} =
             Task.async(fn -> Server.gam_view(server) end) |> Task.await()

    command = %Server.Command{
      kind: :propose,
      args: [:deliver, %{}],
      opts: [external_submission: %{source: :external_actor, submitter_ref: "forged"}]
    }

    assert {:error, :reserved_submission_options} = Server.Command.validate(command)
    assert {:ok, _} = Server.gam_view(server)
  end

  test "provider errors do not persist raw credentials in the ledger" do
    {server, _} = start(operations: %{deliver: [confirm: false]})
    assert {:ok, _} = Server.input(server, "provider-error")
    assert_receive {:completed, {:governed, %{outcome: %{status: :failed}}}}, 5_000
    assert {:ok, view} = Server.gam_view(server)

    refute inspect(view, limit: :infinity, printable_limit: :infinity) =~
             "private-provider-secret"

    assert Enum.any?(view.evidence, &match?(%{reason: %{digest: _}}, &1.payload))
  end

  test "human consent is required and recorded, with private Scope and frozen execution" do
    {server, subject} = start()
    assert {:ok, _} = Server.input(server, "send")
    ref = presentation()
    refute_receive {:effect, _, _}
    assert {:error, _} = Task.async(fn -> Server.presented(server, ref) end) |> Task.await()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000

    assert {:error, _} =
             Task.async(fn -> Server.decide(server, nil, ref, :confirm) end) |> Task.await()

    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:effect, %{body: "send"}, context}, 5_000
    assert context.identity.subject == subject
    refute Map.has_key?(context, :managed)
    refute Keyword.has_key?(context.options, :gam)
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    assert {:error, _} = Server.decide(server, nil, ref, :confirm)
    refute_receive {:effect, _, _}
    assert {:ok, view} = Server.gam_view(server)
    assert length(view.acts) >= 2
  end

  test "trusted text and ordinary OTP callbacks use the same admitted path" do
    {server, _} = start()
    send(server, :deliver)
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.input(server, "yes")
    assert_receive {:effect, %{body: "from OTP"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
  end

  test "business rejection is observed without showing or executing an effect" do
    {server, _} = start()
    assert {:ok, _} = Server.input(server, "reject")
    assert_receive {:completed, {:error, {:action_rejected, :business_rule}}}, 5_000
    refute_receive {Server.GAM.Managed, _, {:presentation, _}}
    refute_receive {:effect, _, _}
    assert {:ok, view} = Server.gam_view(server)
    assert inspect(view.evidence) =~ "spectre_action_preparation_rejected"
  end

  test "rejection needs a human decision and never executes" do
    {server, _} = start()
    assert {:ok, _} = Server.input(server, "send")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :reject)
    assert_receive {:completed, {:consent, :rejected}}, 5_000
    refute_receive {:effect, _, _}
  end

  test "explicit confirmation provides the standard presentation when default consent is disabled" do
    {server, _} = start(operations: %{deliver: [confirm: false]})
    assert {:ok, _} = Server.input(server, "protect")
    ref = presentation()
    refute_receive {:effect, _, _}
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:effect, %{body: "protect"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}, act: act}}}, 5_000
    assert act.consequence["managed_policy"]["confirm"] == true
  end

  test "a protected route supplies the standard confirmation builder independently of operation defaults" do
    {server, _} = start(operations: %{deliver: [confirm: false]})
    assert {:ok, _} = Server.input(server, "protected_route")
    ref = presentation()
    refute_receive {:effect, _, _}
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:effect, %{body: "protected_route"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}, act: act}}}, 5_000
    assert act.consequence["managed_policy"]["confirm"] == true
  end

  @tag :tmp_dir
  test "disk recovery preserves acts and rejects changed authority", %{tmp_dir: path} do
    identity = %{subject: "disk-user"}

    gam = [
      storage: {:disk, path},
      operations: %{deliver: [confirm: false]}
    ]

    opts = [agent: Agent, consumer: self(), identity: identity, gam: gam]
    {:ok, first} = Server.start_link(opts)
    assert {:ok, _} = Server.input(first, "send")
    assert_receive {:effect, %{body: "send"}, _}, 5_000
    assert_receive {:completed, {:governed, %{act: original}}}, 5_000
    assert :ok = GenServer.stop(first, :normal, 35_000)
    {:ok, second} = Server.start_link(opts)
    assert {:ok, recovered} = Server.gam_view(second)
    assert Enum.any?(recovered.acts, &(&1.ref == original.ref))
    assert :ok = GenServer.stop(second, :normal, 35_000)
    changed = Keyword.put(gam, :operations, %{deliver: [confirm: true]})
    assert {:error, _} = Server.start_link(Keyword.put(opts, :gam, changed))
  end

  test "invalid callback policy is rejected before presentation or execution" do
    {server, _} = start(operations: %{deliver: [confirm: false]})

    for text <- ["invalid-message", "invalid-expiry", "invalid-option"] do
      assert {:ok, _} = Server.input(server, text)
      assert_receive {:completed, {:error, :invalid_managed_action_policy}}, 5_000
      refute_receive {Server.GAM.Managed, _, {:presentation, _}}
      refute_receive {:effect, _, _}
    end
  end

  @tag :tmp_dir
  test "ephemeral authority cannot recover an external store or persistent checkpoint", %{
    tmp_dir: path
  } do
    store = start_supervised!({Server.Store.Disk, path: Path.join(path, "coordination")})
    base = [agent: Agent, consumer: self(), identity: %{subject: "storage-user"}]

    config = [
      storage: :ephemeral,
      operations: %{deliver: [confirm: false]}
    ]

    assert {:error, :managed_ephemeral_storage_cannot_recover_external_state} =
             Server.start_link(base ++ [gam: Keyword.put(config, :store, store)])

    assert {:error, :managed_ephemeral_storage_cannot_recover_external_state} =
             Server.start_link(base ++ [gam: config, checkpoint: {store, :agent}])
  end

  @tag :tmp_dir
  test "forced consent survives disk recovery and fresh resume before any effect", %{
    tmp_dir: path
  } do
    store = start_supervised!({Server.Store.Disk, path: Path.join(path, "coordination")})

    opts = [
      agent: Agent,
      consumer: self(),
      identity: %{subject: "recovery-human"},
      checkpoint: {store, :agent},
      gam: [
        storage: {:disk, Path.join(path, "domain")},
        operations: %{deliver: [confirm: false]}
      ]
    ]

    {:ok, first} = Server.start_link(opts)
    assert {:ok, _} = Server.input(first, "short")
    old_ref = presentation()
    assert :ok = Server.presented(first, old_ref)
    assert_receive {Server, ^first, {:pending, _, _}}, 5_000
    [old_pending] = Server.status(first).pending
    assert old_pending.candidate.consequence["managed_policy"]["confirm"] == true
    assert old_pending.candidate.consequence["managed_policy"]["expires_in"] == 60_000
    assert :ok = GenServer.stop(first, :normal, 35_000)
    {:ok, second} = Server.start_link(opts)
    [recovered] = Server.status(second).pending
    assert recovered.status == :suspended
    assert {:error, _} = Server.decide(second, nil, old_ref, :confirm)
    refute_receive {:effect, _, _}
    send(second, :resume_waits)
    new_ref = presentation()
    assert :ok = Server.presented(second, new_ref)
    assert_receive {Server, ^second, {:pending, _, _}}, 5_000
    [fresh] = Server.status(second).pending
    assert fresh.show.primary.act.ref != recovered.show.primary.act.ref
    assert fresh.expires_at - System.system_time(:millisecond) <= 60_000
    assert {:ok, _} = Server.decide(second, nil, new_ref, :confirm)
    assert_receive {:effect, %{body: "short"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    refute_receive {:effect, _, _}
    assert :ok = GenServer.stop(second, :normal, 35_000)
  end

  @tag :tmp_dir
  test "audited closure removes infinite Gate presentation and proofs", %{tmp_dir: path} do
    store = start_supervised!({Server.Store.Disk, path: Path.join(path, "coordination")})

    {:ok, server} =
      Server.start_link(
        agent: Agent,
        consumer: self(),
        identity: %{subject: "close-human"},
        checkpoint: {store, :agent},
        gam: [
          storage: {:disk, Path.join(path, "domain")},
          consent_ttl_ms: :infinity,
          operations: %{deliver: [confirm: true]}
        ]
      )

    assert {:ok, _} = Server.input(server, "send")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    managed = :sys.get_state(server).managed_owner
    gate = :sys.get_state(managed).gate
    assert map_size(:sys.get_state(gate).shows) == 1
    send(server, :close_waits)
    assert_receive {:closed, {:pending_lifecycle, %{kind: :close, status: :applied}}}, 5_000
    assert Server.status(server).pending == []
    assert map_size(:sys.get_state(gate).shows) == 0
    assert map_size(:sys.get_state(gate).proofs) == 0
    refute_receive {:effect, _, _}
    assert :ok = GenServer.stop(server, :normal, 35_000)
  end

  test "resume cannot replace the frozen callback policy with new command options" do
    {server, subject} = start(operations: %{deliver: [confirm: false]})
    assert {:ok, _} = Server.input(server, "short")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    [pending] = Server.status(server).pending
    managed = :sys.get_state(server).managed_owner

    context = %{
      agent: Agent,
      identity: %{subject: subject},
      options: [],
      routing: %{},
      input: Spectre.Input.new("resume"),
      command_id: "manual-resume-policy",
      skill: nil,
      interaction: nil
    }

    task =
      Task.async(fn ->
        Server.GAM.Managed.resume(pending, context.input, context,
          bridge_config: [server: managed],
          action_policy: %{confirm: false, expires_in: 900_000, message: "changed"}
        )
      end)

    next_ref = presentation()
    assert :ok = Server.presented(server, next_ref)
    assert {:pending, resumed} = Task.await(task, 5_000)
    assert resumed.expires_at - System.system_time(:millisecond) <= 60_000
    assert resumed.candidate.consequence["managed_policy"]["confirm"] == true
    assert resumed.candidate.consequence["managed_policy"]["expires_in"] == 60_000
    refute resumed.presentation.rendered_payload =~ "changed"
    gate = :sys.get_state(managed).gate
    assert map_size(:sys.get_state(gate).shows) == 1
    refute_receive {:effect, _, _}
  end

  test "custom interpreter accepts a real consumer phrase but not an actor's phrase" do
    {server, _} = start(bindings: %{deliver: %{interpreter: {__MODULE__, :custom_interpret}}})
    assert {:ok, _} = Server.input(server, "send")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Task.async(fn -> Server.input(server, "procedi pure") end) |> Task.await()
    assert_receive {:completed, {:error, :consent_transport_proof_required}}, 5_000
    refute_receive {:effect, _, _}
    assert {:ok, _} = Server.input(server, "procedi pure")
    assert_receive {:effect, %{body: "send"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
  end

  test "input provenance does not make the default interpreter accept an unknown phrase" do
    {server, _} = start()
    assert {:ok, _} = Server.input(server, "send")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.input(server, "procedi pure")
    assert_receive {:completed, {:error, :confirmation_unclear}}, 5_000
    refute_receive {:effect, _, _}
    assert {:ok, _} = Server.input(server, "yes")
    assert_receive {:effect, %{body: "send"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
  end

  @tag :tmp_dir
  test "diagnostics authenticate the actual consumer and reject privilege-shaped options", %{
    tmp_dir: path
  } do
    server = diagnostics_server(path)

    task =
      Task.async(fn ->
        [
          Server.inspect(server),
          Server.trace(server, "unknown"),
          Server.gam_inspect(server),
          Server.subscribe(server)
        ]
      end)

    assert List.duplicate({:error, :untrusted_audit_transport}, 4) == Task.await(task)
    assert {:ok, _} = Server.inspect(server)

    for opts <- [[scope: :domain], [consumer: self()], [limit: 1, limit: 2]] do
      assert {:error, :invalid_diagnostic_options} = Server.inspect(server, opts)
      assert {:error, :invalid_diagnostic_options} = Server.trace(server, "unknown", opts)
      assert {:error, :invalid_diagnostic_options} = Server.gam_inspect(server, opts)
    end

    assert {:ok, %{total: 0, coverage: %{complete: false}, gam: %{total: 0}}} =
             Server.trace(server, "unknown")
  end

  @tag :tmp_dir
  test "diagnostics publish invalidations and correlate consent and outcomes without payloads", %{
    tmp_dir: path
  } do
    server = diagnostics_server(path)
    assert :ok = Server.subscribe(server)
    assert :ok = Server.subscribe(server)
    assert {:ok, interaction} = Server.input(server, "PRIVATE DIAGNOSTIC BODY")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000

    assert_receive {Server, ^server,
                    {:diagnostics_changed, %{source: :checkpoint, revision: checkpoint_revision}}},
                   5_000

    assert_receive {Server, ^server,
                    {:diagnostics_changed, %{source: :gam, revision: gam_revision}}},
                   5_000

    assert is_integer(checkpoint_revision)
    assert is_integer(gam_revision)

    assert {:ok, operational} = Server.inspect(server)
    assert operational.checkpoint.pending == 1
    refute inspect(operational) =~ "PRIVATE DIAGNOSTIC BODY"

    assert {:ok, pending_trace} = Server.trace(server, interaction, limit: 100)
    assert pending_trace.coverage.complete == false
    assert Enum.any?(pending_trace.gam.records, &(&1.kind == :presentation and &1.ref == ref))

    assert Enum.any?(
             pending_trace.gam.records,
             &(&1.kind == :evidence and &1[:interaction_id] == interaction)
           )

    refute inspect(pending_trace) =~ "PRIVATE DIAGNOSTIC BODY"
    refute Map.has_key?(pending_trace.gam, :scope)

    assert {:ok, first_page} = Server.gam_inspect(server, limit: 1)
    assert length(first_page.records) == 1
    assert first_page.next_cursor != nil
    assert {:ok, next_page} = Server.gam_inspect(server, limit: 1, cursor: first_page.next_cursor)
    assert next_page.revision == first_page.revision
    refute next_page.records == first_page.records

    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:effect, %{body: "PRIVATE DIAGNOSTIC BODY"}, _}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    assert {:error, :stale_cursor} = Server.gam_inspect(server, cursor: first_page.next_cursor)
    assert {:ok, completed_trace} = Server.trace(server, interaction, limit: 100)
    assert Enum.any?(completed_trace.gam.records, &(&1.kind == :act))
    assert Enum.any?(completed_trace.gam.records, &(&1.kind == :outcome))
    refute inspect(completed_trace) =~ "PRIVATE DIAGNOSTIC BODY"
  end

  @tag :tmp_dir
  test "governed contract failures preserve GAM outcome and never reexecute after restore", %{
    tmp_dir: path
  } do
    store = start_supervised!({Server.Store.Disk, path: Path.join(path, "contract-coordination")})

    opts = [
      agent: Agent,
      server: ContractApp,
      consumer: self(),
      identity: %{subject: "contract-human"},
      checkpoint: {store, :agent},
      gam: [
        storage: {:disk, Path.join(path, "contract-gam")},
        operations: %{deliver: [confirm: false]}
      ]
    ]

    {:ok, server} = Server.start_link(opts)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    {:ok, interaction} = Server.input(server, "PRIVATE CONTRACT BODY")
    assert_receive {:effect, %{body: "PRIVATE CONTRACT BODY"}, _}, 5_000

    assert_receive {Server, ^server, {:callback_error, ^interaction, :handle_result, failure}},
                   5_000

    assert failure.kind == :contract
    refute inspect(failure) =~ "PRIVATE CONTRACT BODY"
    refute_receive :invalid_continuation_entered

    [letter] = Map.values(Server.status(server).dead_letters)
    assert is_binary(letter.source.act_ref)
    assert is_binary(letter.source.outcome_ref)
    assert {:ok, trace} = Server.trace(server, interaction, limit: 100)

    assert Enum.any?(
             trace.records,
             &(&1.collection == :dead_letters and &1.command_id == failure.command_id)
           )

    assert Enum.any?(
             trace.gam.records,
             &(&1.kind == :outcome and &1.ref == letter.source.outcome_ref)
           )

    assert :ok = GenServer.stop(server)

    {:ok, restored} = Server.start_link(opts)
    on_exit(fn -> if Process.alive?(restored), do: GenServer.stop(restored) end)
    assert map_size(Server.status(restored).dead_letters) == 1
    refute_receive {:effect, _, _}
    refute_receive :invalid_continuation_entered
  end

  @tag :tmp_dir
  test "diagnostic process group restart preserves the Domain and restores subscriptions", %{
    tmp_dir: path
  } do
    server = diagnostics_server(path)
    managed = :sys.get_state(server).managed_owner
    domain = :sys.get_state(managed).domain
    domain_ref = :sys.get_state(managed).refs.domain
    registry = Spectre.GAM.Domain.Notifications

    assert :ok = Server.subscribe(server)
    assert :ok = Server.subscribe(server)
    assert :pg.get_local_members(registry, domain_ref) == [managed]

    old_registry = Process.whereis(registry)
    Process.exit(old_registry, :kill)

    diagnostics_eventually(fn ->
      replacement = Process.whereis(registry)

      replacement != nil and replacement != old_registry and
        :pg.get_local_members(registry, domain_ref) == [managed]
    end)

    assert Process.alive?(server)
    assert Process.alive?(managed)
    assert Process.alive?(domain)
    assert :sys.get_state(managed).domain == domain
    assert :ok = Server.subscribe(server)
    assert :pg.get_local_members(registry, domain_ref) == [managed]

    # Recovering subscription also invalidates a stale inspector even when no
    # later effect happens to produce another commit.
    assert {:ok, current} = Server.gam_inspect(server)
    revision = current.revision

    assert_receive {Server, ^server,
                    {:diagnostics_changed, %{source: :gam, revision: ^revision}}},
                   5_000

    assert {:ok, _} = Server.input(server, "notifications recovered")
    ref = presentation()
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert_receive {Server, ^server, {:diagnostics_changed, %{source: :gam}}}, 5_000
    assert {:ok, _} = Server.gam_inspect(server)
  end

  @tag :tmp_dir
  test "slow diagnostic reads and legacy views cannot block checkout or terminate the Domain", %{
    tmp_dir: path
  } do
    server = diagnostics_server(path)
    managed = :sys.get_state(server).managed_owner
    domain = :sys.get_state(managed).domain
    :ok = :sys.suspend(domain)

    try do
      for query <- [&Server.gam_inspect/1, &Server.gam_view/1] do
        probe =
          Task.async(fn ->
            diagnostics_eventually(fn ->
              {:messages, messages} = Process.info(domain, :messages)
              Enum.any?(messages, &match?({:"$gen_call", _, {:query, _, _}}, &1))
            end)

            assert {:ok, _} = GenServer.call(managed, :checkout, 250)
            GenServer.cast(managed, {:checkin, self()})
            :ok
          end)

        assert {:error, :diagnostic_source_unavailable} = query.(server)
        assert :ok = Task.await(probe)
        assert Process.alive?(server)
        assert Process.alive?(managed)
        assert Process.alive?(domain)
      end
    after
      :sys.resume(domain)
    end

    assert {:ok, _} = Server.gam_inspect(server)
  end

  @tag :tmp_dir
  test "a subscription accepted while notifications are unavailable retains checkpoint delivery",
       %{tmp_dir: path} do
    server = diagnostics_server(path)
    notifier = Spectre.GAM.Domain.Notifications
    supervisor = Spectre.GAM.ApplicationSupervisor
    managed = :sys.get_state(server).managed_owner
    domain_ref = :sys.get_state(managed).refs.domain
    assert :ok = Supervisor.terminate_child(supervisor, notifier)

    try do
      assert :ok = Server.subscribe(server)
      assert :sys.get_state(server).opts[:diagnostics_notifications]
      assert {:ok, _} = Server.input(server, "pending subscription")
      ref = presentation()
      assert :ok = Server.presented(server, ref)
      assert_receive {Server, ^server, {:pending, _, _}}, 5_000
      assert_receive {Server, ^server, {:diagnostics_changed, %{source: :checkpoint}}}, 5_000
      assert {:ok, _} = Supervisor.restart_child(supervisor, notifier)
      diagnostics_eventually(fn -> managed in :pg.get_local_members(notifier, domain_ref) end)
      assert_receive {Server, ^server, {:diagnostics_changed, %{source: :gam}}}, 5_000
      assert Process.alive?(server)
    after
      if Process.whereis(notifier) == nil, do: Supervisor.restart_child(supervisor, notifier)
    end
  end

  defp diagnostics_eventually(check, attempts \\ 100)
  defp diagnostics_eventually(check, 0), do: assert(check.())

  defp diagnostics_eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(10)
      diagnostics_eventually(check, attempts - 1)
    end
  end

  defp diagnostics_server(path) do
    store =
      start_supervised!({Server.Store.Disk, path: Path.join(path, "diagnostic-coordination")})

    start_supervised!(
      {Server,
       agent: Agent,
       consumer: self(),
       identity: %{subject: "diagnostic-human"},
       checkpoint: {store, :agent},
       gam: [
         storage: {:disk, Path.join(path, "diagnostic-gam")},
         operations: %{deliver: [confirm: true]}
       ]}
    )
  end
end
