defmodule Spectre.Core.ExecutionRoutingBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Execution.Router
  alias Spectre.GovernedAct.Execution
  alias Spectre.V04Test.{Broker, Executor}

  setup c do
    boundary = %{
      routes: %{
        {c.act.executor_ref, c.act.executor_contract_ref} => %{
          executor: Executor,
          executor_opts: []
        }
      },
      broker: %{broker: Broker, broker_opts: [], descriptor: %{profile: :development}}
    }

    %{boundary: boundary}
  end

  test "executor identity and contract select an exact configured pair", c do
    assert {:ok, %{executor: Executor, broker: Broker}} =
             Router.fetch(c.boundary, c.act.executor_ref, c.act.executor_contract_ref)

    assert {:error, {:executor_route_not_configured, "other", "contract"}} =
             Router.fetch(c.boundary, "other", "contract")

    assert {:error, _} = Router.fetch(c.boundary, "", c.act.executor_contract_ref)

    assert {:error, :invalid_execution_boundary} =
             Router.fetch(%{}, c.act.executor_ref, c.act.executor_contract_ref)

    assert {:error, :broker_not_configured} =
             Router.fetch(
               %{c.boundary | broker: nil},
               c.act.executor_ref,
               c.act.executor_contract_ref
             )

    assert {:error, :invalid_execution_boundary} = Router.broker(%{})
  end

  test "development wiring cannot execute an Act pinned to an isolated host profile", c do
    state = c.pending
    profile_ref = c.act.host_profile_ref
    isolated = put_in(state.catalog.host_profiles[profile_ref].mode, :isolated)
    assert :ok = Router.profile_supports_act(state, c.act, %{profile: :development})
    assert :ok = Router.broker_supports_act(state, c.act, c.boundary.broker)

    assert {:error, {:broker_profile_too_weak, :development, ^profile_ref}} =
             Router.profile_supports_act(isolated, c.act, %{profile: :development})

    assert {:error, {:act_host_profile_not_found, ^profile_ref}} =
             Router.profile_supports_act(put_in(state.catalog.host_profiles, %{}), c.act, %{
               profile: :isolated
             })

    assert {:error, {:broker_profile_too_weak, :development, ^profile_ref}} =
             Router.validate_candidate(c.boundary, isolated, c.candidate)

    assert {:error, :host_profile_not_initialized} =
             Router.validate_candidate(
               c.boundary,
               put_in(state.catalog.host_profiles, %{}),
               c.candidate
             )
  end

  test "wiring does not turn invalid or split execution modes into authority", c do
    assert :ok = Router.validate_candidate(c.boundary, c.pending, c.candidate)
    invalid = %{c.candidate | executor_ref: Execution.kernel_executor_ref()}
    assert {:error, reason} = Execution.mode(invalid)
    assert {:error, ^reason} = Router.validate_candidate(c.boundary, c.pending, invalid)
  end
end
