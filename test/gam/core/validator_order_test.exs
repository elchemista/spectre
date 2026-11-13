Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.ValidatorOrderTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Act, Decision}

  test "Act keeps the original first invalid field across sequential validation groups", c do
    fields = [
      candidate_identity_key: :invalid_non_empty_binary,
      material_digest: :invalid_non_empty_binary,
      requested_mandate_ref: :invalid_ref,
      submission_context_ref: :invalid_ref,
      authenticated_principal_ref: :invalid_ref,
      authentication_ref: :invalid_ref,
      ingress_ref: :invalid_ref,
      proposer_ref: :invalid_ref,
      executor_ref: :invalid_ref,
      authorizer_ref: :invalid_ref,
      accountable_ref: :invalid_ref,
      scope_ref: :invalid_ref,
      purpose_ref: :invalid_ref,
      mandate_ref: :invalid_ref,
      presentation_ref: :invalid_ref,
      host_profile_ref: :invalid_ref,
      executor_contract_ref: :invalid_ref
    ]

    assert_first_errors(Act, c.act, fields)
  end

  test "Decision keeps the original first invalid field across sequential validation groups", c do
    fields = [
      candidate_identity_key: :invalid_non_empty_binary,
      candidate_digest: :invalid_non_empty_binary,
      candidate_class: :invalid_non_empty_binary,
      submission_context_ref: :invalid_ref,
      domain_ref: :invalid_ref,
      channel_ref: :invalid_ref,
      session_ref: :invalid_ref,
      authenticated_principal_ref: :invalid_ref,
      authentication_ref: :invalid_ref,
      ingress_ref: :invalid_ref,
      mandate_ref: :invalid_ref,
      proposer_ref: :invalid_ref,
      executor_ref: :invalid_ref,
      authorizer_ref: :invalid_ref,
      accountable_ref: :invalid_ref,
      scope_ref: :invalid_ref,
      host_profile_ref: :invalid_ref
    ]

    assert_first_errors(Decision, c.decision, fields)
  end

  defp assert_first_errors(module, record, fields) do
    assert {:ok, ^record} = module.new(record)
    attrs = record |> Map.from_struct() |> Map.delete(:ref)

    # Multiple invalid portable fields survive normalization/content hashing.
    # Crossing each group boundary must retain the earliest original error,
    # rather than returning the error from an eagerly evaluated later group.
    for {{first, kind}, index} <- Enum.with_index(fields),
        {second, _} <- Enum.drop(fields, index + 1) do
      invalid = attrs |> Map.put(first, "") |> Map.put(second, "")
      assert {:error, {^kind, ^first, :binary}} = module.new(invalid)
    end

    [{first, kind} | _] = fields
    invalid = Enum.reduce(fields, attrs, fn {field, _}, attrs -> Map.put(attrs, field, "") end)
    assert {:error, {^kind, ^first, :binary}} = module.new(invalid)
  end
end
