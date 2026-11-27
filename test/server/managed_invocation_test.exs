defmodule Spectre.Server.ManagedInvocationTest do
  use ExUnit.Case, async: true

  alias ExGAM.{SubmissionContext, Scope}
  alias Spectre.Server.GAM.Invocation
  alias Spectre.Server.GAM.Managed.Ingress

  setup do
    {:ok, context} =
      SubmissionContext.new(%{
        domain_ref: "domain:invocation",
        scope_ref: "scope:invocation",
        authenticated_principal_ref: "principal:account-owner",
        authentication_ref: "authentication:application",
        ingress_ref: Ingress.ref(),
        host_generation: 1
      })

    invocation = %{
      command_id: "command:send",
      interaction: nil,
      operation: :send_email,
      domain_ref: context.domain_ref,
      scope_ref: context.scope_ref,
      principal_ref: context.authenticated_principal_ref
    }

    %{context: context, invocation: invocation}
  end

  test "root computation is attributed separately from authenticated principal", data do
    invocation = Map.merge(data.invocation, %{source: :agent, agent: __MODULE__})
    envelope = %{kind: :spectre_agent_invocation, invocation: invocation}

    assert {:ok, evidence} = Ingress.observe(data.context, envelope, 1_000, [])
    assert evidence.proposition == {:spectre_agent_invocation, "command:send"}
    assert evidence.issuer_ref == Ingress.ref()
    assert evidence.source_ref == Ingress.ref()
    assert evidence.payload.agent == __MODULE__
    assert evidence.payload.principal_ref == "principal:account-owner"
    assert evidence.bindings["authenticated_principal_ref"] == "principal:account-owner"
    assert is_binary(evidence.bindings["spectre_agent_invocation_digest"])
  end

  test "external actor provenance never becomes a user request or approval", data do
    invocation =
      Map.merge(data.invocation, %{
        source: :external_actor,
        agent: __MODULE__,
        submitter_ref: "actor:opaque-reference"
      })

    envelope = %{kind: :spectre_external_invocation, invocation: invocation}
    assert {:ok, evidence} = Ingress.observe(data.context, envelope, 1_000, [])
    assert evidence.proposition == {:spectre_external_invocation, "command:send"}
    assert evidence.payload.submitter_ref == "actor:opaque-reference"
    assert evidence.issuer_ref == Ingress.ref()
    assert evidence.provisional == false
    refute Map.has_key?(evidence.bindings, "presentation_ref")
    refute Map.has_key?(evidence.payload, :consent_proof)
  end

  test "legacy Skill attribution retains its durable vocabulary", data do
    invocation = Map.merge(data.invocation, %{skill: :research, module: __MODULE__})
    assert {:ok, evidence} = Invocation.evidence(data.context, invocation, 1_000)
    assert evidence.proposition == {:spectre_skill_invocation, "command:send"}
    assert is_binary(evidence.bindings["spectre_skill_invocation_digest"])
  end

  test "attribution cannot change the authenticated domain, scope or principal", data do
    invocation = Map.merge(data.invocation, %{source: :agent, agent: __MODULE__})

    for field <- [:domain_ref, :scope_ref, :principal_ref] do
      assert {:error, :invalid_skill_invocation} =
               Invocation.evidence(data.context, Map.put(invocation, field, "forged"), 1_000)
    end
  end

  test "external attribution requires a nonempty portable actor reference", data do
    for actor <- [nil, "", self(), 42] do
      invocation =
        Map.merge(data.invocation, %{
          source: :external_actor,
          agent: __MODULE__,
          submitter_ref: actor
        })

      assert {:error, :invalid_skill_invocation} =
               Invocation.evidence(data.context, invocation, 1_000)
    end
  end

  test "existing manual root bridges do not acquire a new ingress requirement", data do
    scope = %Scope{
      domain: ExGAM.Domain.handle(self(), data.context.domain_ref),
      context: data.context
    }

    assert {:ok, []} = Invocation.record(scope, %{agent: __MODULE__}, :send_email, [])
  end
end
