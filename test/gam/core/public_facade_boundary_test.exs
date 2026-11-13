Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.PublicFacadeBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.GAM.Facade.Access

  test "authority and read APIs reject values that are not authenticated handles" do
    assert {:error, :authenticated_context_required} = Spectre.GAM.open_scope(nil, nil)

    assert {:error, :invalid_governed_scope_opening} =
             Spectre.GAM.open_scope(nil, nil, %{}, %{}, [])

    assert {:error, :invalid_turn} = Spectre.GAM.open_turn(nil, "hello")
    assert {:error, :invalid_turn_continuation} = Spectre.GAM.continue_turn(nil, nil, [])
    assert {:error, :invalid_scope} = Spectre.GAM.surface(nil)
    assert {:error, :invalid_dispatch_query} = Spectre.GAM.dispatch_status(nil, "act")
    assert {:error, :invalid_stateful_turn} = Spectre.GAM.turn(nil, "hello", %{}, [])
    assert {:error, :invalid_presentation} = Spectre.GAM.prepare_presentation(nil, %{})

    assert {:error, :invalid_principal_registration} =
             Spectre.GAM.register_principal(nil, %{}, %{})

    assert {:error, :invalid_mandate_delegation} = Spectre.GAM.delegate_mandate(nil, %{}, %{})
    assert {:error, :invalid_mandate_delegation} = Spectre.GAM.issue_mandate(nil, %{}, %{})

    assert {:error, :invalid_mandate_devolution} =
             Spectre.GAM.devolve_mandate(nil, "child", %{}, %{})

    assert {:error, :invalid_mandate_restriction} =
             Spectre.GAM.restrict_mandate(nil, "prior", %{}, %{})

    assert {:error, :invalid_mandate_revocation} = Spectre.GAM.revoke_mandate(nil, "mandate", %{})
    assert {:error, :invalid_duty_disposition} = Spectre.GAM.dispose_duty(nil, %{}, %{})
    assert {:error, :invalid_erasure_request} = Spectre.GAM.request_erasure(nil, %{}, %{})

    assert {:error, :authenticated_scope_required} = Spectre.GAM.acts(nil)
    assert {:error, :authenticated_scope_required} = Spectre.GAM.declassifications(nil)
    assert {:error, :authenticated_scope_required} = Spectre.GAM.erasures(nil)
  end

  test "the shared facade boundary never interprets malformed host replies as success" do
    assert {:error, :context_domain_mismatch} = Access.context_domain_binding(nil, nil)

    assert {:error, {:invalid_sequencer_response, :query_failed}} =
             Access.sequencer_result(fn -> :unexpected_reply end, :query_failed)

    assert {:error, :durable_error} =
             Access.sequencer_result(fn -> {:error, :durable_error} end, :query_failed)

    assert {:error, :query_failed} =
             Access.sequencer_result(fn -> raise "private domain failure" end, :query_failed)

    assert {:error, {:invalid_keyword_options, :query}} = Access.validate_keyword(%{}, :query)

    assert {:error, {:invalid_keyword_options, :query}} =
             Access.nested_keyword([query: %{timeout: 10}], :query)
  end
end
