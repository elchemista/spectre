defmodule Spectre.Server.AutomaticFoundationTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM
  alias Spectre.Server.GAM.Managed
  alias Spectre.Server.GAM.Managed.Authority

  defmodule Stack do
    use Spectre.Stack
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack
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
end
