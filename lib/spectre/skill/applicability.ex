defmodule Spectre.Skill.Applicability do
  @moduledoc """
  Structured, portable applicability contract for one Skill.

  Scope and tags decide eligibility. Positive and negative examples are an
  executable anti-hijack corpus; they never grant authority or become an
  unstructured model instruction.
  """

  alias Spectre.Canonical.Value

  @schema_version 1
  @fields [
    :schema_version,
    :scopes,
    :required_tags,
    :forbidden_tags,
    :positive,
    :negative,
    :conflicts
  ]

  defstruct schema_version: @schema_version,
            scopes: [],
            required_tags: [],
            forbidden_tags: [],
            positive: [],
            negative: [],
            conflicts: []

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          scopes: [term()],
          required_tags: [term()],
          forbidden_tags: [term()],
          positive: [String.t()],
          negative: [String.t()],
          conflicts: [term()]
        }

  @doc "Returns the current applicability schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates structured applicability."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = applicability), do: applicability |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_skill_applicability, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs = atomize_known_keys(attrs)

    with :ok <- exact_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, scopes} <- normalize_values(Map.get(attrs, :scopes, []), :scopes),
         {:ok, required} <- normalize_values(Map.get(attrs, :required_tags, []), :required_tags),
         {:ok, forbidden} <-
           normalize_values(Map.get(attrs, :forbidden_tags, []), :forbidden_tags),
         :ok <- disjoint(required, forbidden),
         {:ok, positive} <- normalize_examples(Map.get(attrs, :positive, []), :positive),
         {:ok, negative} <- normalize_examples(Map.get(attrs, :negative, []), :negative),
         :ok <- disjoint(positive, negative),
         {:ok, conflicts} <- normalize_values(Map.get(attrs, :conflicts, []), :conflicts) do
      {:ok,
       %__MODULE__{
         scopes: scopes,
         required_tags: required,
         forbidden_tags: forbidden,
         positive: positive,
         negative: negative,
         conflicts: conflicts
       }}
    end
  end

  def new(value), do: {:error, {:invalid_skill_applicability, shape(value)}}

  @doc "Builds applicability or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, applicability} -> applicability
      {:error, reason} -> raise ArgumentError, "invalid Skill applicability: #{inspect(reason)}"
    end
  end

  @doc "Restores applicability from its portable representation."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Returns the portable representation included in Definition identity."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = applicability) do
    %{
      schema_version: applicability.schema_version,
      scopes: applicability.scopes,
      required_tags: applicability.required_tags,
      forbidden_tags: applicability.forbidden_tags,
      positive: applicability.positive,
      negative: applicability.negative,
      conflicts: applicability.conflicts
    }
  end

  @doc "Returns true when a structured host context is eligible."
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{} = applicability, context) when is_map(context) do
    scope = Map.get(context, :scope, Map.get(context, "scope"))
    tags = List.wrap(Map.get(context, :tags, Map.get(context, "tags", [])))

    (applicability.scopes == [] or member?(applicability.scopes, scope)) and
      subset?(applicability.required_tags, tags) and
      not intersects?(applicability.forbidden_tags, tags)
  end

  def matches?(%__MODULE__{}, _context), do: false

  @doc "Returns a deterministic specificity used to detect ambiguous Skills."
  @spec specificity(t()) :: non_neg_integer()
  def specificity(%__MODULE__{} = applicability) do
    scope_score = if applicability.scopes == [], do: 0, else: 1
    scope_score + length(applicability.required_tags)
  end

  @doc "Returns true when this declaration conflicts with a mount or Skill id."
  @spec conflicts?(t(), term()) :: boolean()
  def conflicts?(%__MODULE__{conflicts: conflicts}, id), do: member?(conflicts, id)

  @spec exact_keys(map()) :: :ok | {:error, term()}
  defp exact_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] ->
        :ok

      unknown ->
        {:error, {:unknown_skill_applicability_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec validate_schema(term()) :: :ok | {:error, term()}
  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_skill_applicability_schema, version}}

  @spec normalize_values(term(), atom()) :: {:ok, [term()]} | {:error, term()}
  defp normalize_values(values, field) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn value, {:ok, unique} ->
      case Value.encode(value) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(unique, encoded, value)}}
        {:error, reason} -> {:halt, {:error, {:invalid_skill_applicability_value, field, reason}}}
      end
    end)
    |> case do
      {:ok, unique} -> {:ok, unique |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_values(value, field),
    do: {:error, {:invalid_skill_applicability_values, field, shape(value)}}

  @spec normalize_examples(term(), atom()) :: {:ok, [String.t()]} | {:error, term()}
  defp normalize_examples(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "" and byte_size(&1) <= 1_024)) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_skill_applicability_examples, field}}
    end
  end

  defp normalize_examples(_value, field),
    do: {:error, {:invalid_skill_applicability_examples, field}}

  @spec disjoint([term()], [term()]) :: :ok | {:error, term()}
  defp disjoint(left, right) do
    case Enum.find(left, &member?(right, &1)) do
      nil -> :ok
      value -> {:error, {:conflicting_skill_applicability_value, value}}
    end
  end

  @spec subset?([term()], [term()]) :: boolean()
  defp subset?(required, actual), do: Enum.all?(required, &member?(actual, &1))

  @spec intersects?([term()], [term()]) :: boolean()
  defp intersects?(left, right), do: Enum.any?(left, &member?(right, &1))

  @spec member?([term()], term()) :: boolean()
  defp member?(values, value) do
    encoded = Value.encode!(value)
    Enum.any?(values, &(Value.encode!(&1) == encoded))
  rescue
    ArgumentError -> false
  end

  @spec atomize_known_keys(map()) :: map()
  defp atomize_known_keys(attrs) do
    Enum.reduce(@fields, attrs, fn key, normalized ->
      string = Atom.to_string(key)

      case Map.fetch(normalized, string) do
        {:ok, value} -> normalized |> Map.delete(string) |> Map.put_new(key, value)
        :error -> normalized
      end
    end)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
