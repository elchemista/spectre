defmodule SpectreSubjectRegistryContractTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreSubjectRegistryContractTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:subject_registry_journal, record})
    Keyword.get(opts, :reply, :ok)
  end
end

defmodule SpectreSubjectRegistryContractTest do
  use ExUnit.Case, async: false

  alias Spectre.AgentRef
  alias Spectre.ExternalIdentity
  alias Spectre.Input.Source
  alias Spectre.LinkIntent
  alias Spectre.Subject
  alias Spectre.Subject.Registry, as: SubjectRegistry
  alias Spectre.SubjectLink

  @agent SpectreSubjectRegistryContractTest.Agent

  setup do
    clock =
      start_supervised!(%{
        id: {:subject_registry_clock, System.unique_integer([:positive])},
        start: {Agent, :start_link, [fn -> System.system_time(:millisecond) end]}
      })

    registry =
      start_supervised!({SubjectRegistry, name: nil, clock: fn -> Agent.get(clock, & &1) end})

    %{clock: clock, registry: registry}
  end

  test "logical identities are portable, opaque, and never imply a Subject" do
    agent_ref = AgentRef.new(@agent)
    subject = Subject.new({:account, 42}, metadata: %{tier: :pro})

    identity =
      ExternalIdentity.new(
        provider: :beam,
        channel: :telegram,
        endpoint: :support,
        principal_id: "raw-provider-user-42",
        authenticated_at: 1_000,
        proof_ref: "oauth-receipt-7"
      )

    assert agent_ref.definition == @agent
    assert is_binary(AgentRef.key(agent_ref))
    assert subject.id != inspect({:account, 42})
    assert Subject.key(subject) != AgentRef.key(agent_ref)
    assert identity.id != "raw-provider-user-42"
    refute inspect(identity) =~ "raw-provider-user-42"

    source =
      Source.new(
        kind: :whatsapp,
        mount: :primary,
        actor_id: "provider-principal"
      )

    from_source =
      ExternalIdentity.from_source(source,
        provider: :beam,
        authenticated_at: 2_000
      )

    assert from_source.channel == :whatsapp
    assert from_source.endpoint == :primary
    refute from_source.id == "provider-principal"
  end

  test "bootstrap binding requires proof and resolves only exact Agent-scoped identities", %{
    registry: registry
  } do
    subject = Subject.new("subject-bootstrap")
    identity = identity(:telegram, "principal-bootstrap")

    assert {:error, :subject_link_proof_required} =
             SubjectRegistry.bind(registry, @agent, subject, identity)

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, @agent, identity)

    journal = journal(self())

    assert {:ok, %SubjectLink{status: :active} = link} =
             SubjectRegistry.bind(registry, @agent, subject, identity,
               proof: "raw-authentication-proof",
               journal: journal
             )

    assert link.receipt_ref != "raw-authentication-proof"
    assert {:ok, ^subject, ^link} = SubjectRegistry.resolve(registry, @agent, identity)

    assert_receive {:subject_registry_journal, record}
    refute inspect(record) =~ "raw-authentication-proof"
    refute inspect(record) =~ "principal-bootstrap"

    other_agent_ref = AgentRef.new(@agent, id: "logically-distinct-agent")

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, other_agent_ref, identity)

    assert {:ok, ^link} =
             SubjectRegistry.bind(registry, @agent, subject, identity,
               proof: "a-repeated-bootstrap-is-idempotent"
             )

    assert {:error, {:external_identity_subject_conflict, link_id}} =
             SubjectRegistry.bind(
               registry,
               @agent,
               Subject.new("different-subject"),
               identity,
               proof: "cannot-merge"
             )

    assert link_id == link.id
  end

  test "destination challenges are bounded, one-time, optionally dual-confirmed, and revocable",
       %{clock: clock, registry: registry} do
    subject = Subject.new("subject-linking")
    source = identity(:telegram, "source-principal")
    destination = identity(:whatsapp, "destination-principal")

    assert {:ok, _source_link} =
             SubjectRegistry.bind(registry, @agent, subject, source, proof: "source-proof")

    set_clock(clock, 1_000)

    assert {:ok, %LinkIntent{} = expiring, expiring_challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               destination,
               ttl: 10
             )

    assert expiring.challenge_digest != expiring_challenge
    set_clock(clock, 1_010)

    assert {:error, :link_intent_expired} =
             SubjectRegistry.confirm_link(
               registry,
               expiring.id,
               destination,
               expiring_challenge,
               now: 1_000
             )

    failed_destination = identity(:signal, "failed-principal")

    assert {:ok, failed_intent, _challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               failed_destination,
               attempts: 2
             )

    assert {:error, {:invalid_link_challenge, 1}} =
             SubjectRegistry.confirm_link(
               registry,
               failed_intent.id,
               failed_destination,
               "wrong-one"
             )

    assert {:error, {:invalid_link_challenge, 0}} =
             SubjectRegistry.confirm_link(
               registry,
               failed_intent.id,
               failed_destination,
               "wrong-two"
             )

    assert {:error, {:link_intent_not_pending, :failed}} =
             SubjectRegistry.confirm_link(
               registry,
               failed_intent.id,
               failed_destination,
               "wrong-three"
             )

    confirmed_destination = identity(:matrix, "dual-confirmed-principal")

    assert {:ok, dual_intent, challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               confirmed_destination,
               source_confirmation?: true
             )

    assert {:error, :destination_identity_mismatch} =
             SubjectRegistry.confirm_link(registry, dual_intent.id, source, challenge)

    assert {:ok, %LinkIntent{status: :awaiting_source} = awaiting_source} =
             SubjectRegistry.confirm_link(
               registry,
               dual_intent.id,
               confirmed_destination,
               challenge
             )

    assert awaiting_source.challenge_digest == <<>>

    assert {:error, {:link_intent_not_pending, :awaiting_source}} =
             SubjectRegistry.confirm_link(
               registry,
               dual_intent.id,
               confirmed_destination,
               challenge
             )

    assert {:error, :source_identity_mismatch} =
             SubjectRegistry.confirm_source(
               registry,
               dual_intent.id,
               confirmed_destination
             )

    assert {:ok, %SubjectLink{status: :active} = destination_link} =
             SubjectRegistry.confirm_source(registry, dual_intent.id, source)

    assert {:ok, ^subject, ^destination_link} =
             SubjectRegistry.resolve(registry, @agent, confirmed_destination)

    assert {:ok, %SubjectLink{status: :revoked} = revoked} =
             SubjectRegistry.revoke(registry, destination_link.id)

    assert revoked.revision == destination_link.revision + 1

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, @agent, confirmed_destination)

    assert {:ok, links} = SubjectRegistry.links(registry, @agent, subject)
    assert Enum.any?(links, &(&1.id == destination_link.id and &1.status == :revoked))
  end

  test "competing link intents are each consumed when one destination link already committed", %{
    registry: registry
  } do
    subject = Subject.new("subject-competing-intents")
    source = identity(:telegram, "competing-source")
    destination = identity(:whatsapp, "competing-destination")

    assert {:ok, _source_link} =
             SubjectRegistry.bind(registry, @agent, subject, source, proof: "source-proof")

    assert {:ok, first_intent, first_challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               destination
             )

    assert {:ok, second_intent, second_challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               destination
             )

    assert {:ok, %SubjectLink{} = link} =
             SubjectRegistry.confirm_link(
               registry,
               first_intent.id,
               destination,
               first_challenge
             )

    assert {:ok, ^link} =
             SubjectRegistry.confirm_link(
               registry,
               second_intent.id,
               destination,
               second_challenge
             )

    assert {:ok, %LinkIntent{status: :committed, challenge_digest: <<>>} = consumed} =
             SubjectRegistry.intent(registry, second_intent.id)

    assert consumed.receipt_ref == link.receipt_ref

    assert {:error, {:link_intent_not_pending, :committed}} =
             SubjectRegistry.confirm_link(
               registry,
               second_intent.id,
               destination,
               second_challenge
             )
  end

  test "a failed Journal append does not publish a link", %{registry: registry} do
    subject = Subject.new("journal-atomicity")
    identity = identity(:telegram, "journal-principal")

    rejecting_journal =
      {SpectreSubjectRegistryContractTest.JournalStore,
       events: [:extensions],
       mode: :sync,
       on_error: :error,
       store_opts: [reply: {:error, :journal_down}]}

    assert {:error, _reason} =
             SubjectRegistry.bind(registry, @agent, subject, identity,
               proof: "verified",
               journal: rejecting_journal
             )

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, @agent, identity)
  end

  test "documented default-Registry arities keep options distinct from the server" do
    suffix = System.unique_integer([:positive])
    subject = Subject.new("default-registry-subject-#{suffix}")
    identity = identity(:telegram, "default-registry-principal-#{suffix}")

    assert {:ok, link} =
             SubjectRegistry.bind(@agent, subject, identity, proof: "verified-#{suffix}")

    assert {:ok, ^subject, ^link} = SubjectRegistry.resolve(@agent, identity)
    assert {:ok, links} = SubjectRegistry.links(@agent, subject)
    assert Enum.any?(links, &(&1.id == link.id))
    assert {:ok, %{status: :revoked}} = SubjectRegistry.revoke(link.id)
  end

  test "link commit rechecks source ownership and expiry after destination confirmation", %{
    clock: clock,
    registry: registry
  } do
    subject = Subject.new("toctou-subject")
    source = identity(:telegram, "toctou-source")
    destination = identity(:whatsapp, "toctou-destination")

    assert {:ok, source_link} =
             SubjectRegistry.bind(registry, @agent, subject, source, proof: "source-proof")

    set_clock(clock, 1_000)

    assert {:ok, intent, challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               destination,
               ttl: 100
             )

    set_clock(clock, 1_010)
    assert {:ok, _revoked} = SubjectRegistry.revoke(registry, source_link.id)
    set_clock(clock, 1_020)

    assert {:error, :source_identity_not_linked} =
             SubjectRegistry.confirm_link(
               registry,
               intent.id,
               destination,
               challenge
             )

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, @agent, destination)

    second_source = identity(:matrix, "expiring-source")
    second_destination = identity(:signal, "expiring-destination")

    set_clock(clock, 2_000)

    assert {:ok, _source_link} =
             SubjectRegistry.bind(
               registry,
               @agent,
               subject,
               second_source,
               proof: "second-source"
             )

    assert {:ok, expiring_intent, expiring_challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               second_source,
               second_destination,
               source_confirmation?: true,
               ttl: 10
             )

    set_clock(clock, 2_001)

    assert {:ok, %{status: :awaiting_source}} =
             SubjectRegistry.confirm_link(
               registry,
               expiring_intent.id,
               second_destination,
               expiring_challenge
             )

    set_clock(clock, 2_010)

    assert {:error, :link_intent_expired} =
             SubjectRegistry.confirm_source(
               registry,
               expiring_intent.id,
               second_source
             )

    assert {:error, :unlinked_external_identity} =
             SubjectRegistry.resolve(registry, @agent, second_destination)
  end

  test "malformed value objects fail closed without crashing the Registry", %{registry: registry} do
    invalid_subject = %Subject{id: "", metadata: %{}}

    invalid_identity = %ExternalIdentity{
      id: "",
      provider: :beam,
      channel: :telegram,
      authenticated_at: 0
    }

    assert {:error, {:invalid_subject_id, ""}} =
             SubjectRegistry.bind(
               registry,
               @agent,
               invalid_subject,
               identity(:telegram, "valid-principal"),
               proof: "proof"
             )

    assert {:error, {:invalid_external_identity_id, ""}} =
             SubjectRegistry.resolve(registry, @agent, invalid_identity)

    improper_subject = %Subject{
      id: "portable-id",
      metadata: %{crafted: [:proper | :improper]}
    }

    assert {:error, {:nonportable_run_value, _path, :improper_list}} =
             SubjectRegistry.bind(
               registry,
               @agent,
               improper_subject,
               identity(:telegram, "another-valid-principal"),
               proof: "proof"
             )

    assert Process.alive?(registry)
  end

  test "external identity construction rejects nonportable principal and proof values" do
    for principal <- [self(), make_ref(), fn -> :not_portable end] do
      assert_raise ArgumentError, ~r/nonportable_run_value/, fn ->
        ExternalIdentity.new(
          provider: :beam,
          channel: :web,
          endpoint: :primary,
          principal_id: principal,
          authenticated_at: 1_000
        )
      end
    end

    assert_raise ArgumentError, ~r/nonportable_run_value/, fn ->
      ExternalIdentity.new(
        id: "opaque-id",
        provider: :beam,
        channel: :web,
        endpoint: :primary,
        authenticated_at: 1_000,
        proof_ref: make_ref()
      )
    end
  end

  defp identity(channel, principal) do
    ExternalIdentity.new(
      provider: :beam,
      channel: channel,
      endpoint: {:endpoint, channel},
      principal_id: principal,
      authenticated_at: 1_000
    )
  end

  defp journal(pid) do
    {SpectreSubjectRegistryContractTest.JournalStore,
     events: [:extensions], mode: :sync, store_opts: [pid: pid]}
  end

  defp set_clock(clock, now) do
    Agent.update(clock, fn _previous -> now end)
  end
end
