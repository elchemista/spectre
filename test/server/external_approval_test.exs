defmodule Spectre.Server.ExternalApprovalTest do
  use ExUnit.Case, async: false
  alias Spectre.Server

  defmodule Transport do
    @behaviour Server.GAM.Managed.Approval
    def send_message(message, _) do
      send(Spectre.Server.ExternalApprovalTest, {:wire, message})
      {:ok, :accepted}
    end
  end

  defmodule ControlledTransport do
    @behaviour Server.GAM.Managed.Approval
    def send_message(message, _) do
      send(Spectre.Server.ExternalApprovalTest, {:delivery_started, self(), message})

      receive do
        :deliver -> Transport.send_message(message, [])
        {:return, result} -> result
      after
        10_000 -> {:error, :transport_timeout}
      end
    end
  end

  defmodule SlowStore do
    @behaviour Server.Store
    alias Server.GAM.Managed.Store, as: Memory
    def fetch({store, _}, key), do: Memory.fetch(store, key)
    def list({store, _}, prefix, opts), do: Memory.list(store, prefix, opts)
    def delete({store, _}, key, revision), do: Memory.delete(store, key, revision)

    def compare_and_swap({store, _}, key, revision, value),
      do: Memory.compare_and_swap(store, key, revision, value)

    def put_new({store, control}, key, value) do
      if is_tuple(key) and elem(key, 0) == :external_approval do
        controlled_put(Elixir.Agent.get(control, & &1), store, key, value)
      else
        Memory.put_new(store, key, value)
      end
    end

    defp controlled_put(:pass, store, key, value), do: Memory.put_new(store, key, value)

    defp controlled_put({mode, observer}, store, key, value) do
      result = if mode == :after_commit, do: Memory.put_new(store, key, value)
      send(observer, {:approval_store_waiting, self()})
      wait_for_release(result, store, key, value)
    end

    defp wait_for_release(result, store, key, value) do
      receive do
        :release -> result || Memory.put_new(store, key, value)
      end
    end
  end

  defmodule FaultStore do
    @behaviour Server.Store
    alias Server.GAM.Managed.Store, as: Memory
    def fetch(port, key), do: invoke(port, :fetch, [key])
    def list(port, prefix, opts), do: invoke(port, :list, [prefix, opts])
    def put_new(port, key, value), do: invoke(port, :put_new, [key, value])

    def compare_and_swap(port, key, revision, value),
      do: invoke(port, :compare_and_swap, [key, revision, value])

    def delete(port, key, revision), do: invoke(port, :delete, [key, revision])

    defp invoke({store, control}, operation, [key | _] = args) do
      case {is_tuple(key) and elem(key, 0) == :external_approval, Elixir.Agent.get(control, & &1)} do
        {true, :offline} -> {:error, :database_unavailable}
        {true, {:fail, ^operation, reason}} -> {:error, reason}
        _ -> apply(Memory, operation, [store | args])
      end
    end
  end

  defmodule Effect do
    @behaviour Server.GAM.EffectAdapter
    def prepare(:open, [url], _), do: {:ok, %{"url" => url}}
    def project(:open, result), do: {:ok, result}

    def execute_effect(:open, args, _) do
      send(Spectre.Server.ExternalApprovalTest, {:opened, args})
      {:ok, %{opened: true}}
    end
  end

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :external_approval_test,
      version: "0.1.0",
      spectre: "~> 0.4.0"

    def tools(_),
      do: %{
        browser: %{
          contract: 1,
          adapter: Effect,
          default: nil,
          operations: %{open: %{path: :governed, operation: :browser_open, max_bytes: 8192}}
        }
      }

    def effects(_),
      do: %{
        browser_open: %{
          contract: 1,
          adapter: Effect,
          operation: :open,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [],
          schema_hash: nil,
          config: %{}
        }
      }
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule App do
    use Spectre.Server, tools: Stack

    def init(mode, ctx), do: {:ok, put_private(ctx, :approval_policy, mode)}

    def handle_approval_inbox(event, ctx) do
      case ctx.private[:approval_policy] do
        :buffer -> buffer_event(event, ctx)
        :private -> put_private(ctx, :last_approval_event, event.event)
        :assign -> assign(ctx, :last_approval_event, event.event)
        :invalid -> :invalid
        _ -> :default
      end
    end

    defp buffer_event(%{event: :storage_error, request: request}, ctx) do
      queue =
        Map.put(
          Map.get(ctx.private, :approval_retry, %{}),
          {request["from"], request["id"]},
          request
        )

      put_private(ctx, :approval_retry, queue)
    end

    defp buffer_event(%{event: event, reference: ref}, ctx)
         when event in [:received, :duplicate] do
      queue = Map.delete(Map.get(ctx.private, :approval_retry, %{}), {ref.from, ref.id})
      put_private(ctx, :approval_retry, queue)
    end

    defp buffer_event(_, _), do: :default

    def handle_flow({:web, :open}, input, ctx),
      do: browser(ctx, {:open, input.text}, on_result: :opened)

    def handle_result(:opened, result, ctx) do
      send(Spectre.Server.ExternalApprovalTest, {:completed, result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)

    def handle_info(:resume, ctx) do
      [pending] = Map.values(ctx.pending_by_id)
      {:noreply, resume_pending(ctx, pending.id)}
    end

    def handle_info(:close, ctx) do
      [pending] = Map.values(ctx.pending_by_id)
      {:noreply, close_pending(ctx, pending.id)}
    end

    def handle_info(message, ctx), do: super(message, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App

    flow :web do
      on(:open, regex: ~r/.*/)
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    principal = %{kind: :human, attributes: %{"subject" => "owner"}}

    trust = [
      principal: principal,
      public_key: public,
      mandate_ref: "owner:approve-browser",
      expires_at: System.system_time(:millisecond) + 60_000
    ]

    signer = [principal: principal, private_key: private, mandate_ref: "owner:approve-browser"]

    %{
      client_approvals: [
        address: "spectre://client/assistant",
        transport: {Transport, []},
        approvers: %{"spectre://owner/assistant" => trust}
      ],
      owner_approvals: [
        address: "spectre://owner/assistant",
        transport: {Transport, []},
        signer: signer
      ]
    }
  end

  defp pair(c, extra \\ []) do
    client_opts = [
      agent: Agent,
      consumer: self(),
      identity: %{subject: "client", conversation: Spectre.Identity.uuid7()},
      gam:
        Keyword.merge(
          [
            operations: %{
              browser_open: [confirm: true, approver: {:external, "spectre://owner/assistant"}]
            },
            approvals: c.client_approvals
          ],
          extra
        )
    ]

    client = start_supervised!({Server, Keyword.put(client_opts, :id, :client)})

    owner =
      start_supervised!(
        {Server,
         [
           id: :owner,
           agent: Agent,
           init_arg: c[:owner_init_arg],
           consumer: self(),
           identity:
             Map.get(c, :owner_identity, %{
               subject: "owner",
               conversation: Spectre.Identity.uuid7()
             }),
           gam: Keyword.merge([approvals: c.owner_approvals], Map.get(c, :owner_options, []))
         ]}
      )

    {client, owner, client_opts}
  end

  defp request(client, owner, text \\ "https://example.test") do
    assert {:ok, _} = Server.input(client, text)
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    assert :ok = Server.receive_approval(owner, request)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    refute_receive {:opened, _}
    {request, request["id"]}
  end

  defp presented(client, owner, id) do
    assert :ok = Server.approval_presented(owner, id)
    assert_receive {:wire, %{"type" => "approval.presented"} = shown}
    assert :ok = Server.receive_approval(client, shown)
    assert_receive {Server, ^client, {:pending, _, _}}, 5_000
    shown
  end

  test "two independent Domains approve the exact operation with human Evidence; accepted is not consent",
       c do
    {client, owner, _} = pair(c)
    {request, id} = request(client, owner)
    assert {:ok, client_view} = Server.gam_view(client)
    assert {:ok, owner_view} = Server.gam_view(owner)
    refute client_view.opening.domain_ref == owner_view.opening.domain_ref
    assert {:error, _} = Server.decide(client, nil, request["presentation_ref"], :confirm)
    assert {:error, _} = Server.presented(client, request["presentation_ref"])

    assert {:error, _} =
             Task.async(fn -> Server.approval_presented(owner, id) end) |> Task.await()

    presented(client, owner, id)
    assert {:error, _} = Server.decide(client, nil, request["presentation_ref"], :confirm)

    assert {:error, _} =
             Task.async(fn -> Server.approval_decide(owner, id, :confirm) end) |> Task.await()

    assert :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, %{"url" => "https://example.test"}}, 5_000
    assert_receive {:completed, {:governed, _}}, 5_000
    assert {:ok, view} = Server.gam_view(client)

    approval =
      Enum.find(
        view.evidence,
        &match?(%{"contract_ref" => "spectre.presentation.approval.v1"}, &1.proposition)
      )

    assert approval.issuer_ref == request["principal_ref"]
    assert approval.valid_until == request["expires_at"]
    assert approval.bindings["authenticated_principal_ref"] == request["principal_ref"]
    assert approval.payload.external_approval == %{request: request, response: decision}

    # The kernel's exception admits only this exact observed response. It does
    # not turn the recipient into the owner of the client's opened Scope.
    managed = :sys.get_state(client).managed_owner
    managed_state = :sys.get_state(managed)
    refute request["principal_ref"] in managed_state.mandate.target_refs
    assert managed_state.show_mandate.classes == ["presentation.show"]
    refute managed_state.show_mandate.ceiling.write
    projection = ExGAM.Domain.Sequencer.projection(managed_state.domain)

    {:ok, external_context} =
      ExGAM.SubmissionContext.from_evidence_bindings(approval.bindings)

    assert {:error, _} = ExGAM.GovernedAct.View.scope_context(projection, external_context)

    assert {:ok, _} =
             ExGAM.GovernedAct.View.observation_context(
               projection,
               external_context,
               approval
             )

    {:ok, unrelated} =
      ExGAM.Ingress.evidence(external_context, approval.observed_at,
        proposition: "arbitrary-request",
        payload: %{},
        issuer_ref: approval.issuer_ref
      )

    assert {:error, _} =
             ExGAM.GovernedAct.View.observation_context(
               projection,
               external_context,
               unrelated
             )

    assert {:error, _} =
             ExGAM.GovernedAct.View.observation_context(
               %{projection | outcomes: %{}},
               external_context,
               approval
             )

    assert {:error, _} = Server.receive_approval(client, decision)
    refute_receive {:opened, _}
  end

  test "human rejection records contradiction and cannot execute", c do
    {client, owner, _} = pair(c)
    {_, id} = request(client, owner)
    presented(client, owner, id)
    assert :ok = Server.approval_decide(owner, id, :reject)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:completed, {:consent, :rejected}}, 5_000
    assert {:ok, view} = Server.gam_view(client)
    assert Enum.any?(view.evidence, &(&1.stance == :contradicts))
    refute_receive {:opened, _}
  end

  test "a decision arriving before its rendering receipt waits for successful show completion",
       c do
    {client, owner, _} = pair(c)
    {_, id} = request(client, owner)
    :ok = Server.approval_presented(owner, id)
    assert_receive {:wire, %{"type" => "approval.presented"} = shown}
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    assert :ok = Server.receive_approval(client, decision)
    assert_receive {:opened, _}, 5_000
    assert {:error, _} = Server.receive_approval(client, shown)
    refute_receive {:opened, _}
  end

  test "external consent cannot restore a revoked execution mandate", c do
    {client, owner, _} = pair(c)
    {_, id} = request(client, owner)
    presented(client, owner, id)
    assert {:ok, _} = Spectre.GAM.revoke(client)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:completed, {:governed, %{decision: %{outcome: :refused}}}}, 5_000
    refute_receive {:opened, _}
  end

  test "tampered proof, identity, mandate, digest and correlation are denied", c do
    {client, owner, _} = pair(c)
    {_, id} = request(client, owner)
    presented(client, owner, id)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, decision}

    for field <-
          ~w(signature principal_ref mandate_ref request_digest relates_to decision from to) do
      assert {:error, _} = Server.receive_approval(client, Map.put(decision, field, "forged"))
    end

    refute_receive {:opened, _}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, _}, 5_000
  end

  test "duplicate request and human retry reuse the signed response; a second choice is denied",
       c do
    {client, owner, _} = pair(c)
    {request, id} = request(client, owner)
    assert :ok = Server.receive_approval(owner, request)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    presented(client, owner, id)
    assert :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, decision}
    assert :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, ^decision}
    assert {:error, _} = Server.approval_decide(owner, id, :reject)
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, _}, 5_000
  end

  test "deadline closes the pending request and denies a late signed decision", c do
    {client, owner, _} = pair(c, consent_ttl_ms: 1500)
    {_, id} = request(client, owner)
    presented(client, owner, id)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, decision}
    assert_receive {:completed, {:consent, :expired}}, 5_000
    assert {:error, _} = Server.receive_approval(client, decision)
    assert_receive {:wire, %{"type" => "approval.cancelled"} = cancelled}, 5_000
    assert :ok = Server.receive_approval(owner, cancelled)
    assert {:error, _} = Server.approval_decide(owner, id, :confirm)
    refute_receive {:opened, _}
  end

  test "an unrendered request times out without consent or browser execution", c do
    {client, owner, _} = pair(c, show_timeout: 200)
    {_, id} = request(client, owner)
    assert_receive {:completed, {:error, :presentation_not_shown}}, 5_000
    assert_receive {:wire, %{"type" => "approval.cancelled"} = cancelled}, 5_000
    :ok = Server.receive_approval(owner, cancelled)
    assert {:error, _} = Server.approval_presented(owner, id)
    refute_receive {:opened, _}
  end

  @tag :tmp_dir
  test "the approver recovers its exact signed human reply from the existing store", c do
    identity = %{subject: "owner", conversation: "durable-owner"}
    storage = {:disk, Path.join(c.tmp_dir, "owner")}
    c = c |> Map.put(:owner_identity, identity) |> Map.put(:owner_options, storage: storage)
    {client, owner, _} = pair(c)
    {_, id} = request(client, owner)
    presented(client, owner, id)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, decision}
    :ok = stop_supervised(:owner)

    restored =
      start_supervised!(
        {Server,
         [
           id: :restored_owner,
           agent: Agent,
           consumer: self(),
           identity: identity,
           gam: [storage: storage, approvals: c.owner_approvals]
         ]}
      )

    assert :ok = Server.approval_decide(restored, id, :confirm)
    assert_receive {:wire, ^decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, _}, 5_000
    refute_receive {:opened, _}
  end

  @tag :tmp_dir
  test "disk recovery suspends the old request and requires a fresh Presentation", c do
    {client, owner, opts} = pair(c, storage: {:disk, Path.join(c.tmp_dir, "client")})
    {old, id} = request(client, owner)
    presented(client, owner, id)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:wire, old_decision}
    assert :ok = stop_supervised(:client)
    restored = start_supervised!({Server, Keyword.put(opts, :id, :restored)})
    assert [%{status: :suspended}] = Server.status(restored).pending
    assert {:error, _} = Server.receive_approval(restored, old_decision)
    send(restored, :resume)
    assert_receive {:wire, %{"type" => "approval.request"} = fresh}, 5_000
    refute fresh["id"] == old["id"]
    refute fresh["show_ref"] == old["show_ref"]
    assert fresh["revision"] > old["revision"]
    :ok = Server.receive_approval(owner, fresh)
    presented(restored, owner, fresh["id"])
    :ok = Server.approval_decide(owner, fresh["id"], :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    acquired = Server.receive_approval(restored, decision)
    assert acquired == :ok or match?({:ok, _}, acquired)
    assert_receive {:opened, _}, 5_000
    assert_receive {:completed, {:governed, _}}, 5_000
    :ok = stop_supervised(:restored)
    recovered = start_supervised!({Server, Keyword.put(opts, :id, :replayed)})
    assert Server.status(recovered).pending == []
    assert {:ok, replayed} = Server.gam_view(recovered)
    assert Enum.any?(replayed.evidence, &(&1.issuer_ref == fresh["principal_ref"]))
    refute_receive {:opened, _}
  end

  test "a request transport slower than five seconds leaves Gate and Server responsive", c do
    config = Keyword.put(c.client_approvals, :transport, {ControlledTransport, []})
    {client, owner, _} = pair(%{c | client_approvals: config})
    assert {:ok, _} = Server.input(client, "https://slow.example.test")
    assert_receive {:delivery_started, transport, request}, 5_000
    assert request["rendered_payload"] =~ "Operation: :\"browser_open\""
    assert Server.status(client).pending == []
    managed = :sys.get_state(client).managed_owner
    gate = :sys.get_state(managed).gate
    assert :local = GenServer.call(gate, {:external_auth, nil}, 500)
    Process.send_after(transport, :deliver, 5_100)
    assert_receive {:wire, ^request}, 6_000
    :ok = Server.receive_approval(owner, request)
    presented(client, owner, request["id"])
    :ok = Server.approval_decide(owner, request["id"], :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, %{"url" => "https://slow.example.test"}}, 5_000
  end

  test "lost reply delivery does not block the human Server and explicit retry preserves the choice",
       c do
    config = Keyword.put(c.owner_approvals, :transport, {ControlledTransport, []})
    {client, owner, _} = pair(%{c | owner_approvals: config})
    {_, id} = request(client, owner)
    :ok = Server.approval_presented(owner, id)
    assert_receive {:delivery_started, transport, shown}
    assert is_map(Server.status(owner))
    send(transport, :deliver)
    assert_receive {:wire, ^shown}
    :ok = Server.receive_approval(client, shown)
    assert_receive {Server, ^client, {:pending, _, _}}, 5_000
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:delivery_started, transport, decision}
    send(transport, {:return, {:error, %{outcome: :not_sent}}})

    assert_receive {Server, ^owner,
                    {:approval_delivery, %{type: "approval.decision", status: :not_sent}}}

    refute_receive {:opened, _}
    assert {:error, _} = Server.approval_decide(owner, id, :reject)
    :ok = Server.approval_decide(owner, id, :confirm)
    assert_receive {:delivery_started, retry, ^decision}
    send(retry, :deliver)
    assert_receive {:wire, ^decision}
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, _}, 5_000
    assert {:error, _} = Server.receive_approval(client, decision)
  end

  test "a hung request is bounded and its transport worker is stopped", c do
    config = Keyword.put(c.client_approvals, :transport, {ControlledTransport, []})
    {client, _, _} = pair(%{c | client_approvals: config}, show_timeout: 250)
    assert {:ok, _} = Server.input(client, "https://timeout.example.test")
    assert_receive {:delivery_started, transport, _request}, 5_000
    monitor = Process.monitor(transport)
    assert_receive {:DOWN, ^monitor, :process, ^transport, :killed}, 2_000
    assert_receive {:completed, {:error, :presentation_not_shown}}, 5_000
    refute_receive {:opened, _}
    assert is_map(Server.status(client))
  end

  test "request delivery failure preserves certainty and never executes without consent", c do
    config = Keyword.put(c.client_approvals, :transport, {ControlledTransport, []})

    for failure <- [{:error, %{outcome: :not_sent}}, {:error, :connection_lost}] do
      {client, _, _} = pair(%{c | client_approvals: config})
      assert {:ok, _} = Server.input(client, "https://failure.example.test")
      assert_receive {:delivery_started, transport, %{"type" => "approval.request"}}, 5_000
      send(transport, {:return, failure})
      assert_receive {:completed, {:error, :presentation_not_shown}}, 5_000
      refute_receive {:opened, _}
      assert {:ok, view} = Server.gam_view(client)

      status =
        if failure == {:error, %{outcome: :not_sent}}, do: :definitive_no_effect, else: :ambiguous

      assert Enum.any?(view.outcomes, &(&1.status == status))
      :ok = stop_supervised(:client)
      :ok = stop_supervised(:owner)
    end
  end

  test "a failed reply task reports unknown delivery and keeps its signed decision retryable",
       c do
    config = Keyword.put(c.owner_approvals, :transport, {ControlledTransport, []})
    {client, owner, _} = pair(%{c | owner_approvals: config})
    {_, id} = request(client, owner)
    :ok = Server.approval_presented(owner, id)
    assert_receive {:delivery_started, transport, _shown}
    Process.exit(transport, :kill)
    assert_receive {Server, ^owner, {:approval_delivery, %{status: :unknown}}}
    assert is_map(Server.status(owner))
    :ok = Server.approval_presented(owner, id)
    assert_receive {:delivery_started, retry, shown}
    send(retry, :deliver)
    assert_receive {:wire, ^shown}
    :ok = Server.receive_approval(client, shown)
    assert_receive {Server, ^client, {:pending, _, _}}, 5_000
    refute_receive {:opened, _}
  end

  test "external configuration fails closed for invalid identities, keys and authorization", c do
    alias Server.GAM.Managed.Approval
    [address: address, transport: transport, approvers: approvers] = c.client_approvals
    trust = approvers["spectre://owner/assistant"]

    invalid = [
      [address: address, transport: transport, unknown: true],
      [address: "", transport: transport],
      [address: address, transport: {__MODULE__, []}],
      [address: address, transport: transport, approvers: :invalid],
      [
        address: address,
        transport: transport,
        approvers: %{"peer" => Keyword.put(trust, :public_key, <<0>>)}
      ],
      [
        address: address,
        transport: transport,
        approvers: %{"peer" => Keyword.put(trust, :expires_at, -1)}
      ],
      [address: address, transport: transport, signer: [private_key: <<0>>]],
      [
        address: address,
        transport: transport,
        signer: [
          private_key: :crypto.strong_rand_bytes(32),
          principal: %{kind: :agent},
          mandate_ref: "x"
        ]
      ]
    ]

    for config <- invalid, do: assert({:error, _} = Approval.normalize(approvals: config))
    assert {:ok, normalized} = Approval.normalize(approvals: c.client_approvals)

    assert {:error, :external_approver_not_configured} =
             Approval.approver(normalized, approver: {:external, "missing"})

    assert {:error, :invalid_managed_approver} = Approval.approver(normalized, approver: :agent)
    assert {:ok, nil} = Approval.approver(normalized, [])

    assert {:error, :invalid_external_approval_decision} =
             Approval.prepare_reply(%{}, nil, "id", :invented)
  end

  test "incoming request identity conflicts and premature or cancelled choices cannot sign", c do
    {client, owner, _} = pair(c)
    {request, id} = request(client, owner)
    assert {:error, _} = Server.approval_decide(owner, id, :confirm)

    assert {:error, _} =
             Server.receive_approval(owner, Map.put(request, "rendered_payload", "changed"))

    for key <-
          ~w(type to principal_ref mandate_ref expires_at revision id from presentation_ref show_ref material_digest candidate_binding_ref data_digest scope_ref rendered_payload) do
      assert {:error, _} = Server.receive_approval(owner, Map.put(request, key, nil))
    end

    cancelled = cancellation(request)

    assert {:error, _} =
             Server.receive_approval(owner, Map.put(cancelled, "request_digest", "wrong"))

    :ok = Server.receive_approval(owner, cancelled)
    assert {:error, _} = Server.approval_presented(owner, id)
    refute_receive {:opened, _}
  end

  for mode <- [:private, :assign, :invalid] do
    test "inbox policy callback #{mode} is isolated and uses the regular acquisition contract",
         c do
      {client, owner, _} = pair(Map.put(c, :owner_init_arg, unquote(mode)))
      {_request, _id} = request(client, owner)
      assert_policy_event(unquote(mode), owner)
    end
  end

  defp assert_policy_event(:invalid, owner) do
    assert_receive {Server, ^owner, {:approval_callback_error, _}}
    assert is_map(Server.status(owner))
  end

  defp assert_policy_event(:private, owner),
    do: assert(:sys.get_state(owner).private.last_approval_event == :received)

  defp assert_policy_event(:assign, owner),
    do: assert(:sys.get_state(owner).assigns.last_approval_event == :received)

  @tag :tmp_dir
  test "failed decision and cancellation writes preserve the request until an explicit retry",
       c do
    {client, owner, control} = fault_pair(c)
    {request, id} = request(client, owner)
    presented(client, owner, id)

    for {reason, error} <- [
          {:conflict, :approval_store_conflict},
          {:write_refused, {:approval_store, :write_refused}}
        ] do
      Elixir.Agent.update(control, fn _ -> {:fail, :compare_and_swap, reason} end)
      assert {:error, ^error} = Server.approval_decide(owner, id, :confirm)
      assert {:error, ^error} = Server.receive_approval(owner, cancellation(request))
      assert {:ok, %{status: :pending}} = Server.approval(owner, id)
      refute_receive {:wire, %{"type" => "approval.decision"}}, 20
      refute_receive {:opened, _}, 20
    end

    Elixir.Agent.update(control, fn _ -> :online end)
    assert :ok = Server.receive_approval(owner, cancellation(request))
    assert :ok = Server.receive_approval(owner, cancellation(request))
    assert {:ok, %{status: :cancelled}} = Server.approval(owner, id)
    refute_receive {:opened, _}
  end

  defp fault_pair(c) do
    store = start_supervised!({Server.GAM.Managed.Store, []})
    control = start_supervised!({Elixir.Agent, fn -> :online end})

    config =
      Map.put(c, :owner_options,
        storage: {:disk, Path.join(c.tmp_dir, "owner")},
        store: {FaultStore, {store, control}}
      )

    {client, owner, _} = pair(config)
    {client, owner, control}
  end

  defp cancellation(request),
    do: %{
      "type" => "approval.cancelled",
      "from" => request["from"],
      "to" => request["to"],
      "relates_to" => request["id"],
      "request_digest" => ExGAM.Canonical.Value.digest!(request)
    }

  test "optional maintenance ticks notify application policy without creating consent", c do
    c =
      c
      |> Map.put(:owner_init_arg, :private)
      |> Map.put(:owner_approvals, Keyword.put(c.owner_approvals, :maintenance_interval, 20))

    {_client, owner, _} = pair(c)
    Process.sleep(50)
    assert :sys.get_state(owner).private.last_approval_event == :tick
    assert {:ok, %{entries: []}} = Server.approval_inbox(owner)
  end

  test "request identity is scoped by sender and filtered pages retain their continuation", c do
    {client, owner, _} = pair(c)
    {request, id} = request(client, owner)
    other = Map.put(request, "from", "spectre://other-client")
    assert :ok = Server.receive_approval(owner, other)
    assert {:error, :approval_reference_ambiguous} = Server.approval(owner, id)
    first = %{id: id, from: request["from"]}
    second = %{id: id, from: other["from"]}
    assert {:ok, %{reference: ^first}} = Server.approval(owner, first)
    assert {:ok, %{reference: ^second}} = Server.approval(owner, second)

    assert {:ok, %{entries: [], next_cursor: cursor}} =
             Server.approval_inbox(owner, limit: 1, status: :decided)

    refute is_nil(cursor)

    assert {:ok, %{entries: [], next_cursor: nil}} =
             Server.approval_inbox(owner, after: cursor, status: :decided)

    assert {:ok, %{entries: entries}} = Server.approval_inbox(owner)
    assert length(entries) == 2
  end

  @tag :tmp_dir
  test "slow storage leaves both the runtime and Gate responsive; queries are consumer-only", c do
    store = start_supervised!({Server.GAM.Managed.Store, []})
    observer = self()
    control = start_supervised!({Elixir.Agent, fn -> {:before_commit, observer} end})

    config =
      c
      |> Map.put(:owner_approvals, Keyword.put(c.owner_approvals, :io_workers, 1))
      |> Map.put(:owner_options,
        storage: {:disk, Path.join(c.tmp_dir, "owner")},
        store: {SlowStore, {store, control}}
      )

    {client, owner, _} = pair(config)
    {:ok, _} = Server.input(client, "https://slow-storage.example.test")
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    incoming = Task.async(fn -> Server.receive_approval(owner, request) end)
    assert_receive {:approval_store_waiting, worker}, 5_000
    status = Task.async(fn -> Server.status(owner) end)
    assert is_map(Task.await(status, 500))
    managed = :sys.get_state(owner).managed_owner
    gate = :sys.get_state(managed).gate
    assert :local = GenServer.call(gate, {:external_auth, nil}, 500)
    assert {:error, :approval_store_busy} = Server.approval_inbox(owner)
    refute_receive {Server, ^owner, {:approval_request, _}}
    send(worker, :release)
    assert :ok = Task.await(incoming)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    assert {:ok, %{entries: [entry], next_cursor: nil}} = Server.approval_inbox(owner)
    assert entry.reference == %{id: request["id"], from: request["from"]}
    assert {:ok, ^entry} = Server.approval(owner, entry.reference)

    assert {:error, :untrusted_consent_transport} =
             Task.async(fn -> Server.approval_inbox(owner) end) |> Task.await()

    refute File.exists?(Path.join(c.tmp_dir, "owner/commands.store"))
  end

  @tag :tmp_dir
  test "the outage hook can buffer an immutable request privately and retry after storage returns",
       c do
    {client, owner, control} = fault_pair(Map.put(c, :owner_init_arg, :buffer))
    {:ok, _} = Server.input(client, "https://db-outage.test")
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    Elixir.Agent.update(control, fn _ -> :offline end)

    assert {:error, {:approval_store, :database_unavailable}} =
             Server.receive_approval(owner, request)

    assert_receive {Server, ^owner,
                    {:approval_inbox,
                     %{event: :storage_error, operation: :receive, request: ^request}}}

    refute_receive {Server, ^owner, {:approval_request, _}}
    assert is_map(Server.status(owner))
    assert [^request] = Map.values(:sys.get_state(owner).private.approval_retry)
    assert {:error, {:approval_store, :database_unavailable}} = Server.approval_inbox(owner)

    assert {:error, {:approval_store, :database_unavailable}} =
             Server.approval(owner, request["id"])

    assert {:error, {:approval_store, :database_unavailable}} =
             Server.approval_decide(owner, request["id"], :confirm)

    cancelled = cancellation(request)

    assert {:error, {:approval_store, :database_unavailable}} =
             Server.receive_approval(owner, cancelled)

    assert_receive {Server, ^owner,
                    {:approval_inbox, %{event: :storage_error, operation: :cancel}}}

    Elixir.Agent.update(control, fn _ -> :online end)
    assert :ok = Server.receive_approval(owner, request)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    assert {:ok, %{entries: [_]}} = Server.approval_inbox(owner)
    assert :sys.get_state(owner).private.approval_retry == %{}
    presented(client, owner, request["id"])
    :ok = Server.approval_decide(owner, request["id"], :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}
    result = Server.receive_approval(client, decision)
    assert result == :ok or match?({:ok, _}, result)
    assert_receive {:opened, _}, 5_000
    refute_receive {:opened, _}
  end

  @tag :tmp_dir
  test "an outage policy cannot acquire new durable commands against unavailable storage", c do
    {_client, owner, control} = fault_pair(Map.put(c, :owner_init_arg, :assign))
    Elixir.Agent.update(control, fn _ -> :offline end)
    assert {:error, _} = Server.approval_inbox(owner)
    assert_receive {Server, ^owner, {:approval_callback_error, _}}
    assert is_map(Server.status(owner))
  end

  @tag :tmp_dir
  test "killing the Gate also stops a hung inbox worker and its owned supervisor", c do
    store = start_supervised!({Server.GAM.Managed.Store, []})
    observer = self()
    control = start_supervised!({Elixir.Agent, fn -> {:before_commit, observer} end})

    config =
      Map.put(c, :owner_options,
        storage: {:disk, Path.join(c.tmp_dir, "owner")},
        store: {SlowStore, {store, control}}
      )

    {client, owner, _} = pair(config)
    {:ok, _} = Server.input(client, "https://crash.test")
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    Task.start(fn -> Server.receive_approval(owner, request) end)
    assert_receive {:approval_store_waiting, worker}, 5_000
    gate = :sys.get_state(:sys.get_state(owner).managed_owner).gate
    supervisor = :sys.get_state(gate).tasks
    worker_ref = Process.monitor(worker)
    sup_ref = Process.monitor(supervisor)
    Process.exit(gate, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^sup_ref, :process, ^supervisor, _}, 1_000
  end

  @tag :tmp_dir
  test "a lost store acknowledgement is recoverable without duplicate records or a new decision",
       c do
    store = start_supervised!({Server.GAM.Managed.Store, []})
    observer = self()
    control = start_supervised!({Elixir.Agent, fn -> {:after_commit, observer} end})
    approvals = Keyword.put(c.owner_approvals, :io_timeout, 150)

    config =
      c
      |> Map.put(:owner_approvals, approvals)
      |> Map.put(:owner_options,
        storage: {:disk, Path.join(c.tmp_dir, "owner")},
        store: {SlowStore, {store, control}}
      )

    {client, owner, _} = pair(config)
    {:ok, _} = Server.input(client, "https://lost-ack.example.test")
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    incoming = Task.async(fn -> Server.receive_approval(owner, request) end)
    assert_receive {:approval_store_waiting, worker}, 5_000
    monitor = Process.monitor(worker)
    assert {:error, :approval_storage_unknown} = Task.await(incoming)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    assert is_map(Server.status(owner))
    Elixir.Agent.update(control, fn _ -> :pass end)
    assert :ok = Server.receive_approval(owner, request)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    assert {:ok, %{entries: [_], next_cursor: nil}} = Server.approval_inbox(owner)
    presented(client, owner, request["id"])
    :ok = Server.approval_decide(owner, request["id"], :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = response}
    :ok = Server.approval_decide(owner, request["id"], :confirm)
    assert_receive {:wire, ^response}
    assert {:ok, %{status: :decided, decision: ^response}} = Server.approval(owner, request["id"])
    assert {:ok, _} = Server.receive_approval(client, response)
    assert_receive {:opened, _}, 5_000
    refute_receive {:opened, _}
  end
end
