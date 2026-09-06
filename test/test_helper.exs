ExUnit.start()

Code.require_file("v0_4/support/fixture.ex", __DIR__)
Code.require_file("support/duty_frontier_assertions.ex", __DIR__)

# Keep the shared fake clock alive until Domain on_exit cleanup has finished.
# An ETS table owned by a test process disappears before its on_exit callbacks;
# a racing reconciliation timer then sees a missing clock instead of test time.
{:ok, clock_owner} =
  Agent.start(fn ->
    Spectre.V04Test.Runtime.reset(Spectre.V04Test.Fixture.default_now())
  end)

ExUnit.after_suite(fn _results -> Agent.stop(clock_owner) end)
