defmodule SpectreDoctorTest.Package do
  @moduledoc false
  use Spectre.Stack.Installable,
    id: :doctor_package,
    version: "1.0.0",
    spectre: ">= 0.3.0 and < 0.4.0",
    provides: [{:contract, :doctor_probe}]

  @impl true
  def child_specs(_installation, _opts), do: raise("doctor must not start resources")
end

defmodule SpectreDoctorTest.IncompatiblePackage do
  @moduledoc false
  use Spectre.Stack.Installable,
    id: :doctor_incompatible,
    version: "1.0.0",
    spectre: ">= 0.1.0 and < 0.3.0"
end

defmodule SpectreDoctorTest.CrashingPackage do
  @moduledoc false
  def manifest, do: raise("super-secret-package-callback")
end

defmodule SpectreDoctorTest.Stack do
  @moduledoc false
  use Spectre.Stack, id: :doctor_stack
  install(SpectreDoctorTest.Package)
end

defmodule SpectreDoctorTest.CheckpointStore do
  @moduledoc false
  @behaviour Spectre.Instance.CheckpointStore
  @impl true
  def load(_ref, _opts), do: raise("doctor must not read")
  @impl true
  def compare_and_swap(_ref, _checkpoint, _expected, _revision, _opts),
    do: raise("doctor must not write")
end

defmodule SpectreDoctorTest.EmptyCheckpointStore do
  @moduledoc false
end

defmodule SpectreDoctorTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :doctor_agent, version: 1, stack: SpectreDoctorTest.Stack

  checkpoint_store(SpectreDoctorTest.CheckpointStore,
    diagnostic_marker: "super-secret-store-option"
  )
end

defmodule SpectreDoctorTest.BrokenAgent do
  @moduledoc false
  use Spectre.Agent, id: :doctor_broken_agent, version: 1
  checkpoint_store(SpectreDoctorTest.EmptyCheckpointStore)
end

defmodule SpectreDoctorTest.SecurityProvider do
  @moduledoc false

  @behaviour Spectre.Action.Provider

  alias Spectre.Action.Spec

  @impl Spectre.Action.Provider
  def actions(_opts) do
    [
      Spec.new(name: :protected, via: :remote, visibility: :planner),
      Spec.new(name: :unprotected, via: :remote, visibility: :planner),
      Spec.new(name: :internal, via: :remote, visibility: :deterministic)
    ]
  end

  @impl Spectre.Action.Provider
  def execute(_action, _context, _opts), do: {:ok, :executed}
end

defmodule SpectreDoctorTest.SecurityModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:ok, "safe"}
end

defmodule SpectreDoctorTest.SecurityAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  action_provider(:remote, SpectreDoctorTest.SecurityProvider)
  protect({:remote, :protected}, with: :confirmation)
  model(SpectreDoctorTest.SecurityModel, sanitize_reply: false)

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end
end

defmodule SpectreDoctorTest.BoundedSecurityAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  action_provider(:remote, SpectreDoctorTest.SecurityProvider,
    allowed_hosts: ["api.example.test"]
  )

  protect({:remote, :protected}, with: :confirmation)
  protect({:remote, :unprotected}, with: :confirmation)

  policy :confirmation do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end
end

defmodule SpectreDoctorTest.FailingSecurityProvider do
  @moduledoc false

  @behaviour Spectre.Action.Provider

  @impl Spectre.Action.Provider
  def actions(_opts), do: {:error, :catalog_unavailable}

  @impl Spectre.Action.Provider
  def execute(_action, _context, _opts), do: {:error, :unavailable}
end

defmodule SpectreDoctorTest.FailingSecurityAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  action_provider(:remote, SpectreDoctorTest.FailingSecurityProvider,
    allowed_hosts: ["api.example.test"]
  )
end

defmodule SpectreDoctorTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.Doctor, as: DoctorTask
  alias Spectre.Doctor
  alias Spectre.Doctor.Report
  alias Spectre.Operation.Delivery.Consent

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "Doctor composes public contracts without store IO or resource startup" do
    assert {:ok, report} =
             Doctor.run(agent: SpectreDoctorTest.Agent, packages: [SpectreDoctorTest.Package])

    assert report.status == :ok
    checks = Map.new(report.checks, &{&1.id, &1})
    assert checks["foundation.contract"].code == :foundation_contract_valid
    assert checks["agent.definition"].code == :agent_definition_valid
    assert checks["agent.manifest"].code == :agent_manifest_verified
    assert checks["stack.compatibility"].code == :stack_definition_valid
    assert checks["packages.compatibility"].code == :packages_matrix_valid
    assert checks["checkpoint_store.config"].code == :checkpoint_store_callbacks_valid
    refute Map.has_key?(checks, "foundation.roundtrip")
    refute Enum.any?(Map.keys(checks), &String.starts_with?(&1, "ecosystem."))

    json = Report.format(report, :json)
    refute json =~ "super-secret"
    refute json =~ "doctor must not"
    assert Jason.decode!(json)["status"] == "ok"
  end

  test "failures and option validation expose stable codes without reasons" do
    assert {:ok, incompatible} =
             Doctor.run(packages: [SpectreDoctorTest.IncompatiblePackage])

    assert %{status: :error, code: :packages_matrix_invalid} =
             find(incompatible, "packages.compatibility")

    assert {:ok, crashing} = Doctor.run(packages: [SpectreDoctorTest.CrashingPackage])
    assert %{code: :packages_matrix_invalid} = find(crashing, "packages.compatibility")
    refute Report.format(crashing, :json) =~ "super-secret-package-callback"

    assert {:ok, broken_store} =
             Doctor.run(checkpoint_store: SpectreDoctorTest.EmptyCheckpointStore)

    assert %{code: :checkpoint_store_load_missing} =
             find(broken_store, "checkpoint_store.config")

    missing_agent = Module.concat(__MODULE__, MissingAgent)
    assert {:ok, invalid_agent} = Doctor.run(agent: missing_agent)
    assert %{status: :error, code: :agent_not_loaded} = find(invalid_agent, "agent.definition")

    assert {:error, :unknown_doctor_options} = Doctor.run(satellites: [secret: "hidden"])
    assert {:error, {:invalid_doctor_option, :packages}} = Doctor.run(packages: %{})
    assert {:error, {:invalid_doctor_option, :consents}} = Doctor.run(consents: %{})
    assert {:error, :invalid_doctor_options} = Doctor.run([:not_a_keyword])
  end

  test "security diagnostics report planner, egress, sanitization, and consent gaps" do
    consent =
      Consent.new(
        id: "doctor-unbounded-consent",
        subject_id: "subject-one",
        destination: :inbox,
        granted_at: 10
      )

    assert {:ok, report} =
             Doctor.run(agent: SpectreDoctorTest.SecurityAgent, consents: [consent])

    assert report.status == :warning

    assert %{
             status: :warning,
             code: :unprotected_planner_actions,
             details: %{planner_action_count: 2, unprotected_count: 1}
           } = find(report, "agent.planner_action_protection")

    assert %{
             status: :warning,
             code: :executor_egress_allowlist_missing,
             details: %{executor_count: 1, unbounded_count: 1}
           } = find(report, "agent.executor_egress")

    assert %{status: :warning, code: :reply_sanitization_disabled} =
             find(report, "agent.reply_sanitization")

    assert %{
             status: :warning,
             code: :delivery_consent_expiry_missing,
             details: %{consent_count: 1, unbounded_count: 1}
           } = find(report, "delivery.consent_expiry")

    expiring = %{consent | expires_at: 20}
    assert {:ok, expiring_report} = Doctor.run(consents: [expiring])

    assert %{status: :ok, code: :delivery_consents_expiring} =
             find(expiring_report, "delivery.consent_expiry")

    assert {:ok, bounded} = Doctor.run(agent: SpectreDoctorTest.BoundedSecurityAgent)

    assert %{status: :ok, code: :planner_actions_protected} =
             find(bounded, "agent.planner_action_protection")

    assert %{status: :ok, code: :executor_egress_bounded} =
             find(bounded, "agent.executor_egress")

    assert %{status: :ok, code: :reply_sanitization_enabled} =
             find(bounded, "agent.reply_sanitization")

    assert {:ok, failed_catalog} = Doctor.run(agent: SpectreDoctorTest.FailingSecurityAgent)

    assert %{status: :error, code: :planner_action_catalog_unavailable} =
             find(failed_catalog, "agent.planner_action_protection")

    assert {:ok, invalid_consent} =
             Doctor.run(
               consents: [
                 %{
                   id: "invalid-consent",
                   subject_id: "subject-one",
                   destination: :inbox,
                   granted_at: 10,
                   expires_at: 5
                 }
               ]
             )

    assert %{status: :error, code: :delivery_consents_invalid} =
             find(invalid_consent, "delivery.consent_expiry")
  end

  test "Report contract v1 is fixture-pinned, redacted, and strict-aware" do
    report = %Report{
      contract_version: Doctor.contract_version(),
      spectre_version: Spectre.version(),
      status: :warning,
      checks: [
        %{
          id: "fixture.warning",
          status: :warning,
          code: :fixture_warning,
          summary: "informational",
          details: %{opaque: {:secret, "must-not-leak"}}
        }
      ],
      summary: %{total: 1, passed: 0, warnings: 1, errors: 0, skipped: 0}
    }

    assert Report.to_map(report) == %{
             contract_version: 1,
             spectre_version: Spectre.version(),
             status: "warning",
             checks: [
               %{
                 id: "fixture.warning",
                 status: "warning",
                 code: "fixture_warning",
                 summary: "informational",
                 details: %{"opaque" => "<redacted>"}
               }
             ],
             summary: %{total: 1, passed: 0, warnings: 1, errors: 0, skipped: 0}
           }

    assert Report.acceptable?(report)
    refute Report.acceptable?(report, strict: true)
    refute Report.format(report, :json) =~ "must-not-leak"
  end

  test "Mix task renders JSON and uses stable failures" do
    Mix.Task.reenable("app.config")
    assert :ok = DoctorTask.run(["--format", "json"])
    assert_receive {:mix_shell, :info, [json]}
    assert %{"status" => "ok"} = Jason.decode!(json)

    assert_raise Mix.Error, ~r/\[spectre_doctor_invalid_format\]/, fn ->
      DoctorTask.run(["--format", "yaml"])
    end

    assert_raise Mix.Error, ~r/\[spectre_doctor_failed\]/, fn ->
      DoctorTask.run(["--agent", "SpectreDoctorTest.BrokenAgent"])
    end
  end

  defp find(report, id), do: Enum.find(report.checks, &(&1.id == id))
end
