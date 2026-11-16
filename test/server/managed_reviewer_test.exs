defmodule Spectre.Server.ManagedReviewerTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.Server

  defmodule Effect do
    @behaviour Spectre.Server.GAM.EffectAdapter
    @impl true
    def execute_effect(:charge, _args, _context),
      do: {:error, :ambiguous, :provider_timeout}
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :reviewer_test, version: "0.4.0", spectre: "~> 0.4.0"
    @impl true
    def effects(_) do
      %{
        charge: %{
          contract: 1,
          adapter: Effect,
          operation: :charge,
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
    def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}

    def handle_flow(:unmatched, _input, ctx),
      do: propose(ctx, :charge, %{amount: 1}, on_result: :done)

    def handle_flow(flow, input, ctx), do: super(flow, input, ctx)

    def handle_result(:done, result, ctx) do
      send(ctx.private.observer, {:result, result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
  end

  setup do
    reviewer = spawn_link(fn -> reviewer_loop() end)
    on_exit(fn -> if Process.alive?(reviewer), do: Process.exit(reviewer, :kill) end)
    %{reviewer: reviewer}
  end

  defp reviewer_loop do
    receive do
      {:invoke, owner, function} ->
        send(owner, {:reviewed, function.()})
        reviewer_loop()
    end
  end

  defp review(pid, function) do
    send(pid, {:invoke, self(), function})
    assert_receive {:reviewed, result}, 5000
    result
  end

  defp options(reviewer, extra \\ []) do
    id = "reviewer-#{System.unique_integer([:positive])}"
    gam = [operations: %{charge: []}]

    gam =
      if reviewer,
        do: Keyword.put(gam, :reviewer, identity: %{subject: id <> "-audit"}, consumer: reviewer),
        else: gam

    [
      agent: Agent,
      consumer: self(),
      init_arg: self(),
      identity: %{subject: id},
      gam: Keyword.merge(gam, extra)
    ]
  end

  defp create_duty(server) do
    assert {:ok, _} = Server.input(server, "charge")
    assert_receive {:result, _}, 5000
    assert {:ok, view} = Server.gam_view(server)
    assert [%{status: :open} = duty] = view.duties
    assert Enum.any?(view.outcomes, &(&1.status == :ambiguous))
    duty
  end

  @tag :tmp_dir
  test "an independent reviewer disposes real ambiguous debt and durable recovery preserves cause",
       c do
    deadline = System.system_time(:millisecond) + 1_500
    opts = options(c.reviewer, storage: {:disk, c.tmp_dir}, expires_at: deadline)
    server = start_supervised!({Server, opts})
    managed = :sys.get_state(server).managed_owner
    {:ok, snapshot} = GenServer.call(managed, :checkout)
    refute Map.has_key?(snapshot, :reviewer)
    refute Keyword.has_key?(snapshot.options, :reviewer)
    refute Keyword.has_key?(snapshot.options, :options)
    GenServer.cast(managed, {:checkin, self()})
    duty = create_duty(server)
    support = [supporting_refs: [duty.act_ref]]

    assert {:error, :untrusted_reviewer_transport} =
             GAM.resolve_duty(server, duty.ref, :ratify, support)

    assert {:error, :untrusted_governance_transport} =
             Server.GAM.Managed.dispose(
               :sys.get_state(server).managed_owner,
               duty.ref,
               :ratify,
               support,
               c.reviewer
             )

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} = GAM.revoke(server)
    Process.sleep(max(deadline - System.system_time(:millisecond) + 10, 0))

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}, act: review_act}}} =
             review(c.reviewer, fn -> GAM.resolve_duty(server, duty.ref, :ratify, support) end)

    assert {:ok, before} = Server.gam_view(server)
    assert [%{status: :disposed, disposition_act_ref: disposition_ref}] = before.duties
    assert review_act.ref == disposition_ref
    assert review_act.class == "duty.dispose"
    refute Enum.any?(before.acts, &(&1.ref == disposition_ref))

    assert Enum.any?(before.outcomes, &(&1.status == :ambiguous))

    :ok = stop_supervised(Spectre.Server.Runtime)
    restored = start_supervised!({Server, opts})
    assert {:ok, after_restart} = Server.gam_view(restored)
    assert after_restart.duties == before.duties
    assert after_restart.outcomes == before.outcomes
  end

  test "without reviewer no automatic closure or application self-review is possible" do
    server = start_supervised!({Server, options(nil)})
    duty = create_duty(server)

    assert {:error, :reviewer_not_configured} =
             GAM.resolve_duty(server, duty.ref, :accept_loss, supporting_refs: [duty.act_ref])

    assert {:ok, view} = Server.gam_view(server)
    assert [%{status: :open}] = view.duties
    refute Enum.any?(view.acts, &(&1.class == "duty.dispose"))
  end

  test "reviewer cannot substitute evidence, dispose twice or obtain ordinary user authority",
       c do
    server = start_supervised!({Server, options(c.reviewer)})
    duty = create_duty(server)
    assert {:error, _} = review(c.reviewer, fn -> GAM.revoke(server) end)

    assert {:ok, %{primary: %{decision: %{outcome: :refused}, act: nil}}} =
             review(c.reviewer, fn ->
               GAM.resolve_duty(server, duty.ref, :ratify, supporting_refs: ["unknown-record"])
             end)

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             review(c.reviewer, fn ->
               GAM.resolve_duty(server, duty.ref, :accept_loss, supporting_refs: [duty.act_ref])
             end)

    assert {:error, _} =
             review(c.reviewer, fn ->
               GAM.resolve_duty(server, duty.ref, :ratify, supporting_refs: [duty.act_ref])
             end)
  end

  test "review identity and transport must be independently configured", c do
    opts = options(c.reviewer)
    actor = opts[:identity]

    for config <- [
          [identity: actor, consumer: c.reviewer],
          [identity: Map.put(actor, :conversation, "another-chat"), consumer: c.reviewer],
          [identity: %{subject: "reviewer"}, consumer: self()],
          [identity: %{}, consumer: c.reviewer],
          [identity: %{subject: "reviewer"}, consumer: "untrusted"]
        ] do
      invalid = Keyword.put(opts, :gam, Keyword.put(opts[:gam], :reviewer, config))
      assert {:error, :independent_reviewer_required} = Server.start_link(invalid)
    end
  end
end
