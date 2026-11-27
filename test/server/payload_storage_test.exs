defmodule Spectre.Server.PayloadStorageTest do
  use ExUnit.Case, async: false
  alias Spectre.Server
  alias Spectre.Server.GAM.Managed.Store, as: Memory

  defmodule Blobs do
    @behaviour Spectre.Payload.Store
    def put(bytes, _context, opts) do
      id = Integer.to_string(System.unique_integer([:positive, :monotonic]))
      Elixir.Agent.update(opts[:server], &Map.put(&1, id, bytes))
      {:ok, id}
    end

    def fetch(id, _context, opts) do
      case Elixir.Agent.get(opts[:server], &Map.fetch(&1, id)) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :not_found}
      end
    end
  end

  defmodule Transport do
    @behaviour Server.GAM.Managed.Approval
    def send_message(message, _) do
      send(Spectre.Server.PayloadStorageTest, {:wire, message})
      {:ok, :accepted}
    end
  end

  defmodule ControlledBlobs do
    @behaviour Spectre.Payload.Store
    def put(bytes, %{kind: :operation}, opts) do
      send(opts[:owner], {:payload_waiting, self()})

      receive do
        :release -> Blobs.put(bytes, %{}, opts)
        {:return, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end

    def put(bytes, context, opts), do: Blobs.put(bytes, context, opts)
    def fetch(id, context, opts), do: Blobs.fetch(id, context, opts)
  end

  defmodule ReceiptFailureBlobs do
    @behaviour Spectre.Payload.Store
    def put(bytes, %{kind: :receipt} = context, opts) do
      case Server.Checkpoint.decode_snapshot(bytes) do
        {:ok, %{private_receipt: _}} -> {:error, :receipt_storage_unavailable}
        _ -> Blobs.put(bytes, context, opts)
      end
    end

    def put(bytes, context, opts), do: Blobs.put(bytes, context, opts)
    def fetch(id, context, opts), do: Blobs.fetch(id, context, opts)
  end

  defmodule Effect do
    @behaviour Server.GAM.EffectAdapter
    def prepare(:open, [url], _), do: {:ok, %{"url" => url}}
    def project(:open, result), do: {:ok, result}

    def execute_effect(:open, args, _) do
      send(Spectre.Server.PayloadStorageTest, {:opened, args})
      {:ok, %{url: args["url"], private_receipt: "receipt-content-private"}}
    end
  end

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :payload_storage_test,
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
    def init(_, ctx), do: {:ok, assign(ctx, :private_page, "page-content-private")}

    def handle_action(%{operation: :browser_open, args: %{"url" => url}}, _ctx) do
      if String.contains?(url, "reject"),
        do: {:reject, %{private_reason: "rejection-content-private"}},
        else: {:confirm, %{bind: %{private_binding: "binding-content-private"}}}
    end

    def handle_flow({:web, :open}, input, ctx),
      do: browser(ctx, {:open, input.text}, on_result: :opened)

    def handle_result(:opened, result, ctx) do
      send(Spectre.Server.PayloadStorageTest, {:completed, result})
      no_response(ctx)
    end

    def handle_result(tag, result, ctx), do: super(tag, result, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App

    flow :web do
      on(:open, regex: ~r/.*/)
    end
  end

  setup do
    Process.register(self(), __MODULE__)
    blobs = start_supervised!({Elixir.Agent, fn -> %{} end})
    config = {Blobs, server: blobs}
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    principal = %{kind: :human, attributes: %{"subject" => "owner"}}

    trust = [
      principal: principal,
      public_key: public,
      mandate_ref: "owner:approve",
      expires_at: System.system_time(:millisecond) + 60_000
    ]

    signer = [principal: principal, private_key: private, mandate_ref: "owner:approve"]

    client_approvals = [
      address: "spectre://payload/client",
      transport: {Transport, []},
      approvers: %{"spectre://payload/owner" => trust}
    ]

    owner_approvals = [
      address: "spectre://payload/owner",
      transport: {Transport, []},
      signer: signer
    ]

    %{
      config: config,
      blobs: blobs,
      client_approvals: client_approvals,
      owner_approvals: owner_approvals
    }
  end

  @tag :tmp_dir
  test "an explicit checkpoint retains its coordination adapter with external payloads", c do
    journal = start_supervised!({Memory, []})

    opts = [
      id: :explicit_checkpoint,
      agent: Agent,
      consumer: self(),
      identity: %{subject: "explicit", conversation: Spectre.Identity.uuid7()},
      checkpoint: {Memory, journal, :explicit_checkpoint},
      payload_store: c.config,
      gam: [
        storage: {:disk, Path.join(c.tmp_dir, "explicit")},
        operations: %{browser_open: [confirm: true]}
      ]
    ]

    server = start_supervised!({Server, opts})
    url = "https://private.example.invalid/explicit?token=payload-content-private"
    assert {:ok, _} = Server.input(server, url)
    assert_receive {Server.GAM.Managed, _, {:presentation, material}}, 5_000
    ref = material["presentation_ref"]
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:opened, %{"url" => ^url}}, 5_000
    assert_receive {:completed, {:governed, _}}, 5_000
    assert {:ok, %{value: checkpoint}} = Memory.fetch(journal, :explicit_checkpoint)

    assert {:ok, %{format: "spectre/payload-checkpoint"}} =
             Server.Checkpoint.decode_snapshot(checkpoint)

    assert :ok = stop_supervised(:explicit_checkpoint)
    restored = start_supervised!({Server, opts})
    assert is_map(Server.status(restored))
    refute_receive {:opened, _}
  end

  @tag :tmp_dir
  test "two independent Agents approve and execute while canonical history and coordination retain references",
       c do
    client_store = start_supervised!({Memory, []}, id: :client_store)
    owner_store = start_supervised!({Memory, []}, id: :owner_store)

    client_opts = [
      id: :client,
      agent: Agent,
      consumer: self(),
      payload_store: c.config,
      identity: %{subject: "client", conversation: Spectre.Identity.uuid7()},
      gam: [
        storage: {:disk, Path.join(c.tmp_dir, "client")},
        store: {Memory, client_store},
        approvals: c.client_approvals,
        operations: %{
          browser_open: [confirm: true, approver: {:external, "spectre://payload/owner"}]
        }
      ]
    ]

    owner_opts = [
      id: :owner,
      agent: Agent,
      consumer: self(),
      payload_store: c.config,
      identity: %{subject: "owner", conversation: Spectre.Identity.uuid7()},
      gam: [
        storage: {:disk, Path.join(c.tmp_dir, "owner")},
        store: {Memory, owner_store},
        approvals: c.owner_approvals
      ]
    ]

    client = start_supervised!({Server, client_opts})
    owner = start_supervised!({Server, owner_opts})

    url = "https://private.example.invalid/path?token=payload-content-private"
    assert {:ok, _} = Server.input(client, url)
    assert_receive {:wire, %{"type" => "approval.request"} = request}, 5_000
    assert String.contains?(request["rendered_payload"], url)
    assert String.contains?(request["rendered_payload"], "binding-content-private")
    assert :ok = Server.receive_approval(owner, request)
    assert_receive {Server, ^owner, {:approval_request, ^request}}
    assert :ok = stop_supervised(:owner)
    owner = start_supervised!({Server, owner_opts})
    assert :ok = Server.approval_presented(owner, request["id"])
    assert_receive {:wire, %{"type" => "approval.presented"} = shown}, 5_000
    assert :ok = Server.receive_approval(client, shown)
    assert_receive {Server, ^client, {:pending, _, _}}, 5_000
    refute_receive {:opened, _}
    assert :ok = Server.approval_decide(owner, request["id"], :confirm)
    assert_receive {:wire, %{"type" => "approval.decision"} = decision}, 5_000
    assert {:ok, _} = Server.receive_approval(client, decision)
    assert_receive {:opened, %{"url" => ^url}}, 5_000
    assert_receive {:completed, {:governed, _}}, 5_000
    assert :ok = stop_supervised(:client)
    client = start_supervised!({Server, client_opts})
    assert {:error, _} = Server.receive_approval(client, decision)
    refute_receive {:opened, _}

    for server <- [client, owner] do
      state = server |> :sys.get_state() |> Map.fetch!(:managed_owner) |> :sys.get_state()
      assert {:ok, snapshot} = ExGAM.Ledger.Store.load(state.store, state.refs.domain, [])
      assert_private_absent(snapshot, url)
      projection = ExGAM.Domain.Sequencer.projection(state.domain)
      assert_private_absent(projection, url)
    end

    for journal <- [client_store, owner_store] do
      assert_private_absent(:sys.get_state(journal).values, url)
    end

    blobs = Elixir.Agent.get(c.blobs, &Map.values(&1))
    assert Enum.any?(blobs, &String.contains?(&1, url))
    assert Enum.any?(blobs, &String.contains?(&1, "page-content-private"))
    assert Enum.any?(blobs, &String.contains?(&1, "receipt-content-private"))
  end

  test "slow and unavailable payload storage leaves the Server and Domain responsive and cannot execute",
       c do
    server =
      start_supervised!(
        {Server,
         agent: Agent,
         consumer: self(),
         identity: %{subject: "slow", conversation: Spectre.Identity.uuid7()},
         payload_store: {ControlledBlobs, server: c.blobs, owner: self()},
         gam: [operations: %{browser_open: [confirm: true]}]}
      )

    url = "https://private.example.invalid/path?token=payload-content-private"
    assert {:ok, _} = Server.input(server, url)
    assert_receive {:payload_waiting, worker}, 5_000
    assert is_map(Server.status(server))
    assert {:ok, _} = Server.gam_view(server)
    refute_receive {:opened, _}
    send(worker, {:return, {:error, :unavailable}})
    assert_receive {:completed, {:error, :unavailable}}, 5_000
    refute_receive {:opened, _}
    assert {:ok, view} = Server.gam_view(server)
    assert_private_absent(view, url)
  end

  test "a missing operation payload after presentation prevents execution", c do
    server =
      start_supervised!(
        {Server,
         agent: Agent,
         consumer: self(),
         identity: %{subject: "missing", conversation: Spectre.Identity.uuid7()},
         payload_store: c.config,
         gam: [operations: %{browser_open: [confirm: true]}]}
      )

    url = "https://private.example.invalid/path?token=payload-content-private"
    assert {:ok, _} = Server.input(server, url)
    assert_receive {Server.GAM.Managed, _, {:presentation, material}}, 5_000
    ref = material["presentation_ref"]
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000

    Elixir.Agent.update(c.blobs, fn entries ->
      Map.reject(entries, fn {_id, bytes} ->
        case Server.Checkpoint.decode_snapshot(bytes) do
          {:ok, %{"payload" => %{"url" => ^url}}} -> true
          _ -> false
        end
      end)
    end)

    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:completed, {:error, :not_found}}, 5_000
    refute_receive {:opened, _}
    assert {:ok, view} = Server.gam_view(server)
    assert_private_absent(view, url)
  end

  test "a rejected preparation protects its reason and invocation Evidence", c do
    server =
      start_supervised!(
        {Server,
         agent: Agent,
         consumer: self(),
         identity: %{subject: "rejection", conversation: Spectre.Identity.uuid7()},
         payload_store: c.config,
         gam: [operations: %{browser_open: [confirm: true]}]}
      )

    url = "https://private.example.invalid/reject?token=payload-content-private"
    assert {:ok, _} = Server.input(server, url)

    assert_receive {:completed,
                    {:error, {:action_rejected, %{private_reason: "rejection-content-private"}}}},
                   5_000

    refute_receive {:opened, _}
    state = server |> :sys.get_state() |> Map.fetch!(:managed_owner) |> :sys.get_state()
    assert {:ok, snapshot} = ExGAM.Ledger.Store.load(state.store, state.refs.domain, [])
    assert_private_absent(snapshot, url)
    assert {:ok, view} = Server.gam_view(server)

    assert Enum.any?(
             view.evidence,
             &match?({:spectre_action_preparation_rejected, _}, &1.proposition)
           )

    assert_private_absent(view, url)
  end

  @tag :tmp_dir
  test "receipt storage failure after the effect records uncertainty and never repeats the effect on restart",
       c do
    journal = start_supervised!({Memory, []})

    opts = [
      id: :receipt_server,
      agent: Agent,
      consumer: self(),
      identity: %{subject: "receipt", conversation: Spectre.Identity.uuid7()},
      payload_store: {ReceiptFailureBlobs, server: c.blobs},
      gam: [
        storage: {:disk, Path.join(c.tmp_dir, "receipt")},
        store: {Memory, journal},
        operations: %{browser_open: [confirm: true]}
      ]
    ]

    server = start_supervised!({Server, opts})
    url = "https://private.example.invalid/path?token=payload-content-private"
    assert {:ok, _} = Server.input(server, url)
    assert_receive {Server.GAM.Managed, _, {:presentation, material}}, 5_000
    ref = material["presentation_ref"]
    assert :ok = Server.presented(server, ref)
    assert_receive {Server, ^server, {:pending, _, _}}, 5_000
    assert {:ok, _} = Server.decide(server, nil, ref, :confirm)
    assert_receive {:opened, %{"url" => ^url}}, 5_000
    assert_receive {:completed, {:governed, %{outcome: %{status: :ambiguous}}}}, 5_000
    assert :ok = stop_supervised(:receipt_server)
    server = start_supervised!({Server, opts})
    assert {:error, _} = Server.decide(server, nil, ref, :confirm)
    refute_receive {:opened, _}
    assert {:ok, view} = Server.gam_view(server)
    assert Enum.any?(view.outcomes, &(&1.status == :ambiguous))
    assert_private_absent(view, url)
    assert_private_absent(:sys.get_state(journal).values, url)
  end

  defp assert_private_absent(value, url) do
    for private <- [
          url,
          "page-content-private",
          "receipt-content-private",
          "binding-content-private",
          "rejection-content-private"
        ] do
      refute contains?(value, private), "private content found in persisted records"
    end
  end

  defp contains?(value, needle) when is_binary(value),
    do: :binary.match(value, needle) != :nomatch

  defp contains?(value, needle) when is_map(value),
    do: Enum.any?(Map.to_list(value), &contains?(&1, needle))

  defp contains?(value, needle) when is_list(value), do: Enum.any?(value, &contains?(&1, needle))
  defp contains?(value, needle) when is_tuple(value), do: contains?(Tuple.to_list(value), needle)
  defp contains?(_, _), do: false
end
