defmodule Spectre.Gate.Receipt do
  @moduledoc """
  Content-addressed evidence emitted by one trusted governance checker.

  Receipts bind the immutable proposal, both Definition identities, execution
  closure, evaluation corpus, checker version, profile, result, provenance,
  and validity window. Passing a struct does not grant trust: activation reads
  the receipt back from the configured Definition Store by `Receipt.Ref`.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Gate.Receipt.Ref
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.Data

  @schema_version 1
  @classes CandidateState.gate_classes() ++ [:approval]
  @statuses [:passed, :failed]
  @fields [
    :schema_version,
    :gate_class,
    :candidate_digest,
    :parent_definition_ref,
    :candidate_definition_ref,
    :closure_digest,
    :checker_id,
    :checker_version,
    :evaluation_cases_digest,
    :profile_ref,
    :issued_at,
    :expires_at,
    :status,
    :result_digest,
    :provenance
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            gate_class: nil,
            candidate_digest: nil,
            parent_definition_ref: nil,
            candidate_definition_ref: nil,
            closure_digest: nil,
            checker_id: nil,
            checker_version: nil,
            evaluation_cases_digest: nil,
            profile_ref: nil,
            issued_at: nil,
            expires_at: nil,
            status: nil,
            result_digest: nil,
            provenance: %{}

  @type gate_class :: CandidateState.gate_class() | :approval
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          gate_class: gate_class(),
          candidate_digest: String.t(),
          parent_definition_ref: String.t(),
          candidate_definition_ref: String.t(),
          closure_digest: String.t(),
          checker_id: String.t(),
          checker_version: pos_integer(),
          evaluation_cases_digest: String.t(),
          profile_ref: String.t() | nil,
          issued_at: non_neg_integer(),
          expires_at: non_neg_integer() | nil,
          status: :passed | :failed,
          result_digest: String.t(),
          provenance: map()
        }

  @doc "Builds and validates one gate receipt."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = receipt) do
    receipt |> to_data() |> new()
  rescue
    exception -> {:error, {:invalid_gate_receipt_struct, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:invalid_gate_receipt_struct, kind}}
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_gate_receipt, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         :ok <- validate_schema(value(attrs, :schema_version, @schema_version)),
         {:ok, gate_class} <- enum(value(attrs, :gate_class), @classes, :gate_class),
         :ok <- digest(value(attrs, :candidate_digest), :candidate_digest),
         {:ok, parent_ref} <-
           definition_ref(value(attrs, :parent_definition_ref), :parent_definition_ref),
         {:ok, candidate_ref} <-
           definition_ref(value(attrs, :candidate_definition_ref), :candidate_definition_ref),
         :ok <- digest(value(attrs, :closure_digest), :closure_digest),
         {:ok, checker_id} <- nonempty(value(attrs, :checker_id), :checker_id),
         {:ok, checker_version} <- positive(value(attrs, :checker_version), :checker_version),
         :ok <- digest(value(attrs, :evaluation_cases_digest), :evaluation_cases_digest),
         {:ok, profile_ref} <- optional_binary(value(attrs, :profile_ref), :profile_ref),
         :ok <- require_profile(gate_class, profile_ref),
         {:ok, issued_at} <- non_negative(value(attrs, :issued_at), :issued_at),
         {:ok, expires_at} <- optional_non_negative(value(attrs, :expires_at), :expires_at),
         :ok <- valid_window(issued_at, expires_at),
         {:ok, status} <- enum(value(attrs, :status), @statuses, :status),
         :ok <- digest(value(attrs, :result_digest), :result_digest),
         {:ok, provenance} <- portable_map(value(attrs, :provenance, %{}), :provenance),
         :ok <- require_semantic_live_evidence(gate_class, expires_at, provenance) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         gate_class: gate_class,
         candidate_digest: value(attrs, :candidate_digest),
         parent_definition_ref: parent_ref,
         candidate_definition_ref: candidate_ref,
         closure_digest: value(attrs, :closure_digest),
         checker_id: checker_id,
         checker_version: checker_version,
         evaluation_cases_digest: value(attrs, :evaluation_cases_digest),
         profile_ref: profile_ref,
         issued_at: issued_at,
         expires_at: expires_at,
         status: status,
         result_digest: value(attrs, :result_digest),
         provenance: provenance
       }}
    end
  end

  def new(value), do: {:error, {:invalid_gate_receipt, shape(value)}}

  @doc "Builds a receipt or raises with the stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, receipt} -> receipt
      {:error, reason} -> raise ArgumentError, "invalid gate receipt: #{inspect(reason)}"
    end
  end

  @doc "Returns the receipt's content Ref."
  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{} = receipt), do: Ref.new(receipt)

  @doc "Returns canonical portable receipt data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = receipt) do
    %{
      "schema_version" => receipt.schema_version,
      "gate_class" => Atom.to_string(receipt.gate_class),
      "candidate_digest" => receipt.candidate_digest,
      "parent_definition_ref" => receipt.parent_definition_ref,
      "candidate_definition_ref" => receipt.candidate_definition_ref,
      "closure_digest" => receipt.closure_digest,
      "checker_id" => receipt.checker_id,
      "checker_version" => receipt.checker_version,
      "evaluation_cases_digest" => receipt.evaluation_cases_digest,
      "profile_ref" => receipt.profile_ref,
      "issued_at" => receipt.issued_at,
      "expires_at" => receipt.expires_at,
      "status" => Atom.to_string(receipt.status),
      "result_digest" => receipt.result_digest,
      "provenance" => receipt.provenance
    }
  end

  @doc "Encodes a receipt with the production canonical codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = receipt), do: receipt |> to_data() |> Value.encode()

  @doc "Decodes and revalidates a receipt."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: new(data)
  end

  def decode(value), do: {:error, {:invalid_gate_receipt_binary, shape(value)}}

  @doc "Returns the canonical receipt digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = receipt), do: receipt |> to_data() |> Value.digest!()

  @doc "Verifies receipt binding, freshness, status, and optional checker policy."
  @spec verify(t(), CandidateState.t(), keyword()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = receipt, %CandidateState{} = candidate, opts \\ []) do
    with {:ok, receipt} <- new(receipt),
         {:ok, candidate} <- CandidateState.new(candidate),
         :ok <- verify_binding_validated(receipt, candidate) do
      now = Keyword.get(opts, :now, System.system_time(:millisecond))

      cond do
        receipt.status != :passed ->
          {:error, {:gate_receipt_failed, receipt.gate_class}}

        not is_integer(now) or now < 0 ->
          {:error, {:invalid_gate_verification_time, now}}

        receipt.issued_at > now ->
          {:error, {:gate_receipt_not_yet_valid, receipt.gate_class}}

        not is_nil(receipt.expires_at) and receipt.expires_at <= now ->
          {:error, {:gate_receipt_expired, receipt.gate_class}}

        true ->
          verify_checker(receipt, Keyword.get(opts, :checker_versions, %{}))
      end
    end
  end

  @doc "Verifies immutable proposal binding without interpreting gate outcome."
  @spec verify_binding(t(), CandidateState.t()) :: :ok | {:error, term()}
  def verify_binding(%__MODULE__{} = receipt, %CandidateState{} = candidate) do
    with {:ok, receipt} <- new(receipt),
         {:ok, candidate} <- CandidateState.new(candidate) do
      verify_binding_validated(receipt, candidate)
    end
  end

  defp verify_binding_validated(receipt, candidate) do
    cond do
      receipt.candidate_digest != candidate.proposal_digest ->
        {:error, :gate_receipt_candidate_mismatch}

      receipt.parent_definition_ref != candidate.parent_definition_ref ->
        {:error, :gate_receipt_parent_mismatch}

      receipt.candidate_definition_ref != candidate.candidate_definition_ref ->
        {:error, :gate_receipt_definition_mismatch}

      receipt.closure_digest != candidate.closure_digest ->
        {:error, :gate_receipt_closure_mismatch}

      receipt.evaluation_cases_digest != candidate.evaluation_cases_digest ->
        {:error, :gate_receipt_evaluation_cases_mismatch}

      true ->
        :ok
    end
  end

  defp verify_checker(receipt, versions) when is_map(versions) do
    expected =
      Map.get(versions, receipt.gate_class, Map.get(versions, Atom.to_string(receipt.gate_class)))

    case expected do
      nil ->
        {:error, {:untrusted_gate_checker, receipt.gate_class, receipt.checker_id}}

      {id, version} when id == receipt.checker_id and version == receipt.checker_version ->
        :ok

      %{id: id, version: version}
      when id == receipt.checker_id and version == receipt.checker_version ->
        :ok

      %{"id" => id, "version" => version}
      when id == receipt.checker_id and version == receipt.checker_version ->
        :ok

      _other ->
        {:error, {:gate_checker_mismatch, receipt.gate_class}}
    end
  end

  defp verify_checker(_receipt, value), do: {:error, {:invalid_gate_checker_policy, value}}

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- aliases, collisions} do
      {[], []} -> :ok
      {unknown, []} -> {:error, {:unknown_gate_receipt_fields, Enum.sort_by(unknown, &inspect/1)}}
      {_unknown, collisions} -> {:error, {:ambiguous_gate_receipt_fields, collisions}}
    end
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_gate_receipt_schema, version}}

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_gate_receipt_field, field, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp enum(value, allowed, field) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_gate_receipt_field, field, value}}
  end

  defp definition_ref(value, _field) when is_binary(value) do
    if valid_definition_ref?(value),
      do: {:ok, value},
      else: {:error, {:invalid_gate_definition_ref, value}}
  end

  defp definition_ref(value, field), do: {:error, {:invalid_gate_receipt_field, field, value}}

  defp valid_definition_ref?("sha256:" <> digest),
    do: match?({:ok, <<_::256>>}, Base.decode16(digest, case: :lower))

  defp valid_definition_ref?(_value), do: false

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, <<_::256>>} -> :ok
      :error -> {:error, {:invalid_gate_receipt_digest, value}}
    end
  end

  defp digest(value, field), do: {:error, {:invalid_gate_receipt_digest, field, value}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty(value, field), do: {:error, {:invalid_gate_receipt_field, field, value}}
  defp optional_binary(nil, _field), do: {:ok, nil}
  defp optional_binary(value, field), do: nonempty(value, field)

  defp positive(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(value, field), do: {:error, {:invalid_gate_receipt_field, field, value}}
  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative(value, field), do: {:error, {:invalid_gate_receipt_field, field, value}}
  defp optional_non_negative(nil, _field), do: {:ok, nil}
  defp optional_non_negative(value, field), do: non_negative(value, field)

  defp valid_window(_issued, nil), do: :ok
  defp valid_window(issued, expires) when expires > issued, do: :ok

  defp valid_window(issued, expires),
    do: {:error, {:invalid_gate_receipt_window, issued, expires}}

  defp require_profile(gate, nil) when gate in [:replay, :semantic_live],
    do: {:error, {:gate_receipt_profile_required, gate}}

  defp require_profile(_gate, _profile), do: :ok

  defp require_semantic_live_evidence(:semantic_live, nil, _provenance),
    do: {:error, :semantic_live_receipt_expiry_required}

  defp require_semantic_live_evidence(:semantic_live, _expires_at, provenance) do
    case Map.get(provenance, "variability") do
      %{"sample_count" => sample_count, "measure_digest" => measure_digest}
      when is_integer(sample_count) and sample_count >= 2 ->
        case digest(measure_digest, :variability_measure_digest) do
          :ok -> :ok
          {:error, _reason} -> {:error, :semantic_live_receipt_variability_required}
        end

      _value ->
        {:error, :semantic_live_receipt_variability_required}
    end
  end

  defp require_semantic_live_evidence(_gate, _expires_at, _provenance), do: :ok

  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Data.normalize_map(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:nonportable_gate_receipt_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_gate_receipt_field, field, shape(value)}}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
