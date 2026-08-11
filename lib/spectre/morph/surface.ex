defmodule Spectre.Morph.Surface do
  @moduledoc """
  Canonical, closed declaration of the changes an Agent is willing to review.

  A Surface is a ceiling over proposals, never an authority grant. The
  governance Composer still intersects it with Manifest authority and host
  policy. Runtime data cannot add operation types, widen scopes, or increase
  prompt budgets after the Definition has been published.

  The value object in this module owns transport normalization and identity.
  Enforcement lives in `Spectre.Morph.Surface.Policy`, while mandatory replay
  cases are derived by `Spectre.Morph.Surface.EvaluationObligations`.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Morph.Surface.EvaluationObligations
  alias Spectre.Morph.Surface.Policy

  @schema_version 1
  @schema_ref "spectre.definition.change-surface/1"
  @operation_types ~w(disable_skill mount_skill replace_skill)
  @approval_requirements ~w(host_policy human)
  @fields ~w(schema_version operation_types scope_ceiling prompt_token_ceiling approval_requirement)
  @atom_fields [
    :schema_version,
    :operation_types,
    :scope_ceiling,
    :prompt_token_ceiling,
    :approval_requirement
  ]

  @enforce_keys [
    :schema_version,
    :operation_types,
    :scope_ceiling,
    :prompt_token_ceiling,
    :approval_requirement
  ]
  defstruct schema_version: @schema_version,
            operation_types: [],
            scope_ceiling: [],
            prompt_token_ceiling: nil,
            approval_requirement: :host_policy

  @typedoc "The minimum approval source required by the Agent Surface."
  @type approval_requirement :: :host_policy | :human

  @typedoc "The normalized immutable proposal ceiling sealed in Definition identity."
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          operation_types: [String.t()],
          scope_ceiling: [String.t()],
          prompt_token_ceiling: pos_integer(),
          approval_requirement: approval_requirement()
        }

  @doc "Returns the stable schema reference for the canonical component."
  @spec schema_ref() :: String.t()
  def schema_ref, do: @schema_ref

  @doc "Returns the complete closed vocabulary of Morph proposal operations."
  @spec operation_types() :: [String.t()]
  def operation_types, do: @operation_types

  @doc """
  Builds a normalized proposal Surface.

  Atom keys are accepted only as an Elixir authoring convenience. Transport
  data uses the exact string-key schema returned by `to_data/1`.
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = surface), do: surface |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_morph_surface, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         @schema_version <- value(attrs, :schema_version, @schema_version),
         {:ok, operations} <- operations(value(attrs, :operation_types)),
         {:ok, scopes} <- scopes(value(attrs, :scope_ceiling)),
         {:ok, prompt_tokens} <- prompt_tokens(value(attrs, :prompt_token_ceiling)),
         {:ok, approval} <- approval(value(attrs, :approval_requirement, "host_policy")) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         operation_types: operations,
         scope_ceiling: scopes,
         prompt_token_ceiling: prompt_tokens,
         approval_requirement: approval
       }}
    else
      version when is_integer(version) -> {:error, {:unsupported_morph_surface_schema, version}}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_morph_surface}
    end
  end

  def new(value), do: {:error, {:invalid_morph_surface, shape(value)}}

  @doc "Builds a Surface or raises `ArgumentError` with its validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, surface} -> surface
      {:error, reason} -> raise ArgumentError, "invalid Morph surface: #{inspect(reason)}"
    end
  end

  @doc "Returns the transport-stable data sealed into Definition identity."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = surface) do
    %{
      "schema_version" => surface.schema_version,
      "operation_types" => surface.operation_types,
      "scope_ceiling" => surface.scope_ceiling,
      "prompt_token_ceiling" => surface.prompt_token_ceiling,
      "approval_requirement" => Atom.to_string(surface.approval_requirement)
    }
  end

  @doc "Restores a Surface from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @doc "Reads and validates the immutable Surface of an Agent Definition."
  @spec from_canonical(Canonical.t()) :: {:ok, t()} | {:error, term()}
  def from_canonical(%Canonical{kind: :agent} = canonical) do
    with {:ok, component} <- Canonical.fetch_component(canonical, :change_surface),
         :ok <- validate_component(component) do
      from_data(component.payload)
    else
      {:error, {:unknown_definition_component, :change_surface}} ->
        {:error, :morph_surface_not_declared}

      {:error, _reason} = error ->
        error
    end
  end

  def from_canonical(%Canonical{kind: kind}),
    do: {:error, {:morph_surface_requires_agent, kind}}

  @doc false
  @spec validate_component(Component.t()) :: :ok | {:error, term()}
  def validate_component(%Component{} = component) do
    cond do
      component.component_type != :change_surface ->
        {:error, {:invalid_morph_surface_component_type, component.component_type}}

      component.schema_ref != @schema_ref ->
        {:error, {:invalid_morph_surface_schema_ref, component.schema_ref}}

      component.criticality != :must_understand ->
        {:error, {:invalid_morph_surface_criticality, component.criticality}}

      true ->
        with {:ok, _surface} <- from_data(component.payload), do: :ok
    end
  end

  @doc "Returns whether the Surface permits proposing an operation type."
  @spec allows?(t(), atom() | String.t()) :: boolean()
  def allows?(%__MODULE__{operation_types: allowed}, operation) do
    case operation_name(operation) do
      {:ok, name} -> name in allowed
      {:error, _reason} -> false
    end
  end

  @doc "Builds exact applicability ceilings for the affected mount identifiers."
  @spec applicability_ceilings(t(), [String.t()]) :: map()
  def applicability_ceilings(%__MODULE__{} = surface, mount_ids) when is_list(mount_ids) do
    mount_ids
    |> MapSet.new()
    |> Map.new(fn mount_id ->
      {mount_id,
       %{
         scopes: surface.scope_ceiling,
         required_tags: [],
         forbidden_tags: [],
         positive: [],
         negative: [],
         conflicts: []
       }}
    end)
  end

  @doc false
  @spec constrain(Canonical.t(), [Operation.t()], keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def constrain(%Canonical{} = parent, operations, opts)
      when is_list(operations) and is_list(opts) do
    if Keyword.keyword?(opts) do
      constrain_declared_surface(parent, operations, opts)
    else
      {:error, {:invalid_morph_constraint_options, shape(opts)}}
    end
  end

  def constrain(%Canonical{}, _operations, opts),
    do: {:error, {:invalid_morph_constraint_options, shape(opts)}}

  @doc false
  @spec verify_candidate(Canonical.t(), Canonical.t(), number() | nil, map() | nil) ::
          :ok | {:error, term()}
  def verify_candidate(%Canonical{} = parent, %Canonical{} = candidate, prompt_ceiling, ceilings) do
    case from_canonical(parent) do
      {:ok, surface} ->
        with {:ok, _mutations} <-
               Policy.verify(surface, parent, candidate, prompt_ceiling, ceilings) do
          :ok
        end

      {:error, :morph_surface_not_declared} ->
        verify_closed_candidate(candidate)

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec verify_evaluation_obligations(Canonical.t(), Canonical.t(), [map()]) ::
          :ok | {:error, term()}
  def verify_evaluation_obligations(
        %Canonical{} = parent,
        %Canonical{} = candidate,
        cases
      )
      when is_list(cases) do
    case from_canonical(parent) do
      {:ok, surface} -> EvaluationObligations.verify(surface, parent, candidate, cases)
      {:error, :morph_surface_not_declared} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def verify_evaluation_obligations(%Canonical{}, %Canonical{}, cases),
    do: {:error, {:invalid_morph_evaluation_obligations, shape(cases)}}

  @doc false
  @spec verify_governance(
          Canonical.t(),
          Canonical.t(),
          number() | nil,
          map() | nil,
          [map()]
        ) :: :ok | {:error, term()}
  def verify_governance(
        %Canonical{} = parent,
        %Canonical{} = candidate,
        prompt_ceiling,
        ceilings,
        cases
      )
      when is_list(cases) do
    case from_canonical(parent) do
      {:ok, surface} ->
        with {:ok, mutations} <-
               Policy.verify(
                 surface,
                 parent,
                 candidate,
                 prompt_ceiling,
                 ceilings
               ) do
          EvaluationObligations.verify(surface, mutations, cases)
        end

      {:error, :morph_surface_not_declared} ->
        verify_closed_candidate(candidate)

      {:error, _reason} = error ->
        error
    end
  end

  def verify_governance(%Canonical{}, %Canonical{}, _prompt_ceiling, _ceilings, cases),
    do: {:error, {:invalid_morph_evaluation_obligations, shape(cases)}}

  @doc false
  @spec evaluation_case_id(term(), term(), String.t()) :: String.t()
  def evaluation_case_id(mount_id, scope, purpose),
    do: EvaluationObligations.case_id(mount_id, scope, purpose)

  @doc "Returns the canonical Surface digest used in audit evidence."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = surface), do: surface |> to_data() |> Value.digest!()

  @spec constrain_declared_surface(Canonical.t(), [Operation.t()], keyword()) ::
          {:ok, keyword()} | {:error, term()}
  defp constrain_declared_surface(parent, operations, opts) do
    case from_canonical(parent) do
      {:ok, surface} -> Policy.constrain(surface, operations, opts)
      {:error, :morph_surface_not_declared} -> {:ok, opts}
      {:error, _reason} = error -> error
    end
  end

  @spec verify_closed_candidate(Canonical.t()) :: :ok | {:error, term()}
  defp verify_closed_candidate(candidate) do
    case from_canonical(candidate) do
      {:error, :morph_surface_not_declared} -> :ok
      _value -> {:error, :governance_change_surface_is_immutable}
    end
  end

  @spec exact_fields(map()) :: :ok | {:error, term()}
  defp exact_fields(attrs) do
    keys = Map.keys(attrs)
    allowed = @fields ++ @atom_fields
    unknown = keys -- allowed

    collision =
      Enum.find(Enum.zip(@fields, @atom_fields), fn {string, atom} ->
        Map.has_key?(attrs, string) and Map.has_key?(attrs, atom)
      end)

    cond do
      unknown != [] ->
        {:error, {:unknown_morph_surface_fields, Enum.sort_by(unknown, &inspect/1)}}

      collision != nil ->
        {:error, {:duplicate_morph_surface_field, elem(collision, 0)}}

      true ->
        :ok
    end
  end

  @spec operations(term()) :: {:ok, [String.t()]} | {:error, term()}
  defp operations(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, MapSet.new()}, fn value, {:ok, normalized} ->
      case operation_name(value) do
        {:ok, name} -> {:cont, {:ok, MapSet.put(normalized, name)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.sort(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp operations(value), do: {:error, {:invalid_morph_surface_operations, value}}

  @spec operation_name(term()) :: {:ok, String.t()} | {:error, term()}
  defp operation_name(value) when is_atom(value) and not is_nil(value),
    do: operation_name(Atom.to_string(value))

  defp operation_name(value) when value in @operation_types, do: {:ok, value}
  defp operation_name(value), do: {:error, {:unsupported_morph_operation, value}}

  @spec scopes(term()) :: {:ok, [String.t()]} | {:error, term()}
  defp scopes(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, MapSet.new()}, fn value, {:ok, normalized} ->
      case scope(value) do
        {:ok, name} -> {:cont, {:ok, MapSet.put(normalized, name)}}
        {:error, _reason} -> {:halt, {:error, {:invalid_morph_surface_scopes, values}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.sort(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp scopes(value), do: {:error, {:invalid_morph_surface_scopes, value}}

  @spec scope(term()) :: {:ok, String.t()} | {:error, term()}
  defp scope(value) when is_atom(value) and not is_nil(value), do: scope(Atom.to_string(value))
  defp scope(value) when is_binary(value) and value != "", do: {:ok, value}
  defp scope(value), do: {:error, {:invalid_morph_surface_scope, value}}

  @spec prompt_tokens(term()) :: {:ok, pos_integer()} | {:error, term()}
  defp prompt_tokens(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp prompt_tokens(value), do: {:error, {:invalid_morph_surface_prompt_tokens, value}}

  @spec approval(term()) :: {:ok, approval_requirement()} | {:error, term()}
  defp approval(value) when is_atom(value) and not is_nil(value),
    do: approval(Atom.to_string(value))

  defp approval(value) when value in @approval_requirements,
    do: {:ok, if(value == "human", do: :human, else: :host_policy)}

  defp approval(value), do: {:error, {:invalid_morph_surface_approval, value}}

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec unique_keyword?(keyword()) :: boolean()
  defp unique_keyword?(values) do
    keys = Keyword.keys(values)
    MapSet.size(MapSet.new(keys)) == length(keys)
  end

  @spec shape(term()) :: :map | :tuple | :binary | :other
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
