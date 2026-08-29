defmodule SpectreReflectiveRuntimeTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :reflective_runtime_agent
end

defmodule SpectreReflectiveRuntimeTest.ContractCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.contract-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:contract"

  @impl true
  def critique(reflection, snapshot, _opts) do
    {:ok,
     %{
       "opinion" => "The support route needs a falsifiable empty-input case.",
       "eval_case" => %{
         "id" => "forge-empty-input",
         "input" => "",
         "expected_outcome" => "unknown",
         "llm" => "forbidden",
         "tags" => ["forge"]
       },
       "oracle_ref" => "oracle:contract:routing-v1",
       "provenance" => %{
         "projection_digest" => reflection["digest"],
         "snapshot_digest" => snapshot["digest"]
       }
     }}
  end
end

defmodule SpectreReflectiveRuntimeTest.UnapprovedCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.unapproved-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:unapproved"

  @impl true
  def critique(_reflection, _snapshot, _opts) do
    {:ok,
     %{
       "opinion" => "This remains opinion until an independent oracle is approved.",
       "eval_case" => %{
         "id" => "forge-unapproved",
         "input" => "delete everything",
         "expected_outcome" => "unknown"
       },
       "oracle_ref" => "oracle:proposed:unapproved",
       "provenance" => %{"source" => "model_critique"}
     }}
  end
end

defmodule SpectreReflectiveRuntimeTest.TextCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.text-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:text"

  @impl true
  def critique(_reflection, _snapshot, _opts), do: {:ok, "change the kernel"}
end

defmodule SpectreReflectiveRuntimeTest.AgreementCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  @impl true
  def id, do: "test.agreement-critic"

  @impl true
  def version, do: 1

  @impl true
  def profile_ref, do: "prism:test:agreement"

  @impl true
  def critique(reflection, snapshot, opts) do
    SpectreReflectiveRuntimeTest.UnapprovedCritic.critique(reflection, snapshot, opts)
  end
end

defmodule SpectreReflectiveRuntimeTest.BadExperienceStore do
  @moduledoc false
  @behaviour Spectre.Experience.Store

  @impl true
  def identity(opts), do: reply(opts, :identity, :bad_experience_store)

  @impl true
  def durability(opts), do: reply(opts, :durability, :volatile)

  @impl true
  def get(_key, opts), do: reply(opts, :get, :not_found)

  @impl true
  def put(_key, _encoded, opts), do: reply(opts, :put, :ok)

  @impl true
  def list(opts), do: reply(opts, :list, {:ok, []})

  @impl true
  def delete(_key, opts), do: reply(opts, :delete, :not_found)

  defp reply(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :raise -> raise "adapter failure"
      {:throw, reason} -> throw(reason)
      value -> value
    end
  end
end

defmodule SpectreReflectiveRuntimeTest.RaisingCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: "test.raising"
  def version, do: 1
  def profile_ref, do: "prism:test:raising"
  def critique(_reflection, _snapshot, _opts), do: raise("critic failure")
end

defmodule SpectreReflectiveRuntimeTest.ThrowingCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: "test.throwing"
  def version, do: 1
  def profile_ref, do: "prism:test:throwing"
  def critique(_reflection, _snapshot, _opts), do: throw(:critic_failure)
end

defmodule SpectreReflectiveRuntimeTest.InvalidMetadataCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: ""
  def version, do: 0
  def profile_ref, do: ""
  def critique(_reflection, _snapshot, _opts), do: {:ok, %{"opinion" => "unused"}}
end

defmodule SpectreReflectiveRuntimeTest.ErrorCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: "test.error"
  def version, do: 1
  def profile_ref, do: "prism:test:error"
  def critique(_reflection, _snapshot, _opts), do: {:error, :offline}
end

defmodule SpectreReflectiveRuntimeTest.UnknownFieldCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: "test.unknown-field"
  def version, do: 1
  def profile_ref, do: "prism:test:unknown-field"

  def critique(_reflection, _snapshot, _opts),
    do: {:ok, %{"opinion" => "bounded", "unexpected" => true}}
end

defmodule SpectreReflectiveRuntimeTest.AmbiguousResponseCritic do
  @moduledoc false
  @behaviour Spectre.Forge.Critic

  def id, do: "test.ambiguous-response"
  def version, do: 1
  def profile_ref, do: "prism:test:ambiguous-response"

  def critique(_reflection, _snapshot, _opts),
    do: {:ok, %{"opinion" => "two", opinion: "one"}}
end

defmodule SpectreReflectiveRuntimeTest do
  use ExUnit.Case, async: true

  alias Spectre.Authority.Envelope
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Resolver
  alias Spectre.Definition.Store
  alias Spectre.Definition.Store.Memory, as: DefinitionMemory
  alias Spectre.Execution.Closure
  alias Spectre.Experience
  alias Spectre.Experience.Evidence
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Experience.Store.Memory, as: ExperienceMemory
  alias Spectre.Forge
  alias Spectre.Forge.Critic
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Forge.Proposal
  alias Spectre.Foundation.Conformance
  alias Spectre.Governance.ChangeSet
  alias Spectre.Instance.Activation
  alias Spectre.Projection.Reflection, as: ReflectionProjection
  alias Spectre.Reflection.Policy

  alias SpectreReflectiveRuntimeTest.Agent
  alias SpectreReflectiveRuntimeTest.AgreementCritic
  alias SpectreReflectiveRuntimeTest.AmbiguousResponseCritic
  alias SpectreReflectiveRuntimeTest.BadExperienceStore
  alias SpectreReflectiveRuntimeTest.ContractCritic
  alias SpectreReflectiveRuntimeTest.ErrorCritic
  alias SpectreReflectiveRuntimeTest.InvalidMetadataCritic
  alias SpectreReflectiveRuntimeTest.RaisingCritic
  alias SpectreReflectiveRuntimeTest.TextCritic
  alias SpectreReflectiveRuntimeTest.ThrowingCritic
  alias SpectreReflectiveRuntimeTest.UnapprovedCritic
  alias SpectreReflectiveRuntimeTest.UnknownFieldCritic

  @digest String.duplicate("a", 64)

  test "Experience is opt-in, redacted, transport-stable and retention-bounded" do
    %{activation: activation, experience_store: store} = fixture()
    attrs = evidence_attrs(activation, 10, 100)

    assert {:error, :experience_recording_not_enabled} = Experience.record(store, attrs)
    assert {:ok, ref} = Experience.record(store, attrs, enabled?: true)
    assert {:ok, evidence} = Experience.fetch(store, ref)

    assert evidence.facts["token"] == "[REDACTED]"
    assert ["facts", "token"] in evidence.redactions
    refute inspect(evidence) =~ "raw-secret"

    json = evidence |> Evidence.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^evidence} = Evidence.from_data(json)
    assert :ok = Evidence.verify(evidence)

    assert {:error, :experience_purge_confirmation_required} =
             Experience.purge_expired(store, 100)

    assert {:ok, [deleted]} = Experience.purge_expired(store, 100, confirm?: true)
    assert deleted == to_string(ref)
    assert :not_found = Experience.fetch(store, ref)
  end

  test "Experience rejects ambiguous keys, unredacted bypasses and unsafe retention" do
    %{activation: activation, experience_store: store} = fixture()
    attrs = evidence_attrs(activation, 10, 100)

    assert {:error, {:ambiguous_experience_key, ["token"]}} =
             Experience.record(
               store,
               put_in(attrs, [:facts], %{:token => "one", "token" => "two"}),
               enabled?: true
             )

    assert {:error, {:unredacted_experience_field, ["token"]}} =
             attrs
             |> Map.put(:facts, %{"token" => "raw-secret"})
             |> Map.put(:redactions, [])
             |> Evidence.new()

    assert {:error, {:experience_evidence_expiry_required, :bounded}} =
             attrs |> Map.put(:expires_at, nil) |> Evidence.new()

    assert {:error, {:ambiguous_experience_record_fields, [:facts]}} =
             Experience.record(store, Map.put(attrs, "facts", %{}), enabled?: true)

    assert {:error, {:invalid_experience_record, :list}} =
             Experience.record(store, Map.to_list(attrs) ++ [facts: %{}], enabled?: true)

    assert {:error, :invalid_experience_record_options} =
             Experience.record(store, attrs, [1])

    assert {:error, :invalid_experience_record_options} =
             Experience.record(store, attrs, enabled?: true, enabled?: false)
  end

  test "transport constructors and snapshots reject ambiguous or mutated input" do
    fixture = forge_fixture()

    assert {:ok, [evidence]} =
             Experience.list(fixture.experience_store, fixture.canonical_ref, as_of: 50)

    duplicate_snapshot = %{
      fixture.snapshot
      | evidence: [evidence, evidence],
        evidence_refs: [to_string(Evidence.ref(evidence)), to_string(Evidence.ref(evidence))]
    }

    assert {:error, :duplicate_experience_snapshot_evidence} =
             ExperienceStore.verify_snapshot(duplicate_snapshot)

    assert {:error, {:invalid_reflection_policy, :list}} =
             Policy.new(actor_refs: ["one"], actor_refs: ["two"])

    assert {:error, {:invalid_forge_critique, :list}} =
             Critique.new(opinion: "one", opinion: "two")

    assert {:error, {:invalid_forge_oracle_approval, :list}} =
             OracleApproval.new(oracle_ref: "one", oracle_ref: "two")

    assert {:error, {:invalid_forge_proposal, :list}} =
             Proposal.new(change_set: nil, change_set: nil)

    assert {:ok, proposal} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [%{"type" => "disable_skill", "payload" => %{"mount_id" => "lookup"}}],
               author_ref: "forge:test",
               reason: "exercise load boundary",
               created_at: 60
             )

    tampered = %{proposal | change_set: nil}
    assert {:error, {:invalid_forge_proposal_struct, _kind}} = Proposal.verify(tampered)

    assert {:error, {:invalid_forge_proposal_struct, _kind}} =
             Forge.rebase(tampered, fixture.activation, fixture.reflection, fixture.snapshot,
               created_at: 70
             )
  end

  test "public reflective boundaries reject malformed scalar and adapter input" do
    assert {:error, {:invalid_experience_evidence_ref, 123}} =
             Spectre.Experience.Evidence.Ref.parse(123)

    refute Spectre.Experience.Evidence.Ref.valid?(123)

    assert {:error, {:invalid_reflection_policy, :other}} = Policy.new(:bad)

    assert {:error, {:invalid_reflection_policy_field, :actor_refs}} =
             Policy.new(%{actor_refs: :all})

    assert {:error, :invalid_reflection_operation_input} =
             Spectre.Reflection.Operation.execute([], %{})

    assert {:error, :reflection_operation_not_configured} =
             Spectre.Reflection.Operation.execute(%{}, :bad)

    assert {:error, :invalid_reflection_projection} =
             ReflectionProjection.verify(:bad, :bad, :bad, :bad, :bad)

    assert {:error, {:invalid_forge_critique, :other}} = Critique.new(:bad)

    assert {:error, {:invalid_forge_oracle_approval, :other}} =
             OracleApproval.new(:bad)

    assert {:error, {:invalid_forge_proposal, :other}} = Proposal.new(:bad)
  end

  test "the redactor handles nested portable data and rejects unsafe shapes and depth" do
    assert {:ok, redacted, paths} =
             Spectre.Experience.Redactor.redact(
               %{
                 list: [%{password: "secret"}, :ok, 1],
                 nested: %{"private" => "hidden"}
               },
               keys: [:private, "tenant_secret"]
             )

    assert redacted["list"] == [%{"password" => "[REDACTED]"}, "ok", 1]
    assert redacted["nested"]["private"] == "[REDACTED]"
    assert ["list", 0, "password"] in paths
    assert Spectre.Experience.Redactor.sensitive_key?(:password)
    refute Spectre.Experience.Redactor.sensitive_key?(123)

    assert {:error, {:invalid_experience_redaction_input, :list, :list}} =
             Spectre.Experience.Redactor.redact([])

    assert {:error, {:invalid_experience_redaction_keys, :token}} =
             Spectre.Experience.Redactor.redact(%{}, keys: :token)

    assert {:error, {:invalid_experience_redaction_key, 1}} =
             Spectre.Experience.Redactor.redact(%{}, keys: [1])

    assert {:error, {:invalid_experience_key, [], 1}} =
             Spectre.Experience.Redactor.redact(%{1 => "value"})

    assert {:error, {:nonportable_experience_value, ["unsafe"], :function}} =
             Spectre.Experience.Redactor.redact(%{"unsafe" => fn -> :ok end})

    too_deep = Enum.reduce(1..66, "value", fn index, value -> %{index => value} end)

    assert {:error, {:invalid_experience_key, _path, 66}} =
             Spectre.Experience.Redactor.redact(too_deep)

    too_deep = Enum.reduce(1..66, "value", fn index, value -> %{"k#{index}" => value} end)

    assert {:error, {:experience_redaction_depth_exceeded, _path, 64}} =
             Spectre.Experience.Redactor.redact(too_deep)
  end

  test "one constitutional denylist redacts secrets, PII and chain-of-thought across boundaries" do
    sensitive = %{
      "apiKey" => "sk-live-secret",
      "api_secret" => "api-secret",
      "access_token" => "access-secret",
      "auth_token" => "auth-secret",
      "client-secret" => "client-secret",
      "dbPassword" => "database-password",
      "JWT" => "header.payload.signature",
      "bearer" => "Bearer secret",
      "email_address" => "person@example.test",
      "session_key" => "session-secret",
      "secret_key" => "secret-key",
      "signingKey" => "signing-secret",
      "x-api-key" => "api-key-secret",
      "nested" => %{"chainOfThought" => "private reasoning"}
    }

    assert {:ok, redacted, paths} = Spectre.Experience.Redactor.redact(sensitive)

    assert redacted == %{
             "JWT" => "[REDACTED]",
             "access_token" => "[REDACTED]",
             "api_secret" => "[REDACTED]",
             "apiKey" => "[REDACTED]",
             "auth_token" => "[REDACTED]",
             "bearer" => "[REDACTED]",
             "client-secret" => "[REDACTED]",
             "dbPassword" => "[REDACTED]",
             "email_address" => "[REDACTED]",
             "session_key" => "[REDACTED]",
             "secret_key" => "[REDACTED]",
             "signingKey" => "[REDACTED]",
             "x-api-key" => "[REDACTED]",
             "nested" => %{"chainOfThought" => "[REDACTED]"}
           }

    assert Enum.sort(paths) ==
             Enum.sort([
               ["JWT"],
               ["access_token"],
               ["api_secret"],
               ["apiKey"],
               ["auth_token"],
               ["bearer"],
               ["client-secret"],
               ["dbPassword"],
               ["email_address"],
               ["session_key"],
               ["secret_key"],
               ["signingKey"],
               ["x-api-key"],
               ["nested", "chainOfThought"]
             ])

    for safe_key <-
          ~w(atom_key cache_key idempotency_key monkey tokenizer keyboard secretary passwordless) do
      refute Spectre.Experience.Redactor.sensitive_key?(safe_key)
    end

    for key <- Map.keys(sensitive) -- ["nested"] do
      assert {:error, {:secret_component_payload, [^key]}} =
               Spectre.Definition.Component.new(
                 component_type: :audit,
                 schema_ref: "spectre.test/audit/1",
                 criticality: :descriptive,
                 payload: %{key => "secret"}
               )
    end

    assert {:error, {:secret_component_payload, ["nested", "chainOfThought"]}} =
             Spectre.Definition.Component.new(
               component_type: :audit,
               schema_ref: "spectre.test/audit/1",
               criticality: :descriptive,
               payload: %{"nested" => %{"chainOfThought" => "private reasoning"}}
             )
  end

  test "Experience evidence validates every transport and retention boundary" do
    %{activation: activation} = fixture()
    attrs = validated_evidence_attrs(activation, 10, 100)

    assert {:ok, evidence} = Evidence.new(Map.to_list(attrs))
    assert {:ok, ^evidence} = Evidence.new(evidence)
    assert {:ok, encoded} = Evidence.encode(evidence)
    assert {:ok, ^evidence} = Evidence.decode(encoded)
    assert {:error, {:invalid_experience_evidence_binary, :other}} = Evidence.decode(:bad)
    assert {:error, {:invalid_experience_evidence, :function}} = Evidence.new(fn -> :bad end)
    assert_raise ArgumentError, fn -> Evidence.new!(%{}) end

    retained =
      attrs
      |> Map.put(:retention, "retained")
      |> Map.put(:expires_at, nil)
      |> Evidence.new!()

    refute Evidence.expired?(retained, 1_000)
    assert Evidence.expired?(evidence, :invalid)

    assert {:error, {:unsupported_experience_evidence_schema, 2}} =
             attrs |> Map.put(:schema_version, 2) |> Evidence.new()

    assert {:error, {:unknown_experience_evidence_fields, _fields}} =
             attrs |> Map.put(:unknown, true) |> Evidence.new()

    assert {:error, {:ambiguous_experience_evidence_fields, [:kind]}} =
             attrs |> Map.put("kind", "other") |> Evidence.new()

    assert {:error, _reason} = attrs |> Map.put(:definition_ref, "bad") |> Evidence.new()

    assert {:error, {:invalid_experience_evidence_kind, "UPPER"}} =
             attrs |> Map.put(:kind, "UPPER") |> Evidence.new()

    assert {:error, {:invalid_experience_evidence_expiry, 10}} =
             attrs |> Map.put(:expires_at, 10) |> Evidence.new()

    assert {:ok, _ephemeral} =
             attrs |> Map.put(:retention, "ephemeral") |> Evidence.new()

    assert {:error, {:invalid_experience_evidence_retention, "forever"}} =
             attrs |> Map.put(:retention, "forever") |> Evidence.new()

    assert {:error, {:invalid_experience_evidence_field, :facts, _reason}} =
             attrs |> Map.put(:facts, %{"bad" => self()}) |> Evidence.new()

    assert {:error, {:unredacted_experience_field, ["items", 0, "password"]}} =
             attrs |> Map.put(:facts, %{"items" => [%{"password" => "raw"}]}) |> Evidence.new()

    assert {:error, {:invalid_experience_redactions, :bad}} =
             attrs |> Map.put(:redactions, :bad) |> Evidence.new()

    assert {:error, {:invalid_experience_redaction_path, []}} =
             attrs |> Map.put(:redactions, [[]]) |> Evidence.new()

    assert {:error, {:invalid_experience_evidence, _kind}} =
             Evidence.verify(%{evidence | definition_ref: nil})
  end

  test "Experience Store adapters fail closed and the memory adapter is immutable" do
    %{activation: activation, experience_store: store} = fixture()
    evidence = validated_evidence_attrs(activation, 10, 100) |> Evidence.new!()
    ref = Evidence.ref(evidence)

    assert {:ok, _identity} = ExperienceStore.identity(store)
    assert {:ok, :volatile} = ExperienceStore.durability(store)
    {ExperienceMemory, memory_opts} = store
    server = Keyword.fetch!(memory_opts, :server)
    assert ExperienceMemory.count(server) == 0

    assert {:ok, ^ref} = ExperienceStore.publish(store, evidence)
    assert {:ok, ^ref} = ExperienceStore.publish(store, evidence)
    assert ExperienceMemory.count(server) == 1

    assert {:error, {:immutable_conflict, "same"}} =
             ExperienceMemory.put("same", "second", server: server)
             |> then(fn
               {:ok, :created} -> ExperienceMemory.put("same", "different", server: server)
               other -> other
             end)

    assert :ok = ExperienceMemory.delete("same", server: server)
    assert :not_found = ExperienceMemory.delete("missing", server: server)
    assert {:ok, {BadExperienceStore, []}} = ExperienceStore.normalize(BadExperienceStore)
    assert {:error, {:invalid_experience_store, 123}} = ExperienceStore.normalize(123)
    assert {:error, {:invalid_experience_store_adapter, :bad}} = ExperienceStore.identity(:bad)

    assert {:error, :invalid_experience_store_durability} =
             ExperienceStore.durability({BadExperienceStore, durability: :unknown})

    assert {:error, {:experience_store_exception, BadExperienceStore, :identity, RuntimeError}} =
             ExperienceStore.identity({BadExperienceStore, identity: :raise})

    assert {:error, {:experience_store_failure, BadExperienceStore, :identity, :throw, :failure}} =
             ExperienceStore.identity({BadExperienceStore, identity: {:throw, :failure}})

    assert {:error, {:invalid_experience_store_get_reply, :invalid}} =
             ExperienceStore.fetch({BadExperienceStore, get: :invalid}, ref)

    assert {:error, {:invalid_experience_store_put_reply, :invalid}} =
             ExperienceStore.publish({BadExperienceStore, put: :invalid}, evidence)

    assert {:error, :experience_store_readback_missing} =
             ExperienceStore.publish(
               {BadExperienceStore, put: :ok, get: :not_found},
               evidence
             )

    assert {:error, :experience_store_readback_mismatch} =
             ExperienceStore.publish(
               {BadExperienceStore, put: :ok, get: {:ok, "different"}},
               evidence
             )

    assert {:error, {:invalid_experience_store_list_reply, :invalid}} =
             ExperienceStore.list_evidence(
               {BadExperienceStore, list: :invalid},
               activation.definition_ref
             )

    assert {:error, {:invalid_experience_snapshot_timestamp, :bad}} =
             ExperienceStore.list_evidence(store, activation.definition_ref, as_of: :bad)

    assert {:error, {:invalid_experience_snapshot_limit, 0}} =
             ExperienceStore.list_evidence(store, activation.definition_ref, limit: 0)

    assert {:error, :invalid_experience_store_options} =
             ExperienceStore.list_evidence(store, activation.definition_ref, [1])

    assert {:error, {:invalid_experience_store_options, :bad}} =
             ExperienceStore.list_evidence(store, activation.definition_ref, :bad)

    assert {:error, {:experience_store_entry_limit_exceeded, 10_000}} =
             ExperienceStore.list_evidence(
               {BadExperienceStore, list: {:ok, List.duplicate({"key", "value"}, 10_001)}},
               activation.definition_ref
             )

    assert {:error, {:invalid_experience_store_entry, 0, {:bad, :entry}}} =
             ExperienceStore.list_evidence(
               {BadExperienceStore, list: {:ok, [{:bad, :entry}]}},
               activation.definition_ref
             )

    assert {:ok, snapshot} = ExperienceStore.snapshot(store, activation.definition_ref)
    assert {:ok, snapshot_bytes} = ExperienceStore.encode_snapshot(snapshot)
    assert {:ok, ^snapshot} = ExperienceStore.decode_snapshot(snapshot_bytes)

    assert {:error, :experience_snapshot_integrity_mismatch} =
             ExperienceStore.verify_snapshot(%{snapshot | digest: String.duplicate("0", 64)})

    assert {:ok, snapshot_data} = ExperienceStore.snapshot_to_data(snapshot)

    assert {:error, :experience_snapshot_integrity_mismatch} =
             snapshot_data
             |> Map.put("digest", String.duplicate("0", 64))
             |> ExperienceStore.snapshot_from_data()

    future = validated_evidence_attrs(activation, 150, 200) |> Evidence.new!()
    assert {:ok, _future_ref} = ExperienceStore.publish(store, future)

    assert {:ok, listed} =
             ExperienceStore.list_evidence(store, activation.definition_ref,
               as_of: 100,
               include_expired?: true
             )

    assert Enum.all?(listed, &(&1.observed_at <= 100))

    assert {:ok, bounded_snapshot} =
             ExperienceStore.snapshot(store, activation.definition_ref,
               as_of: 100,
               include_expired?: true
             )

    assert bounded_snapshot.evidence == []
    assert :ok = ExperienceStore.verify_snapshot(bounded_snapshot)

    assert {:error, :invalid_experience_snapshot} = ExperienceStore.verify_snapshot(%{})
    assert {:error, :invalid_experience_snapshot_data} = ExperienceStore.snapshot_from_data(%{})
    assert {:error, :invalid_experience_snapshot_binary} = ExperienceStore.decode_snapshot(:bad)
    assert {:error, _reason} = ExperienceStore.decode_snapshot("not canonical")

    assert {:ok, entries} = ExperienceMemory.list(server: server)

    assert {:ok, []} =
             ExperienceStore.purge_expired(
               {BadExperienceStore, list: {:ok, entries}, delete: :not_found},
               100,
               confirm?: true
             )

    assert {:error, :delete_blocked} =
             ExperienceStore.purge_expired(
               {BadExperienceStore, list: {:ok, entries}, delete: {:error, :delete_blocked}},
               100,
               confirm?: true
             )

    assert {:error, {:invalid_experience_store_delete_reply, :invalid}} =
             ExperienceStore.purge_expired(
               {BadExperienceStore, list: {:ok, entries}, delete: :invalid},
               100,
               confirm?: true
             )

    assert {:error, {:invalid_experience_purge, :bad, :bad}} =
             ExperienceStore.purge_expired(store, :bad, :bad)

    assert {:error, :invalid_experience_store_options} =
             ExperienceStore.purge_expired(store, 100, [1])
  end

  test "Reflection separates Declared, Effective and Observed as quoted data" do
    fixture = fixture()
    assert {:ok, _ref} = record(fixture, 10, 100)

    assert {:ok, snapshot} =
             Experience.snapshot(fixture.experience_store, fixture.canonical_ref, as_of: 50)

    opts = reflection_opts(fixture, 50)

    assert {:ok, first} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               opts
             )

    assert {:ok, second} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               opts
             )

    assert first == second
    assert first.content["instruction_semantics"] == "quoted_data_only"
    assert first.content["declared"]["definition"]["id"] == "reflective_runtime_agent"

    assert first.content["effective"]["activation"]["activation_receipt"] ==
             fixture.activation.activation_receipt

    assert first.content["observed"]["status"] == "evidence_available"
    assert first.content["observed"]["snapshot_digest"] == snapshot.digest
    refute inspect(first.content) =~ "raw-secret"

    assert {:ok, snapshot_data} = ExperienceStore.snapshot_to_data(snapshot)
    snapshot_json = snapshot_data |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^snapshot} = ExperienceStore.snapshot_from_data(snapshot_json)

    transported = first |> ReflectionProjection.to_data() |> Jason.encode!() |> Jason.decode!()

    assert {:ok, ^first} =
             ReflectionProjection.from_data(
               transported,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               snapshot
             )

    assert :ok =
             ReflectionProjection.verify(
               first,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               snapshot
             )

    assert {:ok, %{format: :reflection, digest: digest}} =
             Conformance.verify_reflection(
               transported,
               fixture.canonical,
               fixture.manifest,
               Activation.to_data(fixture.activation),
               snapshot_json
             )

    assert digest == first.digest
  end

  test "Reflection requires host policy and exposes absence of evidence honestly" do
    fixture = fixture()

    assert {:error, :reflection_policy_required} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               actor_ref: "operator:test",
               purpose: "inspect",
               as_of: 50
             )

    assert {:error, :reflection_actor_not_authorized} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               Keyword.put(reflection_opts(fixture, 50), :actor_ref, "intruder")
             )

    opts = Keyword.delete(reflection_opts(fixture, 50), :experience_store)

    assert {:ok, reflection} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               opts
             )

    assert reflection.content["observed"]["status"] == "no_evidence"
    assert reflection.content["observed"]["evidence"] == []
  end

  test "Reflection policies and projections reject stale, mutated and nonportable inputs" do
    fixture = fixture()

    assert {:error, {:unknown_reflection_policy_fields, [:unknown]}} =
             Policy.new(%{unknown: true})

    assert {:error, {:invalid_reflection_policy_field, :actor_refs}} =
             Policy.new(%{actor_refs: [1], purposes: ["inspect"]})

    assert {:error, {:invalid_reflection_policy_limit, 0}} =
             Policy.new(%{actor_refs: [], purposes: [], max_evidence: 0})

    assert_raise ArgumentError, fn -> Policy.new!(max_evidence: 0) end
    deny_all = Policy.new!(%{})
    assert {:error, :reflection_actor_required} = Policy.authorize(deny_all, nil, "inspect")
    assert {:error, :reflection_purpose_required} = Policy.authorize(deny_all, "actor", nil)

    assert {:error, :reflection_actor_not_authorized} =
             Policy.authorize(deny_all, "actor", "inspect")

    actor_only = Policy.new!(actor_refs: ["actor"], purposes: ["inspect"])

    assert {:error, :reflection_purpose_not_authorized} =
             Policy.authorize(actor_only, "actor", "other")

    base_opts = reflection_opts(fixture, 50)

    assert {:error, :invalid_reflection_options} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               [1]
             )

    assert {:error, :reflection_as_of_required} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               Keyword.delete(base_opts, :as_of)
             )

    assert {:error, {:invalid_reflection_as_of, :bad}} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               fixture.activation,
               Keyword.put(base_opts, :as_of, :bad)
             )

    missing_ref = "sha256:" <> String.duplicate("f", 64)

    assert {:error, :reflection_definition_not_found} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               missing_ref,
               fixture.activation,
               base_opts
             )

    {:ok, other_ref} = Spectre.Definition.Ref.parse(missing_ref)

    assert {:error, :reflection_definition_not_active} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               %{fixture.activation | definition_ref: other_ref},
               base_opts
             )

    assert {:error, {:invalid_reflection_request, :other, :list}} =
             Spectre.Reflection.reflect(
               fixture.definition_store,
               fixture.canonical_ref,
               :bad,
               []
             )

    assert {:ok, snapshot} = ExperienceStore.empty_snapshot(fixture.canonical_ref, 50)
    assert {:ok, reflection} = reflection(fixture, snapshot, 50)

    assert {:error, :projection_digest_mismatch} =
             ReflectionProjection.verify(
               %{reflection | digest: String.duplicate("0", 64)},
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               snapshot
             )

    assert {:error, {:invalid_reflection_projection_input, :other, :map, :map}} =
             ReflectionProjection.generate(
               :bad,
               fixture.manifest,
               fixture.activation,
               snapshot
             )

    assert {:error, {:invalid_reflection_projection_options, :other}} =
             ReflectionProjection.project(fixture.canonical, :bad)

    assert {:error, :invalid_reflection_projection_options} =
             ReflectionProjection.project(fixture.canonical, [1])

    assert {:error, :invalid_reflection_projection_options} =
             ReflectionProjection.generate(
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               snapshot,
               [1]
             )

    assert {:error, :invalid_reflection_projection_data} =
             ReflectionProjection.from_data(
               %{},
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               snapshot
             )

    unsafe_activation = %{fixture.activation | state_bindings: %{"unsafe" => self()}}

    assert {:error, {:nonportable_reflection_projection_value, _path, :other}} =
             ReflectionProjection.generate(
               fixture.canonical,
               fixture.manifest,
               unsafe_activation,
               snapshot
             )

    ahead_attrs = validated_evidence_attrs(%{fixture.activation | generation: 2}, 10, 100)
    assert {:ok, _ref} = Experience.record(fixture.experience_store, ahead_attrs, enabled?: true)

    assert {:ok, ahead_snapshot} =
             Experience.snapshot(fixture.experience_store, fixture.canonical_ref, as_of: 50)

    assert {:error, :reflection_experience_generation_ahead} =
             ReflectionProjection.generate(
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               ahead_snapshot
             )
  end

  test "the registered Reflection operation takes policy and stores only from host context" do
    fixture = fixture()
    assert {:ok, _ref} = record(fixture, 10, 100)

    input = %{
      "definition_ref" => to_string(fixture.canonical_ref),
      "actor_ref" => "intruder:runtime-data",
      "purpose" => "exfiltrate",
      "as_of" => 50
    }

    context = %{
      opts: [
        reflection: %{
          definition_store: fixture.definition_store,
          experience_store: fixture.experience_store,
          activation: fixture.activation,
          policy: policy(),
          actor_ref: "operator:test",
          purpose: "inspect"
        }
      ]
    }

    assert {:ok, %{"generator_id" => "spectre.projection.reflection"}} =
             Spectre.Reflection.Operation.execute(input, context)

    intruder_context =
      %{
        context
        | opts:
            Keyword.update!(context.opts, :reflection, &Map.put(&1, :actor_ref, "intruder:host"))
      }

    assert {:error, :reflection_actor_not_authorized} =
             Spectre.Reflection.Operation.execute(
               Map.take(input, ["definition_ref", "as_of"]),
               intruder_context
             )

    assert {:error, :reflection_operation_not_configured} =
             Spectre.Reflection.Operation.execute(input, %{opts: []})

    spec = Spectre.Reflection.Operation.spec()
    assert spec.side_effect == :none
    assert spec.executor == Spectre.Reflection.Operation
  end

  test "Forge accepts only typed operations and only oracle-backed critique cases" do
    fixture = forge_fixture()

    assert {:ok, proposal} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [ContractCritic, UnapprovedCritic],
               trusted_oracle_refs: ["oracle:contract:routing-v1"],
               author_ref: "forge:test",
               reason: "Add independently falsifiable routing evidence",
               created_at: 60
             )

    assert %Proposal{} = proposal
    assert length(proposal.critiques) == 2
    assert Enum.map(proposal.change_set.operations, & &1.type) == ["add_eval_case"]
    [operation] = proposal.change_set.operations
    assert operation.payload["case"]["id"] == "forge-empty-input"
    refute inspect(ChangeSet.to_data(proposal.change_set)) =~ "forge-unapproved"
    assert :ok = Proposal.verify(proposal)

    transported = proposal |> Proposal.to_data() |> Jason.encode!() |> Jason.decode!()
    assert {:ok, ^proposal} = Proposal.from_data(transported)

    assert {:ok, %{format: :forge_proposal, digest: proposal_digest}} =
             Conformance.verify_forge_proposal(transported)

    assert proposal_digest == proposal.digest

    matrix = Conformance.matrix()
    assert matrix.release == "0.3.4"
    assert matrix.reflection.reflection_projection == 1
    assert matrix.forge.proposal_schema == 1

    refute function_exported?(Forge, :activate, 2)
    refute function_exported?(Forge, :activate, 3)
    refute "replace_eval_case" in Forge.operation_types()

    assert {:error, {:invalid_forge_operation, 0, _reason}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               ["change it"],
               author_ref: "forge:test",
               reason: "text is not an operation",
               created_at: 60
             )
  end

  test "foundation reflection and Forge gates reverify structs, bytes and malformed transports" do
    fixture = forge_fixture()

    assert {:ok, %{format: :reflection, digest: reflection_digest}} =
             Conformance.verify_reflection(
               fixture.reflection,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               fixture.snapshot
             )

    assert reflection_digest == fixture.reflection.digest

    reflection_bytes =
      fixture.reflection
      |> ReflectionProjection.to_data()
      |> Spectre.Canonical.Value.encode!()

    assert {:ok, %{digest: ^reflection_digest}} =
             Conformance.verify_reflection(
               reflection_bytes,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               fixture.snapshot
             )

    assert {:error, {:invalid_foundation_activation, :list}} =
             Conformance.verify_reflection(
               fixture.reflection,
               fixture.canonical,
               fixture.manifest,
               [],
               fixture.snapshot
             )

    assert {:error, {:invalid_foundation_experience_snapshot, :tuple}} =
             Conformance.verify_reflection(
               fixture.reflection,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               {:snapshot}
             )

    assert {:error, {:invalid_foundation_reflection, :atom}} =
             Conformance.verify_reflection(
               :reflection,
               fixture.canonical,
               fixture.manifest,
               fixture.activation,
               fixture.snapshot
             )

    assert {:ok, proposal} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [%{"type" => "disable_skill", "payload" => %{"mount_id" => "lookup"}}],
               author_ref: "forge:foundation",
               reason: "exercise every conformance transport",
               created_at: 60
             )

    assert {:ok, %{format: :forge_proposal, digest: proposal_digest}} =
             Conformance.verify_forge_proposal(proposal)

    assert proposal_digest == proposal.digest
    assert {:ok, encoded_proposal} = Proposal.encode(proposal)

    assert {:ok, %{digest: ^proposal_digest}} =
             Conformance.verify_forge_proposal(encoded_proposal)

    assert {:error, {:invalid_foundation_forge_proposal, :tuple}} =
             Conformance.verify_forge_proposal({:proposal})

    assert {:error, {:invalid_state_payload, :list}} = Conformance.verify_state("[]")

    assert {:error, %Jason.DecodeError{}} = Conformance.verify_state("{bad-json}")
  end

  test "model agreement is not evidence and malformed textual critique fails closed" do
    fixture = forge_fixture()

    assert {:error, {:forge_critic_failed, 0, {:invalid_forge_critic_response, :binary}}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [TextCritic],
               author_ref: "forge:test",
               reason: "reject prose",
               created_at: 60
             )

    assert {:error, :forge_proposal_requires_typed_operation} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [UnapprovedCritic, AgreementCritic],
               author_ref: "forge:test",
               reason: "agreement still needs an oracle",
               created_at: 60
             )
  end

  test "compiled critic adapters fail closed on limits, crashes and malformed replies" do
    fixture = forge_fixture()

    assert {:error, :invalid_forge_critic_options} =
             Critic.run([], fixture.reflection, fixture.snapshot, [1])

    assert {:error, {:forge_critic_limit_exceeded, 17, 16}} =
             Critic.run(
               List.duplicate(UnapprovedCritic, 17),
               fixture.reflection,
               fixture.snapshot
             )

    assert {:error, :invalid_forge_critics} =
             Critic.run(:bad, fixture.reflection, fixture.snapshot)

    for {critic, expected} <- [
          {RaisingCritic, :forge_critic_exception},
          {ThrowingCritic, :forge_critic_failure},
          {ErrorCritic, :offline},
          {InvalidMetadataCritic, :invalid_forge_critic_id},
          {UnknownFieldCritic, :unknown_forge_critic_response_fields},
          {AmbiguousResponseCritic, :ambiguous_forge_critic_response_fields}
        ] do
      assert {:error, {:forge_critic_failed, 0, reason}} =
               Critic.run([critic], fixture.reflection, fixture.snapshot)

      assert inspect(reason) =~ Atom.to_string(expected)
    end

    assert {:error, {:forge_critic_failed, 0, {:invalid_forge_critic_adapter, String}}} =
             Critic.run([String], fixture.reflection, fixture.snapshot)

    assert {:error, :duplicate_forge_critic_identity} =
             Critic.run(
               [UnapprovedCritic, UnapprovedCritic],
               fixture.reflection,
               fixture.snapshot
             )
  end

  test "Critique, oracle approval and Proposal loaders reject corrupted lineage" do
    fixture = forge_fixture()

    assert {:ok, [critique]} =
             Critic.run([UnapprovedCritic], fixture.reflection, fixture.snapshot)

    approval =
      OracleApproval.new!(%{
        case_digest: Critique.case_digest(critique),
        oracle_ref: critique.oracle_ref,
        approver_ref: "operator:test",
        approved_at: 55,
        provenance: %{"source" => "independent_review"}
      })

    critique_data = Critique.to_data(critique)

    for corrupted <- [
          Map.put(critique_data, "schema_version", 2),
          Map.put(critique_data, "unknown", true),
          Map.put(critique_data, :critic_id, "ambiguous"),
          Map.put(critique_data, "critic_id", "UPPER"),
          Map.put(critique_data, "critic_version", 0),
          Map.put(critique_data, "profile_ref", "Elixir.System"),
          Map.put(critique_data, "reflection_digest", "bad"),
          Map.put(critique_data, "opinion", self()),
          Map.put(critique_data, "eval_case", "not-a-case"),
          Map.put(critique_data, "oracle_ref", nil),
          Map.put(critique_data, "provenance", %{"password" => "raw"}),
          Map.put(critique_data, "digest", String.duplicate("0", 64))
        ] do
      assert {:error, _reason} = Critique.from_data(corrupted)
    end

    opinion_only =
      critique_data
      |> Map.put("eval_case", nil)
      |> Map.put("oracle_ref", nil)
      |> Map.put("digest", nil)

    assert {:ok, opinion} = Critique.from_data(opinion_only)
    assert Critique.case_digest(opinion) == nil
    assert :ok = Critique.verify(opinion)

    approval_data = OracleApproval.to_data(approval)

    for corrupted <- [
          Map.put(approval_data, "schema_version", 2),
          Map.put(approval_data, "unknown", true),
          Map.put(approval_data, :oracle_ref, "ambiguous"),
          Map.put(approval_data, "case_digest", "bad"),
          Map.put(approval_data, "oracle_ref", "Elixir.System"),
          Map.put(approval_data, "approved_at", -1),
          Map.put(approval_data, "provenance", %{"token" => "raw"}),
          Map.put(approval_data, "digest", String.duplicate("0", 64))
        ] do
      assert {:error, _reason} = OracleApproval.from_data(corrupted)
    end

    assert_raise ArgumentError, fn -> OracleApproval.new!(%{}) end
    assert :ok = OracleApproval.verify(approval)

    assert {:ok, proposal} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [UnapprovedCritic],
               oracle_approvals: [approval],
               author_ref: "forge:test",
               reason: "exercise Proposal lineage",
               created_at: 60
             )

    proposal_data = Proposal.to_data(proposal)

    for corrupted <- [
          Map.put(proposal_data, "schema_version", 2),
          Map.put(proposal_data, "unknown", true),
          Map.put(proposal_data, :reflection_digest, String.duplicate("1", 64)),
          Map.put(proposal_data, "reflection_digest", "bad"),
          Map.put(proposal_data, "critiques", List.duplicate(critique_data, 17)),
          Map.put(proposal_data, "oracle_approvals", List.duplicate(approval_data, 17)),
          Map.put(proposal_data, "trusted_oracle_refs", ["Elixir.System"]),
          Map.put(proposal_data, "parent_proposal_digest", "bad"),
          Map.put(proposal_data, "digest", String.duplicate("0", 64)),
          proposal_data
          |> Map.put("critiques", [])
          |> Map.put("digest", nil)
        ] do
      assert {:error, _reason} = Proposal.from_data(corrupted)
    end

    assert {:ok, encoded} = Proposal.encode(proposal)
    assert {:ok, ^proposal} = Proposal.decode(encoded)
    assert {:error, {:invalid_forge_proposal_binary, :other}} = Proposal.decode(:bad)
  end

  test "Forge bounds untrusted collections before normalizing their contents" do
    fixture = forge_fixture()

    assert {:error, {:forge_operation_limit_exceeded, 256}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               List.duplicate(%{}, 257),
               []
             )

    assert {:error, {:forge_oracle_approval_limit_exceeded, 16}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               oracle_approvals: List.duplicate(%{}, 17)
             )

    assert {:error, {:forge_trusted_oracle_limit_exceeded, 256}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               trusted_oracle_refs: Enum.map(1..257, &"oracle:#{&1}")
             )
  end

  test "Forge rejects invalid typed input, mismatched approvals and forged projections" do
    fixture = forge_fixture()

    assert {:error, :invalid_forge_options} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [], [1])

    assert {:error, {:forge_operation_not_allowed, 0}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [%{"type" => "add_eval_case", "payload" => %{}}],
               []
             )

    assert {:error, {:invalid_forge_oracle_approval, 0, _reason}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               oracle_approvals: [%{}]
             )

    assert {:error, {:invalid_forge_oracle_approvals, :map}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               oracle_approvals: %{}
             )

    assert {:error, :invalid_forge_trusted_oracle_refs} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               trusted_oracle_refs: :all
             )

    assert {:ok, [critique]} =
             Critic.run([UnapprovedCritic], fixture.reflection, fixture.snapshot)

    unrelated_approval =
      OracleApproval.new!(%{
        case_digest: String.duplicate("d", 64),
        oracle_ref: critique.oracle_ref,
        approver_ref: "operator:test",
        approved_at: 55,
        provenance: %{}
      })

    assert {:error, {:forge_oracle_approval_without_critique, _ref}} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [UnapprovedCritic],
               oracle_approvals: [unrelated_approval]
             )

    valid_operation = %{"type" => "disable_skill", "payload" => %{"mount_id" => "lookup"}}

    assert {:error, {:forge_field_required, :author_ref, nil}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [valid_operation],
               reason: "missing author",
               created_at: 60
             )

    assert {:error, {:forge_field_required, :reason, nil}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [valid_operation],
               author_ref: "forge:test",
               created_at: 60
             )

    assert {:error, {:invalid_forge_created_at, nil}} =
             Forge.propose(
               fixture.activation,
               fixture.reflection,
               fixture.snapshot,
               [valid_operation],
               author_ref: "forge:test",
               reason: "missing time"
             )

    assert {:error, {:invalid_forge_proposal_input, :tuple, :list}} =
             Forge.propose(:bad, :bad, :bad, {:bad}, [])

    assert {:error, :invalid_forge_rebase} = Forge.rebase(:bad, :bad, :bad, :bad)

    forged_content =
      put_in(
        fixture.reflection.content,
        ["effective", "activation", "activation_receipt"],
        "forged"
      )

    forged_digest =
      Spectre.Canonical.Value.digest!(%{
        definition_ref: to_string(fixture.reflection.definition_ref),
        generator_id: fixture.reflection.generator_id,
        generator_version: fixture.reflection.generator_version,
        input_evidence_digest: fixture.reflection.input_evidence_digest,
        content: forged_content
      })

    forged_projection = %{
      fixture.reflection
      | content: forged_content,
        digest: forged_digest
    }

    assert {:error, :forge_reflection_evidence_mismatch} =
             Forge.propose(
               fixture.activation,
               forged_projection,
               fixture.snapshot,
               [valid_operation],
               author_ref: "forge:test",
               reason: "reject forged projection",
               created_at: 60
             )
  end

  test "independent oracle approval admits a case and explicit rebase replaces evidence" do
    fixture = forge_fixture()

    assert {:ok, [critique]} =
             Critic.run([UnapprovedCritic], fixture.reflection, fixture.snapshot)

    approval =
      OracleApproval.new!(%{
        case_digest: Critique.case_digest(critique),
        oracle_ref: critique.oracle_ref,
        approver_ref: "operator:test",
        approved_at: 55,
        provenance: %{"source" => "independent_review"}
      })

    assert {:ok, proposal} =
             Forge.propose(fixture.activation, fixture.reflection, fixture.snapshot, [],
               critics: [UnapprovedCritic],
               oracle_approvals: [approval],
               author_ref: "forge:test",
               reason: "approved adversarial case",
               created_at: 60
             )

    assert [%{type: "add_eval_case"}] = proposal.change_set.operations

    assert {:ok, _ref} = record(fixture, 51, 120)

    assert {:ok, new_snapshot} =
             Experience.snapshot(fixture.experience_store, fixture.canonical_ref, as_of: 70)

    assert {:ok, new_reflection} = reflection(fixture, new_snapshot, 70)

    assert {:error, :stale_governance_evidence_digest} =
             ChangeSet.verify_base(
               proposal.change_set,
               fixture.activation,
               Forge.evidence(new_reflection, new_snapshot)
             )

    assert {:ok, rebased} =
             Forge.rebase(proposal, fixture.activation, new_reflection, new_snapshot,
               critics: [UnapprovedCritic],
               oracle_approvals: [approval],
               created_at: 80
             )

    assert rebased.parent_proposal_digest == proposal.digest
    assert rebased.digest != proposal.digest

    assert rebased.change_set.observed_evidence_digest !=
             proposal.change_set.observed_evidence_digest
  end

  test "the permanent 0.3.0 fixture pins Reflection and Forge identities" do
    fixture_path =
      "test/fixtures/compatibility/0.3.0/reflective-runtime-v1.json"

    expected = permanent_fixture()
    assert File.exists?(fixture_path)
    assert Jason.decode!(File.read!(fixture_path)) == expected
  end

  defp forge_fixture do
    fixture = fixture()
    assert {:ok, _ref} = record(fixture, 10, 100)

    assert {:ok, snapshot} =
             Experience.snapshot(fixture.experience_store, fixture.canonical_ref, as_of: 50)

    assert {:ok, reflection} = reflection(fixture, snapshot, 50)
    Map.merge(fixture, %{snapshot: snapshot, reflection: reflection})
  end

  defp fixture(logical_id \\ System.unique_integer([:positive, :monotonic])) do
    definition_server =
      start_supervised!({DefinitionMemory, id: {:reflection_definition, logical_id}})

    experience_server =
      start_supervised!({ExperienceMemory, id: {:reflection_experience, logical_id}})

    definition_store = {DefinitionMemory, server: definition_server}
    experience_store = {ExperienceMemory, server: experience_server}
    canonical = Definition.canonical!(Agent)
    manifest = Manifest.new!(canonical, Envelope.empty(), closure())
    assert {:ok, _receipt} = Store.publish(definition_store, canonical, manifest)

    assert {:ok, candidate_ref} =
             Resolver.bootstrap_candidate(definition_store, Canonical.ref(canonical),
               source: :compiled,
               created_at: 1
             )

    assert {:ok, resolved} =
             Resolver.resolve_candidate_for_activation(definition_store, candidate_ref)

    assert {:ok, activation} =
             Activation.new(resolved.candidate, resolved.resolution,
               generation: 1,
               authority_epoch: 0,
               owner_fencing_token: 1,
               activated_at: 2,
               provenance: %{source: :test}
             )

    %{
      definition_store: definition_store,
      experience_store: experience_store,
      canonical: canonical,
      canonical_ref: Canonical.ref(canonical),
      manifest: manifest,
      activation: activation
    }
  end

  defp reflection(fixture, snapshot, as_of) do
    ReflectionProjection.generate(
      fixture.canonical,
      fixture.manifest,
      fixture.activation,
      snapshot,
      as_of: as_of
    )
  end

  defp record(fixture, observed_at, expires_at) do
    Experience.record(
      fixture.experience_store,
      evidence_attrs(fixture.activation, observed_at, expires_at),
      enabled?: true
    )
  end

  defp evidence_attrs(activation, observed_at, expires_at) do
    %{
      definition_ref: activation.definition_ref,
      activation_generation: activation.generation,
      kind: "routing.observation",
      source_ref: "journal:redacted:1",
      observed_at: observed_at,
      expires_at: expires_at,
      retention: :bounded,
      facts: %{outcome: :matched, token: "raw-secret"},
      provenance: %{source: :test}
    }
  end

  defp validated_evidence_attrs(activation, observed_at, expires_at) do
    activation
    |> evidence_attrs(observed_at, expires_at)
    |> Map.put(:facts, %{"outcome" => "matched", "token" => "[REDACTED]"})
    |> Map.put(:redactions, [["facts", "token"]])
  end

  defp reflection_opts(fixture, as_of) do
    [
      policy: policy(),
      actor_ref: "operator:test",
      purpose: "inspect",
      as_of: as_of,
      experience_store: fixture.experience_store
    ]
  end

  defp permanent_fixture do
    fixture = fixture("reflective-runtime-v1")
    assert {:ok, evidence_ref} = record(fixture, 10, 100)

    assert {:ok, snapshot} =
             Experience.snapshot(fixture.experience_store, fixture.canonical_ref, as_of: 50)

    assert {:ok, reflection} = reflection(fixture, snapshot, 50)
    assert {:ok, [critique]} = Critic.run([UnapprovedCritic], reflection, snapshot)

    approval =
      OracleApproval.new!(%{
        case_digest: Critique.case_digest(critique),
        oracle_ref: critique.oracle_ref,
        approver_ref: "operator:fixture",
        approved_at: 55,
        provenance: %{"source" => "fixture_review"}
      })

    assert {:ok, proposal} =
             Forge.propose(fixture.activation, reflection, snapshot, [],
               critics: [UnapprovedCritic],
               oracle_approvals: [approval],
               author_ref: "forge:fixture",
               reason: "Pin reflective runtime compatibility",
               created_at: 60,
               provenance: %{"fixture" => "0.3.0"}
             )

    %{
      "release" => "0.3.0",
      "schemas" => %{
        "experience_evidence" => Evidence.schema_version(),
        "experience_artifact" => ExperienceStore.artifact_schema_version(),
        "reflection_projection" => ReflectionProjection.version(),
        "critic" => Critique.schema_version(),
        "oracle_approval" => OracleApproval.schema_version(),
        "forge_proposal" => Proposal.schema_version()
      },
      "definition_ref" => to_string(fixture.canonical_ref),
      "activation_receipt" => fixture.activation.activation_receipt,
      "experience_ref" => to_string(evidence_ref),
      "experience_snapshot_digest" => snapshot.digest,
      "reflection_digest" => reflection.digest,
      "reflection_input_evidence_digest" => reflection.input_evidence_digest,
      "critique_digest" => critique.digest,
      "oracle_approval_ref" => OracleApproval.ref(approval),
      "change_set_digest" => ChangeSet.digest(proposal.change_set),
      "proposal_digest" => proposal.digest
    }
  end

  defp policy do
    Policy.new!(actor_refs: ["operator:test"], purposes: ["inspect"], max_evidence: 10)
  end

  defp closure do
    Closure.new!(%{
      stack_ref: "spectre.stack:none",
      package_refs: [],
      contract_refs: [],
      prompt_fragment_digests: [],
      projection_generators: [
        %{id: "spectre.projection.audit", version: 1},
        %{id: "spectre.projection.reflection", version: 1}
      ],
      state_schema_ref: "spectre.instance.canonical/1",
      state_codec_ref: "spectre.instance.canonical.codec/1",
      model_profile_refs: [],
      recording_refs: [],
      build_fingerprints: %{"beam:Agent" => @digest},
      evaluation_corpus_digest: @digest,
      compatibility_mode: :adapted_v1
    })
  end
end
