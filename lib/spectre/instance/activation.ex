defmodule Spectre.Instance.Activation do
  @moduledoc """
  Canonical snapshot binding one Instance to an active Definition.

  Activation is mutable only through generation-fenced compare-and-swap. The
  snapshot records the Candidate and publication that were re-read from a
  trusted Definition Store, the observed authority epoch, execution closure,
  state bindings, owner fencing token, timestamp, and provenance.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Execution.Closure

  @schema_version 1

  @enforce_keys [
    :schema_version,
    :definition_ref,
    :candidate_ref,
    :manifest_digest,
    :publication_id,
    :closure_digest,
    :state_bindings,
    :generation,
    :authority_epoch,
    :owner_fencing_token,
    :activation_receipt,
    :activated_at,
    :provenance
  ]
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            candidate_ref: nil,
            manifest_digest: nil,
            publication_id: nil,
            closure_digest: nil,
            state_bindings: %{},
            generation: nil,
            authority_epoch: nil,
            owner_fencing_token: nil,
            activation_receipt: nil,
            activated_at: nil,
            provenance: %{}

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: DefinitionRef.t(),
          candidate_ref: CandidateRef.t(),
          manifest_digest: String.t(),
          publication_id: String.t(),
          closure_digest: String.t(),
          state_bindings: map(),
          generation: pos_integer(),
          authority_epoch: non_neg_integer(),
          owner_fencing_token: pos_integer(),
          activation_receipt: String.t(),
          activated_at: non_neg_integer(),
          provenance: map()
        }

  @doc "Returns the Activation snapshot schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds a prospective Activation from a Candidate and verified resolution.

  This function does not commit the snapshot. Callers must pass it through
  `compare_and_swap/3` on the Instance sequencer.
  """
  @spec new(Candidate.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(
        %Candidate{} = candidate,
        %{
          definition_ref: definition_ref,
          manifest: manifest,
          publication_receipt: receipt
        } = resolution,
        opts
      )
      when is_list(opts) do
    provenance =
      opts
      |> Keyword.get(:provenance, %{})
      |> Map.put(
        :build_evidence,
        Map.get(resolution, :drift, %{status: :unobserved, drifts: [], observed_builds: %{}})
      )

    attrs = %{
      schema_version: @schema_version,
      definition_ref: definition_ref,
      candidate_ref: Candidate.ref(candidate),
      manifest_digest: Manifest.digest(manifest),
      publication_id: Map.get(receipt, :publication_id),
      closure_digest: Closure.digest(manifest.execution_closure),
      state_bindings: Keyword.get(opts, :state_bindings, %{}),
      generation: Keyword.get(opts, :generation),
      authority_epoch: Keyword.get(opts, :authority_epoch, 0),
      owner_fencing_token: Keyword.get(opts, :owner_fencing_token),
      activated_at: Keyword.get(opts, :activated_at, System.system_time(:millisecond)),
      provenance: provenance
    }

    with :ok <- verify_candidate(candidate, attrs), do: build(attrs)
  end

  def new(candidate, resolution, _opts),
    do: {:error, {:invalid_activation_input, shape(candidate), shape(resolution)}}

  @doc "Builds and validates an Activation from normalized attributes."
  @spec build(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_list(attrs), do: attrs |> Map.new() |> build()

  def build(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, definition_ref} <- normalize_definition_ref(Map.get(attrs, :definition_ref)),
         {:ok, candidate_ref} <- normalize_candidate_ref(Map.get(attrs, :candidate_ref)),
         :ok <- validate_digest(Map.get(attrs, :manifest_digest), :manifest_digest),
         :ok <- validate_binary(Map.get(attrs, :publication_id), :publication_id),
         :ok <- validate_digest(Map.get(attrs, :closure_digest), :closure_digest),
         :ok <- validate_portable_map(Map.get(attrs, :state_bindings, %{}), :state_bindings),
         :ok <- validate_positive(Map.get(attrs, :generation), :generation),
         :ok <- validate_non_negative(Map.get(attrs, :authority_epoch, 0), :authority_epoch),
         :ok <-
           validate_positive(Map.get(attrs, :owner_fencing_token), :owner_fencing_token),
         :ok <- validate_non_negative(Map.get(attrs, :activated_at), :activated_at),
         :ok <- validate_portable_map(Map.get(attrs, :provenance, %{}), :provenance) do
      base = %{
        schema_version: @schema_version,
        definition_ref: definition_ref,
        candidate_ref: candidate_ref,
        manifest_digest: Map.fetch!(attrs, :manifest_digest),
        publication_id: Map.fetch!(attrs, :publication_id),
        closure_digest: Map.fetch!(attrs, :closure_digest),
        state_bindings: Map.get(attrs, :state_bindings, %{}),
        generation: Map.fetch!(attrs, :generation),
        authority_epoch: Map.get(attrs, :authority_epoch, 0),
        owner_fencing_token: Map.fetch!(attrs, :owner_fencing_token),
        activated_at: Map.fetch!(attrs, :activated_at),
        provenance: Map.get(attrs, :provenance, %{})
      }

      receipt = activation_receipt(base)

      case Map.get(attrs, :activation_receipt, receipt) do
        ^receipt -> {:ok, struct!(__MODULE__, Map.put(base, :activation_receipt, receipt))}
        supplied -> {:error, {:activation_receipt_mismatch, supplied, receipt}}
      end
    end
  end

  def build(value), do: {:error, {:invalid_instance_activation, shape(value)}}

  @doc """
  Applies an activation generation compare-and-swap.

  `expected_generation` is `0` before the first activation. Authority epochs
  may stay equal or increase; they can never move backwards.
  """
  @spec compare_and_swap(t() | nil, non_neg_integer(), t()) ::
          {:ok, t()} | {:error, term()}
  def compare_and_swap(current, expected_generation, %__MODULE__{} = next)
      when is_integer(expected_generation) and expected_generation >= 0 do
    current_generation = generation(current)
    current_epoch = authority_epoch(current)
    current_fencing_token = owner_fencing_token(current)

    cond do
      current_generation != expected_generation ->
        {:error, {:stale_activation_generation, expected_generation, current_generation}}

      next.generation != current_generation + 1 ->
        {:error, {:invalid_activation_generation, next.generation, current_generation + 1}}

      next.authority_epoch < current_epoch ->
        {:error, {:stale_authority_epoch, next.authority_epoch, current_epoch}}

      next.owner_fencing_token < current_fencing_token ->
        {:error, {:stale_owner_fencing_token, next.owner_fencing_token, current_fencing_token}}

      true ->
        with {:ok, ^next} <- build(Map.from_struct(next)), do: {:ok, next}
    end
  end

  def compare_and_swap(_current, expected_generation, _next),
    do: {:error, {:invalid_activation_compare_and_swap, expected_generation}}

  @doc "Returns `0` when no Activation exists."
  @spec generation(t() | nil) :: non_neg_integer()
  def generation(nil), do: 0
  def generation(%__MODULE__{generation: generation}), do: generation

  @doc "Returns `0` when no Activation exists."
  @spec authority_epoch(t() | nil) :: non_neg_integer()
  def authority_epoch(nil), do: 0
  def authority_epoch(%__MODULE__{authority_epoch: epoch}), do: epoch

  defp owner_fencing_token(nil), do: 0
  defp owner_fencing_token(%__MODULE__{owner_fencing_token: token}), do: token

  @doc "Returns portable canonical data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = activation) do
    %{
      "schema_version" => activation.schema_version,
      "definition_ref" => DefinitionRef.to_string(activation.definition_ref),
      "definition_canonicalization_version" => activation.definition_ref.canonicalization_version,
      "definition_contract_version" => activation.definition_ref.contract_version,
      "candidate_ref" => CandidateRef.to_string(activation.candidate_ref),
      "manifest_digest" => activation.manifest_digest,
      "publication_id" => activation.publication_id,
      "closure_digest" => activation.closure_digest,
      "state_bindings" => activation.state_bindings,
      "generation" => activation.generation,
      "authority_epoch" => activation.authority_epoch,
      "owner_fencing_token" => activation.owner_fencing_token,
      "activation_receipt" => activation.activation_receipt,
      "activated_at" => activation.activated_at,
      "provenance" => activation.provenance
    }
  end

  @doc "Restores and verifies an Activation from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "schema_version" => schema_version,
        "definition_ref" => definition_ref,
        "definition_canonicalization_version" => canonicalization_version,
        "definition_contract_version" => contract_version,
        "candidate_ref" => candidate_ref,
        "manifest_digest" => manifest_digest,
        "publication_id" => publication_id,
        "closure_digest" => closure_digest,
        "state_bindings" => state_bindings,
        "generation" => generation,
        "authority_epoch" => authority_epoch,
        "owner_fencing_token" => owner_fencing_token,
        "activation_receipt" => activation_receipt,
        "activated_at" => activated_at,
        "provenance" => provenance
      }) do
    with {:ok, definition_ref} <-
           DefinitionRef.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         {:ok, candidate_ref} <- CandidateRef.parse(candidate_ref) do
      build(%{
        schema_version: schema_version,
        definition_ref: definition_ref,
        candidate_ref: candidate_ref,
        manifest_digest: manifest_digest,
        publication_id: publication_id,
        closure_digest: closure_digest,
        state_bindings: state_bindings,
        generation: generation,
        authority_epoch: authority_epoch,
        owner_fencing_token: owner_fencing_token,
        activation_receipt: activation_receipt,
        activated_at: activated_at,
        provenance: provenance
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_instance_activation_data, shape(value)}}

  @doc "Encodes the Activation into portable canonical bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = activation), do: activation |> to_data() |> Value.encode()

  @doc "Decodes and verifies portable Activation bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_instance_activation_binary, shape(value)}}

  @spec verify_candidate(Candidate.t(), map()) :: :ok | {:error, term()}
  defp verify_candidate(candidate, attrs) do
    cond do
      candidate.definition_ref != attrs.definition_ref ->
        {:error, :activation_candidate_definition_mismatch}

      candidate.manifest_digest != attrs.manifest_digest ->
        {:error, :activation_candidate_manifest_mismatch}

      candidate.publication_id != attrs.publication_id ->
        {:error, :activation_candidate_publication_mismatch}

      true ->
        :ok
    end
  end

  @spec activation_receipt(map()) :: String.t()
  defp activation_receipt(base) do
    data =
      base
      |> Map.put(:definition_ref, DefinitionRef.to_string(base.definition_ref))
      |> Map.put(:candidate_ref, CandidateRef.to_string(base.candidate_ref))

    "activation:sha256:" <> Value.digest!(data)
  end

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = [
      :schema_version,
      :definition_ref,
      :candidate_ref,
      :manifest_digest,
      :publication_id,
      :closure_digest,
      :state_bindings,
      :generation,
      :authority_epoch,
      :owner_fencing_token,
      :activation_receipt,
      :activated_at,
      :provenance
    ]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_instance_activation_fields, Enum.sort(unknown)}}
    end
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_instance_activation_schema, version}}

  defp normalize_definition_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, :invalid_activation_definition_ref}
  end

  defp normalize_definition_ref(value) when is_binary(value), do: DefinitionRef.parse(value)
  defp normalize_definition_ref(_value), do: {:error, :invalid_activation_definition_ref}

  defp normalize_candidate_ref(%CandidateRef{} = ref) do
    if CandidateRef.valid?(ref), do: {:ok, ref}, else: {:error, :invalid_activation_candidate_ref}
  end

  defp normalize_candidate_ref(value) when is_binary(value), do: CandidateRef.parse(value)
  defp normalize_candidate_ref(_value), do: {:error, :invalid_activation_candidate_ref}

  defp validate_digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, <<_::256>>} -> :ok
      :error -> {:error, :invalid_activation_digest}
    end
  end

  defp validate_digest(value, field), do: {:error, {:invalid_activation_digest, field, value}}

  defp validate_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_binary(value, field), do: {:error, {:invalid_activation_field, field, value}}

  defp validate_portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_activation_field, field, reason}}
    end
  end

  defp validate_portable_map(value, field),
    do: {:error, {:invalid_activation_field, field, shape(value)}}

  defp validate_positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp validate_positive(value, field), do: {:error, {:invalid_activation_field, field, value}}

  defp validate_non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(value, field),
    do: {:error, {:invalid_activation_field, field, value}}

  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
