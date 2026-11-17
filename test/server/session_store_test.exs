defmodule Spectre.Server.SessionStoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.Session
  alias Spectre.Server.Store.Disk

  defmodule App do
    use Spectre.Server
  end

  defmodule Agent do
    use Spectre.Agent, server: App
  end

  defmodule OfflineStore do
    @behaviour Spectre.Server.Store
    def fetch(_, _), do: {:error, :offline}
    def put_new(_, _, _), do: {:error, :offline}
    def compare_and_swap(_, _, _, _), do: {:error, :offline}
    def delete(_, _, _), do: {:error, :offline}
  end

  test "an absent generation retains the configured Domain and checkpoint" do
    store = start_supervised!({Managed.Store, []})

    opts =
      options(
        storage: :ledger,
        store: {Managed.Store, store},
        options: [checkpoint: {store, :root}]
      )

    assert {:ok, effective, session} = Session.restore(opts)
    assert session.generation == nil
    assert session.revision == nil
    assert effective[:domain] == "session-test"
    assert effective[:options][:checkpoint] == {store, :root}
    assert {:store, {Managed.Store, ^store}, key} = session.pointer
    assert :not_found = Managed.Store.fetch(store, key)
  end

  test "preparing a generation leaves the active pointer untouched until CAS activation" do
    store = start_supervised!({Managed.Store, []})

    opts =
      options(
        storage: :ledger,
        store: {Managed.Store, store},
        options: [checkpoint: {store, :root}]
      )

    assert {:ok, _, original} = Session.restore(opts)
    assert {:ok, candidate, next_opts} = Session.prepare(original, :configured)
    assert candidate.domain != original.domain
    assert {:ok, _, unchanged} = Session.restore(opts)
    assert unchanged.generation == nil

    assert {:ok, staged_opts, staged} = Session.restore(next_opts)
    assert staged.generation == candidate.generation

    assert staged_opts[:options][:checkpoint] ==
             {store, {:spectre_session, :root, candidate.generation}}

    assert {:ok, active} = Session.activate(candidate)
    assert active.revision > 0
    assert {:ok, restored_opts, restored} = Session.restore(opts)
    assert restored.generation == candidate.generation
    assert restored.domain == candidate.domain
    assert restored_opts[:options][:checkpoint] == staged_opts[:options][:checkpoint]

    # Dynamic runtime bindings cannot make a later reset wrap an older session
    # key or reopen an automatically owned, retired coordination process.
    assert {:ok, later, _} = Session.prepare(restored, :configured)
    dynamic = [checkpoint: {store, {:spectre_session, :root, candidate.generation}}]

    assert Session.runtime_options(later, dynamic)[:checkpoint] ==
             {store, {:spectre_session, :root, later.generation}}
  end

  test "a stale activation cannot replace a generation selected by another writer" do
    store = start_supervised!({Managed.Store, []})
    opts = options(storage: :ledger, store: {Managed.Store, store})
    assert {:ok, _, original} = Session.restore(opts)
    assert {:ok, first, _} = Session.prepare(original, :configured)
    assert {:ok, stale, _} = Session.prepare(original, :configured)
    assert {:ok, _} = Session.activate(first)
    assert {:error, :session_conflict} = Session.activate(stale)
    assert {:ok, _, current} = Session.restore(opts)
    assert current.generation == first.generation

    assert {:ok, next, _} = Session.prepare(current, :configured)
    assert {:ok, active} = Session.activate(next)
    assert active.revision > current.revision
    assert {:error, :session_conflict} = Session.activate(next)
    assert {:ok, _, restored} = Session.restore(opts)
    assert restored.generation == next.generation
    assert Process.alive?(store)
  end

  @tag :tmp_dir
  test "a disk generation stages separately and remains selected after all owners restart", %{
    tmp_dir: path
  } do
    opts = options(storage: {:disk, path})
    assert {:ok, original} = Managed.start_link(opts)
    on_exit(fn -> Managed.close(original) end)
    original_state = :sys.get_state(original)
    assert original_state.options[:storage] == {:disk, path}
    assert {:ok, original_profile} = File.read(Path.join(path, "authority.profile"))

    assert {:ok, candidate, candidate_opts} = Session.prepare(original_state.session, :configured)
    assert {:ok, staged} = Managed.start_link(candidate_opts)
    on_exit(fn -> Managed.close(staged) end)
    staged_state = :sys.get_state(staged)
    assert staged_state.refs.domain == candidate.domain

    assert staged_state.options[:storage] ==
             {:disk, Path.join([path, "sessions", candidate.generation])}

    assert {:ok, _, unchanged} = Session.restore(opts)
    assert unchanged.generation == nil
    assert {:ok, ^original_profile} = File.read(Path.join(path, "authority.profile"))

    assert {:ok, _} = Session.activate(candidate)
    assert :ok = Managed.close(staged)
    assert :ok = Managed.close(original)
    assert {:ok, replacement} = Managed.start_link(opts)
    on_exit(fn -> Managed.close(replacement) end)
    assert Managed.info(replacement).domain == candidate.domain
    assert :sys.get_state(replacement).session.generation == candidate.generation
    assert {:ok, ^original_profile} = File.read(Path.join(path, "authority.profile"))

    # The temporary pointer owner is released after both restore and activation.
    assert {:ok, pointer} = Disk.start_link(path: Path.join(path, "session.store"))
    assert :ok = GenServer.stop(pointer)
  end

  @tag :tmp_dir
  test "a rejected staged bootstrap leaves the legacy generation selected", %{tmp_dir: path} do
    opts = options(storage: {:disk, path})
    assert {:ok, _, original} = Session.restore(opts)
    assert {:ok, candidate, candidate_opts} = Session.prepare(original, :configured)
    invalid = %{candidate | base_options: Keyword.put(candidate.base_options, :expires_at, -1)}

    assert {:error, :invalid_managed_authorization_deadline} =
             Managed.start_link(Keyword.put(candidate_opts, :session, invalid))

    assert {:ok, restored_opts, restored} = Session.restore(opts)
    assert restored.generation == nil
    assert restored_opts[:storage] == {:disk, path}
  end

  test "explicit RAM preparation and activation never access the retired database" do
    store = start_supervised!({Managed.Store, []})

    opts =
      options(
        storage: :ledger,
        store: {Managed.Store, store},
        payload_store: {OfflineStore, []},
        options: [checkpoint: {store, :root}, payload_store: {OfflineStore, []}]
      )

    assert {:ok, _, original} = Session.restore(opts)
    assert :ok = GenServer.stop(store)
    assert {:ok, candidate, next_opts} = Session.prepare(original, :memory)
    assert {:ok, effective, staged} = Session.restore(next_opts)
    assert effective[:storage] == :ephemeral
    assert effective[:store] == nil
    refute Keyword.has_key?(effective, :payload_store)
    refute Keyword.has_key?(effective[:options], :checkpoint)
    refute Keyword.has_key?(effective[:options], :payload_store)
    assert staged.mode == :memory
    assert candidate.domain != original.domain
    assert {:ok, ^candidate} = Session.activate(candidate)

    # The decision is explicitly process-local; startup does not claim that a
    # database which was never reached now selects this RAM generation.
    assert {:error, :session_store_unavailable} = Session.restore(opts)
  end

  test "configured storage failures and corrupt pointers never become a fresh session" do
    assert {:error, :offline} =
             Session.restore(options(storage: :ledger, store: {OfflineStore, :offline}))

    store = start_supervised!({Managed.Store, []})
    opts = options(storage: :ledger, store: {Managed.Store, store})
    assert {:ok, _, session} = Session.restore(opts)
    assert {:store, _, key} = session.pointer

    assert {:ok, revision} =
             Managed.Store.put_new(store, key, %{version: 1, generation: "../../old"})

    assert {:error, :invalid_server_session} = Session.restore(opts)
    assert {:ok, _} = Managed.Store.compare_and_swap(store, key, revision, %{version: 2})
    assert {:error, :invalid_server_session} = Session.restore(opts)
  end

  defp options(extra) do
    Keyword.merge(
      [
        agent: Agent,
        identity: %{subject: "session-test-human"},
        domain: "session-test",
        runtime: self(),
        runtime_control: make_ref(),
        consumer: self()
      ],
      extra
    )
  end
end
