defmodule Spectre.ServerDiagnosticsTest.Server do
  @moduledoc false
  use Spectre.Server
  @impl true
  def init(_, _), do: raise("diagnostics must not initialize a Server")
end

defmodule Spectre.ServerDiagnosticsTest.ChildServer do
  @moduledoc false
  use Spectre.Server
end

defmodule Spectre.ServerDiagnosticsTest.IncompleteServer do
  @moduledoc false
  def init(_, ctx), do: {:ok, ctx}
end

defmodule Spectre.ServerDiagnosticsTest.Child do
  @moduledoc false
  use Spectre.Skill, server: Spectre.ServerDiagnosticsTest.ChildServer

  flow :work do
    on(:ping, regex: ~r/^ping$/)
  end
end

defmodule Spectre.ServerDiagnosticsTest.Inherited do
  @moduledoc false
  use Spectre.Skill

  flow :work do
    on(:inherited, regex: ~r/^inherited$/)
  end
end

defmodule Spectre.ServerDiagnosticsTest.BrokenChild do
  @moduledoc false
  use Spectre.Skill, server: Spectre.ServerDiagnosticsTest.IncompleteServer
end

defmodule Spectre.ServerDiagnosticsTest.Agent do
  @moduledoc false
  use Spectre.Agent, server: Spectre.ServerDiagnosticsTest.Server

  flow :root do
    on(:hello, regex: ~r/^hello$/)
  end

  skill(Spectre.ServerDiagnosticsTest.Child, as: :child)
  skill(Spectre.ServerDiagnosticsTest.Inherited, as: :inherited)
end

defmodule Spectre.ServerDiagnosticsTest.BrokenAgent do
  @moduledoc false
  use Spectre.Agent, server: Spectre.ServerDiagnosticsTest.IncompleteServer
end

defmodule Spectre.ServerDiagnosticsTest.MissingAgent do
  @moduledoc false
  use Spectre.Agent, server: Spectre.ServerDiagnosticsTest.NoSuchServer
end

defmodule Spectre.ServerDiagnosticsTest.BrokenMountAgent do
  @moduledoc false
  use Spectre.Agent, server: Spectre.ServerDiagnosticsTest.Server
  skill(Spectre.ServerDiagnosticsTest.BrokenChild, as: :broken)
end

defmodule Spectre.ServerDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Spectre.Doctor
  alias Spectre.Doctor.Report

  test "Doctor checks root and mounted Server callbacks without starting resources" do
    assert {:ok, report} = Doctor.run(agent: __MODULE__.Agent)
    checks = Map.new(report.checks, &{&1.id, &1})
    assert checks["server.callbacks"].status == :ok
    assert checks["skill.child.server_callbacks"].status == :ok
    assert checks["skill.inherited.server_callbacks"].status == :ok
    assert Report.acceptable?(report, strict: true)
  end

  test "Doctor rejects missing callbacks, unloaded Servers and invalid Skill bindings" do
    for agent <- [__MODULE__.BrokenAgent, __MODULE__.MissingAgent] do
      assert {:ok, report} = Doctor.run(agent: agent)
      refute Report.acceptable?(report)
      check = Enum.find(report.checks, &(&1.id == "server.callbacks"))
      assert check.code == :server_callbacks_missing
      assert "handle_flow/3" in check.details.missing_callbacks
    end

    assert {:ok, report} = Doctor.run(agent: __MODULE__.BrokenMountAgent)
    check = Enum.find(report.checks, &(&1.id == "skill.broken.server_callbacks"))
    assert check.status == :error
    refute Report.acceptable?(report, strict: true)

    assert_raise Mix.Error, ~r/spectre_doctor_failed/, fn ->
      capture_io(fn ->
        Mix.Tasks.Spectre.Doctor.run(["--agent", inspect(__MODULE__.BrokenAgent)])
      end)
    end
  end

  test "route destinations identify mounted Servers and root inheritance" do
    json =
      capture_io(fn -> Mix.Tasks.Spectre.Routes.run([inspect(__MODULE__.Agent), "--json"]) end)

    routes = json |> Spectre.JSON.decode!() |> Map.new(&{&1["intent"], &1})
    assert routes["hello"]["server"] == inspect(__MODULE__.Server)
    assert routes["ping"]["server"] == inspect(__MODULE__.ChildServer)
    assert routes["ping"]["scope"] == "{:skill, :child}"
    assert routes["inherited"]["server"] == inspect(__MODULE__.Server)
  end
end
