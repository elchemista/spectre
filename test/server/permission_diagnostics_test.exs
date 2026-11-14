defmodule Spectre.Server.PermissionDiagnosticsTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.PermissionDiagnostics
  alias Spectre.Skill.Mount

  defmodule Agent do
    def __spectre_skills__ do
      [
        %Mount{id: :mail, bindings: %{send: :send_email}},
        %Mount{id: :notes, bindings: %{save: :remember}, opts: [governed: [:search, :search]]},
        %Mount{id: :observer, bindings: %{}, opts: [governed: []]}
      ]
    end
  end

  test "reports concrete missing root permissions without widening the intersection" do
    assert [
             %{code: :mount_operation_not_enabled, mount: :mail, operation: :send_email},
             %{code: :mount_operation_not_enabled, mount: :notes, operation: :search}
           ] = PermissionDiagnostics.report(Agent, %{})

    assert [] == PermissionDiagnostics.report(Agent, %{send_email: %{}, search: %{}})
    assert :ok == PermissionDiagnostics.validate_options!(Agent, gam: [operations: %{}])
  end

  test "strict validation is opt-in and rejects mismatches before bootstrap" do
    assert_raise ArgumentError, ~r/incompatible Skill operation permissions/, fn ->
      PermissionDiagnostics.validate_options!(Agent,
        strict_permissions: true,
        gam: [operations: %{}]
      )
    end

    assert :ok ==
             PermissionDiagnostics.validate_options!(Agent,
               strict_permissions: true,
               gam: [operations: %{send_email: %{}, search: %{}}]
             )

    assert_raise ArgumentError, ~r/strict_permissions must be boolean/, fn ->
      PermissionDiagnostics.validate_options!(Agent, strict_permissions: :yes)
    end
  end
end
