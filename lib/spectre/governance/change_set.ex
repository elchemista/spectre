defmodule Spectre.Governance.ChangeSet do
  @moduledoc """
  Immutable, non-executable proposal to derive a Definition from an observed
  Instance Activation.

  A ChangeSet binds the exact Activation receipt, Candidate, Definition,
  authority epoch, and mechanical evidence observed by its author. Composition
  fails when any of those observations is stale; rebasing is always an
  explicit new ChangeSet.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Data
  alias Spectre.Instance.Activation

  @schema_version 1
  @max_operations 256
  @fields [
    :schema_version,
    :base_activation_receipt,
    :base_candidate_ref,
    :observed_definition_ref,
    :observed_authority_epoch,
    :observed_evidence_digest,
    :operations,
    :author_ref,
    :provenance,
    :reason,
    :created_at
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            base_activation_receipt: nil,
            base_candidate_ref: nil,
            observed_definition_ref: nil,
            observed_authority_epoch: nil,
            observed_evidence_digest: nil,
            operations: [],
            author_ref: nil,
            provenance: %{},
            reason: nil,
            created_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          base_activation_receipt: String.t(),
          base_candidate_ref: CandidateRef.t(),
          observed_definition_ref: DefinitionRef.t(),
          observed_authority_epoch: non_neg_integer(),
          observed_evidence_digest: String.t(),
          operations: [Operation.t()],
          author_ref: String.t(),
          provenance: map(),
          reason: String.t(),
          created_at: non_neg_integer()
        }

  @doc "Returns the ChangeSet schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and verifies a ChangeSet from host or decoded JSON-shaped data."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = change_set) do
    change_set |> to_data() |> new()
  rescue
    exception -> {:error, {:invalid_governance_change_set_struct, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:invalid_governance_change_set_struct, kind}}
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_governance_change_set, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         :ok <- validate_schema(value(attrs, :schema_version, @schema_version)),
         {:ok, activation_receipt} <-
           nonempty(value(attrs, :base_activation_receipt), :base_activation_receipt),
         {:ok, candidate_ref} <- candidate_ref(value(attrs, :base_candidate_ref)),
         {:ok, definition_ref} <- definition_ref(attrs),
         {:ok, authority_epoch} <-
           non_negative(value(attrs, :observed_authority_epoch), :observed_authority_epoch),
         :ok <-
           validate_digest(value(attrs, :observed_evidence_digest), :observed_evidence_digest),
         {:ok, operations} <- operations(value(attrs, :operations)),
         {:ok, author_ref} <- nonempty(value(attrs, :author_ref), :author_ref),
         {:ok, provenance} <- portable_map(value(attrs, :provenance, %{}), :provenance),
         {:ok, reason} <- nonempty(value(attrs, :reason), :reason),
         {:ok, created_at} <- non_negative(value(attrs, :created_at), :created_at) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         base_activation_receipt: activation_receipt,
         base_candidate_ref: candidate_ref,
         observed_definition_ref: definition_ref,
         observed_authority_epoch: authority_epoch,
         observed_evidence_digest: value(attrs, :observed_evidence_digest),
         operations: operations,
         author_ref: author_ref,
         provenance: provenance,
         reason: reason,
         created_at: created_at
       }}
    end
  end

  def new(value), do: {:error, {:invalid_governance_change_set, shape(value)}}

  @doc "Builds a ChangeSet or raises with the stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, change_set} -> change_set
      {:error, reason} -> raise ArgumentError, "invalid governance ChangeSet: #{inspect(reason)}"
    end
  end

  @doc "Returns canonical portable ChangeSet data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = change_set) do
    %{
      "schema_version" => change_set.schema_version,
      "base_activation_receipt" => change_set.base_activation_receipt,
      "base_candidate_ref" => CandidateRef.to_string(change_set.base_candidate_ref),
      "observed_definition_ref" => DefinitionRef.to_string(change_set.observed_definition_ref),
      "observed_definition_canonicalization_version" =>
        change_set.observed_definition_ref.canonicalization_version,
      "observed_definition_contract_version" =>
        change_set.observed_definition_ref.contract_version,
      "observed_authority_epoch" => change_set.observed_authority_epoch,
      "observed_evidence_digest" => change_set.observed_evidence_digest,
      "operations" => Enum.map(change_set.operations, &Operation.to_data/1),
      "author_ref" => change_set.author_ref,
      "provenance" => change_set.provenance,
      "reason" => change_set.reason,
      "created_at" => change_set.created_at
    }
  end

  @doc "Restores a ChangeSet from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Encodes a ChangeSet with the production canonical codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = change_set), do: change_set |> to_data() |> Value.encode()

  @doc "Decodes and revalidates a ChangeSet."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_governance_change_set_binary, shape(value)}}

  @doc "Returns the stable ChangeSet digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = change_set), do: change_set |> to_data() |> Value.digest!()

  @doc "Derives the mechanical evidence digest used for stale-base detection."
  @spec evidence_digest(Activation.t()) :: String.t()
  def evidence_digest(%Activation{} = activation),
    do: activation |> Activation.to_data() |> Value.digest!()

  @doc "Checks that this proposal still describes the supplied Activation."
  @spec verify_base(t(), Activation.t() | nil) :: :ok | {:error, term()}
  def verify_base(%__MODULE__{}, nil), do: {:error, :governance_change_set_requires_activation}

  def verify_base(%__MODULE__{} = change_set, %Activation{} = activation) do
    cond do
      change_set.base_activation_receipt != activation.activation_receipt ->
        {:error, :stale_governance_activation_receipt}

      change_set.base_candidate_ref != activation.candidate_ref ->
        {:error, :stale_governance_candidate_ref}

      change_set.observed_definition_ref != activation.definition_ref ->
        {:error, :stale_governance_definition_ref}

      change_set.observed_authority_epoch != activation.authority_epoch ->
        {:error, :stale_governance_authority_epoch}

      change_set.observed_evidence_digest != evidence_digest(activation) ->
        {:error, :stale_governance_evidence_digest}

      true ->
        :ok
    end
  end

  @spec exact_fields(map()) :: :ok | {:error, term()}
  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    ref_versions = [
      "observed_definition_canonicalization_version",
      "observed_definition_contract_version"
    ]

    case {Map.keys(attrs) -- (aliases ++ ref_versions), collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_governance_change_set_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_governance_change_set_fields, collisions}}
    end
  end

  defp validate_schema(@schema_version), do: :ok

  defp validate_schema(version),
    do: {:error, {:unsupported_governance_change_set_schema, version}}

  defp candidate_ref(%CandidateRef{} = ref) do
    if CandidateRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_governance_base_candidate_ref, ref}}
  end

  defp candidate_ref(value) when is_binary(value), do: CandidateRef.parse(value)
  defp candidate_ref(value), do: {:error, {:invalid_governance_base_candidate_ref, value}}

  defp definition_ref(attrs) do
    case value(attrs, :observed_definition_ref) do
      %DefinitionRef{} = ref ->
        if DefinitionRef.valid?(ref),
          do: {:ok, ref},
          else: {:error, {:invalid_governance_observed_definition_ref, ref}}

      ref when is_binary(ref) ->
        DefinitionRef.parse(ref,
          canonicalization_version:
            Map.get(attrs, "observed_definition_canonicalization_version", 1),
          contract_version: Map.get(attrs, "observed_definition_contract_version", 1)
        )

      ref ->
        {:error, {:invalid_governance_observed_definition_ref, ref}}
    end
  end

  defp operations(values)
       when is_list(values) and values != [] and length(values) <= @max_operations do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, normalized} ->
      case Operation.new(value) do
        {:ok, operation} -> {:cont, {:ok, [operation | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_governance_operation, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp operations(values) when is_list(values) and length(values) > @max_operations,
    do: {:error, {:governance_operation_limit_exceeded, length(values), @max_operations}}

  defp operations(value), do: {:error, {:invalid_governance_operations, shape(value)}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty(value, field), do: {:error, {:invalid_governance_change_set_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative(value, field),
    do: {:error, {:invalid_governance_change_set_field, field, value}}

  defp validate_digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :mixed) do
      {:ok, <<_::256>>} -> :ok
      :error -> {:error, {:invalid_governance_change_set_digest, value}}
    end
  end

  defp validate_digest(value, field),
    do: {:error, {:invalid_governance_change_set_digest, field, value}}

  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Data.normalize_map(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:nonportable_governance_change_set_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_governance_change_set_field, field, shape(value)}}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
