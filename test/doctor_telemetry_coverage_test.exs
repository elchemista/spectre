defmodule SpectreDoctorTelemetryCoverageTest.InvalidDefinitionAgent do
  @moduledoc false

  def __spectre_definition__, do: :invalid_definition
end

defmodule SpectreDoctorTelemetryCoverageTest.InvalidManifestAgent do
  @moduledoc false

  def __spectre_definition__ do
    Spectre.Definition.new(
      id: :doctor_telemetry_invalid_manifest,
      owner: __MODULE__,
      config: [description: self()]
    )
  end
end

defmodule SpectreDoctorTelemetryCoverageTest.LoadOnlyStore do
  @moduledoc false

  def load(_ref, _opts), do: raise("private checkpoint must not be loaded")
end

defmodule SpectreDoctorTelemetryCoverageTest.Package do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :doctor_telemetry_package,
    version: "1.0.0",
    spectre: "~> 0.3.0",
    provides: [{:contract, :doctor_telemetry_probe}]
end

defmodule SpectreDoctorTelemetryCoverageTest.IncompatiblePackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :doctor_telemetry_incompatible_package,
    version: "1.0.0",
    spectre: ">= 0.1.0 and < 0.3.0"
end

defmodule SpectreDoctorTelemetryCoverageTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.Doctor, as: DoctorTask
  alias Spectre.Doctor
  alias Spectre.Doctor.Report
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Instance.Telemetry, as: InstanceTelemetry

  @missing_agent SpectreDoctorTelemetryCoverageTest.MissingAgent
  @missing_store SpectreDoctorTelemetryCoverageTest.MissingStore

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(shell) end)
  end

  test "Doctor rejects malformed public options before running diagnostics" do
    assert {:error, :invalid_doctor_options} = Doctor.run(:not_a_keyword)

    assert {:error, :duplicate_doctor_options} =
             Doctor.run(agent: __MODULE__, agent: __MODULE__)

    assert {:error, {:invalid_doctor_option, :agent}} = Doctor.run(agent: "Unsafe.Module")
    assert {:error, {:invalid_doctor_option, :agent}} = Doctor.run(agent: true)
    assert {:error, {:invalid_doctor_option, :stack}} = Doctor.run(stack: false)
  end

  test "Doctor classifies unavailable and malformed Agent contracts without leaking replies" do
    assert {:ok, missing} = Doctor.run(agent: @missing_agent)
    assert_check(missing, "agent.definition", :error, :agent_not_loaded)
    assert_check(missing, "agent.manifest", :skipped, :agent_definition_unavailable)

    assert {:ok, invalid} =
             Doctor.run(agent: SpectreDoctorTelemetryCoverageTest.InvalidDefinitionAgent)

    assert_check(invalid, "agent.definition", :error, :agent_definition_invalid)
    refute Report.format(invalid, :json) =~ "invalid_definition"

    assert {:ok, invalid_manifest} =
             Doctor.run(agent: SpectreDoctorTelemetryCoverageTest.InvalidManifestAgent)

    assert_check(invalid_manifest, "agent.definition", :ok, :agent_definition_valid)
    assert_check(invalid_manifest, "agent.manifest", :error, :agent_manifest_invalid)
    refute Report.format(invalid_manifest, :json) =~ inspect(self())
  end

  test "Doctor reports Stack and package matrix boundaries with stable codes" do
    assert {:ok, valid} =
             Doctor.run(stack: [SpectreDoctorTelemetryCoverageTest.Package])

    assert_check(valid, "stack.compatibility", :ok, :stack_matrix_valid)

    assert {:ok, incompatible} =
             Doctor.run(stack: [SpectreDoctorTelemetryCoverageTest.IncompatiblePackage])

    assert_check(incompatible, "stack.compatibility", :error, :stack_matrix_invalid)

    assert {:ok, invalid_module} = Doctor.run(stack: String)
    assert_check(invalid_module, "stack.compatibility", :error, :stack_definition_invalid)

    assert {:ok, empty_packages} = Doctor.run(packages: [])
    assert_check(empty_packages, "packages.compatibility", :error, :packages_empty)
  end

  test "Doctor validates checkpoint adapter shape and callbacks without invoking them" do
    assert {:ok, invalid_config} = Doctor.run(checkpoint_store: 42)

    assert_check(
      invalid_config,
      "checkpoint_store.config",
      :error,
      :checkpoint_store_config_invalid
    )

    assert {:ok, invalid_options} =
             Doctor.run(
               checkpoint_store:
                 {SpectreDoctorTelemetryCoverageTest.LoadOnlyStore, [:not_a_keyword]}
             )

    assert_check(
      invalid_options,
      "checkpoint_store.config",
      :error,
      :checkpoint_store_options_invalid
    )

    assert {:ok, unavailable} = Doctor.run(checkpoint_store: @missing_store)

    assert_check(
      unavailable,
      "checkpoint_store.config",
      :error,
      :checkpoint_store_not_loaded
    )

    assert {:ok, missing_cas} =
             Doctor.run(checkpoint_store: SpectreDoctorTelemetryCoverageTest.LoadOnlyStore)

    assert_check(
      missing_cas,
      "checkpoint_store.config",
      :error,
      :checkpoint_store_cas_missing
    )

    refute Report.format(missing_cas, :json) =~ "private checkpoint"
  end

  test "Report text and maps recursively redact unsafe keys and values" do
    private_pid = self()

    report = %Report{
      contract_version: Doctor.contract_version(),
      spectre_version: Spectre.version(),
      status: :warning,
      checks: [
        %{
          id: "coverage.warning",
          status: :warning,
          code: :coverage_warning,
          summary: "privacy boundary",
          details: %{
            {:private, "raw-key"} => "safe-value",
            classification: :timeout,
            values: [:retry, private_pid]
          }
        },
        %{
          id: "coverage.skipped",
          status: :skipped,
          code: :coverage_skipped,
          summary: "not requested",
          details: %{}
        }
      ],
      summary: %{total: 2, passed: 0, warnings: 1, errors: 0, skipped: 1}
    }

    mapped = Report.to_map(report)
    details = hd(mapped.checks).details

    assert details["classification"] == "timeout"
    assert details["values"] == ["retry", "<redacted>"]
    assert details["redacted_key"] == "safe-value"

    text = Report.format(report)
    assert text =~ "Spectre doctor #{Spectre.version()}: warning"
    assert text =~ "WARNING coverage.warning [coverage_warning]"
    assert text =~ "SKIPPED coverage.skipped [coverage_skipped] not requested"
    refute text =~ "raw-key"
    refute text =~ inspect(private_pid)

    assert Report.acceptable?(report)
    refute Report.acceptable?(report, strict: true)

    error_report = %{
      report
      | status: :error,
        summary: %{report.summary | errors: 1, warnings: 0}
    }

    refute Report.acceptable?(error_report)
  end

  test "Doctor Mix task renders text and rejects unsafe argument and Agent forms" do
    Mix.Task.reenable("app.config")
    assert :ok = DoctorTask.run([])
    assert_receive {:mix_shell, :info, [text]}
    assert text =~ "Spectre doctor #{Spectre.version()}: ok"

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_arguments\]/, fn ->
      DoctorTask.run(["unexpected"])
    end

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_arguments\]/, fn ->
      DoctorTask.run(["--unknown", "value"])
    end

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_agent\]/, fn ->
      DoctorTask.run(["--agent", "SpectreDoctorTelemetryCoverageTest.MissingAgent"])
    end

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_agent\]/, fn ->
      DoctorTask.run(["--agent", "not_a_module"])
    end

    fresh_alias = "DefinitelyFreshDoctorCoverageAlias#{System.unique_integer([:positive])}"

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_agent\]/, fn ->
      DoctorTask.run(["--agent", fresh_alias])
    end
  end

  test "Instance telemetry emits only opaque identity and stable reason classes" do
    test_pid = self()

    handler = fn event, measurements, metadata ->
      send(test_pid, {:instance_coverage_telemetry, event, measurements, metadata})
    end

    data = %InstanceState{
      agent: __MODULE__,
      ref: nil,
      generation: "generation-coverage",
      base_opts: [telemetry_handler: handler]
    }

    assert :ok = InstanceTelemetry.emit(:coverage, data, %{count: 1})

    assert_receive {:instance_coverage_telemetry, [:spectre, :instance, :coverage], %{count: 1},
                    metadata}

    assert metadata == %{
             agent: __MODULE__,
             instance_id: "unavailable",
             generation: "generation-coverage"
           }

    assert InstanceTelemetry.id_digest(self()) == "unavailable"
    assert InstanceTelemetry.reason_class(%{kind: :timeout}) == :timeout
    assert InstanceTelemetry.reason_class({:adapter_failed, "private-reason"}) == :adapter_failed
    assert InstanceTelemetry.reason_class({123, "private-reason"}) == :error
    assert InstanceTelemetry.reason_class(:closed) == :closed
    assert InstanceTelemetry.reason_class(%{kind: "private-kind"}) == :error
  end

  defp assert_check(report, id, status, code) do
    assert %{status: ^status, code: ^code} = Enum.find(report.checks, &(&1.id == id))
  end
end
