defmodule Spectre.Server.ActivityFenceTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.Ledger.Store, as: Ledger
  alias Spectre.Server.Activities
  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.Store.Port, as: Store

  defmodule Effect do
    @behaviour Spectre.Server.GAM.EffectAdapter

    @impl true
    def execute_effect(:deliver, args, context) do
      send(Spectre.Server.ActivityFenceTest, {:effect, args, context.activity})
      {:ok, :delivered}
    end
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :activity_fence_test, version: "0.1.0", spectre: "~> 0.4.0"

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
    use Spectre.Server
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
  end

  defmodule Interpreter do
    def interpret(%Spectre.Input{text: "hold"}, _) do
      send(Spectre.Server.ActivityFenceTest, {:interpreting, self()})

      receive do
        :release -> :confirm
      after
        5_000 -> :unclear
      end
    end

    def interpret(input, presentation), do: Managed.Binding.interpret(input, presentation)
  end

  defmodule HeldLedger do
    @behaviour Ledger

    @impl true
    def append(domain, batch, payloads, revision, opts) do
      {inner, opts} = Keyword.pop!(opts, :inner)

      if Enum.any?(
           payloads,
           &match?(%{"type" => "act_committed", "data" => %{"class" => "test.deliver"}}, &1)
         ) do
        send(Spectre.Server.ActivityFenceTest, {:appending_admission, self()})

        receive do
          :commit -> :ok
        after
          5_000 -> raise "admission barrier not released"
        end
      end

      Ledger.append(inner, domain, batch, payloads, revision, opts)
    end

    @impl true
    def load(domain, opts) do
      {inner, opts} = Keyword.pop!(opts, :inner)
      Ledger.load(inner, domain, opts)
    end

    @impl true
    def lookup_batch(domain, batch, opts) do
      {inner, opts} = Keyword.pop!(opts, :inner)
      Ledger.lookup_batch(inner, domain, batch, opts)
    end

    @impl true
    def export(domain, opts) do
      {inner, opts} = Keyword.pop!(opts, :inner)
      Ledger.export(inner, domain, opts)
    end
  end

  defmodule FaultStore do
    @behaviour Spectre.Server.Store

    @impl true
    def fetch({inner, faults}, key) do
      case :ets.take(faults, :fetch) do
        [{:fetch, :offline}] -> raise "store offline"
        [{:fetch, :busy}] -> {:error, :store_busy}
        [] -> Store.fetch(inner, key)
      end
    end

    @impl true
    def put_new({inner, faults}, key, value) do
      case :ets.take(faults, :put_new) do
        [{:put_new, :busy}] -> {:error, :store_busy}
        [] -> Store.put_new(inner, key, value)
      end
    end

    @impl true
    def compare_and_swap({inner, faults}, key, revision, value) do
      result = Store.compare_and_swap(inner, key, revision, value)

      case :ets.take(faults, :compare_and_swap) do
        [{:compare_and_swap, :lose_acknowledgement}] -> exit(:lost_acknowledgement)
        [] -> result
      end
    end

    @impl true
    def delete({inner, _faults}, key, revision), do: Store.delete(inner, key, revision)
  end

  defmodule WaitingChild do
    use GenServer

    def start_link(opts),
      do:
        GenServer.start_link(
          __MODULE__,
          Keyword.fetch!(opts, :observer),
          Keyword.take(opts, [:name])
        )

    @impl true
    def init(observer), do: {:ok, observer}

    @impl true
    def handle_info({Activities, _, :cancel, revision}, observer) do
      send(observer, {:cancel, revision})
      {:stop, :normal, observer}
    end

    def handle_info({Activities, _, action, value}, observer) do
      send(observer, {action, value})
      {:noreply, observer}
    end

    def handle_info({Activities, _, :signal, revision, signal}, observer) do
      send(observer, {:signal, revision, signal})
      {:noreply, observer}
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    :ok
  end

  for mode <- [:memory, :durable] do
    @tag :tmp_dir
    test "revision wins against the in-flight consent in #{mode}", %{tmp_dir: path} do
      {owner, control, opts} = start_managed(unquote(mode), path)
      ref = start_activity(owner, control)
      {pending, proof} = prepare_consent(owner, control, ref)
      context = context(ref, 0, Spectre.Input.new("hold")) |> Map.put(:consent_proof, proof)

      confirmation =
        Task.async(fn ->
          Managed.confirm(pending, context.input, context, bridge(owner, control))
        end)

      assert_receive {:interpreting, interpreter}, 5_000

      transition = transition(ref, :revise)

      assert {:error, :activity_fence_unavailable} =
               Managed.fence_activity(owner, make_ref(), transition)

      assert {:error, :invalid_activity_transition} =
               Managed.fence_activity(owner, control, %{transition | revision: -1})

      assert {:ok, 1} = Managed.fence_activity(owner, control, transition)
      send(interpreter, :release)
      assert {:error, :superseded} = Task.await(confirmation, 5_000)
      refute_receive {:effect, _, _}
      assert {:ok, 1} = Managed.fence_activity(owner, control, transition)

      assert {:error, :superseded} =
               Managed.fence_activity(owner, control, transition(ref, :cancel))

      assert {:error, :superseded} =
               Managed.confirm(pending, context.input, context, bridge(owner, control))

      if unquote(mode) == :durable do
        assert :ok = Managed.close(owner)
        {:ok, reopened} = Managed.start_link(opts)
        on_exit(fn -> Managed.close(reopened) end)
        {:ok, {_coordinator, control}} = Managed.activity_owner(reopened, :start)
        assert {:ok, 1} = Managed.fence_activity(reopened, control, transition)

        recovered = %{context | activity: %{ref: ref, revision: 1}}

        assert {:error, :superseded} =
                 Managed.recover_command(context.command_id, recovered, bridge(reopened, control))
      end
    end

    @tag :tmp_dir
    test "an admission at the real #{mode} ledger commit survives cancellation", %{tmp_dir: path} do
      {owner, control, _opts} = start_managed(unquote(mode), path)
      ref = start_activity(owner, control)
      {pending, proof} = prepare_consent(owner, control, ref)
      context = context(ref, 0, Spectre.Input.new("confermo")) |> Map.put(:consent_proof, proof)
      %{domain: domain} = :sys.get_state(owner)
      :sys.replace_state(domain, &%{&1 | store: {HeldLedger, inner: &1.store}})

      approval =
        Task.async(fn ->
          Managed.confirm(pending, context.input, context, bridge(owner, control))
        end)

      assert_receive {:appending_admission, ^domain}, 5_000

      transition = transition(ref, :cancel)

      cancellation =
        try do
          task = Task.async(fn -> Managed.fence_activity(owner, control, transition) end)
          assert_waiting_fence(domain, transition)
          task
        after
          send(domain, :commit)
        end

      assert {:ok, 1} = Task.await(cancellation, 5_000)

      assert {:governed, %{act: %{ref: act}, outcome: %{ref: outcome, status: :succeeded}}} =
               Task.await(approval, 5_000)

      assert_receive {:effect, %{body: "hello"}, %{ref: ^ref, revision: 0}}, 5_000
      recovered = %{context | activity: %{ref: ref, revision: 1}}

      assert {:ok, 1} = Managed.fence_activity(owner, control, transition)

      assert {:error, :activity_transition_conflict} =
               Managed.fence_activity(owner, control, %{transition | revision: 1, kind: :revise})

      assert {:error, :superseded} =
               Managed.fence_activity(owner, control, %{transition(ref, :revise) | revision: 1})

      assert :ok = Managed.retire_activity(owner, control, ref)
      assert :ok = Managed.retire_activity(owner, control, ref)

      assert {:governed, %{act: %{ref: ^act}, outcome: %{ref: ^outcome, status: :succeeded}}} =
               Managed.recover_command(context.command_id, recovered, bridge(owner, control))

      refute_receive {:effect, _, _}

      assert {:error, :unknown_activity} =
               Managed.confirm(pending, context.input, context, bridge(owner, control))
    end
  end

  test "concurrent consent and revision keep one admission per Activity" do
    {owner, control, _opts} = start_managed(:memory, nil)
    :rand.seed(:exsss, {14, 81, 54})

    for _ <- 1..6 do
      ref = start_activity(owner, control)
      {pending, proof} = prepare_consent(owner, control, ref)
      context = context(ref, 0, Spectre.Input.new("confermo")) |> Map.put(:consent_proof, proof)

      approval =
        gated_task(fn ->
          Managed.confirm(pending, context.input, context, bridge(owner, control))
        end)

      revision =
        gated_task(fn -> Managed.fence_activity(owner, control, transition(ref, :revise)) end)

      Enum.each(Enum.shuffle([approval, revision]), &send(&1.pid, :race))

      assert {:ok, 1} = Task.await(revision, 5_000)

      case Task.await(approval, 5_000) do
        {:governed, %{outcome: %{status: :succeeded}}} ->
          assert_receive {:effect, %{body: "hello"}, %{ref: ^ref, revision: 0}}, 5_000

        {:error, :superseded} ->
          :ok
      end

      refute_receive {:effect, _, %{ref: ^ref}}
    end
  end

  test "closing the presentation after fencing reports supersession to an in-flight decision" do
    {owner, control, _opts} = start_managed(:memory, nil)
    ref = start_activity(owner, control)
    {pending, proof} = prepare_consent(owner, control, ref)
    context = context(ref, 0, Spectre.Input.new("hold")) |> Map.put(:consent_proof, proof)

    confirmation =
      Task.async(fn ->
        Managed.confirm(pending, context.input, context, bridge(owner, control))
      end)

    assert_receive {:interpreting, interpreter}, 5_000
    show_ref = pending.show.primary.act.ref

    assert {:error, :untrusted_activity_transport} =
             Managed.close_activity_show(owner, make_ref(), show_ref)

    assert {:ok, 1} = Managed.fence_activity(owner, control, transition(ref, :cancel))
    assert :ok = Managed.close_activity_show(owner, control, show_ref)
    send(interpreter, :release)
    assert {:error, :superseded} = Task.await(confirmation, 5_000)
    refute_receive {:effect, _, _}
  end

  test "lost fence acknowledgement pauses the Activity until the same transition is confirmed" do
    {owner, control, _opts} = start_managed(:memory, nil)
    {:ok, {coordinator, ^control}} = Managed.activity_owner(owner, :existing)
    {store, faults, domain_ref} = fail_fence_store(owner)
    ref = start_waiting(coordinator)
    key = {:spectre_activity_fence, domain_ref, ref}

    :ets.insert(faults, {:compare_and_swap, :lose_acknowledgement})
    revision = transition(ref, :revise)
    signal = {:signal, {:revise, :new_work}}
    id = revision.transition_id

    assert {:pending, ^id} = Activities.control(coordinator, ref, id, signal, if_revision: 0)
    assert_receive {:pause, 0}
    assert {:ok, %{value: %{revision: 1, transition_id: ^id}}} = Store.fetch(store, key)
    assert {:ok, %{revision: 0}} = Activities.view(coordinator, ref)
    assert {:pending, ^id} = Activities.control(coordinator, ref, id, signal, [])

    assert {:error, :activity_busy} =
             Activities.control(coordinator, ref, "competing", :cancel, [])

    refute_received {:signal, _, _}

    assert_receive {:signal, 1, {:revise, :new_work}}, 5_000
    assert {:ok, %{revision: 1}} = Activities.control(coordinator, ref, id, signal, [])

    assert {:error, :superseded} =
             Activities.control(coordinator, ref, "stale", :cancel, if_revision: 0)

    assert {:ok, %{revision: 1}} =
             Activities.control(coordinator, ref, "nudge", {:signal, :nudge}, [])

    assert_receive {:signal, 1, :nudge}
    refute_received {:signal, _, {:revise, :new_work}}
  end

  test "missing, unavailable or corrupt fence records cannot authorize an effect" do
    {owner, control, _opts} = start_managed(:memory, nil)
    {:ok, {coordinator, ^control}} = Managed.activity_owner(owner, :existing)
    {store, faults, domain_ref} = fail_fence_store(owner)

    :ets.insert(faults, {:put_new, :busy})

    assert {:error, :store_busy} =
             Managed.register_activity(owner, control, "failed-registration")

    assert {:error, :invalid_activity_ref} = Managed.register_activity(owner, control, "")
    assert {:error, :invalid_activity_ref} = Managed.retire_activity(owner, control, "")

    ref = start_waiting(coordinator)
    assert :ok = Managed.register_activity(owner, control, ref)
    {pending, proof} = prepare_consent(owner, control, ref)
    context = context(ref, 0, Spectre.Input.new("confermo")) |> Map.put(:consent_proof, proof)

    :ets.insert(faults, {:fetch, :busy})
    assert {:error, :store_busy} = Managed.retire_activity(owner, control, ref)
    :ets.insert(faults, {:fetch, :offline})

    assert {:error, :activity_fence_store_unavailable} =
             Managed.confirm(pending, context.input, context, bridge(owner, control))

    key = {:spectre_activity_fence, domain_ref, ref}
    assert {:ok, %{revision: version}} = Store.fetch(store, key)
    assert {:ok, version} = Store.compare_and_swap(store, key, version, %{revision: -1})

    assert {:error, :invalid_activity_fence} =
             Managed.confirm(pending, context.input, context, bridge(owner, control))

    assert {:error, :invalid_activity_fence} =
             Activities.control(coordinator, ref, "cancel-corrupt", :cancel, [])

    assert_receive {:cancel, 1}
    assert {:ok, %{status: :failed}} = Activities.view(coordinator, ref)

    assert {:error, :inactive_activity} =
             Activities.control(coordinator, ref, "already-failed", :cancel, [])

    assert :ok = Store.delete(store, key, version)
    missing = context("missing-record", 0, Spectre.Input.new("hello"))

    assert {:error, :unknown_activity} =
             Managed.propose(:deliver, %{body: "hello"}, missing, bridge(owner, control))

    refute_receive {:effect, _, _}
    refute_received {Managed, ^owner, {:presentation, _}}
  end

  defp start_waiting(coordinator) do
    assert {:ok, ref} =
             Activities.start(
               coordinator,
               Spectre.Identity.uuid7(),
               {WaitingChild, [observer: self()]}
             )

    assert_receive {:activate, ^ref}
    ref
  end

  defp fail_fence_store(owner) do
    %{domain: domain, refs: %{domain: domain_ref}} = :sys.get_state(owner)
    %{activity_fence: {token, store}} = :sys.get_state(domain)
    faults = :ets.new(:activity_fence_faults, [:public])

    :sys.replace_state(domain, &%{&1 | activity_fence: {token, {FaultStore, {store, faults}}}})
    {store, faults, domain_ref}
  end

  defp gated_task(fun) do
    Task.async(fn ->
      receive do
        :race -> fun.()
      end
    end)
  end

  defp start_managed(mode, path) do
    opts = [
      agent: Agent,
      identity: %{subject: Spectre.Identity.uuid7()},
      runtime: self(),
      runtime_control: make_ref(),
      consumer: self(),
      operations: %{deliver: [confirm: true, class: "test.deliver"]},
      bindings: %{deliver: %{interpreter: {Interpreter, :interpret}}},
      storage: if(mode == :durable, do: {:disk, path}, else: :ephemeral)
    ]

    {:ok, owner} = Managed.start_link(opts)
    on_exit(fn -> Managed.close(owner) end)
    assert {:ok, nil} = Managed.activity_owner(owner, :existing)
    assert {:ok, {_coordinator, control}} = Managed.activity_owner(owner, :start)

    assert {:error, :untrusted_governance_transport} =
             GenServer.call(owner, {:checkout, control})

    {owner, control, opts}
  end

  defp start_activity(owner, control) do
    ref = Spectre.Identity.uuid7()
    assert :ok = Managed.register_activity(owner, control, ref)
    ref
  end

  defp context(ref, revision, input) do
    %{
      agent: Agent,
      input: input,
      identity: %{},
      options: [],
      interaction: Spectre.Identity.uuid7(),
      command_id: Spectre.Identity.uuid7(),
      activity: %{ref: ref, revision: revision}
    }
  end

  defp prepare_consent(owner, control, ref) do
    context = context(ref, 0, Spectre.Input.new("hello"))
    context = %{context | identity: :sys.get_state(owner).options[:identity]}

    task =
      Task.async(fn ->
        Managed.propose(:deliver, %{body: "hello"}, context, bridge(owner, control))
      end)

    assert_receive {Managed, ^owner, {:presentation, %{"presentation_ref" => presentation_ref}}},
                   5_000

    assert :ok = Managed.presented(owner, presentation_ref, self())
    assert {:pending, pending} = Task.await(task, 5_000)
    assert {:ok, proof} = Managed.authorize_decision(owner, presentation_ref, :confirm, self())
    {pending, proof}
  end

  defp transition(ref, kind),
    do: %{ref: ref, revision: 0, transition_id: Spectre.Identity.uuid7(), kind: kind}

  defp bridge(owner, control), do: [bridge_config: [server: owner, control: control]]

  defp assert_waiting_fence(domain, transition, attempts \\ 250)

  defp assert_waiting_fence(_domain, _transition, 0),
    do: flunk("fence did not reach the sequencer")

  defp assert_waiting_fence(domain, transition, attempts) do
    {:messages, messages} = Process.info(domain, :messages)

    unless Enum.any?(
             messages,
             &match?({:"$gen_call", _, {:activity_fence, _, {:advance, ^transition}}}, &1)
           ) do
      receive do
      after
        4 -> assert_waiting_fence(domain, transition, attempts - 1)
      end
    end
  end
end
