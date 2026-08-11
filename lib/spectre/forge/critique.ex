defmodule Spectre.Forge.Critique do
  @moduledoc """
  Immutable result of one compiled Forge critic adapter.

  Prose is retained only as opinion. An optional evaluation case is inert
  until its oracle is independently trusted or approved.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Eval.Case
  alias Spectre.Experience.Redactor
  alias Spectre.Governance.Data

  @schema_version 1
  @fields [
    :schema_version,
    :critic_id,
    :critic_version,
    :profile_ref,
    :reflection_digest,
    :experience_snapshot_digest,
    :opinion,
    :eval_case,
    :oracle_ref,
    :provenance,
    :digest
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            critic_id: nil,
            critic_version: nil,
            profile_ref: nil,
            reflection_digest: nil,
            experience_snapshot_digest: nil,
            opinion: nil,
            eval_case: nil,
            oracle_ref: nil,
            provenance: %{},
            digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          critic_id: String.t(),
          critic_version: pos_integer(),
          profile_ref: String.t(),
          reflection_digest: String.t(),
          experience_snapshot_digest: String.t(),
          opinion: String.t(),
          eval_case: map() | nil,
          oracle_ref: String.t() | nil,
          provenance: map(),
          digest: String.t()
        }

  @doc "Returns the Critique transport schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds a transport-stable critique."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = critique), do: critique |> to_data() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_forge_critique, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         @schema_version <- value(attrs, :schema_version, @schema_version),
         {:ok, critic_id} <- name(value(attrs, :critic_id), :critic_id),
         {:ok, critic_version} <- positive(value(attrs, :critic_version), :critic_version),
         {:ok, profile_ref} <- ref(value(attrs, :profile_ref), :profile_ref),
         :ok <- digest(value(attrs, :reflection_digest), :reflection_digest),
         :ok <- digest(value(attrs, :experience_snapshot_digest), :experience_snapshot_digest),
         {:ok, opinion} <- opinion(value(attrs, :opinion)),
         {:ok, evaluation_case} <- evaluation_case(value(attrs, :eval_case)),
         {:ok, oracle_ref} <- optional_ref(value(attrs, :oracle_ref), :oracle_ref),
         :ok <- oracle_pair(evaluation_case, oracle_ref),
         {:ok, provenance} <- portable_map(value(attrs, :provenance, %{}), :provenance),
         :ok <- reject_sensitive(provenance),
         base = %{
           schema_version: @schema_version,
           critic_id: critic_id,
           critic_version: critic_version,
           profile_ref: profile_ref,
           reflection_digest: value(attrs, :reflection_digest),
           experience_snapshot_digest: value(attrs, :experience_snapshot_digest),
           opinion: opinion,
           eval_case: evaluation_case,
           oracle_ref: oracle_ref,
           provenance: provenance
         },
         expected = content_digest(base),
         :ok <- supplied_digest(value(attrs, :digest), expected) do
      {:ok, struct!(__MODULE__, Map.put(base, :digest, expected))}
    else
      version when is_integer(version) -> {:error, {:unsupported_forge_critique_schema, version}}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_forge_critique, shape(value)}}
    end
  end

  def new(value), do: {:error, {:invalid_forge_critique, shape(value)}}

  @doc "Returns canonical JSON-shaped critique data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = critique) do
    %{
      "schema_version" => critique.schema_version,
      "critic_id" => critique.critic_id,
      "critic_version" => critique.critic_version,
      "profile_ref" => critique.profile_ref,
      "reflection_digest" => critique.reflection_digest,
      "experience_snapshot_digest" => critique.experience_snapshot_digest,
      "opinion" => critique.opinion,
      "eval_case" => critique.eval_case,
      "oracle_ref" => critique.oracle_ref,
      "provenance" => critique.provenance,
      "digest" => critique.digest
    }
  end

  @doc "Restores a critique from decoded transport data."
  def from_data(data), do: new(data)

  @doc "Returns the exact proposed evaluation-case digest, if present."
  @spec case_digest(t()) :: String.t() | nil
  def case_digest(%__MODULE__{eval_case: nil}), do: nil
  def case_digest(%__MODULE__{eval_case: evaluation_case}), do: Value.digest!(evaluation_case)

  @doc "Revalidates all fields and the content digest."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = critique) do
    case critique |> to_data() |> from_data() do
      {:ok, ^critique} -> :ok
      {:ok, _other} -> {:error, :forge_critique_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp content_digest(base) do
    base
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Value.digest!()
  end

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- aliases, collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_forge_critique_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_forge_critique_fields, collisions}}
    end
  end

  defp name(value, _field) when is_binary(value) and value != "" do
    if Regex.match?(~r/^[a-z][a-z0-9_.:-]{0,127}\z/, value),
      do: {:ok, value},
      else: {:error, {:invalid_forge_critic_id, value}}
  end

  defp name(value, field), do: {:error, {:invalid_forge_critique_field, field, value}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive(value, field), do: {:error, {:invalid_forge_critique_field, field, value}}

  defp ref(value, _field) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, :forge_code_reference_forbidden},
      else: {:ok, value}
  end

  defp ref(value, field), do: {:error, {:invalid_forge_critique_field, field, value}}
  defp optional_ref(nil, _field), do: {:ok, nil}
  defp optional_ref(value, field), do: ref(value, field)

  defp opinion(value) when is_binary(value) and byte_size(value) <= 32_768, do: {:ok, value}
  defp opinion(value), do: {:error, {:invalid_forge_critique_opinion, shape(value)}}

  defp evaluation_case(nil), do: {:ok, nil}

  defp evaluation_case(value) when is_map(value) and not is_struct(value) do
    with {:ok, normalized} <- Data.normalize_map(value),
         {:ok, evaluation_case} <- Case.new(normalized) do
      {:ok, Case.to_data(evaluation_case)}
    end
  end

  defp evaluation_case(value), do: {:error, {:invalid_forge_eval_case, shape(value)}}

  defp oracle_pair(nil, nil), do: :ok
  defp oracle_pair(%{}, oracle) when is_binary(oracle), do: :ok
  defp oracle_pair(nil, _oracle), do: {:error, :forge_oracle_requires_eval_case}
  defp oracle_pair(_case, nil), do: {:error, :forge_eval_case_requires_oracle}

  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Data.normalize_map(value) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:nonportable_forge_critique_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_forge_critique_field, field, shape(value)}}

  defp reject_sensitive(value), do: reject_sensitive(value, [])

  defp reject_sensitive(value, path) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      case reject_sensitive_entry(key, item, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case reject_sensitive(item, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reject_sensitive(_value, _path), do: :ok

  defp reject_sensitive_entry(key, item, path) do
    if Redactor.sensitive_key?(key) and item != "[REDACTED]",
      do: {:error, {:sensitive_forge_provenance, Enum.reverse([key | path])}},
      else: reject_sensitive(item, [key | path])
  end

  defp supplied_digest(nil, _expected), do: :ok
  defp supplied_digest(expected, expected), do: :ok
  defp supplied_digest(_supplied, _expected), do: {:error, :forge_critique_digest_mismatch}

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    if match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower)),
      do: :ok,
      else: {:error, {:invalid_forge_critique_digest, value}}
  end

  defp digest(value, field), do: {:error, {:invalid_forge_critique_digest, field, value}}

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
