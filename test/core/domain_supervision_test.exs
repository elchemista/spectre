defmodule Spectre.CoreTest.DomainSupervisionTest do
  use ExUnit.Case, async: false

  alias Spectre.Domain
  alias Spectre.Ledger.Store.Disk
  alias Spectre.V04Test.{Fixture, Runtime}

  @moduletag :tmp_dir

  test "host child specs boot in dependency order and recover under the same supervisor", c do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "host-supervision")
    opts = Keyword.drop(fixture.sequencer_opts, [:store, :generation])
    Fixture.stop_domain(fixture)

    store = {Disk, server: Spectre.TestSupervisedLedger}
    domain_opts = Keyword.put(opts, :store, store)

    children = [
      {Disk, name: Spectre.TestSupervisedLedger, directory: c.tmp_dir},
      {Domain, domain_opts}
    ]

    supervisor =
      start_supervised!(%{
        id: :host_tree,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
        type: :supervisor
      })

    store_pid = Process.whereis(Spectre.TestSupervisedLedger)
    assert is_pid(store_pid)
    assert {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
    assert domain.server == Domain.whereis(fixture.refs.domain)

    authentication = %{
      principal_ref: fixture.refs.proposer,
      authentication_ref: fixture.refs.authentication,
      session_ref: fixture.refs.session
    }

    assert {:ok, context} =
             Spectre.authenticate(domain, fixture.refs.scope, authentication)

    assert {:ok, scope} = Spectre.open_scope(domain, context, opened_at: Runtime.now())
    assert {:ok, before} = Spectre.head(domain)
    id = {Domain, fixture.refs.domain}
    assert :ok = Supervisor.terminate_child(supervisor, id)
    assert {:ok, restarted} = Supervisor.restart_child(supervisor, id)
    refute restarted == domain.server
    assert Process.whereis(Spectre.TestSupervisedLedger) == store_pid
    assert {:ok, recovered} = Spectre.lookup_domain(fixture.refs.domain)
    assert recovered.server == restarted
    assert {:ok, ^before} = Spectre.head(recovered)

    # Durability does not restore authentication across the generation fence.
    assert {:error, :submission_context_generation_mismatch} = Spectre.acts(scope)
    assert {:ok, fresh} = Spectre.authenticate(recovered, fixture.refs.scope, authentication)
    assert {:error, {:scope_context_binding_mismatch, _}} = Spectre.resume_scope(recovered, fresh)

    assert {:ok, new_context} =
             Spectre.authenticate(recovered, "scope:after-restart", authentication)

    assert {:ok, new_scope} =
             Spectre.open_scope(recovered, new_context, opened_at: Runtime.now())

    assert {:ok, []} = Spectre.acts(new_scope)
  end
end
