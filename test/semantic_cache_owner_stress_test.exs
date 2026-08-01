defmodule SpectreSemanticCacheOwnerStressTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner

  @online_table Module.concat(Learned, Online)
  @revision_table Module.concat(Learned, Revisions)
  @tables [Learned, @online_table, @revision_table]

  test "rapid owner crashes recreate every ETS table before the replacement is usable" do
    application_supervisor = Process.whereis(Spectre.ApplicationSupervisor)
    assert is_pid(application_supervisor)
    assert :ok = Supervisor.terminate_child(application_supervisor, Owner)

    try do
      {:ok, stress_supervisor} =
        Supervisor.start_link([{Owner, []}],
          strategy: :one_for_one,
          max_restarts: 50,
          max_seconds: 1
        )

      Process.unlink(stress_supervisor)

      try do
        initial_owner = await_ready_owner(nil)

        Enum.reduce(1..25, initial_owner, fn iteration, old_owner ->
          marker = {:restart_stress, iteration}

          Enum.each(@tables, fn table ->
            assert true = :ets.insert(table, {marker, old_owner})
          end)

          monitor = Process.monitor(old_owner)
          Process.exit(old_owner, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^old_owner, :killed}, 1_000

          new_owner = await_ready_owner(old_owner)
          refute new_owner == old_owner

          Enum.each(@tables, fn table ->
            assert :ets.info(table, :owner) == new_owner
            assert :ets.lookup(table, marker) == []
          end)

          assert {:ok, Learned} =
                   Owner.ensure_table(Learned, [:named_table, :public, :set])

          new_owner
        end)
      after
        if Process.alive?(stress_supervisor), do: Supervisor.stop(stress_supervisor)
      end
    after
      restart_application_owner(application_supervisor)
    end
  end

  defp await_ready_owner(previous_owner, attempts \\ 200)

  defp await_ready_owner(previous_owner, attempts) when attempts > 0 do
    case Process.whereis(Owner) do
      owner when is_pid(owner) and owner != previous_owner ->
        if Enum.all?(@tables, &(:ets.info(&1, :owner) == owner)) do
          owner
        else
          retry_ready_owner(previous_owner, attempts)
        end

      _other ->
        retry_ready_owner(previous_owner, attempts)
    end
  end

  defp await_ready_owner(previous_owner, 0) do
    flunk(
      "semantic-cache owner did not become ready after #{inspect(previous_owner)}; " <>
        "owner=#{inspect(Process.whereis(Owner))}, " <>
        "tables=#{inspect(Enum.map(@tables, &{&1, :ets.info(&1, :owner)}))}"
    )
  end

  defp retry_ready_owner(previous_owner, attempts) do
    Process.sleep(5)
    await_ready_owner(previous_owner, attempts - 1)
  end

  defp restart_application_owner(supervisor) do
    case Supervisor.restart_child(supervisor, Owner) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, :running} -> :ok
    end

    _owner = await_ready_owner(nil)
    :ok
  end
end
