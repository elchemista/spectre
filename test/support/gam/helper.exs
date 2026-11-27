# Synthetic ingress for the Spectre integration tests.
Code.require_file("fixture.ex", __DIR__)
Code.require_file("governed_boundary_case.ex", __DIR__)

unless Process.whereis(Spectre.Test.GAM.ClockOwner) do
  {:ok, _pid} =
    Agent.start(
      fn ->
        Spectre.Test.GAM.Runtime.reset(Spectre.Test.GAM.Fixture.default_now())
      end,
      name: Spectre.Test.GAM.ClockOwner
    )
end
