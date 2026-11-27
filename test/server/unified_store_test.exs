Code.require_file("../support/gam/projection_store.ex", __DIR__)

defmodule Spectre.Server.UnifiedStoreTest do
  use ExUnit.Case, async: false

  alias ExGAM.Domain.Projection.Store, as: ProjectionStore
  alias ExGAM.Ledger
  alias ExGAM.Ledger.Store.Disk, as: LedgerDisk
  alias Spectre.Test.GAM.ProjectionStore, as: ProjectionMemory
  alias Spectre.Server
  alias Spectre.Server.GAM.Managed.LedgerStorage
  alias Spectre.Server.Store.Disk

  # One behaviour, one reference and no application-authored GAM adapter modules.
  # The disk and RAM delegates stand in for a host-owned database in these tests.
  defmodule Provider do
    @behaviour Spectre.Server.Store

    @impl true
    def fetch(ref, key), do: Disk.fetch(ref.journal, key)
    @impl true
    def put_new(ref, key, value), do: Disk.put_new(ref.journal, key, value)
    @impl true
    def compare_and_swap(ref, key, revision, value),
      do: Disk.compare_and_swap(ref.journal, key, revision, value)

    @impl true
    def delete(ref, key, revision), do: Disk.delete(ref.journal, key, revision)
    @impl true
    def list(ref, prefix, opts), do: Disk.list(ref.journal, prefix, opts)

    @impl true
    def ledger_append(ref, domain, batch, payloads, revision, opts),
      do:
        LedgerDisk.append(
          domain,
          batch,
          payloads,
          revision,
          Keyword.put(opts, :server, ref.ledger)
        )

    @impl true
    def ledger_load(ref, domain, opts),
      do: LedgerDisk.load(domain, Keyword.put(opts, :server, ref.ledger))

    @impl true
    def ledger_head(ref, domain, opts),
      do: LedgerDisk.head(domain, Keyword.put(opts, :server, ref.ledger))

    @impl true
    def ledger_read_batch(ref, domain, revision, opts),
      do: LedgerDisk.read_batch(domain, revision, Keyword.put(opts, :server, ref.ledger))

    @impl true
    def ledger_lookup_batch(ref, domain, batch, opts),
      do: LedgerDisk.lookup_batch(domain, batch, Keyword.put(opts, :server, ref.ledger))

    @impl true
    def ledger_export(ref, domain, opts),
      do: LedgerDisk.export(domain, Keyword.put(opts, :server, ref.ledger))

    @impl true
    def projection_open(ref, domain, opts),
      do: ProjectionMemory.open(domain, Keyword.put(opts, :server, ref.projection))

    @impl true
    def projection_head(ref, domain, opts),
      do: ProjectionMemory.head(domain, Keyword.put(opts, :server, ref.projection))

    @impl true
    def projection_commit(ref, handle, before, next, changes, opts),
      do:
        ProjectionMemory.commit(
          handle,
          before,
          next,
          changes,
          Keyword.put(opts, :server, ref.projection)
        )

    @impl true
    def projection_fetch(ref, handle, cursor, keys, opts),
      do: ProjectionMemory.fetch(handle, cursor, keys, Keyword.put(opts, :server, ref.projection))

    @impl true
    def projection_page(ref, handle, cursor, collection, opts),
      do:
        ProjectionMemory.page(
          handle,
          cursor,
          collection,
          Keyword.put(opts, :server, ref.projection)
        )

    @impl true
    def projection_select(ref, handle, cursor, collection, selection, opts),
      do:
        ProjectionMemory.select(
          handle,
          cursor,
          collection,
          selection,
          Keyword.put(opts, :server, ref.projection)
        )
  end

  defmodule HistoryOnly do
    @behaviour Spectre.Server.Store
    defdelegate fetch(ref, key), to: Provider
    defdelegate put_new(ref, key, value), to: Provider
    defdelegate compare_and_swap(ref, key, revision, value), to: Provider
    defdelegate delete(ref, key, revision), to: Provider
    defdelegate ledger_append(ref, domain, batch, payloads, revision, opts), to: Provider
    defdelegate ledger_load(ref, domain, opts), to: Provider
    defdelegate ledger_head(ref, domain, opts), to: Provider
    defdelegate ledger_read_batch(ref, domain, revision, opts), to: Provider
    defdelegate ledger_lookup_batch(ref, domain, batch, opts), to: Provider
    defdelegate ledger_export(ref, domain, opts), to: Provider
  end

  defmodule PartialHistory do
    @behaviour Spectre.Server.Store
    defdelegate fetch(ref, key), to: Provider
    defdelegate put_new(ref, key, value), to: Provider
    defdelegate compare_and_swap(ref, key, revision, value), to: Provider
    defdelegate delete(ref, key, revision), to: Provider
    defdelegate ledger_head(ref, domain, opts), to: Provider
  end

  defmodule PartialProjection do
    @behaviour Spectre.Server.Store
    defdelegate fetch(ref, key), to: Provider
    defdelegate put_new(ref, key, value), to: Provider
    defdelegate compare_and_swap(ref, key, revision, value), to: Provider
    defdelegate delete(ref, key, revision), to: Provider
    defdelegate ledger_append(ref, domain, batch, payloads, revision, opts), to: Provider
    defdelegate ledger_load(ref, domain, opts), to: Provider
    defdelegate ledger_head(ref, domain, opts), to: Provider
    defdelegate ledger_read_batch(ref, domain, revision, opts), to: Provider
    defdelegate ledger_lookup_batch(ref, domain, batch, opts), to: Provider
    defdelegate ledger_export(ref, domain, opts), to: Provider
    defdelegate projection_open(ref, domain, opts), to: Provider
  end

  defmodule LegacyHistory do
    @behaviour Spectre.Server.Store
    defdelegate fetch(ref, key), to: Provider
    defdelegate put_new(ref, key, value), to: Provider
    defdelegate compare_and_swap(ref, key, revision, value), to: Provider
    defdelegate delete(ref, key, revision), to: Provider
    def gam_ledger(ref), do: {:ok, {LedgerDisk, server: ref.ledger}}
  end

  defmodule LegacyDomain do
    @behaviour Spectre.Server.Store
    defdelegate fetch(ref, key), to: Provider
    defdelegate put_new(ref, key, value), to: Provider
    defdelegate compare_and_swap(ref, key, revision, value), to: Provider
    defdelegate delete(ref, key, revision), to: Provider
    defdelegate gam_ledger(ref), to: LegacyHistory

    def gam_domain(%{selection: :not_configured}), do: :not_configured
    def gam_domain(%{selection: {:error, reason}}), do: {:error, reason}
    def gam_domain(%{selection: :malformed}), do: :malformed
    def gam_domain(%{selection: :unreachable}), do: exit(:noproc)

    def gam_domain(ref),
      do:
        {:ok,
         %{
           ledger: {LedgerDisk, server: ref.ledger},
           projection: {ProjectionMemory, server: ref.projection}
         }}
  end

  defmodule UnavailableHistory do
    def gam_ledger(:ledger_offline), do: exit(:noproc)
    def gam_ledger(ref), do: LegacyHistory.gam_ledger(ref)

    def fetch(:conflicted, _), do: {:error, :offline}
    def fetch(_, {:managed_authority, _}), do: :not_found
    def fetch(_, {:managed_agent, _}), do: {:error, :offline}

    def compare_and_swap(_, _, _, _), do: {:error, :conflict}
  end

  defmodule Faults do
    def ledger_append(_, _, _, _, _, _), do: exit(:lost_acknowledgement)
    def ledger_load(_, _, _), do: raise("offline")

    def ledger_load_from(observer, domain, revision, opts) do
      send(observer, {:native_suffix, domain, revision, opts})
      :not_found
    end
  end

  defmodule App do
    use Spectre.Server

    def handle_flow(:unmatched, %{text: "run"}, ctx),
      do: propose(ctx, :run, %{}, on_result: :ran)

    def handle_flow(:unmatched, input, ctx), do: respond(ctx, input.text)

    def handle_result(:ran, result, ctx) do
      send(Spectre.Server.UnifiedStoreTest, {:effect_result, result})
      no_response(ctx)
    end
  end

  defmodule Effect do
    def execute_effect(:run, _, _) do
      send(Spectre.Server.UnifiedStoreTest, :effect_executed)
      {:ok, %{completed: true}}
    end
  end

  defmodule Effects do
    use Spectre.Stack.Installable, id: :unified_effect, version: "0.1.0", spectre: "~> 0.4.0"

    def effects(_),
      do: %{
        run: %{
          contract: 1,
          adapter: Effect,
          operation: :run,
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
    install(Effects)
  end

  defmodule Definition do
    use Spectre.Agent, server: App, stack: Stack
  end

  setup %{tmp_dir: path} do
    Process.register(self(), __MODULE__)
    journal_opts = [path: Path.join(path, "coordination.store")]
    ledger_opts = [path: Path.join(path, "history")]
    journal = start_supervised!({Disk, journal_opts})
    ledger = start_supervised!({LedgerDisk, ledger_opts})
    projection = start_supervised!(%{id: :projection, start: {ProjectionMemory, :start_link, []}})

    {:ok,
     ref: %{journal: journal, ledger: ledger, projection: projection},
     journal_opts: journal_opts,
     ledger_opts: ledger_opts}
  end

  @moduletag :tmp_dir
  test "one provider admits work and rebuilds its read model after all owners restart", c do
    opts = shorthand_options(Provider, c.ref, "persistent")
    server = start_supervised!({Server, opts}, id: :root)
    assert {:ok, _} = Server.input(server, "remember me")
    assert_receive {Server, ^server, {:response, _, "remember me", _}}, 5_000
    run_effect(server)

    state = :sys.get_state(server)
    managed = :sys.get_state(state.managed_owner)
    domain = managed.refs.domain
    assert managed.journal == {Provider, c.ref}
    assert managed.owned == []
    assert {:ok, head} = Ledger.Store.head(managed.store, domain)

    assert {:ok, %{cursor: ^head} = projection_head} =
             ProjectionStore.head(managed.projection_store, domain)

    assert {:ok, [{key, bytes}], next} =
             ProjectionStore.page(
               managed.projection_store,
               projection_head.handle,
               head,
               :principals,
               limit: 1
             )

    assert is_binary(bytes)
    assert next != nil

    assert {:ok, %{^key => ^bytes}} =
             ProjectionStore.fetch(managed.projection_store, projection_head.handle, head, [key])

    {:principals, principal} = key

    assert {:ok, [{{:record_refs, {^principal, :principals}}, _}], nil} =
             ProjectionStore.page(
               managed.projection_store,
               projection_head.handle,
               head,
               :record_refs,
               group: principal,
               limit: 1
             )

    assert {:ok, suffix} = Ledger.Store.load_from(managed.store, domain, 0, [])
    assert suffix.revision == head.revision
    assert {:ok, export} = Ledger.Store.export(managed.store, domain, [])
    assert export["domain_ref"] == domain

    assert :ok = stop_supervised(:root)
    assert Process.alive?(c.ref.journal)
    assert Process.alive?(c.ref.ledger)
    assert Process.alive?(c.ref.projection)
    assert :ok = stop_supervised(Disk)
    assert :ok = stop_supervised(LedgerDisk)
    assert :ok = stop_supervised(:projection)
    journal = start_supervised!({Disk, c.journal_opts})
    ledger = start_supervised!({LedgerDisk, c.ledger_opts})
    projection = start_supervised!(%{id: :projection, start: {ProjectionMemory, :start_link, []}})
    ref = %{journal: journal, ledger: ledger, projection: projection}

    restarted = start_supervised!({Server, options(Provider, ref, "persistent")}, id: :root)
    recovered = :sys.get_state(restarted)
    fresh = :sys.get_state(recovered.managed_owner)
    assert fresh.refs.domain == domain
    assert Enum.any?(recovered.history, &(&1.user == "remember me"))
    assert {:ok, rebuilt} = ProjectionStore.head(fresh.projection_store, domain)
    assert rebuilt.cursor.revision >= head.revision
    run_effect(restarted)
    assert :ok = stop_supervised(:root)
    assert Process.alive?(journal)
    assert Process.alive?(ledger)
  end

  test "persisted projections are optional and identities isolate a shared provider", c do
    left = start_supervised!({Server, shorthand_options(HistoryOnly, c.ref, "left")}, id: :left)
    right = start_supervised!({Server, options(HistoryOnly, c.ref, "right")}, id: :right)
    left_state = :sys.get_state(left)
    right_state = :sys.get_state(right)
    left_host = :sys.get_state(left_state.managed_owner)
    right_host = :sys.get_state(right_state.managed_owner)
    assert left_host.projection_store == nil
    assert right_host.projection_store == nil
    refute left_host.refs.domain == right_host.refs.domain
    refute left_state.opts[:checkpoint] == right_state.opts[:checkpoint]
    assert {:ok, _} = Server.input(left, "left history")
    assert_receive {Server, ^left, {:response, _, "left history", _}}, 5_000
    assert :sys.get_state(right).history == []
    run_effect(left)
    run_effect(right)
  end

  test "storage shorthand rejects a second store selection before bootstrap", c do
    for store <- [{Provider, c.ref}, nil] do
      opts =
        shorthand_options(Provider, c.ref, "conflict")
        |> Keyword.update!(:gam, &Keyword.put(&1, :store, store))

      assert {:error, :conflicting_managed_storage} = Server.start_link(opts)
    end

    assert {:ok, [], nil} = Disk.list(c.ref.journal, {:managed_authority}, [])
  end

  test "reset keeps the unified backend and restores the new session after restart", c do
    opts = shorthand_options(Provider, c.ref, "reset")
    server = start_supervised!({Server, opts}, id: :root)
    assert {:ok, _} = Server.input(server, "before reset")
    assert_receive {Server, ^server, {:response, _, "before reset", _}}, 5_000
    previous = :sys.get_state(server)
    old_domain = :sys.get_state(previous.managed_owner).refs.domain
    old_session = Server.status(server).session
    {Provider, _, old_checkpoint} = previous.opts[:checkpoint]

    assert :ok = Server.reset(server)

    assert_receive {Server, ^server,
                    {:reset, %{session: session, previous_domain: ^old_domain, domain: domain}}},
                   5_000

    assert Server.status(server).session == session
    refute session == old_session
    refute domain == old_domain
    fresh = :sys.get_state(server)
    host = :sys.get_state(fresh.managed_owner)
    assert host.journal == {Provider, c.ref}
    refute host.ephemeral
    assert fresh.history == []
    assert {:ok, _} = Provider.fetch(c.ref, old_checkpoint)
    assert {:ok, _} = Provider.ledger_head(c.ref, old_domain, [])

    assert {:error, :session_required} =
             Server.deliver(server, "missing-session", :external, {:ok, :late})

    assert {:error, :stale_session} =
             Server.deliver(server, "old-session", :external, {:ok, :late}, session: old_session)

    assert {:ok, _} = Server.input(server, "after reset")
    assert_receive {Server, ^server, {:response, _, "after reset", _}}, 5_000
    assert :ok = stop_supervised(:root)

    restarted = start_supervised!({Server, opts}, id: :root)
    restored = :sys.get_state(restarted)
    assert Server.status(restarted).session == session
    assert :sys.get_state(restored.managed_owner).refs.domain == domain
    assert Enum.any?(restored.history, &(&1.user == "after reset"))
    refute Enum.any?(restored.history, &(&1.user == "before reset"))
    run_effect(restarted)
  end

  test "partial history and projection groups fail before writing authority", c do
    for {provider, group} <- [{PartialHistory, :ledger}, {PartialProjection, :projection}] do
      domain = "incomplete-#{group}"

      assert {:error, {:incomplete_server_store, ^provider, ^group, missing}} =
               LedgerStorage.open(:ledger, {provider, c.ref}, domain, "profile")

      assert missing != []
      assert :not_found = Disk.fetch(c.ref.journal, {:managed_authority, domain})
      assert :not_found = LedgerDisk.head(domain, server: c.ref.ledger)
      assert Process.alive?(c.ref.journal)
      assert Process.alive?(c.ref.ledger)
    end
  end

  test "legacy domain, history-only and explicit ledger configurations remain selectable", c do
    assert {:ok, history} =
             LedgerStorage.open(:ledger, {LegacyHistory, c.ref}, "legacy-history", "profile")

    assert history.store == {LedgerDisk, server: c.ref.ledger}
    assert history.projection_store == nil

    assert {:ok, domain} =
             LedgerStorage.open(:ledger, {LegacyDomain, c.ref}, "legacy-domain", "profile")

    assert domain.projection_store == {ProjectionMemory, server: c.ref.projection}

    fallback_ref = Map.put(c.ref, :selection, :not_configured)

    assert {:ok, fallback} =
             LedgerStorage.open(
               :ledger,
               {LegacyDomain, fallback_ref},
               "legacy-fallback",
               "profile"
             )

    assert fallback.projection_store == nil
    offline_ref = Map.put(c.ref, :selection, {:error, :offline})

    assert {:error, :offline} =
             LedgerStorage.open(:ledger, {LegacyDomain, offline_ref}, "legacy-offline", "profile")

    assert :not_found = Disk.fetch(c.ref.journal, {:managed_authority, "legacy-offline"})
    selected = {LedgerDisk, server: c.ref.ledger}

    assert {:ok, explicit} =
             LedgerStorage.open({:ledger, selected}, {Provider, c.ref}, "explicit", "profile")

    assert explicit.store == selected
    assert explicit.projection_store == nil
  end

  test "malformed or unreachable legacy providers fail before creating authority", c do
    assert {:error, :managed_ledger_requires_coordination_store} =
             LedgerStorage.open(:ledger, nil, "unconfigured", "profile")

    for selection <- [:malformed, :unreachable] do
      ref = Map.put(c.ref, :selection, selection)

      assert {:error, _reason} =
               LedgerStorage.open(:ledger, {LegacyDomain, ref}, "unavailable", "profile")

      assert :not_found = Disk.fetch(c.ref.journal, {:managed_authority, "unavailable"})
      assert :not_found = LedgerDisk.head("unavailable", server: c.ref.ledger)
    end
  end

  test "legacy history and coordination read errors preserve the original failure", c do
    assert {:error, _reason} =
             LedgerStorage.open(
               :ledger,
               {UnavailableHistory, :ledger_offline},
               "legacy",
               "profile"
             )

    journal = {UnavailableHistory, c.ref}
    assert {:error, :offline} = LedgerStorage.open(:ledger, journal, "legacy", "profile")

    key = {:managed_authority, "legacy"}
    entry = %{revision: 1, value: %{digest: "profile", issued_at: 1, ready: false}}

    assert {:error, :offline} =
             LedgerStorage.ready(%{
               journal: {UnavailableHistory, :conflicted},
               authority_profile: {key, entry}
             })
  end

  test "legacy projection and ledger readers use the same ExGAM records and cursors", c do
    alias Spectre.GAM.Domain.Projection.{IndexRows, Rows, Store}
    alias Spectre.GAM.Ledger.{Entry, Reader}
    alias Spectre.GAM.Ledger.Store, as: History

    domain = "legacy-reader"
    config = {ProjectionMemory, server: c.ref.projection}
    history = {LedgerDisk, server: c.ref.ledger}
    cursor = %{revision: 0, head_digest: Entry.genesis_digest()}
    key = {:evidence_revisions, 1}
    row = %ExGAM.Row{write: true}
    next = %{cursor | revision: 1}

    assert :not_found = History.head(history, domain)

    assert :not_found =
             Reader.reduce(history, domain, cursor, [], fn _, state -> {:ok, state} end)

    assert Spectre.GAM.Portable.sha256_digest?(cursor.head_digest)

    assert {:ok, handle} = ProjectionStore.open(config, domain)
    assert :ok = ProjectionStore.commit(config, handle, cursor, next, [{:put, key, row}])
    assert {:ok, %{handle: ^handle, cursor: ^next}} = Store.head(config, domain)
    assert {:ok, %{^key => bytes}} = Store.fetch(config, handle, next, [key])
    assert {:ok, [{^key, ^bytes}], nil} = Store.page(config, handle, next, :evidence_revisions)
    assert {:ok, ^bytes} = Rows.encode(row)
    assert {:ok, ^row} = Rows.decode(bytes)
    assert :evidence_revisions in Rows.collections()
    assert IndexRows.position(:evidence_revisions, 1) == 1
    assert IndexRows.group(:act_declassifications, {"act", "record"}) == "act"
  end

  test "legacy PostgreSQL configuration and callbacks forward to ExGAM" do
    alias Spectre.GAM.Ledger.Store.Postgres

    opts = [table_prefix: "spectre_gam"]
    assert {:ok, %{table_prefix: "spectre_gam"}} = Postgres.namespace(opts)
    assert Postgres.migration_sql(opts) == ExGAM.Ledger.Store.Postgres.migration_sql(opts)

    for {callback, args} <- [
          append: ["legacy", "batch", [], 0],
          load: ["legacy"],
          load_from: ["legacy", 0],
          head: ["legacy"],
          read_batch: ["legacy", 1],
          lookup_batch: ["legacy", "batch"],
          export: ["legacy"]
        ] do
      assert {:error, {:missing_ledger_postgres_option, :repo}} =
               apply(Postgres, callback, args ++ [[]])
    end
  end

  test "the translating ledger retains guarded ambiguity and native suffix options" do
    store = {Spectre.Server.Store.Ledger, store: {Faults, self()}}
    assert {:error, :ambiguous} = Ledger.Store.append(store, "faults", "batch", [%{}], 0, [])

    assert {:error, {:ledger_store_exception, Spectre.Server.Store.Ledger, :load, RuntimeError}} =
             Ledger.Store.load(store, "faults", [])

    assert :not_found = Ledger.Store.load_from(store, "faults", 3, timeout: 42)
    assert_receive {:native_suffix, "faults", 3, [timeout: 42]}
  end

  defp options(provider, ref, session) do
    [
      agent: Definition,
      consumer: self(),
      identity: %{tenant: "tests", subject: "support", conversation: session},
      gam: [storage: :ledger, store: {provider, ref}, operations: %{run: [confirm: false]}]
    ]
  end

  defp shorthand_options(provider, ref, session) do
    options(provider, ref, session)
    |> Keyword.update!(:gam, fn gam ->
      gam |> Keyword.delete(:store) |> Keyword.put(:storage, {provider, ref})
    end)
  end

  defp run_effect(server) do
    assert {:ok, _} = Server.input(server, "run")
    assert_receive :effect_executed, 5_000
    assert_receive {:effect_result, {:governed, %{outcome: %{status: :succeeded}}}}, 5_000
    assert %{busy: false, outbox_size: 0} = Server.status(server)
  end
end
