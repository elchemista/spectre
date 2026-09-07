defmodule Spectre.Condition do
  @moduledoc """
  Portable evidence requirement attached to a mandate.

  Conditions describe what Recognition must establish.  They never select a
  mandate and never produce authority or a grant. Atom keys in opaque
  application maps are converted recursively to strings at construction, so
  attenuation and content identity never depend on which key spelling crossed
  the boundary; colliding atom/string keys are rejected.
  """

  require Spectre.Portable

  alias Spectre.{Evidence, Portable}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :proposition,
    :coverage,
    :bindings,
    :cardinality,
    :accepted_provenance,
    :freshness_ms,
    :allow_provisional,
    :parameters
  ]
  @provenance Evidence.provenances()
  @semantic_fields [:proposition, :coverage, :bindings, :parameters]

  @enforce_keys [
    :schema_version,
    :ref,
    :proposition,
    :coverage,
    :bindings,
    :cardinality,
    :accepted_provenance,
    :allow_provisional,
    :parameters
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            proposition: nil,
            coverage: :all,
            bindings: %{},
            cardinality: %{"min" => 1, "max" => nil},
            accepted_provenance: [:observed],
            freshness_ms: nil,
            allow_provisional: false,
            parameters: %{}

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          proposition: term(),
          coverage: term(),
          bindings: map(),
          cardinality: %{String.t() => non_neg_integer() | nil},
          accepted_provenance: [:observed | :derived | :generated],
          freshness_ms: non_neg_integer() | nil,
          allow_provisional: boolean(),
          parameters: map()
        }

  @doc "Builds and validates an evidence condition."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = condition), do: condition |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :condition),
         attrs <- defaults(attrs),
         {:ok, attrs} <- normalize_semantic_keys(attrs),
         {:ok, cardinality} <- normalize_cardinality(Map.fetch!(attrs, :cardinality)),
         {:ok, provenance} <-
           normalize_provenance(Map.fetch!(attrs, :accepted_provenance)),
         attrs =
           attrs
           |> Map.put(:cardinality, cardinality)
           |> Map.put(:accepted_provenance, provenance),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         condition = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(condition),
         :ok <- Portable.validate(canonical(condition)) do
      {:ok, condition}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = condition), do: Portable.canonical_fields(condition, @fields)

  @doc "Restores a condition from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :condition)

  @doc "Returns the stable digest of the complete condition."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = condition), do: condition |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = condition),
    do: Portable.content_ref!(:condition, content(condition))

  @doc """
  Checks that `child` is the same requirement as, or a stricter requirement
  than, `parent`.

  The comparison is deliberately structural and closed. It permits stronger
  coverage/bindings, a narrower provenance set, tighter cardinality and
  freshness, and rejecting provisional Evidence. Proposition and opaque
  domain-specific parameters must remain byte-for-byte equivalent because the
  core cannot safely infer a restriction relation for their vocabulary.
  References are identifiers and are therefore not used as proof of semantic
  equivalence.
  """
  @spec attenuation(t() | map() | keyword(), t() | map() | keyword()) ::
          :ok | {:error, term()}
  def attenuation(parent, child) do
    with {:ok, parent} <- normalize_for_attenuation(parent, :parent),
         {:ok, child} <- normalize_for_attenuation(child, :child),
         :ok <- same_proposition(parent, child),
         :ok <- stronger_requirement(:coverage, parent.coverage, child.coverage),
         :ok <- stronger_requirement(:bindings, parent.bindings, child.bindings),
         :ok <- stronger_cardinality(parent.cardinality, child.cardinality),
         :ok <- narrower_provenance(parent.accepted_provenance, child.accepted_provenance),
         :ok <- tighter_freshness(parent.freshness_ms, child.freshness_ms),
         :ok <- provisional_not_weakened(parent.allow_provisional, child.allow_provisional) do
      unchanged_parameters(parent.parameters, child.parameters)
    end
  end

  @doc "Returns whether `child` is a valid attenuation of `parent`."
  @spec attenuates?(t() | map() | keyword(), t() | map() | keyword()) :: boolean()
  def attenuates?(child, parent), do: attenuation(parent, child) == :ok

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:coverage, :all)
    |> Map.put_new(:bindings, %{})
    |> Map.put_new(:cardinality, %{"min" => 1, "max" => nil})
    |> Map.put_new(:accepted_provenance, [:observed])
    |> Map.put_new(:freshness_ms, nil)
    |> Map.put_new(:allow_provisional, false)
    |> Map.put_new(:parameters, %{})
  end

  defp normalize_cardinality(value) when Portable.is_non_negative_integer(value),
    do: {:ok, %{"min" => value, "max" => value}}

  defp normalize_cardinality(value) when Portable.is_plain_map(value) do
    allowed = [:min, :max]

    with {:ok, attrs} <- Portable.normalize_attrs(value, allowed, :condition_cardinality) do
      {:ok, %{"min" => Map.get(attrs, :min, 1), "max" => Map.get(attrs, :max)}}
    end
  end

  defp normalize_cardinality(value),
    do: {:error, {:invalid_condition_cardinality, Portable.shape(value)}}

  defp normalize_provenance(value) when is_list(value) do
    if valid_provenance?(value) do
      {:ok, Enum.filter(@provenance, &(&1 in value))}
    else
      {:error, {:invalid_condition_provenance, value}}
    end
  end

  defp normalize_provenance(value),
    do: {:error, {:invalid_condition_provenance, value}}

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:condition, ref, content(attrs))

  defp content(%__MODULE__{} = condition), do: condition |> canonical() |> Map.delete("ref")

  defp content(attrs), do: Portable.canonical_fields(attrs, @fields -- [:ref])

  defp validate_record(%__MODULE__{} = condition) do
    min = Map.get(condition.cardinality, "min")
    max = Map.get(condition.cardinality, "max")

    with :ok <- validate_header(condition),
         :ok <- validate_cardinality(min, max),
         :ok <- validate_evidence_policy(condition) do
      validate_parameters_and_ref(condition)
    end
  end

  defp validate_header(condition) do
    cond do
      condition.schema_version !== @schema_version ->
        {:error, {:unsupported_condition_schema_version, condition.schema_version}}

      is_nil(condition.proposition) ->
        {:error, :missing_condition_proposition}

      not Portable.is_plain_map(condition.bindings) ->
        {:error, {:invalid_condition_bindings, Portable.shape(condition.bindings)}}

      true ->
        :ok
    end
  end

  defp validate_cardinality(min, max) do
    cond do
      not Portable.is_non_negative_integer(min) ->
        {:error, {:invalid_condition_cardinality_min, min}}

      not (is_nil(max) or (is_integer(max) and max >= min)) ->
        {:error, {:invalid_condition_cardinality_max, max}}

      true ->
        :ok
    end
  end

  defp validate_evidence_policy(condition) do
    cond do
      not valid_provenance?(condition.accepted_provenance) ->
        {:error, {:invalid_condition_provenance, condition.accepted_provenance}}

      not (is_nil(condition.freshness_ms) or
               Portable.is_non_negative_integer(condition.freshness_ms)) ->
        {:error, {:invalid_condition_freshness_ms, condition.freshness_ms}}

      not is_boolean(condition.allow_provisional) ->
        {:error, {:invalid_condition_allow_provisional, condition.allow_provisional}}

      true ->
        :ok
    end
  end

  defp validate_parameters_and_ref(condition) do
    if Portable.is_plain_map(condition.parameters) do
      with :ok <- validate_assumption_policy(condition.parameters) do
        Portable.validate_ref(condition.ref, :ref)
      end
    else
      {:error, {:invalid_condition_parameters, Portable.shape(condition.parameters)}}
    end
  end

  # Application parameters remain opaque. This reserved key is interpreted by
  # Recognition, so reject a non-list policy here rather than crashing during
  # admission when Evidence happens to carry an assumption.
  defp validate_assumption_policy(%{"accepted_assumptions" => value}) when not is_list(value),
    do: {:error, {:invalid_condition_parameter, "accepted_assumptions", Portable.shape(value)}}

  defp validate_assumption_policy(_parameters), do: :ok

  defp valid_provenance?([]), do: false

  defp valid_provenance?([value | rest]) when value in @provenance,
    do: valid_provenance_tail?(rest)

  defp valid_provenance?(_value), do: false

  defp valid_provenance_tail?([]), do: true

  defp valid_provenance_tail?([value | rest]) when value in @provenance,
    do: valid_provenance_tail?(rest)

  defp valid_provenance_tail?(_value), do: false

  defp normalize_for_attenuation(value, side) do
    case new(value) do
      {:ok, condition} -> {:ok, condition}
      {:error, reason} -> {:error, {:invalid_attenuation_condition, side, reason}}
    end
  end

  defp same_proposition(parent, child) do
    if parent.proposition === child.proposition,
      do: :ok,
      else: {:error, {:condition_weakened, :proposition}}
  end

  defp stronger_requirement(field, parent, child) do
    parent = normalize_open_requirement(parent)
    child = normalize_open_requirement(child)

    if requirement_contains?(child, parent),
      do: :ok,
      else: {:error, {:condition_weakened, field}}
  end

  # Recognition treats both sentinels as an open aggregate-coverage
  # requirement. A concrete child requirement can narrow either one.
  defp normalize_open_requirement(value) when value in [:all, :any], do: nil
  defp normalize_open_requirement(value), do: value

  # `stronger` contains at least every requirement expressed by `weaker`.
  defp requirement_contains?(_stronger, nil), do: true
  defp requirement_contains?(nil, _weaker), do: false

  defp requirement_contains?(stronger, weaker)
       when is_map(stronger) and is_map(weaker) and not is_struct(stronger) and
              not is_struct(weaker) do
    Enum.all?(weaker, fn {key, required} ->
      case Map.fetch(stronger, key) do
        {:ok, actual} -> requirement_contains?(actual, required)
        :error -> false
      end
    end)
  end

  defp requirement_contains?(stronger, weaker) when is_list(stronger) and is_list(weaker),
    do: Enum.all?(weaker, &(&1 in stronger))

  defp requirement_contains?(stronger, weaker), do: stronger === weaker

  defp normalize_semantic_keys(attrs) do
    Enum.reduce_while(@semantic_fields, {:ok, attrs}, fn field, {:ok, normalized} ->
      case Portable.stringify_atom_keys(Map.get(normalized, field)) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(normalized, field, value)}}

        {:error, {:equivalent_map_keys, path}} ->
          {:halt, {:error, {:condition_key_collision, List.last(path)}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp stronger_cardinality(parent, child) do
    parent_min = Map.fetch!(parent, "min")
    parent_max = Map.fetch!(parent, "max")
    child_min = Map.fetch!(child, "min")
    child_max = Map.fetch!(child, "max")

    if child_min >= parent_min and upper_bound_within?(child_max, parent_max),
      do: :ok,
      else: {:error, {:condition_weakened, :cardinality}}
  end

  defp upper_bound_within?(_child, nil), do: true
  defp upper_bound_within?(nil, _parent), do: false
  defp upper_bound_within?(child, parent), do: child <= parent

  defp narrower_provenance(parent, child) do
    if MapSet.subset?(MapSet.new(child), MapSet.new(parent)),
      do: :ok,
      else: {:error, {:condition_weakened, :accepted_provenance}}
  end

  defp tighter_freshness(nil, _child), do: :ok

  defp tighter_freshness(_parent, nil),
    do: {:error, {:condition_weakened, :freshness_ms}}

  defp tighter_freshness(parent, child) do
    if child <= parent,
      do: :ok,
      else: {:error, {:condition_weakened, :freshness_ms}}
  end

  defp provisional_not_weakened(false, true),
    do: {:error, {:condition_weakened, :allow_provisional}}

  defp provisional_not_weakened(_parent, _child), do: :ok

  defp unchanged_parameters(value, value), do: :ok

  defp unchanged_parameters(_parent, _child),
    do: {:error, {:condition_weakened, :parameters}}
end
