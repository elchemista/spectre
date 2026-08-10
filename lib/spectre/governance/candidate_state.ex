defmodule Spectre.Governance.CandidateState do
  @moduledoc """
  Immutable governance state attached to a Definition Candidate.

  `proposal_digest` identifies the fixed proposal independently from later
  gate and approval receipts. Advancing the state creates a new outer
  `Candidate.Ref`, while every receipt remains bound to the same proposal.
  This avoids circular receipt identities without weakening content addressing.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Eval.Case
  alias Spectre.Governance.Data

  @schema_version 1
  @max_candidate_cases 10_000
  @max_state_migrations 10_000
  @max_gate_receipts 10
  @max_lineage_refs 10_000
  @states [:composed, :evaluated, :approved, :rejected]
  @risks [:low, :medium, :high, :critical]
  @gate_classes [
    :structural,
    :authority,
    :closure,
    :prompt_budget,
    :applicability,
    :replay,
    :regression,
    :semantic_live,
    :evaluation_delta
  ]
  @fields [
    :schema_version,
    :proposal_digest,
    :change_set_digest,
    :base_activation_receipt,
    :base_candidate_ref,
    :parent_definition_ref,
    :candidate_definition_ref,
    :observed_authority_epoch,
    :observed_evidence_digest,
    :closure_digest,
    :evaluation_cases_digest,
    :candidate_cases,
    :candidate_case_ids,
    :state_migrations,
    :risk,
    :required_gates,
    :state,
    :gate_receipt_refs,
    :approval_receipt_ref,
    :report_digest,
    :lineage_refs
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            proposal_digest: nil,
            change_set_digest: nil,
            base_activation_receipt: nil,
            base_candidate_ref: nil,
            parent_definition_ref: nil,
            candidate_definition_ref: nil,
            observed_authority_epoch: nil,
            observed_evidence_digest: nil,
            closure_digest: nil,
            evaluation_cases_digest: nil,
            candidate_cases: [],
            candidate_case_ids: [],
            state_migrations: [],
            risk: nil,
            required_gates: [],
            state: nil,
            gate_receipt_refs: [],
            approval_receipt_ref: nil,
            report_digest: nil,
            lineage_refs: []

  @type gate_class ::
          :structural
          | :authority
          | :closure
          | :prompt_budget
          | :applicability
          | :replay
          | :regression
          | :semantic_live
          | :evaluation_delta
  @type state :: :composed | :evaluated | :approved | :rejected
  @type risk :: :low | :medium | :high | :critical
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          proposal_digest: String.t(),
          change_set_digest: String.t(),
          base_activation_receipt: String.t(),
          base_candidate_ref: String.t(),
          parent_definition_ref: String.t(),
          candidate_definition_ref: String.t(),
          observed_authority_epoch: non_neg_integer(),
          observed_evidence_digest: String.t(),
          closure_digest: String.t(),
          evaluation_cases_digest: String.t(),
          candidate_cases: [map()],
          candidate_case_ids: [String.t()],
          state_migrations: [map()],
          risk: risk(),
          required_gates: [gate_class()],
          state: state(),
          gate_receipt_refs: [String.t()],
          approval_receipt_ref: String.t() | nil,
          report_digest: String.t() | nil,
          lineage_refs: [String.t()]
        }

  @doc "Returns the governance Candidate-state schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the supported non-approval gate classes."
  @spec gate_classes() :: [gate_class()]
  def gate_classes, do: @gate_classes

  @doc "Builds and verifies a Candidate governance state."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = state) do
    state |> to_data() |> new()
  rescue
    exception -> {:error, {:invalid_governance_candidate_state_struct, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:invalid_governance_candidate_state_struct, kind}}
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_governance_candidate_state, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         :ok <- validate_schema(value(attrs, :schema_version, @schema_version)),
         :ok <- digest(value(attrs, :change_set_digest), :change_set_digest),
         {:ok, base_activation} <-
           nonempty(value(attrs, :base_activation_receipt), :base_activation_receipt),
         {:ok, base_candidate} <-
           ref(value(attrs, :base_candidate_ref), "candidate:sha256:", :base_candidate_ref),
         {:ok, parent_definition} <-
           ref(value(attrs, :parent_definition_ref), "sha256:", :parent_definition_ref),
         {:ok, candidate_definition} <-
           ref(value(attrs, :candidate_definition_ref), "sha256:", :candidate_definition_ref),
         {:ok, epoch} <-
           non_negative(value(attrs, :observed_authority_epoch), :observed_authority_epoch),
         :ok <- digest(value(attrs, :observed_evidence_digest), :observed_evidence_digest),
         :ok <- digest(value(attrs, :closure_digest), :closure_digest),
         :ok <- digest(value(attrs, :evaluation_cases_digest), :evaluation_cases_digest),
         {:ok, candidate_case_data} <- candidate_cases(value(attrs, :candidate_cases, [])),
         {:ok, candidate_case_ids} <-
           string_list(value(attrs, :candidate_case_ids, []), :candidate_case_ids),
         :ok <- validate_candidate_case_ids(candidate_case_ids, candidate_case_data),
         {:ok, state_migrations} <- state_migrations(value(attrs, :state_migrations, [])),
         {:ok, risk} <- enum(value(attrs, :risk), @risks, :risk),
         {:ok, required_gates} <- gate_list(value(attrs, :required_gates)),
         {:ok, state} <- enum(value(attrs, :state, :composed), @states, :state),
         {:ok, gate_refs} <-
           refs(
             value(attrs, :gate_receipt_refs, []),
             "gate:sha256:",
             :gate_receipt_refs,
             @max_gate_receipts
           ),
         {:ok, approval_ref} <-
           optional_ref(
             value(attrs, :approval_receipt_ref),
             "gate:sha256:",
             :approval_receipt_ref
           ),
         :ok <- optional_digest(value(attrs, :report_digest), :report_digest),
         {:ok, lineage_refs} <-
           refs(
             value(attrs, :lineage_refs, []),
             "candidate:sha256:",
             :lineage_refs,
             @max_lineage_refs
           ) do
      data = %{
        schema_version: @schema_version,
        change_set_digest: value(attrs, :change_set_digest),
        base_activation_receipt: base_activation,
        base_candidate_ref: base_candidate,
        parent_definition_ref: parent_definition,
        candidate_definition_ref: candidate_definition,
        observed_authority_epoch: epoch,
        observed_evidence_digest: value(attrs, :observed_evidence_digest),
        closure_digest: value(attrs, :closure_digest),
        evaluation_cases_digest: value(attrs, :evaluation_cases_digest),
        candidate_cases: candidate_case_data,
        candidate_case_ids: candidate_case_ids,
        state_migrations: state_migrations,
        risk: risk,
        required_gates: required_gates,
        state: state,
        gate_receipt_refs: gate_refs,
        approval_receipt_ref: approval_ref,
        report_digest: value(attrs, :report_digest),
        lineage_refs: lineage_refs
      }

      expected = proposal_digest(data)

      case value(attrs, :proposal_digest, expected) do
        ^expected -> {:ok, struct!(__MODULE__, Map.put(data, :proposal_digest, expected))}
        supplied -> {:error, {:governance_candidate_proposal_digest_mismatch, supplied, expected}}
      end
    end
  end

  def new(value), do: {:error, {:invalid_governance_candidate_state, shape(value)}}

  @doc "Builds governance state or raises with the stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, state} ->
        state

      {:error, reason} ->
        raise ArgumentError, "invalid governance Candidate state: #{inspect(reason)}"
    end
  end

  @doc "Advances mutable review state while preserving the proposal digest."
  @spec transition(t(), state(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = current, next, opts \\ []) when is_list(opts) do
    with :ok <- allowed_transition(current.state, next) do
      current
      |> Map.from_struct()
      |> Map.put(:state, next)
      |> Map.put(
        :gate_receipt_refs,
        Keyword.get(opts, :gate_receipt_refs, current.gate_receipt_refs)
      )
      |> Map.put(
        :approval_receipt_ref,
        Keyword.get(opts, :approval_receipt_ref, current.approval_receipt_ref)
      )
      |> Map.put(:report_digest, Keyword.get(opts, :report_digest, current.report_digest))
      |> Map.put(:lineage_refs, Keyword.get(opts, :lineage_refs, current.lineage_refs))
      |> new()
    end
  end

  @doc "Returns portable governance state data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = state) do
    %{
      "schema_version" => state.schema_version,
      "proposal_digest" => state.proposal_digest,
      "change_set_digest" => state.change_set_digest,
      "base_activation_receipt" => state.base_activation_receipt,
      "base_candidate_ref" => state.base_candidate_ref,
      "parent_definition_ref" => state.parent_definition_ref,
      "candidate_definition_ref" => state.candidate_definition_ref,
      "observed_authority_epoch" => state.observed_authority_epoch,
      "observed_evidence_digest" => state.observed_evidence_digest,
      "closure_digest" => state.closure_digest,
      "evaluation_cases_digest" => state.evaluation_cases_digest,
      "candidate_cases" => state.candidate_cases,
      "candidate_case_ids" => state.candidate_case_ids,
      "state_migrations" => state.state_migrations,
      "risk" => Atom.to_string(state.risk),
      "required_gates" => Enum.map(state.required_gates, &Atom.to_string/1),
      "state" => Atom.to_string(state.state),
      "gate_receipt_refs" => state.gate_receipt_refs,
      "approval_receipt_ref" => state.approval_receipt_ref,
      "report_digest" => state.report_digest,
      "lineage_refs" => state.lineage_refs
    }
  end

  @doc "Returns the immutable proposal digest from normalized core fields."
  @spec proposal_digest(t() | map()) :: String.t()
  def proposal_digest(%__MODULE__{} = state), do: state |> Map.from_struct() |> proposal_digest()

  def proposal_digest(attrs) when is_map(attrs) do
    %{
      "schema_version" => value(attrs, :schema_version, @schema_version),
      "change_set_digest" => value(attrs, :change_set_digest),
      "base_activation_receipt" => value(attrs, :base_activation_receipt),
      "base_candidate_ref" => value(attrs, :base_candidate_ref),
      "parent_definition_ref" => value(attrs, :parent_definition_ref),
      "candidate_definition_ref" => value(attrs, :candidate_definition_ref),
      "observed_authority_epoch" => value(attrs, :observed_authority_epoch),
      "observed_evidence_digest" => value(attrs, :observed_evidence_digest),
      "closure_digest" => value(attrs, :closure_digest),
      "evaluation_cases_digest" => value(attrs, :evaluation_cases_digest),
      "candidate_cases" => value(attrs, :candidate_cases, []),
      "candidate_case_ids" => value(attrs, :candidate_case_ids, []),
      "state_migrations" => value(attrs, :state_migrations, []),
      "risk" => attrs |> value(:risk) |> enum_string(),
      "required_gates" => attrs |> value(:required_gates, []) |> Enum.map(&enum_string/1)
    }
    |> Value.digest!()
  end

  defp allowed_transition(:composed, next) when next in [:evaluated, :rejected], do: :ok
  defp allowed_transition(:evaluated, :approved), do: :ok
  defp allowed_transition(state, state), do: :ok

  defp allowed_transition(current, next),
    do: {:error, {:invalid_governance_candidate_transition, current, next}}

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- aliases, collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_governance_candidate_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_governance_candidate_fields, collisions}}
    end
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_governance_candidate_schema, version}}

  defp gate_list(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, gates} ->
      case enum(value, @gate_classes, :required_gates) do
        {:ok, gate} -> {:cont, {:ok, [gate | gates]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, gates} -> {:ok, gates |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end)
  end

  defp gate_list(value),
    do: {:error, {:invalid_governance_candidate_field, :required_gates, value}}

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_governance_candidate_field, field, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp enum(value, allowed, field) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_governance_candidate_field, field, value}}
  end

  defp enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp enum_string(value), do: value

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, <<_::256>>} -> :ok
      :error -> {:error, {:invalid_governance_candidate_digest, value}}
    end
  end

  defp digest(value, field), do: {:error, {:invalid_governance_candidate_digest, field, value}}
  defp optional_digest(nil, _field), do: :ok
  defp optional_digest(value, field), do: digest(value, field)

  defp nonempty(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty(value, field), do: {:error, {:invalid_governance_candidate_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative(value, field),
    do: {:error, {:invalid_governance_candidate_field, field, value}}

  defp string_list(values, _field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_governance_candidate_string_list}
  end

  defp string_list(value, field),
    do: {:error, {:invalid_governance_candidate_field, field, value}}

  defp candidate_cases(values) when is_list(values) and length(values) <= @max_candidate_cases do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {value, index}, {:ok, normalized} when is_map(value) and not is_struct(value) ->
        with {:ok, normalized_value} <- Data.normalize_map(value),
             {:ok, evaluation_case} <- Case.new(normalized_value),
             canonical = case_data(evaluation_case),
             true <- canonical == normalized_value do
          {:cont, {:ok, [canonical | normalized]}}
        else
          false ->
            {:halt, {:error, {:noncanonical_governance_candidate_case, index}}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_governance_candidate_case, index, reason}}}
        end

      {_value, index}, _acc ->
        {:halt, {:error, {:invalid_governance_candidate_case, index}}}
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp candidate_cases(values) when is_list(values),
    do: {:error, {:governance_candidate_case_limit_exceeded, length(values)}}

  defp candidate_cases(value),
    do: {:error, {:invalid_governance_candidate_field, :candidate_cases, value}}

  defp case_data(evaluation_case) do
    %{
      "id" => evaluation_case.id,
      "input" => evaluation_case.input,
      "expected_route" => evaluation_case.expected_route,
      "expected_strategy" => evaluation_case.expected_strategy,
      "expected_outcome" => Atom.to_string(evaluation_case.expected_outcome),
      "allowed_routes" => evaluation_case.allowed_routes,
      "llm" => Atom.to_string(evaluation_case.llm),
      "state" => evaluation_case.state,
      "tags" => evaluation_case.tags,
      "max_duration_us" => evaluation_case.max_duration_us
    }
  end

  defp state_migrations(values)
       when is_list(values) and length(values) <= @max_state_migrations do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"skill_id" => skill_id, "migration_ref" => migration_ref} = migration, _index},
      {:ok, normalized}
      when map_size(migration) == 2 and is_binary(skill_id) and skill_id != "" and
             is_binary(migration_ref) and migration_ref != "" ->
        cond do
          String.starts_with?(migration_ref, "Elixir.") ->
            {:halt, {:error, :governance_state_migration_code_reference_forbidden}}

          Enum.any?(normalized, &(&1["skill_id"] == skill_id)) ->
            {:halt, {:error, {:duplicate_governance_state_migration, skill_id}}}

          true ->
            {:cont, {:ok, [migration | normalized]}}
        end

      {_value, index}, _acc ->
        {:halt, {:error, {:invalid_governance_state_migration, index}}}
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp state_migrations(values) when is_list(values),
    do: {:error, {:governance_state_migration_limit_exceeded, length(values)}}

  defp state_migrations(value),
    do: {:error, {:invalid_governance_candidate_field, :state_migrations, value}}

  defp validate_candidate_case_ids(ids, cases) do
    actual =
      cases
      |> Enum.map(&Map.get(&1, "id", Map.get(&1, :id)))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      length(actual) != length(cases) -> {:error, :invalid_governance_candidate_case_ids}
      ids != actual -> {:error, {:governance_candidate_case_ids_mismatch, ids, actual}}
      true -> :ok
    end
  end

  defp refs(values, prefix, field, limit) when is_list(values) and length(values) <= limit do
    with {:ok, values} <- string_list(values, field),
         true <- Enum.all?(values, &valid_ref?(&1, prefix)) do
      {:ok, values}
    else
      false -> {:error, {:invalid_governance_candidate_refs, field}}
      {:error, _reason} = error -> error
    end
  end

  defp refs(values, _prefix, field, limit) when is_list(values),
    do: {:error, {:governance_candidate_ref_limit_exceeded, field, length(values), limit}}

  defp refs(value, _prefix, field, _limit),
    do: {:error, {:invalid_governance_candidate_field, field, value}}

  defp ref(value, prefix, _field) when is_binary(value) do
    if valid_ref?(value, prefix),
      do: {:ok, value},
      else: {:error, {:invalid_governance_candidate_ref, value}}
  end

  defp ref(value, _prefix, field),
    do: {:error, {:invalid_governance_candidate_field, field, value}}

  defp optional_ref(nil, _prefix, _field), do: {:ok, nil}
  defp optional_ref(value, prefix, field), do: ref(value, prefix, field)

  defp valid_ref?(value, prefix) do
    case String.split_at(value, byte_size(prefix)) do
      {^prefix, digest} -> match?({:ok, <<_::256>>}, Base.decode16(digest, case: :mixed))
      _other -> false
    end
  end

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
