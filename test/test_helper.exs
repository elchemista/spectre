ExUnit.start()

Code.require_file("v0_4/support/fixture.ex", __DIR__)
Code.require_file("support/authoring.ex", __DIR__)
Code.require_file("support/handler_agent_case.ex", __DIR__)
Code.require_file("support/semantic_cache_customer_support.ex", __DIR__)
Code.require_file("support/endurance_agent.ex", __DIR__)
Code.require_file("support/documentation.ex", __DIR__)
Code.require_file("support/documentation_runtime.ex", __DIR__)
Code.require_file("support/duty_frontier_assertions.ex", __DIR__)
Code.require_file("support/full_agent_case.ex", __DIR__)
Code.require_file("support/routed_agent_case.ex", __DIR__)

# Keep the shared fake clock alive for the test VM, like the application broker.
# An ETS table owned by a test process disappears before its on_exit callbacks;
# a racing reconciliation timer then sees a missing clock instead of test time.
# after_suite runs BETWEEN --repeat-until-failure iterations too, so it must
# not stop an owner shared by those runs. The VM releases it on shutdown.
{:ok, _clock_owner} =
  Agent.start(fn ->
    Spectre.V04Test.Runtime.reset(Spectre.V04Test.Fixture.default_now())
  end)
