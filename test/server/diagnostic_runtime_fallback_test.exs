defmodule Spectre.Server.DiagnosticRuntimeFallbackTest do
  use ExUnit.Case, async: true
  alias Spectre.Server

  defmodule App do
    use Spectre.Server
  end

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.DiagnosticRuntimeFallbackTest.App
  end

  defmodule CustomAdapter do
    # A diagnostic read must not invent a protocol on a custom execution adapter.
  end

  @tag :tmp_dir
  test "custom adapter trace retains checkpoint facts with explicit unavailable GAM coverage", %{
    tmp_dir: path
  } do
    store = start_supervised!({Server.Store.Disk, path: Path.join(path, "checkpoint.bin")})

    server =
      start_supervised!(
        {Server.Runtime,
         agent: Agent,
         consumer: self(),
         gam: CustomAdapter,
         checkpoint: {store, :session},
         assigns: %{secret: "PRIVATE VALUE"}}
      )

    assert {:ok, trace} = Server.trace(server, "unknown")
    assert trace.gam == nil
    assert trace.coverage.source == :retained_checkpoint
    assert trace.coverage.complete == false
    assert trace.coverage.gam == %{available: false, reason: :managed_gam_not_configured}
    assert :gam_history in trace.coverage.missing
    assert is_integer(trace.revision)
    refute inspect(trace) =~ "PRIVATE VALUE"
    assert {:ok, _} = Server.inspect(server)

    for cursor <- [nil, "unexpected", {1, 0, "scope", nil, 0}] do
      assert {:error, :invalid_diagnostic_options} = Server.inspect(server, cursor: cursor)
    end
  end
end
