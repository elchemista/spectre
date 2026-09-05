defmodule Spectre.Core.SubmissionContextTest do
  use ExUnit.Case, async: true
  alias Spectre.SubmissionContext

  setup do
    {:ok, context} =
      SubmissionContext.new(
        domain_ref: "domain",
        scope_ref: "scope",
        authenticated_principal_ref: "principal",
        authentication_ref: "authentication",
        ingress_ref: "ingress",
        host_generation: 7
      )

    %{context: context, secret: :binary.copy(<<42>>, 32)}
  end

  test "the runtime seal fences content and secret without changing canonical identity", %{
    context: context,
    secret: secret
  } do
    assert {:error, :submission_context_authentication_failed} =
             SubmissionContext.verify_seal(context, secret)

    assert {:ok, sealed} = SubmissionContext.seal(context, secret)
    assert :ok = SubmissionContext.verify_seal(sealed, secret)
    assert SubmissionContext.canonical(sealed) == SubmissionContext.canonical(context)
    assert SubmissionContext.digest(sealed) == SubmissionContext.digest(context)

    for {field, value} <- [
          host_generation: 8,
          scope_ref: "other",
          authenticated_principal_ref: "other"
        ] do
      assert {:error, :submission_context_authentication_failed} =
               SubmissionContext.verify_seal(Map.put(sealed, field, value), secret)
    end

    assert {:error, :submission_context_authentication_failed} =
             SubmissionContext.verify_seal(sealed, :binary.copy(<<43>>, 32))

    assert {:ok, restored} =
             sealed |> SubmissionContext.canonical() |> SubmissionContext.from_canonical()

    assert restored.seal == nil
  end

  test "Decision bindings have an explicit, frozen field contract", %{context: context} do
    assert SubmissionContext.decision_bindings(context) == %{
             submission_context_ref: context.ref,
             domain_ref: "domain",
             scope_ref: "scope",
             authenticated_principal_ref: "principal",
             authentication_ref: "authentication",
             ingress_ref: "ingress",
             channel_ref: nil,
             session_ref: nil,
             host_generation: 7
           }
  end

  test "application evidence cannot overwrite trusted context, with either key spelling", %{
    context: context
  } do
    for key <- [:scope_ref, "scope_ref"] do
      assert {:error, {:reserved_evidence_binding, :scope_ref}} =
               SubmissionContext.merge_evidence_bindings(context, %{key => "scope"})
    end

    assert {:ok, bindings} = SubmissionContext.merge_evidence_bindings(context, %{"order" => "1"})
    assert bindings["order"] == "1"
    assert {:ok, ^context} = SubmissionContext.from_evidence_bindings(bindings)
  end
end
