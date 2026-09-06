defmodule Spectre.Core.DiagnosticToolsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.Doctor, as: DoctorTask
  alias Mix.Tasks.Spectre.Gen.PostgresLedgerMigration, as: MigrationTask
  alias Spectre.{Doctor, Genesis, HostProfile, Surface}
  alias Spectre.Domain.Sequencer
  alias Spectre.Ledger.Store.Postgres
  alias Spectre.V04Test.{Fixture, Ingress, Runtime}

  @moduletag :tmp_dir

  setup do
    Runtime.reset(Fixture.default_now())
    fixture = Fixture.start_domain(namespace: "diagnostics")
    state = Sequencer.projection(fixture.server)
    old_shell = Mix.shell()
    old_config = Application.fetch_env(:spectre, :doctor)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Fixture.stop_domain(fixture)
      Mix.shell(old_shell)

      case old_config do
        {:ok, value} -> Application.put_env(:spectre, :doctor, value)
        :error -> Application.delete_env(:spectre, :doctor)
      end
    end)

    %{
      fixture: fixture,
      config: [
        store: fixture.store_config,
        ingress: Ingress,
        genesis: fixture.genesis,
        host_profile: Map.fetch!(state.catalog.host_profiles, state.catalog.host_profile_ref),
        surface: Map.fetch!(state.catalog.surfaces, state.catalog.surface_ref)
      ]
    }
  end

  test "checking a live declared boundary is read-only and keeps host assumptions visible", c do
    before = Fixture.snapshot(c.fixture)
    report = Doctor.check(c.config)
    assert report.ok?
    assert report.errors == []
    assert report.checks == [:zone_dependencies, :ledger_store, :ingress, :boundary_declaration]

    assert %{
             check: :boundary_declaration,
             reason: :development_profile_is_not_gam_conformance
           } in report.warnings

    assert Fixture.snapshot(c.fixture) === before
  end

  test "missing configuration is reported as unchecked, not certified" do
    report = Doctor.check([])
    refute report.ok?
    assert report.errors == [%{check: :ingress, reason: :domain_ingress_required}]
    assert %{check: :ledger_store, reason: :ledger_store_not_checked} in report.warnings

    assert %{check: :boundary_declaration, reason: :boundary_declaration_not_checked} in report.warnings
  end

  test "a compiled executor presented as Mind has its direct boundary dependencies detected", c do
    report = Doctor.check(Keyword.put(c.config, :mind_modules, [Spectre.Attempt.Runner]))
    refute report.ok?

    assert Enum.any?(report.errors, fn
             %{
               check: :zone_dependencies,
               reason: {:zone_m_references_boundary, Spectre.Attempt.Runner, modules}
             } ->
               Spectre.Kernel.Grant in modules

             _other ->
               false
           end)
  end

  test "nonexistent and invalid modules yield findings without successful fallback", c do
    for module <- [Spectre.DoesNotExist, "unloaded-module", 42] do
      report = Doctor.check(Keyword.put(c.config, :mind_modules, [module]))
      refute report.ok?
      assert Enum.any?(report.errors, &(&1.check == :zone_dependencies))
    end

    assert {:error, {:invalid_doctor_module, 42}} = Doctor.dependencies(42)
  end

  test "an improper nested module list cannot crash the diagnostic API", c do
    for zone <- [:mind_modules, :executor_modules] do
      report = Doctor.check(Keyword.put(c.config, zone, [Spectre.Mind | :invalid]))
      refute report.ok?
      assert Enum.any?(report.errors, &(&1.check == :zone_dependencies))
    end
  end

  test "a canonical but different host profile cannot masquerade as the Genesis binding", c do
    profile = Keyword.fetch!(c.config, :host_profile)

    assert {:ok, changed} =
             profile
             |> Map.from_struct()
             |> Map.delete(:ref)
             |> Map.put(:attestation_ref, "different-attestation")
             |> HostProfile.new()

    report = Doctor.check(Keyword.put(c.config, :host_profile, changed))
    refute report.ok?

    assert %{check: :boundary_declaration, reason: :genesis_host_profile_mismatch} in report.errors
  end

  test "a canonical Surface revision with a new ref still requires a matching Genesis", c do
    surface = Keyword.fetch!(c.config, :surface)

    assert {:ok, changed} =
             surface
             |> Map.from_struct()
             |> Map.delete(:ref)
             |> Map.update!(:revision, &(&1 + 1))
             |> Surface.new()

    report = Doctor.check(Keyword.put(c.config, :surface, changed))
    refute report.ok?
    assert %{check: :boundary_declaration, reason: :genesis_surface_mismatch} in report.errors
  end

  test "a mediated declaration still reports host assumptions with matching records", c do
    profile = Keyword.fetch!(c.config, :host_profile)

    assert {:ok, changed} =
             profile
             |> Map.from_struct()
             |> Map.delete(:ref)
             |> Map.put(:mode, :mediated)
             |> HostProfile.new()

    assert {:ok, genesis} =
             c.fixture.genesis
             |> Map.from_struct()
             |> Map.put(:ref, "genesis:diagnostics:mediated")
             |> Map.put(:host_profile_ref, changed.ref)
             |> Genesis.new()

    report = Doctor.check(Keyword.merge(c.config, genesis: genesis, host_profile: changed))
    assert report.ok?

    assert %{
             check: :boundary_declaration,
             reason: :mediated_profile_depends_on_host_side_channel_assumptions
           } in report.warnings
  end

  test "a partial declaration or application store cannot pass the ledger contract", c do
    report =
      Doctor.check(
        c.config
        |> Keyword.delete(:surface)
        |> Keyword.put(:store, Spectre.Store.Memory)
      )

    refute report.ok?

    assert %{check: :boundary_declaration, reason: {:missing_boundary_declaration, :surface}} in report.errors

    assert %{check: :ledger_store, reason: :ledger_store_callbacks_unavailable} in report.errors
  end

  test "Doctor CLI emits warnings on success and raises on a missing ingress", c do
    Application.put_env(:spectre, :doctor, c.config)
    DoctorTask.run([])
    assert_receive {:mix_shell, :info, [warning]}
    assert warning =~ "development_profile_is_not_gam_conformance"
    assert_receive {:mix_shell, :info, [success]}
    assert success =~ "Spectre doctor passed"

    Application.put_env(:spectre, :doctor, Keyword.delete(c.config, :ingress))
    assert_raise Mix.Error, ~r/doctor found 1 error/, fn -> DoctorTask.run([]) end
    assert_receive {:mix_shell, :error, [error]}
    assert error =~ "domain_ingress_required"
  end

  test "Doctor CLI rejects unknown arguments without rewriting application configuration", c do
    Application.put_env(:spectre, :doctor, c.config)
    assert_raise Mix.Error, ~r/does not accept/, fn -> DoctorTask.run(["--ignore-errors"]) end
    assert Application.fetch_env!(:spectre, :doctor) == c.config
  end

  test "migration generator emits parseable host-owned SQL without an Ecto dependency", c do
    MigrationTask.run([
      "--migrations-path",
      c.tmp_dir,
      "--schema",
      "audit",
      "--table-prefix",
      "agent_ledger"
    ])

    assert [file] = File.ls!(c.tmp_dir)
    source = File.read!(Path.join(c.tmp_dir, file))
    assert {:ok, _ast} = Code.string_to_quoted(source)
    assert source =~ "use Ecto.Migration"
    assert source =~ "def up"
    assert source =~ "def down"
    assert {:ok, sql} = Postgres.migration_sql(schema: "audit", table_prefix: "agent_ledger")

    for statement <- sql.up ++ sql.down do
      # Ignore indentation only; no fake database is claimed by this generator test.
      normalized = String.replace(statement, ~r/\s+/, " ") |> String.trim()
      assert String.replace(source, ~r/\s+/, " ") =~ normalized
    end

    refute Enum.any?(Mix.Project.config()[:deps], &(elem(&1, 0) in [:ecto, :ecto_sql, :postgrex]))
  end

  test "migration generator never overwrites an existing migration", c do
    MigrationTask.run(["--migrations-path", c.tmp_dir])
    assert [file] = File.ls!(c.tmp_dir)
    path = Path.join(c.tmp_dir, file)
    original = File.read!(path)

    assert_raise Mix.Error, ~r/migration_already_exists/, fn ->
      MigrationTask.run(["--migrations-path", c.tmp_dir, "--table-prefix", "other"])
    end

    assert File.ls!(c.tmp_dir) == [file]
    assert File.read!(path) === original
  end

  test "invalid migration options and SQL identifiers create no file", c do
    for args <- [
          ["unexpected"],
          ["--unknown", "value"],
          ["--schema", "public; DROP SCHEMA public"],
          ["--table-prefix", "bad\"name"]
        ] do
      assert_raise Mix.Error, fn ->
        MigrationTask.run(["--migrations-path", c.tmp_dir] ++ args)
      end

      assert File.ls!(c.tmp_dir) == []
    end
  end
end
