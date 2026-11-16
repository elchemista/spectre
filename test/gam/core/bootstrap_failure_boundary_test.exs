Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.BootstrapFailureBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.Domain.{Bootstrap, Configuration, Startup}
  alias Spectre.GAM.Ledger.Store.{ETS, Mock}
  alias Spectre.GAM.V04Test.Runtime

  defmodule Verifier do
    def verify(_genesis, opts) do
      case Keyword.fetch!(opts, :fault) do
        :exception -> raise ArgumentError, "private verifier detail"
        :exit -> exit(:private_reason)
        :throw -> throw(:private_reason)
      end
    end
  end

  test "bootstrap record errors report the missing authority artifact", c do
    state = c.before

    for key <- [:host_profile, :surface] do
      assert {:error, {:missing_domain_bootstrap_record, ^key}} =
               Bootstrap.records(Keyword.delete(c.f.sequencer_opts, key))
    end

    for key <- [:principals, :root_mandates] do
      assert {:error, {:missing_domain_bootstrap_records, ^key}} =
               Bootstrap.records(Keyword.delete(c.f.sequencer_opts, key))

      assert {:error, {:invalid_domain_bootstrap_records, ^key}} =
               Bootstrap.records(Keyword.put(c.f.sequencer_opts, key, %{}))
    end

    assert {:error, :invalid_domain_bootstrap} = Bootstrap.records([:invalid])
    assert {:error, :invalid_domain_bootstrap} = Bootstrap.prepare(nil, [], 0)
    assert {:error, :invalid_domain_projection} = Bootstrap.verify_projection(nil, [])

    assert {:error, :genesis_required} =
             Bootstrap.verify_projection(put_in(state.catalog.genesis, nil), [])

    assert {:error, :invalid_domain_genesis} =
             Bootstrap.verify_projection(put_in(state.catalog.genesis, %{}), [])

    assert {:error, :governed_surface_required} =
             Bootstrap.verify_projection(put_in(state.catalog.surface_ref, nil), [])
  end

  test "a verifier crash never becomes an accepted Genesis or leaks its private reason", c do
    for fault <- [:exception, :throw, :exit] do
      expected = if fault == :exception, do: ArgumentError, else: fault

      assert {:error, {:genesis_verifier_failed, ^expected}} =
               Bootstrap.verify_projection(c.before, genesis_verifier: {Verifier, [fault: fault]})
    end

    for verifier <- [Spectre.GAM.Test.MissingGenesisVerifier, String] do
      assert {:error, :genesis_verifier_unavailable} =
               Bootstrap.verify_projection(c.before, genesis_verifier: verifier)
    end

    assert {:error, :invalid_genesis_verifier} =
             Bootstrap.verify_projection(c.before, genesis_verifier: %{})
  end

  test "lost bootstrap acknowledgement recovers the real committed batch", c do
    {config, mock} = fresh_config(c, [{:append, :after, {:error, :ambiguous}}])
    assert {:ok, state} = Startup.load(config)
    assert state.catalog.genesis == c.f.genesis
    assert length(Enum.filter(Mock.calls(mock), &(&1.operation == :append))) == 1
    assert {:ok, ^state} = Startup.load(config)
  end

  test "an uncommitted ambiguous bootstrap has a bounded retry budget", c do
    {config, mock} = fresh_config(c, [{:append, :before, {:error, :ambiguous}}])
    assert {:ok, state} = Startup.load(config)
    assert state.catalog.genesis == c.f.genesis
    assert length(Enum.filter(Mock.calls(mock), &(&1.operation == :append))) == 2
  end

  test "exhaustion and storage errors do not return a fabricated booted state", c do
    for {script, error} <- [
          {[{:append, :before, {:error, :ambiguous}}], :ambiguous_bootstrap_unresolved},
          {[{:append, :before, {:error, :disk_full}}], :disk_full},
          {[{:load, :after, :not_found}, {:load, :after, :not_found}],
           :domain_bootstrap_not_durable},
          {[
             {:append, :before, {:error, :ambiguous}},
             {:lookup_batch, :before, {:error, :unreadable}}
           ], :unreadable}
        ] do
      {config, _mock} = fresh_config(c, script)
      assert {:error, ^error} = Startup.load(%{config | ambiguous_retries: 0})
    end
  end

  test "another writer winning bootstrap CAS is recovered, never overwritten", c do
    mock =
      start_supervised!(
        {Mock,
         store: c.f.store_config,
         script: [{:load, :before, :not_found}, {:append, :before, {:error, :conflict}}]}
      )

    {:ok, config} =
      Configuration.new(
        c.f.sequencer_opts
        |> Keyword.put(:store, {Mock, [server: mock]})
        |> Keyword.put(:projection_store, nil)
      )

    assert {:ok, state} = Startup.load(config)
    assert state.head_digest == c.attempted.head_digest
    assert state.acts[c.act.ref] == c.act
    assert Enum.any?(Mock.calls(mock), &(&1.operation == :append))
  end

  defp fresh_config(c, script) do
    store = start_supervised!({ETS, []}, id: make_ref())

    mock =
      start_supervised!({Mock, store: {ETS, [server: store]}, script: script}, id: make_ref())

    {:ok, config} =
      Configuration.new(
        c.f.sequencer_opts
        |> Keyword.put(:store, {Mock, [server: mock]})
        |> Keyword.put(:projection_store, nil)
      )

    assert config.clock.now() == Runtime.now()
    {config, mock}
  end
end
