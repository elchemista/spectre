defmodule SpectreRehearsalProjectionSubjectContractTest.Agent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreRehearsalProjectionSubjectContractTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl true
  def append(_record, opts), do: Keyword.get(opts, :reply, :ok)
end

defmodule SpectreRehearsalProjectionSubjectContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Execution.Program
  alias Spectre.Execution.Rehearsal
  alias Spectre.Execution.Rehearsal.Report
  alias Spectre.ExternalIdentity
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.LinkIntent
  alias Spectre.Projection.HumanReport
  alias Spectre.Subject
  alias Spectre.Subject.Registry, as: SubjectRegistry
  alias Spectre.SubjectLink

  @agent SpectreRehearsalProjectionSubjectContractTest.Agent
  @journal_store SpectreRehearsalProjectionSubjectContractTest.JournalStore
  @digest String.duplicate("a", 64)

  test "rehearsal reports both successful and declared failed terminal programs" do
    input = %{"value" => 1}

    assert {:ok, %Report{} = completed} =
             Rehearsal.run(terminal_program(:complete), input, [],
               agent: @agent,
               materialization_digest: @digest,
               definition_ref: "sha256:" <> @digest
             )

    assert completed.status == :completed
    assert completed.outcome.category == :completed
    assert completed.materialization_digest == @digest
    assert completed.recordings == 0
    assert completed.consumed_recordings == 0

    assert {:ok, %Report{} = failed} =
             Rehearsal.run(terminal_program(:fail), input, [], agent: @agent)

    assert failed.status == :failed
    assert failed.outcome.category == :failed
    assert failed.outcome.reason_digest
    assert failed.effect_dispatches == 0
  end

  test "rehearsal validates typed release evidence before running the program" do
    program = terminal_program(:complete)

    assert {:error, {:invalid_execution_rehearsal_digest, :materialization_digest, :latest}} =
             Rehearsal.run(program, %{}, [], agent: @agent, materialization_digest: :latest)

    assert {:error, {:invalid_execution_rehearsal_definition_ref, :active}} =
             Rehearsal.run(program, %{}, [], agent: @agent, definition_ref: :active)

    assert {:error, {:invalid_execution_rehearsal_input, :binary, :list}} =
             Rehearsal.run(program, %{}, "recording", [])

    assert {:error, {:invalid_execution_rehearsal_input, :list, :binary}} =
             Rehearsal.run(program, %{}, [], "options")
  end

  test "human reports expose real map and list additions and removals symmetrically" do
    parent =
      canonical(%{
        "labels" => ["stable", "legacy"],
        "settings" => %{"kept" => true, "removed" => "legacy"}
      })

    candidate =
      canonical(%{
        "labels" => ["stable", "current", "new"],
        "settings" => %{"added" => "current", "kept" => true}
      })

    assert HumanReport.id() == "spectre.projection.human-report"
    assert HumanReport.version() == 1

    assert {:error, :human_report_requires_evaluation_delta} =
             HumanReport.project(parent, candidate)

    assert {:ok, report} =
             HumanReport.project(parent, candidate, evaluation_delta: evaluation_delta())

    assert Enum.any?(report.structural_changes, fn change ->
             change["change"] == "removed" and
               change["path"] == ["components", 0, "payload", "settings", "removed"]
           end)

    assert Enum.any?(report.structural_changes, fn change ->
             change["change"] == "added" and
               change["path"] == ["components", 0, "payload", "settings", "added"]
           end)

    assert Enum.any?(report.structural_changes, fn change ->
             change["change"] == "added" and
               change["path"] == ["components", 0, "payload", "labels", 2]
           end)

    assert :ok = HumanReport.verify(report)
    assert {:ok, encoded} = HumanReport.encode(report)
    assert {:ok, ^report} = HumanReport.decode(encoded)

    assert {:ok, reverse} =
             HumanReport.project(candidate, parent, evaluation_delta: evaluation_delta())

    assert Enum.any?(reverse.structural_changes, fn change ->
             change["change"] == "removed" and
               change["path"] == ["components", 0, "payload", "labels", 2]
           end)

    assert {:error, {:invalid_human_report, {:unsupported_human_report_generator, "other"}}} =
             HumanReport.verify(%{report | generator_id: "other"})

    assert {:error, {:invalid_human_report_data, :list}} = HumanReport.from_data([])
    assert {:error, {:invalid_human_report_binary, :tuple}} = HumanReport.decode({})

    assert {:error, {:invalid_human_report_definitions, :other, :map}} =
             HumanReport.project(:invalid, candidate, [])
  end

  test "Subject Registry completes an audited dual-confirmation lifecycle" do
    registry = start_registry(:dual_confirmation)
    suffix = System.unique_integer([:positive, :monotonic])
    subject = Subject.new("default-lifecycle-#{suffix}")
    source = identity(:web, "default-source-#{suffix}")
    destination = identity(:email, "default-destination-#{suffix}")

    assert {:error, :subject_link_proof_required} =
             SubjectRegistry.bind(registry, @agent, subject, source)

    assert {:ok, source_link} =
             SubjectRegistry.bind(registry, @agent, subject, source,
               proof: "source-proof-#{suffix}"
             )

    assert {:ok, %LinkIntent{} = intent, challenge} =
             SubjectRegistry.open_link(registry, @agent, subject, source, destination)

    assert {:ok, ^intent} = SubjectRegistry.intent(registry, intent.id)

    assert {:error, {:link_intent_not_awaiting_source, :pending}} =
             SubjectRegistry.confirm_source(registry, intent.id, source)

    assert {:ok, %SubjectLink{} = destination_link} =
             SubjectRegistry.confirm_link(registry, intent.id, destination, challenge)

    assert {:ok, ^subject, ^destination_link} =
             SubjectRegistry.resolve(registry, @agent, destination)

    assert {:ok, revoked} = SubjectRegistry.revoke(registry, destination_link.id)
    assert revoked.status == :revoked
    assert {:ok, ^revoked} = SubjectRegistry.revoke(registry, destination_link.id)

    assert {:error, :unknown_subject_link} =
             SubjectRegistry.revoke(registry, "unknown-link-#{suffix}")

    assert source_link.status == :active
  end

  test "source ownership is rechecked after destination confirmation" do
    registry = start_registry(:source_recheck)
    suffix = System.unique_integer([:positive, :monotonic])
    subject = Subject.new("source-recheck-#{suffix}")
    source = identity(:matrix, "recheck-source-#{suffix}")
    destination = identity(:signal, "recheck-destination-#{suffix}")

    assert {:ok, source_link} =
             SubjectRegistry.bind(registry, @agent, subject, source,
               proof: "source-proof-#{suffix}"
             )

    assert {:ok, intent, challenge} =
             SubjectRegistry.open_link(
               registry,
               @agent,
               subject,
               source,
               destination,
               source_confirmation?: true
             )

    assert {:ok, %{status: :awaiting_source}} =
             SubjectRegistry.confirm_link(registry, intent.id, destination, challenge)

    assert {:ok, %{status: :revoked}} = SubjectRegistry.revoke(registry, source_link.id)

    assert {:error, :source_identity_not_linked} =
             SubjectRegistry.confirm_source(registry, intent.id, source)
  end

  test "a failed revoke journal write leaves the active identity resolution intact" do
    registry =
      start_supervised!(
        {SubjectRegistry,
         name: nil,
         id: {:revoke_atomicity_registry, System.unique_integer([:positive, :monotonic])}}
      )

    suffix = System.unique_integer([:positive, :monotonic])
    subject = Subject.new("revoke-atomicity-#{suffix}")
    identity = identity(:telegram, "revoke-atomicity-#{suffix}")

    assert {:ok, link} =
             SubjectRegistry.bind(registry, @agent, subject, identity, proof: "verified")

    rejecting_journal =
      {@journal_store,
       events: [:extensions],
       mode: :sync,
       on_error: :error,
       store_opts: [reply: {:error, :journal_down}]}

    assert {:error, _reason} =
             SubjectRegistry.revoke(registry, link.id, journal: rejecting_journal)

    assert {:ok, ^subject, ^link} = SubjectRegistry.resolve(registry, @agent, identity)
  end

  test "Subject Registry normalizes documented values and keeps existing links idempotent" do
    registry =
      start_supervised!(
        {SubjectRegistry,
         name: nil, id: {:normalization_registry, System.unique_integer([:positive, :monotonic])}}
      )

    suffix = System.unique_integer([:positive, :monotonic])
    subject_value = "normalized-subject-#{suffix}"
    source = identity(:web, "normalized-source-#{suffix}")

    assert {:ok, %SubjectLink{} = link} =
             SubjectRegistry.bind(registry, @agent, subject_value, source, proof: "verified")

    assert {:ok, ^link} =
             SubjectRegistry.open_link(registry, @agent, subject_value, source, source)

    assert {:ok, [^link]} = SubjectRegistry.links(registry, @agent, subject_value)

    assert {:error, {:invalid_agent_ref, 123}} =
             SubjectRegistry.links(registry, 123, subject_value)

    assert {:error, :missing_subject} = SubjectRegistry.links(registry, @agent, nil)

    assert {:error, {:invalid_external_identity, :unknown}} =
             SubjectRegistry.resolve(registry, @agent, :unknown)

    assert {:error, :unknown_link_intent} = SubjectRegistry.intent(registry, :unknown)

    assert {:error, :invalid_subject_link_proof} =
             SubjectRegistry.bind(
               registry,
               @agent,
               "unsafe-proof-#{suffix}",
               identity(:email, "unsafe-proof-#{suffix}"),
               proof: self()
             )

    destination = identity(:signal, "normalized-destination-#{suffix}")

    assert {:ok, intent, _challenge} =
             SubjectRegistry.open_link(registry, @agent, subject_value, source, destination)

    assert {:error, {:invalid_link_challenge, 2}} =
             SubjectRegistry.confirm_link(registry, intent.id, destination, :not_text)
  end

  defp terminal_program(kind) do
    node =
      case kind do
        :complete -> %{id: :terminal, kind: :complete, output: :state}
        :fail -> %{id: :terminal, kind: :fail, reason: :declared_failure}
      end

    Program.new!(%{
      id: "terminal-#{kind}",
      version: 1,
      entry: :terminal,
      input: :map,
      state: :map,
      initial: :input,
      budget: %{steps: 1, attempts: 1},
      nodes: [node]
    })
  end

  defp canonical(payload) do
    Canonical.new!(
      kind: :agent,
      id: :coverage_human_report,
      declared_version: 1,
      origin: :runtime,
      components: [
        Component.new!(
          component_type: :metadata,
          schema_ref: "spectre.definition.metadata/1",
          criticality: :descriptive,
          payload: payload
        )
      ]
    )
  end

  defp evaluation_delta do
    protected = [%{"id" => "protected", "input" => "lookup"}]

    EvaluationDelta.new!(
      [%{case_id: "protected", passed: true, score: 1.0}],
      [%{case_id: "protected", passed: true, score: 1.0}],
      protected_cases: protected
    )
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

  defp start_registry(label) do
    start_supervised!(
      {SubjectRegistry, name: nil, id: {label, System.unique_integer([:positive, :monotonic])}}
    )
  end
end
