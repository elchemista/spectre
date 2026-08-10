defmodule Spectre.Definition.Candidate do
  @moduledoc """
  Minimal immutable Candidate admitted by the 0.2.3 activation boundary.

  This is deliberately not the later governed Candidate state machine. A
  bootstrap Candidate can be authored only by trusted host code or compiled
  Definition lowering, and binds one already-published Definition, Manifest,
  and publication receipt. Activation always re-reads this value from the
  configured Definition Store by `Candidate.Ref`.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate.Ref
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref, as: DefinitionRef

  @schema_version 1
  @sources [:compiled, :trusted_host]

  @enforce_keys [
    :schema_version,
    :definition_ref,
    :manifest_digest,
    :publication_id,
    :source,
    :parent_ref,
    :provenance_refs,
    :created_at
  ]
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            manifest_digest: nil,
            publication_id: nil,
            source: nil,
            parent_ref: nil,
            provenance_refs: [],
            created_at: nil

  @type source :: :compiled | :trusted_host
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: DefinitionRef.t(),
          manifest_digest: String.t(),
          publication_id: String.t(),
          source: source(),
          parent_ref: Ref.t() | nil,
          provenance_refs: [String.t()],
          created_at: non_neg_integer()
        }

  @doc "Returns the bootstrap Candidate schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates a minimal Candidate from normalized attributes."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = candidate), do: candidate |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:schema_version, @schema_version)
      |> Map.put_new(:source, :trusted_host)
      |> Map.put_new(:parent_ref, nil)
      |> Map.put_new(:provenance_refs, [])
      |> Map.put_new(:created_at, System.system_time(:millisecond))

    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version)),
         {:ok, definition_ref} <- normalize_definition_ref(Map.get(attrs, :definition_ref)),
         :ok <- validate_digest(Map.get(attrs, :manifest_digest)),
         :ok <- validate_binary(Map.get(attrs, :publication_id), :publication_id),
         :ok <- validate_source(Map.get(attrs, :source)),
         {:ok, parent_ref} <- normalize_parent_ref(Map.get(attrs, :parent_ref)),
         {:ok, provenance_refs} <- normalize_refs(Map.get(attrs, :provenance_refs)),
         :ok <- validate_timestamp(Map.get(attrs, :created_at)) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         definition_ref: definition_ref,
         manifest_digest: Map.fetch!(attrs, :manifest_digest),
         publication_id: Map.fetch!(attrs, :publication_id),
         source: Map.fetch!(attrs, :source),
         parent_ref: parent_ref,
         provenance_refs: provenance_refs,
         created_at: Map.fetch!(attrs, :created_at)
       }}
    end
  end

  def new(value), do: {:error, {:invalid_definition_candidate, shape(value)}}

  @doc "Builds a Candidate or raises with the stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, candidate} -> candidate
      {:error, reason} -> raise ArgumentError, "invalid Definition Candidate: #{inspect(reason)}"
    end
  end

  @doc "Builds a Candidate from a verified Definition resolution."
  @spec from_resolution(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_resolution(resolution, opts \\ [])

  def from_resolution(
        %{
          definition_ref: definition_ref,
          manifest: manifest,
          publication_receipt: receipt
        },
        opts
      )
      when is_list(opts) do
    new(
      definition_ref: definition_ref,
      manifest_digest: Manifest.digest(manifest),
      publication_id: Map.get(receipt, :publication_id),
      source: Keyword.get(opts, :source, :trusted_host),
      parent_ref: Keyword.get(opts, :parent_ref),
      provenance_refs: Keyword.get(opts, :provenance_refs, []),
      created_at: Keyword.get(opts, :created_at, System.system_time(:millisecond))
    )
  end

  def from_resolution(value, _opts),
    do: {:error, {:invalid_candidate_resolution, shape(value)}}

  @doc "Returns the Candidate's content-addressed Ref."
  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{} = candidate), do: Ref.new(candidate)

  @doc "Returns portable canonical data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = candidate) do
    %{
      "schema_version" => candidate.schema_version,
      "definition_ref" => DefinitionRef.to_string(candidate.definition_ref),
      "definition_canonicalization_version" => candidate.definition_ref.canonicalization_version,
      "definition_contract_version" => candidate.definition_ref.contract_version,
      "manifest_digest" => candidate.manifest_digest,
      "publication_id" => candidate.publication_id,
      "source" => Atom.to_string(candidate.source),
      "parent_ref" => candidate.parent_ref && Ref.to_string(candidate.parent_ref),
      "provenance_refs" => candidate.provenance_refs,
      "created_at" => candidate.created_at
    }
  end

  @doc "Restores a Candidate from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "schema_version" => schema_version,
        "definition_ref" => definition_ref,
        "definition_canonicalization_version" => canonicalization_version,
        "definition_contract_version" => contract_version,
        "manifest_digest" => manifest_digest,
        "publication_id" => publication_id,
        "source" => source,
        "parent_ref" => parent_ref,
        "provenance_refs" => provenance_refs,
        "created_at" => created_at
      }) do
    with {:ok, definition_ref} <-
           DefinitionRef.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         {:ok, source} <- source_from_data(source),
         {:ok, parent_ref} <- parent_from_data(parent_ref) do
      new(%{
        schema_version: schema_version,
        definition_ref: definition_ref,
        manifest_digest: manifest_digest,
        publication_id: publication_id,
        source: source,
        parent_ref: parent_ref,
        provenance_refs: provenance_refs,
        created_at: created_at
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_definition_candidate_data, shape(value)}}

  @doc "Encodes the Candidate into canonical portable bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = candidate), do: candidate |> to_data() |> Value.encode()

  @doc "Decodes and validates canonical Candidate bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_definition_candidate_binary, shape(value)}}

  @doc "Returns the stable Candidate digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = candidate), do: candidate |> to_data() |> Value.digest!()

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = [
      :schema_version,
      :definition_ref,
      :manifest_digest,
      :publication_id,
      :source,
      :parent_ref,
      :provenance_refs,
      :created_at
    ]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_definition_candidate_fields, Enum.sort(unknown)}}
    end
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_definition_candidate_schema, version}}

  defp normalize_definition_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_candidate_definition_ref, ref}}
  end

  defp normalize_definition_ref(value) when is_binary(value), do: DefinitionRef.parse(value)

  defp normalize_definition_ref(value),
    do: {:error, {:invalid_candidate_definition_ref, value}}

  defp normalize_parent_ref(nil), do: {:ok, nil}

  defp normalize_parent_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_candidate_parent_ref, ref}}
  end

  defp normalize_parent_ref(value) when is_binary(value), do: Ref.parse(value)
  defp normalize_parent_ref(value), do: {:error, {:invalid_candidate_parent_ref, value}}

  defp normalize_refs(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_candidate_provenance_refs}
  end

  defp normalize_refs(value), do: {:error, {:invalid_candidate_provenance_refs, shape(value)}}

  defp validate_digest(digest) when is_binary(digest) and byte_size(digest) == 64 do
    case Base.decode16(digest, case: :mixed) do
      {:ok, <<_::256>>} -> :ok
      :error -> {:error, {:invalid_candidate_manifest_digest, digest}}
    end
  end

  defp validate_digest(digest), do: {:error, {:invalid_candidate_manifest_digest, digest}}

  defp validate_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_binary(value, field), do: {:error, {:invalid_candidate_field, field, value}}

  defp validate_source(source) when source in @sources, do: :ok
  defp validate_source(source), do: {:error, {:invalid_candidate_source, source}}

  defp validate_timestamp(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_timestamp(value), do: {:error, {:invalid_candidate_created_at, value}}

  defp source_from_data("compiled"), do: {:ok, :compiled}
  defp source_from_data("trusted_host"), do: {:ok, :trusted_host}
  defp source_from_data(value), do: {:error, {:invalid_candidate_source, value}}

  defp parent_from_data(nil), do: {:ok, nil}
  defp parent_from_data(value) when is_binary(value), do: Ref.parse(value)
  defp parent_from_data(value), do: {:error, {:invalid_candidate_parent_ref, value}}

  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
