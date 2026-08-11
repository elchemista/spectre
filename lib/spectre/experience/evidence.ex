defmodule Spectre.Experience.Evidence do
  @moduledoc """
  Immutable, redacted and non-canonical operational evidence.

  Evidence is tied to an exact Definition and activation generation. It may
  inform reflection and future proposals, but it never authorizes execution,
  replaces Instance state, or becomes a Journal record.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Experience.Evidence.Ref
  alias Spectre.Experience.Redactor
  alias Spectre.Governance.Data

  @schema_version 1
  @retentions [:ephemeral, :bounded, :retained]
  @fields [
    :schema_version,
    :definition_ref,
    :activation_generation,
    :kind,
    :source_ref,
    :observed_at,
    :expires_at,
    :retention,
    :facts,
    :provenance,
    :redactions
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            activation_generation: nil,
            kind: nil,
            source_ref: nil,
            observed_at: nil,
            expires_at: nil,
            retention: nil,
            facts: %{},
            provenance: %{},
            redactions: []

  @type retention :: :ephemeral | :bounded | :retained
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: DefinitionRef.t(),
          activation_generation: non_neg_integer(),
          kind: String.t(),
          source_ref: String.t(),
          observed_at: non_neg_integer(),
          expires_at: non_neg_integer() | nil,
          retention: retention(),
          facts: map(),
          provenance: map(),
          redactions: [[String.t() | non_neg_integer()]]
        }

  @doc "Returns the Experience evidence schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and verifies already-redacted Experience evidence."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = evidence), do: evidence |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_experience_evidence, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         :ok <- schema(value(attrs, :schema_version, @schema_version)),
         {:ok, definition_ref} <- definition_ref(attrs),
         {:ok, generation} <- non_negative(value(attrs, :activation_generation), :generation),
         {:ok, kind} <- name(value(attrs, :kind), :kind),
         {:ok, source_ref} <- nonempty(value(attrs, :source_ref), :source_ref),
         {:ok, observed_at} <- non_negative(value(attrs, :observed_at), :observed_at),
         {:ok, expires_at} <- expiry(value(attrs, :expires_at), observed_at),
         {:ok, retention} <- retention(value(attrs, :retention, :bounded), expires_at),
         {:ok, facts} <- normalized_map(value(attrs, :facts, %{}), :facts),
         :ok <- reject_sensitive_keys(facts),
         {:ok, provenance} <- normalized_map(value(attrs, :provenance, %{}), :provenance),
         :ok <- reject_sensitive_keys(provenance),
         {:ok, redactions} <- redactions(value(attrs, :redactions, [])) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         definition_ref: definition_ref,
         activation_generation: generation,
         kind: kind,
         source_ref: source_ref,
         observed_at: observed_at,
         expires_at: expires_at,
         retention: retention,
         facts: facts,
         provenance: provenance,
         redactions: redactions
       }}
    end
  end

  def new(value), do: {:error, {:invalid_experience_evidence, shape(value)}}

  @doc "Builds evidence or raises with the stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, evidence} -> evidence
      {:error, reason} -> raise ArgumentError, "invalid Experience evidence: #{inspect(reason)}"
    end
  end

  @doc "Returns the content-addressed evidence Ref."
  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{} = evidence), do: Ref.new(evidence)

  @doc "Returns canonical portable evidence data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = evidence) do
    %{
      "schema_version" => evidence.schema_version,
      "definition_ref" => DefinitionRef.to_string(evidence.definition_ref),
      "definition_canonicalization_version" => evidence.definition_ref.canonicalization_version,
      "definition_contract_version" => evidence.definition_ref.contract_version,
      "activation_generation" => evidence.activation_generation,
      "kind" => evidence.kind,
      "source_ref" => evidence.source_ref,
      "observed_at" => evidence.observed_at,
      "expires_at" => evidence.expires_at,
      "retention" => Atom.to_string(evidence.retention),
      "facts" => evidence.facts,
      "provenance" => evidence.provenance,
      "redactions" => evidence.redactions
    }
  end

  @doc "Restores and verifies evidence from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Encodes evidence with the production canonical codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = evidence), do: evidence |> to_data() |> Value.encode()

  @doc "Decodes and revalidates canonical evidence bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_experience_evidence_binary, shape(value)}}

  @doc "Returns the stable full-content evidence digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = evidence), do: evidence |> to_data() |> Value.digest!()

  @doc "Revalidates evidence and its canonical transport representation."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = evidence) do
    case evidence |> to_data() |> from_data() do
      {:ok, ^evidence} -> :ok
      {:ok, _other} -> {:error, :experience_evidence_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:invalid_experience_evidence, exception.__struct__}}
  end

  @doc "Returns whether evidence is expired at the supplied millisecond timestamp."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now)
      when is_integer(now) and now >= 0,
      do: now >= expires_at

  def expired?(%__MODULE__{}, _now), do: true

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    versions = ["definition_canonicalization_version", "definition_contract_version"]
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- (aliases ++ versions), collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_experience_evidence_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_experience_evidence_fields, collisions}}
    end
  end

  defp schema(@schema_version), do: :ok
  defp schema(value), do: {:error, {:unsupported_experience_evidence_schema, value}}

  defp definition_ref(attrs) do
    case value(attrs, :definition_ref) do
      %DefinitionRef{} = ref ->
        if DefinitionRef.valid?(ref),
          do: {:ok, ref},
          else: {:error, {:invalid_experience_definition_ref, ref}}

      ref when is_binary(ref) ->
        DefinitionRef.parse(ref,
          canonicalization_version: value(attrs, :definition_canonicalization_version, 1),
          contract_version: value(attrs, :definition_contract_version, 1)
        )

      ref ->
        {:error, {:invalid_experience_definition_ref, ref}}
    end
  end

  defp name(value, _field) when is_atom(value) and not is_nil(value),
    do: name(Atom.to_string(value), :kind)

  defp name(value, _field) when is_binary(value) and value != "" do
    if Regex.match?(~r/^[a-z][a-z0-9_.:-]{0,127}\z/, value),
      do: {:ok, value},
      else: {:error, {:invalid_experience_evidence_kind, value}}
  end

  defp name(value, field), do: {:error, {:invalid_experience_evidence_field, field, value}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp nonempty(value, field), do: {:error, {:invalid_experience_evidence_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative(value, field),
    do: {:error, {:invalid_experience_evidence_field, field, value}}

  defp expiry(nil, _observed_at), do: {:ok, nil}
  defp expiry(value, observed_at) when is_integer(value) and value > observed_at, do: {:ok, value}
  defp expiry(value, _observed_at), do: {:error, {:invalid_experience_evidence_expiry, value}}

  defp retention(value, expires_at) when is_binary(value) do
    case value do
      "ephemeral" -> retention(:ephemeral, expires_at)
      "bounded" -> retention(:bounded, expires_at)
      "retained" -> retention(:retained, expires_at)
      _other -> {:error, {:invalid_experience_evidence_retention, value}}
    end
  end

  defp retention(value, nil) when value in [:ephemeral, :bounded],
    do: {:error, {:experience_evidence_expiry_required, value}}

  defp retention(value, _expires_at) when value in @retentions, do: {:ok, value}

  defp retention(value, _expires_at),
    do: {:error, {:invalid_experience_evidence_retention, value}}

  defp normalized_map(value, field) do
    case Data.normalize_map(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_experience_evidence_field, field, reason}}
    end
  end

  defp reject_sensitive_keys(value), do: reject_sensitive_keys(value, [])

  defp reject_sensitive_keys(value, path) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      case reject_sensitive_entry(key, item, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive_keys(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case reject_sensitive_keys(item, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive_keys(_value, _path), do: :ok

  defp reject_sensitive_entry(key, item, path) do
    cond do
      Redactor.sensitive_key?(key) and item != "[REDACTED]" ->
        {:error, {:unredacted_experience_field, Enum.reverse([key | path])}}

      Redactor.sensitive_key?(key) ->
        :ok

      true ->
        reject_sensitive_keys(item, [key | path])
    end
  end

  defp redactions(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, paths} ->
      if is_list(path) and path != [] and Enum.all?(path, &valid_path_item?/1),
        do: {:cont, {:ok, [path | paths]}},
        else: {:halt, {:error, {:invalid_experience_redaction_path, path}}}
    end)
    |> case do
      {:ok, paths} -> {:ok, paths |> Enum.uniq() |> Enum.sort_by(&Value.encode!/1)}
      {:error, _reason} = error -> error
    end
  end

  defp redactions(value), do: {:error, {:invalid_experience_redactions, value}}

  defp valid_path_item?(value),
    do: (is_binary(value) and value != "") or (is_integer(value) and value >= 0)

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_function(value), do: :function
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_reference(value), do: :reference
  defp shape(_value), do: :other
end
