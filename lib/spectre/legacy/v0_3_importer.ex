defmodule Spectre.Legacy.V03Importer do
  @moduledoc """
  One-way preparation of selected 0.3 history for a new governed Domain.

  Imported records are Evidence labelled `"pre_governance"`; they are never
  reconstructed as Acts or Mandates.  Records whose old execution may still be
  in flight, or whose outcome is ambiguous, additionally open an explicit Duty
  with retry forbidden.  The importer therefore preserves useful history while
  refusing to invent authority or retroactively ratify it.

  Import data is accepted only as part of a fresh Domain bootstrap.  A caller
  must supply a new Genesis, Principals and root Mandates independently.
  """

  alias Spectre.{Duty, Evidence, Label, Portable}

  @source_contract "spectre.import.v0.3.record.v1"
  @label "pre_governance"
  @assumptions [
    "import_source_correctly_reports_the_legacy_record",
    "imported_history_did_not_pass_the_governed_act_boundary"
  ]
  @statuses [:terminal, :in_flight, :ambiguous]
  @unresolved_statuses [:in_flight, :ambiguous]
  @config_fields [:source_ref, :imported_at, :records]
  @record_fields [
    :legacy_ref,
    :status,
    :recorded_at,
    :payload,
    :payload_ref,
    :subject_refs,
    :accountable_ref,
    :disposition_authority_refs
  ]

  @type prepared :: %{evidence: [Evidence.t()], duties: [Duty.t()]}
  @type import_status :: :terminal | :in_flight | :ambiguous

  @doc "Validates import material and constructs records for the Genesis batch."
  @spec prepare(String.t(), map() | keyword() | nil, [String.t()]) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(_domain_ref, nil, _principal_refs), do: {:ok, %{evidence: [], duties: []}}

  def prepare(domain_ref, config, principal_refs)
      when is_binary(domain_ref) and domain_ref != "" and is_list(principal_refs) do
    with :ok <- Portable.validate_ref(domain_ref, :domain_ref),
         {:ok, principals} <- Portable.normalize_refs(principal_refs, :principal_refs),
         {:ok, attrs} <- Portable.normalize_attrs(config, @config_fields, :legacy_v0_3_import),
         {:ok, source_ref} <- required_ref(attrs, :source_ref),
         {:ok, imported_at} <- required_time(attrs, :imported_at),
         {:ok, records} <- normalize_records(Map.get(attrs, :records), imported_at),
         :ok <- unique_legacy_refs(records),
         :ok <- validate_principal_bindings(records, MapSet.new(principals)),
         {:ok, prepared} <- build_records(domain_ref, source_ref, imported_at, records),
         :ok <-
           validate_import_batch(domain_ref, prepared.evidence, prepared.duties,
             genesis_batch?: true
           ) do
      {:ok, prepared}
    end
  end

  def prepare(_domain_ref, _config, _principal_refs),
    do: {:error, :invalid_legacy_v0_3_import}

  @doc false
  @spec imported_evidence?(term()) :: boolean()
  def imported_evidence?(%Evidence{labels: labels, proposition: proposition})
      when is_list(labels) do
    Enum.any?(labels, &match?(%Label{value: @label}, &1)) or
      (is_map(proposition) and Map.get(proposition, "contract_ref") == @source_contract)
  end

  def imported_evidence?(_evidence), do: false

  @doc false
  @spec imported_duty?(term()) :: boolean()
  def imported_duty?(%Duty{class: :pre_governance_ambiguity}), do: true

  def imported_duty?(%Duty{cause_key: {:pre_governance_ambiguity, _evidence_ref}}),
    do: true

  def imported_duty?(_duty), do: false

  @doc false
  @spec import_status(Evidence.t()) :: {:ok, import_status()} | {:error, term()}
  def import_status(%Evidence{} = evidence) do
    with {:ok, claim} <- import_claim(evidence), do: {:ok, claim.status}
  end

  @doc false
  @spec validate_import_evidence(String.t(), Evidence.t()) :: :ok | {:error, term()}
  def validate_import_evidence(domain_ref, %Evidence{} = evidence) do
    with :ok <- Portable.validate_ref(domain_ref, :domain_ref),
         {:ok, normalized} <- Evidence.new(evidence),
         true <- normalized == evidence,
         {:ok, claim} <- import_claim(evidence),
         :ok <- exact_evidence_contract(domain_ref, evidence, claim) do
      :ok
    else
      false -> {:error, :noncanonical_pre_governance_evidence}
      {:error, _reason} = error -> error
    end
  end

  def validate_import_evidence(_domain_ref, _evidence),
    do: {:error, :invalid_pre_governance_evidence}

  @doc false
  @spec validate_import_duty(String.t(), Evidence.t(), Duty.t()) :: :ok | {:error, term()}
  def validate_import_duty(domain_ref, %Evidence{} = evidence, %Duty{} = duty) do
    with :ok <- validate_import_evidence(domain_ref, evidence),
         {:ok, claim} <- import_claim(evidence),
         true <- claim.status in @unresolved_statuses,
         {:ok, normalized} <- Duty.new(duty),
         true <- normalized == duty,
         :ok <- exact_duty_contract(evidence, duty, claim) do
      :ok
    else
      false -> {:error, :invalid_pre_governance_duty}
      {:error, _reason} = error -> error
    end
  end

  def validate_import_duty(_domain_ref, _evidence, _duty),
    do: {:error, :invalid_pre_governance_duty}

  @doc false
  @spec validate_import_batch(String.t(), [Evidence.t()], [Duty.t()], keyword()) ::
          :ok | {:error, term()}
  def validate_import_batch(domain_ref, evidence, duties, opts)
      when is_list(evidence) and is_list(duties) and is_list(opts) do
    imported_evidence = Enum.filter(evidence, &imported_evidence?/1)
    imported_duties = Enum.filter(duties, &imported_duty?/1)
    import_present? = imported_evidence != [] or imported_duties != []

    with {:ok, genesis_batch?} <- genesis_batch_flag(opts),
         :ok <- import_requires_genesis_batch(import_present?, genesis_batch?),
         :ok <- validate_import_evidence_set(domain_ref, imported_evidence),
         :ok <- validate_import_duty_set(domain_ref, imported_evidence, imported_duties),
         :ok <- exact_duty_cardinality(imported_evidence, imported_duties) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_import_batch(_domain_ref, _evidence, _duties, _opts),
    do: {:error, :invalid_pre_governance_import_batch}

  defp normalize_records(records, imported_at) when is_list(records) and records != [] do
    records
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, normalized} ->
      case normalize_record(input, imported_at) do
        {:ok, record} -> {:cont, {:ok, [record | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1.legacy_ref)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_records(_records, _imported_at),
    do: {:error, :legacy_v0_3_import_records_required}

  defp normalize_record(input, imported_at) do
    with {:ok, attrs} <- Portable.normalize_attrs(input, @record_fields, :legacy_v0_3_record),
         {:ok, legacy_ref} <- required_ref(attrs, :legacy_ref),
         {:ok, status} <- status(Map.get(attrs, :status)),
         {:ok, recorded_at} <- required_time(attrs, :recorded_at),
         :ok <- not_from_future(recorded_at, imported_at, legacy_ref),
         :ok <- payload_present(attrs),
         {:ok, subjects} <-
           Portable.normalize_refs(Map.get(attrs, :subject_refs, []), :subject_refs),
         {:ok, authorities} <-
           Portable.normalize_refs(
             Map.get(attrs, :disposition_authority_refs, []),
             :disposition_authority_refs
           ),
         {:ok, record} <-
           normalized_record(attrs, legacy_ref, status, recorded_at, subjects, authorities),
         :ok <- Portable.validate(record) do
      {:ok, record}
    end
  end

  defp normalized_record(attrs, legacy_ref, status, recorded_at, subjects, authorities) do
    record = %{
      legacy_ref: legacy_ref,
      status: status,
      recorded_at: recorded_at,
      payload: Map.get(attrs, :payload),
      payload_ref: Map.get(attrs, :payload_ref),
      subject_refs: subjects,
      accountable_ref: Map.get(attrs, :accountable_ref),
      disposition_authority_refs: authorities
    }

    if status == :terminal do
      validate_terminal_record(record)
    else
      validate_open_debt(record)
    end
  end

  defp validate_terminal_record(record) do
    if is_nil(record.accountable_ref) and record.disposition_authority_refs == [],
      do: {:ok, record},
      else: {:error, {:legacy_terminal_record_must_not_assign_authority, record.legacy_ref}}
  end

  defp validate_open_debt(record) do
    cond do
      not present_ref?(record.accountable_ref) ->
        {:error, {:legacy_import_accountable_required, record.legacy_ref}}

      record.disposition_authority_refs == [] ->
        {:error, {:legacy_import_disposition_authority_required, record.legacy_ref}}

      record.accountable_ref in record.disposition_authority_refs ->
        {:error, {:legacy_import_independent_disposition_required, record.legacy_ref}}

      true ->
        {:ok, record}
    end
  end

  defp unique_legacy_refs(records) do
    duplicates =
      records
      |> Enum.group_by(& &1.legacy_ref)
      |> Enum.find(fn {_ref, same_ref} -> length(same_ref) > 1 end)

    case duplicates do
      nil -> :ok
      {ref, _records} -> {:error, {:duplicate_legacy_import_ref, ref}}
    end
  end

  defp validate_principal_bindings(records, principal_refs) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      required =
        if record.status == :terminal,
          do: [],
          else: [record.accountable_ref | record.disposition_authority_refs]

      case Enum.find(required, &(not MapSet.member?(principal_refs, &1))) do
        nil ->
          {:cont, :ok}

        ref ->
          {:halt, {:error, {:legacy_import_principal_not_in_genesis, record.legacy_ref, ref}}}
      end
    end)
  end

  defp build_records(domain_ref, source_ref, imported_at, records) do
    Enum.reduce_while(records, {:ok, %{evidence: [], duties: []}}, fn record, {:ok, prepared} ->
      with {:ok, evidence} <- build_evidence(domain_ref, source_ref, imported_at, record),
           :ok <- validate_import_evidence(domain_ref, evidence),
           {:ok, duty} <- maybe_build_duty(evidence, record, imported_at),
           :ok <- validate_optional_import_duty(domain_ref, evidence, duty) do
        next = %{
          evidence: [evidence | prepared.evidence],
          duties: if(duty, do: [duty | prepared.duties], else: prepared.duties)
        }

        {:cont, {:ok, next}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} ->
        {:ok,
         %{
           evidence: Enum.reverse(prepared.evidence),
           duties: Enum.reverse(prepared.duties)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp build_evidence(domain_ref, source_ref, imported_at, record) do
    with {:ok, label} <- legacy_label(source_ref) do
      Evidence.new(%{
        proposition: import_proposition(record, imported_at),
        stance: :supports,
        issuer_ref: nil,
        source_ref: source_ref,
        provenance: :observed,
        parent_refs: [],
        observed_at: record.recorded_at,
        valid_from: nil,
        valid_until: nil,
        freshness_ms: nil,
        bindings: %{"domain_ref" => domain_ref, "legacy_ref" => record.legacy_ref},
        assumptions: @assumptions,
        labels: [label],
        payload: record.payload,
        payload_ref: record.payload_ref,
        provisional: false
      })
    end
  end

  defp maybe_build_duty(_evidence, %{status: :terminal}, _imported_at), do: {:ok, nil}

  defp maybe_build_duty(evidence, record, imported_at) do
    Duty.new(%{
      cause_key: {:pre_governance_ambiguity, evidence.ref},
      class: :pre_governance_ambiguity,
      act_ref: nil,
      attempt_ref: nil,
      mandate_ref: nil,
      subjects: record.subject_refs,
      accountable: record.accountable_ref,
      evidence_refs: [evidence.ref],
      missing: Duty.pre_governance_missing(),
      containment: Duty.pre_governance_containment(),
      closing_conditions: [],
      disposition_authority_refs: record.disposition_authority_refs,
      conflict_refs: [record.accountable_ref],
      opened_at: imported_at,
      status: :open,
      disposition_act_ref: nil
    })
  end

  defp required_ref(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" ->
        with :ok <- Portable.validate_ref(value, field), do: {:ok, value}

      _missing ->
        {:error, {:missing_legacy_import_field, field}}
    end
  end

  defp required_time(attrs, field) do
    case Map.get(attrs, field) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _missing -> {:error, {:invalid_legacy_import_time, field}}
    end
  end

  defp status(value) when value in @statuses, do: {:ok, value}
  defp status(value), do: {:error, {:invalid_legacy_import_status, value}}

  defp payload_present(attrs) do
    payload = Map.get(attrs, :payload)
    payload_ref = Map.get(attrs, :payload_ref)

    cond do
      is_nil(payload) and is_nil(payload_ref) ->
        {:error, :legacy_import_payload_required}

      not is_nil(payload) and not is_nil(payload_ref) ->
        {:error, :legacy_import_payload_ambiguous}

      not is_nil(payload) ->
        Portable.validate(payload)

      true ->
        Portable.validate_content_ref(payload_ref, :payload, :payload_ref)
    end
  end

  defp import_proposition(record, imported_at) do
    %{
      "contract_ref" => @source_contract,
      "imported_at" => imported_at,
      "legacy_ref" => record.legacy_ref,
      "reported_status" => record.status,
      "source_recorded_at" => record.recorded_at,
      "subject_refs" => record.subject_refs
    }
  end

  defp import_claim(%Evidence{proposition: proposition}) do
    case proposition do
      %{
        "contract_ref" => @source_contract,
        "imported_at" => imported_at,
        "legacy_ref" => legacy_ref,
        "reported_status" => status,
        "source_recorded_at" => recorded_at,
        "subject_refs" => subjects
      }
      when map_size(proposition) == 6 and status in @statuses and is_integer(imported_at) and
             imported_at >= 0 and is_integer(recorded_at) and recorded_at >= 0 and
             recorded_at <= imported_at ->
        with :ok <- Portable.validate_ref(legacy_ref, :legacy_ref),
             {:ok, normalized_subjects} <- Portable.normalize_refs(subjects, :subject_refs),
             true <- normalized_subjects == subjects do
          {:ok,
           %{
             imported_at: imported_at,
             legacy_ref: legacy_ref,
             recorded_at: recorded_at,
             status: status,
             subjects: subjects
           }}
        else
          false -> {:error, :noncanonical_pre_governance_subjects}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_pre_governance_proposition}
    end
  end

  defp exact_evidence_contract(domain_ref, evidence, claim) do
    with {:ok, label} <- legacy_label(evidence.source_ref) do
      valid? =
        evidence.stance == :supports and is_nil(evidence.issuer_ref) and
          evidence.provenance == :observed and evidence.parent_refs == [] and
          evidence.observed_at == claim.recorded_at and is_nil(evidence.valid_from) and
          is_nil(evidence.valid_until) and is_nil(evidence.freshness_ms) and
          evidence.bindings == %{
            "domain_ref" => domain_ref,
            "legacy_ref" => claim.legacy_ref
          } and evidence.assumptions == @assumptions and evidence.labels == [label] and
          evidence.provisional == false

      if valid?, do: :ok, else: {:error, :invalid_pre_governance_evidence_contract}
    end
  end

  defp legacy_label(owner_ref), do: Label.new(%{owner_ref: owner_ref, value: @label})

  defp exact_duty_contract(evidence, duty, claim) do
    valid? =
      duty.class == :pre_governance_ambiguity and
        duty.cause_key == {:pre_governance_ambiguity, evidence.ref} and
        duty.evidence_refs == [evidence.ref] and duty.subjects == claim.subjects and
        duty.conflict_refs == [duty.accountable] and duty.opened_at == claim.imported_at

    if valid?, do: :ok, else: {:error, :invalid_pre_governance_duty_contract}
  end

  defp validate_optional_import_duty(_domain_ref, _evidence, nil), do: :ok

  defp validate_optional_import_duty(domain_ref, evidence, duty),
    do: validate_import_duty(domain_ref, evidence, duty)

  defp import_requires_genesis_batch(false, _genesis_batch?), do: :ok
  defp import_requires_genesis_batch(true, true), do: :ok

  defp import_requires_genesis_batch(true, false),
    do: {:error, :pre_governance_outside_genesis_batch}

  defp genesis_batch_flag(genesis_batch?: value) when is_boolean(value), do: {:ok, value}

  defp genesis_batch_flag(_opts),
    do: {:error, :invalid_pre_governance_import_batch_options}

  defp validate_import_evidence_set(domain_ref, evidence) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      case validate_import_evidence(domain_ref, item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_import_duty_set(domain_ref, evidence, duties) do
    evidence_by_ref = Map.new(evidence, &{&1.ref, &1})

    Enum.reduce_while(duties, :ok, fn duty, :ok ->
      evidence_ref = imported_duty_evidence_ref(duty)

      with %Evidence{} = item <- Map.get(evidence_by_ref, evidence_ref),
           :ok <- validate_import_duty(domain_ref, item, duty) do
        {:cont, :ok}
      else
        nil -> {:halt, {:error, {:pre_governance_duty_evidence_missing, evidence_ref}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp exact_duty_cardinality(evidence, duties) do
    expected =
      evidence
      |> Enum.filter(fn item ->
        case import_status(item) do
          {:ok, status} -> status in @unresolved_statuses
          {:error, _reason} -> false
        end
      end)
      |> Enum.map(& &1.ref)
      |> Enum.sort()

    actual = duties |> Enum.map(&imported_duty_evidence_ref/1) |> Enum.sort()

    if actual == expected,
      do: :ok,
      else: {:error, {:pre_governance_duty_cardinality_mismatch, expected, actual}}
  end

  defp imported_duty_evidence_ref(%Duty{
         cause_key: {:pre_governance_ambiguity, evidence_ref}
       }),
       do: evidence_ref

  defp imported_duty_evidence_ref(_duty), do: nil

  defp not_from_future(recorded_at, imported_at, _legacy_ref) when recorded_at <= imported_at,
    do: :ok

  defp not_from_future(_recorded_at, _imported_at, legacy_ref),
    do: {:error, {:legacy_import_record_from_future, legacy_ref}}

  defp present_ref?(value), do: is_binary(value) and value != ""
end
