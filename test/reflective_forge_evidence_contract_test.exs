defmodule SpectreReflectiveForgeEvidenceContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Forge.Proposal
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Operation

  @reflection_digest String.duplicate("a", 64)
  @experience_digest String.duplicate("b", 64)
  @case_digest String.duplicate("c", 64)
  @other_digest String.duplicate("d", 64)

  test "critic prose stays inert while a typed eval case remains content-bound" do
    assert Critique.schema_version() == 1

    assert {:ok, critique} =
             Critique.new(
               critic_id: "critic.routing",
               critic_version: 2,
               profile_ref: "profile:review",
               reflection_digest: @reflection_digest,
               experience_snapshot_digest: @experience_digest,
               opinion: "The route needs an independently falsifiable case.",
               eval_case: %{
                 id: "refund-route",
                 input: "refund",
                 expected_route: "REFUND",
                 llm: "forbidden",
                 tags: ["governance"]
               },
               oracle_ref: "oracle:routing-v1",
               provenance: %{"source" => "compiled-critic"}
             )

    assert :ok = Critique.verify(critique)
    assert is_binary(Critique.case_digest(critique))
    assert byte_size(Critique.case_digest(critique)) == 64
    assert {:ok, ^critique} = Critique.new(Critique.to_data(critique))

    assert {:ok, opinion_only} =
             Critique.new(%{
               critic_id: "critic.opinion",
               critic_version: 1,
               profile_ref: "profile:review",
               reflection_digest: @reflection_digest,
               experience_snapshot_digest: @experience_digest,
               opinion: "No executable instruction is present.",
               eval_case: nil,
               oracle_ref: nil,
               provenance: %{}
             })

    assert Critique.case_digest(opinion_only) == nil

    base = Critique.to_data(critique) |> Map.put("digest", nil)

    invalid = [
      {Map.put(base, "schema_version", 9), {:unsupported_forge_critique_schema, 9}},
      {Map.put(base, "critic_id", "UPPER"), {:invalid_forge_critic_id, "UPPER"}},
      {Map.put(base, "critic_version", 0), {:invalid_forge_critique_field, :critic_version, 0}},
      {Map.put(base, "profile_ref", "Elixir.System"), :forge_code_reference_forbidden},
      {Map.put(base, "reflection_digest", "bad"),
       {:invalid_forge_critique_digest, :reflection_digest, "bad"}},
      {Map.put(base, "opinion", 42), {:invalid_forge_critique_opinion, :other}},
      {Map.put(base, "eval_case", []), {:invalid_forge_eval_case, :list}},
      {Map.put(base, "eval_case", nil), :forge_oracle_requires_eval_case},
      {Map.put(base, "oracle_ref", nil), :forge_eval_case_requires_oracle},
      {Map.put(base, "provenance", []), {:invalid_forge_critique_field, :provenance, :list}},
      {Map.put(base, "provenance", %{"auth_token" => "secret"}),
       {:sensitive_forge_provenance, ["auth_token"]}},
      {Map.put(base, "unknown", true), {:unknown_forge_critique_fields, ["unknown"]}}
    ]

    Enum.each(invalid, fn {data, reason} -> assert {:error, ^reason} = Critique.new(data) end)

    assert {:error, {:ambiguous_forge_critique_fields, [:critic_id]}} =
             base |> Map.put(:critic_id, "critic.other") |> Critique.new()

    assert {:error, :forge_critique_digest_mismatch} =
             critique |> Critique.to_data() |> Map.put("digest", @other_digest) |> Critique.new()

    assert {:error, {:invalid_forge_critique, :list}} = Critique.new([:invalid])
    assert {:error, {:invalid_forge_critique, :tuple}} = Critique.new({})
  end

  test "oracle approvals are independent evidence and never executable authority" do
    assert OracleApproval.schema_version() == 1

    approval =
      OracleApproval.new!(
        case_digest: @case_digest,
        oracle_ref: "oracle:routing-v1",
        approver_ref: "operator:reviewer",
        approved_at: 10,
        provenance: %{"review" => "independent"}
      )

    assert :ok = OracleApproval.verify(approval)
    assert OracleApproval.approves?(approval, @case_digest, "oracle:routing-v1")
    refute OracleApproval.approves?(approval, @other_digest, "oracle:routing-v1")
    assert String.starts_with?(OracleApproval.ref(approval), "oracle-approval:sha256:")

    base = OracleApproval.to_data(approval) |> Map.put("digest", nil)

    invalid = [
      {Map.put(base, "schema_version", 2), {:unsupported_forge_oracle_approval_schema, 2}},
      {Map.put(base, "case_digest", "bad"), {:invalid_forge_oracle_digest, :case_digest, "bad"}},
      {Map.put(base, "oracle_ref", "Elixir.File"), :forge_code_reference_forbidden},
      {Map.put(base, "approver_ref", ""),
       {:invalid_forge_oracle_approval_field, :approver_ref, ""}},
      {Map.put(base, "approved_at", -1),
       {:invalid_forge_oracle_approval_field, :approved_at, -1}},
      {Map.put(base, "provenance", []), {:invalid_forge_oracle_provenance, :list}},
      {Map.put(base, "provenance", %{"signing_key" => "secret"}),
       {:sensitive_forge_provenance, ["signing_key"]}},
      {Map.put(base, "unknown", true), {:unknown_forge_oracle_approval_fields, ["unknown"]}}
    ]

    Enum.each(invalid, fn {data, reason} ->
      assert {:error, ^reason} = OracleApproval.new(data)
    end)

    assert {:error, {:ambiguous_forge_oracle_approval_fields, [:oracle_ref]}} =
             base |> Map.put(:oracle_ref, "oracle:other") |> OracleApproval.new()

    assert {:error, :forge_oracle_approval_digest_mismatch} =
             approval
             |> OracleApproval.to_data()
             |> Map.put("digest", @other_digest)
             |> OracleApproval.new()

    assert_raise ArgumentError, ~r/invalid Forge oracle approval/, fn ->
      OracleApproval.new!(case_digest: "bad")
    end
  end

  test "Proposal permits only typed Forge operations bound to exact evidence lineage" do
    assert Proposal.schema_version() == 1
    change_set = forge_change_set("mount_skill")

    assert {:ok, proposal} =
             Proposal.new(%{
               change_set: change_set,
               reflection_digest: @reflection_digest,
               experience_snapshot_digest: @experience_digest,
               critiques: [],
               oracle_approvals: [],
               trusted_oracle_refs: [],
               parent_proposal_digest: nil
             })

    assert :ok = Proposal.verify(proposal)
    assert String.starts_with?(Proposal.ref(proposal), "forge-proposal:sha256:")
    assert {:ok, encoded} = Proposal.encode(proposal)
    assert {:ok, ^proposal} = Proposal.decode(encoded)

    base = Proposal.to_data(proposal) |> Map.put("digest", nil)

    invalid = [
      {Map.put(base, "schema_version", 2), {:unsupported_forge_proposal_schema, 2}},
      {Map.put(base, "reflection_digest", "bad"),
       {:invalid_forge_proposal_digest, :reflection_digest, "bad"}},
      {Map.put(base, "critiques", "bad"), {:invalid_forge_critiques, :binary}},
      {Map.put(base, "oracle_approvals", "bad"), {:invalid_forge_oracle_approvals, :binary}},
      {Map.put(base, "trusted_oracle_refs", ["Elixir.System"]),
       :invalid_forge_trusted_oracle_refs},
      {Map.put(base, "parent_proposal_digest", "bad"),
       {:invalid_forge_proposal_digest, :parent_proposal_digest, "bad"}},
      {Map.put(base, "unknown", true), {:unknown_forge_proposal_fields, ["unknown"]}}
    ]

    Enum.each(invalid, fn {data, reason} -> assert {:error, ^reason} = Proposal.new(data) end)

    assert {:error, {:forge_critique_limit_exceeded, 17, 16}} =
             base |> Map.put("critiques", List.duplicate(%{}, 17)) |> Proposal.new()

    assert {:error, {:forge_oracle_approval_limit_exceeded, 17, 16}} =
             base |> Map.put("oracle_approvals", List.duplicate(%{}, 17)) |> Proposal.new()

    assert {:error, {:ambiguous_forge_proposal_fields, [:change_set]}} =
             base |> Map.put(:change_set, change_set) |> Proposal.new()

    assert {:error, :forge_proposal_digest_mismatch} =
             proposal |> Proposal.to_data() |> Map.put("digest", @other_digest) |> Proposal.new()

    assert {:error, {:forge_operation_not_allowed, "update_authority"}} =
             base
             |> Map.put("change_set", ChangeSet.to_data(forge_change_set("update_authority")))
             |> Proposal.new()

    bad_provenance =
      change_set
      |> ChangeSet.to_data()
      |> put_in(["provenance", "forge", "reflection_digest"], @other_digest)

    assert {:error, :forge_proposal_provenance_mismatch} =
             base |> Map.put("change_set", bad_provenance) |> Proposal.new()

    assert {:error, {:invalid_forge_proposal_binary, :list}} = Proposal.decode([])
    assert {:error, {:invalid_forge_proposal, :list}} = Proposal.new([:invalid])
  end

  test "ChangeSet and Operation reject aliases, executable values and stale activation absence" do
    assert {:ok, operation} = Operation.new(type: :mount_skill, payload: %{mount_id: "refunds"})
    assert operation.type == "mount_skill"

    assert Operation.to_data(operation) == %{
             "type" => "mount_skill",
             "payload" => %{"mount_id" => "refunds"}
           }

    invalid_operations = [
      {%{type: "", payload: %{}}, {:invalid_governance_operation_type, ""}},
      {%{type: "Mount-Skill", payload: %{}}, {:invalid_governance_operation_type, "Mount-Skill"}},
      {%{type: "mount_skill", payload: []}, {:invalid_governance_operation_payload, :list}},
      {%{type: "mount_skill", payload: %{callback: fn -> :ok end}},
       {:invalid_governance_operation_payload,
        {:nonportable_governance_data, ["callback"], :function}}},
      {%{type: "mount_skill", payload: %{}, unknown: true},
       {:unknown_governance_operation_fields, [:unknown]}},
      {%{"type" => "mount_skill", type: "mount_skill", payload: %{}},
       {:ambiguous_governance_operation_fields, [:type]}}
    ]

    Enum.each(invalid_operations, fn {attrs, reason} ->
      assert {:error, ^reason} = Operation.new(attrs)
    end)

    assert {:error, {:invalid_governance_operation, :list}} = Operation.new([:invalid])
    assert {:error, {:invalid_governance_operation, :function}} = Operation.new(fn -> :ok end)

    change_set = forge_change_set("mount_skill")
    assert ChangeSet.schema_version() == 1
    assert {:ok, ^change_set} = ChangeSet.new(ChangeSet.to_data(change_set))
    assert {:ok, ^change_set} = change_set |> ChangeSet.encode() |> elem(1) |> ChangeSet.decode()

    assert {:error, :governance_change_set_requires_activation} =
             ChangeSet.verify_base(change_set, nil)

    assert {:error, {:invalid_governance_activation, :other}} =
             ChangeSet.verify_base(change_set, :invalid)

    data = ChangeSet.to_data(change_set)

    assert {:error, {:unknown_governance_change_set_fields, ["unknown"]}} =
             data |> Map.put("unknown", true) |> ChangeSet.new()

    assert {:error, {:ambiguous_governance_change_set_fields, [:reason]}} =
             data |> Map.put(:reason, "duplicate") |> ChangeSet.new()

    assert {:error, {:invalid_governance_operations, :list}} =
             data |> Map.put("operations", []) |> ChangeSet.new()

    assert {:error, {:invalid_governance_operation, 0, {:invalid_governance_operation_type, ""}}} =
             data |> put_in(["operations", Access.at(0), "type"], "") |> ChangeSet.new()

    assert {:error, {:invalid_governance_change_set_binary, :map}} = ChangeSet.decode(%{})
  end

  defp forge_change_set(type) do
    {:ok, candidate_ref} = CandidateRef.parse("candidate:sha256:" <> @reflection_digest)
    {:ok, definition_ref} = DefinitionRef.parse("sha256:" <> @experience_digest)

    forge = %{
      "reflection_digest" => @reflection_digest,
      "experience_snapshot_digest" => @experience_digest,
      "critique_digests" => [],
      "oracle_approval_refs" => [],
      "trusted_oracle_refs" => [],
      "parent_proposal_digest" => nil
    }

    ChangeSet.new!(%{
      base_activation_receipt: "activation:receipt",
      base_candidate_ref: candidate_ref,
      observed_definition_ref: definition_ref,
      observed_authority_epoch: 1,
      observed_evidence_digest: @case_digest,
      operations: [%{type: type, payload: %{"mount_id" => "refunds"}}],
      author_ref: "forge:test",
      provenance: %{"forge" => forge},
      reason: "exercise governed learning",
      created_at: 10
    })
  end
end
