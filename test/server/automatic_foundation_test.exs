defmodule Spectre.Server.AutomaticFoundationTest do
  use ExUnit.Case, async: false

  alias ExGAM, as: GAM
  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.GAM.Managed.Authority
  alias Spectre.Server.GAM.Managed.LedgerStorage
  alias Spectre.Server.GAM.Managed.Store, as: Memory
  alias ExGAM.Ledger.Store.ETS, as: LedgerETS

  defmodule Stack do
    use Spectre.Stack
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack
  end

  defmodule FaultStore do
    def fetch({_, :offline}, _), do: {:error, :offline}
    def fetch({pid, _}, key), do: Memory.fetch(pid, key)

    def put_new({pid, :lost_ack}, key, value) do
      {:ok, _} = Memory.put_new(pid, key, value)
      {:error, :ambiguous}
    end

    def put_new({pid, _}, key, value), do: Memory.put_new(pid, key, value)

    def compare_and_swap({_, :offline}, _, _, _), do: {:error, :offline}
    def delete(_, _, _), do: {:error, :unused}
    def gam_ledger({_, :offline}), do: {:error, :offline}
    def gam_ledger({_, :unconfigured}), do: :not_configured
    def gam_ledger({_, :invalid}), do: {:ok, :missing_adapter}
    def gam_ledger({_, {:ledger, store}}), do: {:ok, store}
  end

  defp options(extra \\ []) do
    Keyword.merge(
      [
        runtime: self(),
        consumer: self(),
        agent: Agent,
        identity: %{subject: "foundation-#{System.unique_integer([:positive])}"}
      ],
      extra
    )
  end

  test "automatic foundation needs no environment selector and grants no undeclared operation" do
    assert {:ok, managed} = Managed.start_link(options())
    on_exit(fn -> Managed.close(managed) end)
    state = :sys.get_state(managed)

    assert state.profile.mode == :mediated
    assert state.operations == %{}
    assert state.mandate.classes == ["presentation.show"]
    assert state.mandate.expires_at == 253_402_300_799_999

    assert :ok =
             Authority.verify(state.genesis, genesis_digest: GAM.Genesis.digest(state.genesis))

    assert {:ok, _} = Managed.view(managed)
  end

  test "configuration attestation binds the complete foundation, not just its name" do
    assert {:ok, managed} = Managed.start_link(options())
    on_exit(fn -> Managed.close(managed) end)
    state = :sys.get_state(managed)
    opts = [genesis_digest: GAM.Genesis.digest(state.genesis)]

    forged = %{state.genesis | root_mandate_refs: ["unexpected-root"]}
    assert forged.attestation_ref == state.genesis.attestation_ref
    assert {:error, :application_authority_mismatch} = Authority.verify(forged, opts)
  end

  test "application identity does not assert an unauthenticated human" do
    assert {:ok, managed} = Managed.start_link(options(identity: %{task: "scheduled-job"}))
    on_exit(fn -> Managed.close(managed) end)
    state = :sys.get_state(managed)

    actor = Enum.find(state.principals, &(&1.ref == state.refs.proposer))
    assert actor.kind == :service
    assert state.mandate.holder_ref == actor.ref
    assert state.mandate.grantor_ref == state.refs.accountable
    refute state.mandate.grantor_ref == actor.ref
    assert Enum.any?(state.profile.assumptions, &String.contains?(&1, "no authenticated human"))
  end

  test "removed authority selector and invalid deadlines return explicit startup errors" do
    assert {:error, :managed_authority_selector_removed} =
             Managed.start_link(options(authority: :development))

    for deadline <- [nil, -1, "tomorrow", System.system_time(:millisecond) - 1] do
      assert {:error, :invalid_managed_authorization_deadline} =
               Managed.start_link(options(expires_at: deadline))
    end
  end

  @tag :tmp_dir
  test "malformed lifecycle timeouts are rejected before allocating storage or a Domain", %{
    tmp_dir: root
  } do
    path = Path.join(root, "unallocated")
    domain = "invalid-timeout-#{System.unique_integer([:positive])}"
    defaults = options(storage: {:disk, path}, domain: domain)

    invalid = [nil, false, "100", 0, -1]

    for {key, values, error} <- [
          {:show_timeout, invalid ++ [:infinity, 4_294_967_296], :invalid_managed_show_timeout},
          {:shutdown_timeout, invalid ++ [:infinity, 4_294_967_296],
           :invalid_managed_shutdown_timeout},
          {:consent_ttl_ms, invalid, :invalid_managed_consent_ttl}
        ],
        value <- values do
      assert {:error, ^error} = Managed.start_link(Keyword.put(defaults, key, value))
      refute File.exists?(path)
      assert GAM.Domain.whereis(domain) == nil
    end
  end

  test "timer upper bounds and explicitly infinite consent are retained exactly" do
    opts =
      options(
        show_timeout: 4_294_967_295,
        shutdown_timeout: 4_294_967_295,
        consent_ttl_ms: :infinity
      )

    assert {:ok, managed} = Managed.start_link(opts)
    state = :sys.get_state(managed)
    assert state.options[:show_timeout] == 4_294_967_295
    assert state.options[:shutdown_timeout] == 4_294_967_295
    assert state.options[:consent_ttl_ms] == :infinity
    assert :ok = Managed.close(managed)
  end

  @tag :tmp_dir
  test "a physical storage directory has one owner even through a symlink alias", %{tmp_dir: root} do
    path = Path.join(root, "state")
    alias_path = Path.join(root, "state-alias")
    opts = options(storage: {:disk, path})
    assert {:ok, managed} = Managed.start_link(opts)
    on_exit(fn -> Managed.close(managed) end)
    :ok = File.ln_s(path, alias_path)

    assert {:error, :managed_storage_path_in_use} = Managed.start_link(opts)

    assert {:error, :managed_storage_path_in_use} =
             Managed.start_link(Keyword.put(opts, :storage, {:disk, alias_path}))

    assert {:ok, _} = Managed.view(managed)
  end

  @tag :tmp_dir
  test "expired authority can still recover its history without extending its deadline", %{
    tmp_dir: path
  } do
    deadline = System.system_time(:millisecond) + 500
    opts = options(storage: {:disk, path}, expires_at: deadline)
    assert {:ok, managed} = Managed.start_link(opts)
    original = :sys.get_state(managed)
    :ok = Managed.close(managed)
    Process.sleep(max(deadline - System.system_time(:millisecond) + 10, 0))

    assert {:ok, recovered} = Managed.start_link(opts)
    on_exit(fn -> Managed.close(recovered) end)
    state = :sys.get_state(recovered)
    assert state.genesis == original.genesis
    assert state.mandate.expires_at == deadline
    assert state.mandate.expires_at < System.system_time(:millisecond)
    assert {:ok, _} = Managed.view(recovered)
  end

  @tag :tmp_dir
  test "durable restart retains exact authority deadline and rejects changed grants", %{
    tmp_dir: path
  } do
    deadline = System.system_time(:millisecond) + 3_600_000
    opts = options(storage: {:disk, path}, expires_at: deadline)
    assert {:ok, managed} = Managed.start_link(opts)
    original = :sys.get_state(managed)
    :ok = Managed.close(managed)

    assert {:ok, recovered} = Managed.start_link(opts)
    state = :sys.get_state(recovered)
    assert state.genesis == original.genesis
    assert state.mandate.expires_at == deadline
    :ok = Managed.close(recovered)

    assert {:error, :managed_authority_configuration_changed} =
             Managed.start_link(Keyword.put(opts, :expires_at, deadline + 1))
  end

  test "host-owned ledger and journal recover one foundation without local files or owned stores" do
    ledger = start_supervised!(LedgerETS)
    journal = start_supervised!({Memory, []})
    selected = {LedgerETS, server: ledger}
    opts = options(storage: {:ledger, selected}, store: {Memory, journal})

    assert {:ok, managed} = Managed.start_link(opts)
    original = :sys.get_state(managed)
    assert original.store == selected
    assert original.owned == []
    :ok = Managed.close(managed)
    assert Process.alive?(ledger)
    assert Process.alive?(journal)

    assert {:ok, recovered} = Managed.start_link(opts)
    state = :sys.get_state(recovered)
    assert state.genesis == original.genesis
    assert state.mandate == original.mandate
    :ok = Managed.close(recovered)

    assert {:error, :managed_authority_configuration_changed} =
             Managed.start_link(Keyword.put(opts, :purpose, "changed"))

    empty = start_supervised!(LedgerETS, id: :empty)

    assert {:error, :managed_authority_history_missing} =
             Managed.start_link(
               Keyword.put(opts, :storage, {:ledger, {LedgerETS, server: empty}})
             )

    assert :not_found = GAM.Ledger.Store.head({LedgerETS, server: empty}, state.refs.domain)

    :ok = stop_supervised(LedgerETS)
    assert {:error, _} = Managed.start_link(opts)
  end

  test "ledger storage requires compatible providers and never silently falls back to memory" do
    journal = start_supervised!({Memory, []})

    assert {:error, :managed_ledger_requires_coordination_store} =
             Managed.start_link(options(storage: :ledger))

    assert {:error, :managed_gam_ledger_unavailable} =
             Managed.start_link(options(storage: :ledger, store: {Memory, journal}))

    assert {:error, {:adapter_callback_missing, Memory, :append, 5}} =
             Managed.start_link(options(storage: {:ledger, Memory}, store: {Memory, journal}))

    ledger = start_supervised!(LedgerETS)
    {:ok, _} = Memory.put_new(journal, {:managed_agent, "existing"}, %{checkpoint: :previous})

    assert {:error, :managed_authority_migration_required} =
             Managed.start_link(
               options(
                 domain: "existing",
                 storage: {:ledger, {LedgerETS, server: ledger}},
                 store: {Memory, journal}
               )
             )
  end

  test "racing first opens share the exact profile and an interrupted bootstrap can resume" do
    ledger = start_supervised!(LedgerETS)
    journal = start_supervised!({Memory, []})
    selected = {:ledger, {LedgerETS, server: ledger}}

    hosts =
      1..12
      |> Task.async_stream(fn _ ->
        LedgerStorage.open(selected, {Memory, journal}, "racing", "configuration-digest")
      end)
      |> Enum.map(fn {:ok, {:ok, host}} -> host end)

    assert hosts |> Enum.map(& &1.issued_at) |> Enum.uniq() |> length() == 1
    assert Enum.all?(hosts, fn host -> elem(host.authority_profile, 1).value.ready == false end)
    assert {:ok, [_], nil} = Memory.list(journal, {:managed_authority})

    # Simulates publication after successful ledger verification. Concurrent
    # publishers may only accept the exact already-published profile.
    Enum.each(hosts, &assert(:ok = LedgerStorage.ready(&1)))

    assert {:error, :managed_authority_history_missing} =
             LedgerStorage.open(selected, {Memory, journal}, "racing", "configuration-digest")
  end

  test "unavailable providers and ambiguous profile writes never manufacture a fresh authority" do
    ledger = start_supervised!(LedgerETS)
    journal = start_supervised!({Memory, []})
    selected = {:ledger, {LedgerETS, server: ledger}}

    assert {:ok, %{store: {LedgerETS, _}}} =
             LedgerStorage.open(
               :ledger,
               {FaultStore, {journal, selected}},
               "configured",
               "digest"
             )

    assert {:error, :offline} =
             LedgerStorage.open(:ledger, {FaultStore, {journal, :offline}}, "offline", "digest")

    assert {:error, :managed_gam_ledger_unavailable} =
             LedgerStorage.open(
               :ledger,
               {FaultStore, {journal, :unconfigured}},
               "offline",
               "digest"
             )

    assert {:error, {:adapter_module_not_loaded, :missing_adapter}} =
             LedgerStorage.open(:ledger, {FaultStore, {journal, :invalid}}, "offline", "digest")

    assert {:error, :offline} =
             LedgerStorage.open(selected, {FaultStore, {journal, :offline}}, "offline", "digest")

    assert {:error, :ambiguous} =
             LedgerStorage.open(selected, {FaultStore, {journal, :lost_ack}}, "unknown", "digest")

    assert {:ok, saved} = Memory.fetch(journal, {:managed_authority, "unknown"})
    assert {:ok, host} = LedgerStorage.open(selected, {Memory, journal}, "unknown", "digest")
    assert host.issued_at == saved.value.issued_at
    assert host.authority_profile == {{:managed_authority, "unknown"}, saved}

    assert {:error, :offline} =
             LedgerStorage.ready(%{host | journal: {FaultStore, {journal, :offline}}})

    {:ok, _} =
      Memory.compare_and_swap(journal, {:managed_authority, "unknown"}, saved.revision, %{
        saved.value
        | digest: "other-configuration"
      })

    assert {:error, :managed_authority_configuration_changed} = LedgerStorage.ready(host)
    assert :not_found = GAM.Ledger.Store.head({LedgerETS, server: ledger}, "unknown")
  end
end
