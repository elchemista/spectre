# Imported kernel fixtures; synthetic ingress is test-only.
Code.require_file("v0_4/support/fixture.ex", __DIR__)
Code.require_file("support/duty_frontier_assertions.ex", __DIR__)
Code.require_file("support/governed_boundary_case.ex", __DIR__)

unless Process.whereis(Spectre.GAM.Test.ClockOwner) do
  {:ok, _pid} =
    Agent.start(
      fn ->
        Spectre.GAM.V04Test.Runtime.reset(Spectre.GAM.V04Test.Fixture.default_now())
      end,
      name: Spectre.GAM.Test.ClockOwner
    )
end
