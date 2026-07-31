defmodule Spectre.Operation.Spec do
  @moduledoc """
  Immutable registry entry for one operation available to an operational loop.

  Executors and validators are stable module/function references. They are
  resolved from code after restart and are never embedded in checkpoints.
  """

  alias Spectre.Operation.Retry
  alias Spectre.Run.Value

  @kinds [:function, :action, :effect, :cognitive, :planner]
  @side_effects [:none, :idempotent, :reconcilable, :non_idempotent]

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    :executor,
    :input,
    :output,
    :reconcile,
    :fallback,
    :policy,
    :domain,
    :risk,
    :description,
    :remember,
    timeout: 30_000,
    side_effect: :none,
    retry: %Retry{},
    catalog: [],
    metadata: %{}
  ]

  @type validator :: nil | atom() | module() | {module(), atom()}
  @type executor :: nil | module() | {module(), atom()}

  @type t :: %__MODULE__{
          id: atom() | String.t(),
          kind: :function | :action | :effect | :cognitive | :planner,
          executor: executor() | term(),
          input: validator(),
          output: validator(),
          reconcile: executor(),
          fallback: executor(),
          policy: :registered | executor(),
          domain: [term()] | nil,
          risk: atom() | nil,
          description: String.t() | nil,
          remember: false | true | map(),
          timeout: pos_integer(),
          side_effect: :none | :idempotent | :reconcilable | :non_idempotent,
          retry: Retry.t(),
          catalog: [atom() | String.t()],
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = spec), do: validate!(spec)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: attr(attrs, :id),
      kind: attr(attrs, :kind, :function),
      executor: attr(attrs, :executor),
      input: attr(attrs, :input),
      output: attr(attrs, :output),
      reconcile: attr(attrs, :reconcile),
      fallback: attr(attrs, :fallback),
      policy: attr(attrs, :policy, :registered),
      domain: attr(attrs, :domain),
      risk: attr(attrs, :risk),
      description: attr(attrs, :description),
      remember: attr(attrs, :remember, false),
      timeout: attr(attrs, :timeout, 30_000),
      side_effect: attr(attrs, :side_effect, default_side_effect(attr(attrs, :kind, :function))),
      retry: Retry.new(attr(attrs, :retry)),
      catalog: List.wrap(attr(attrs, :catalog, [])),
      metadata: attr(attrs, :metadata, %{})
    }
    |> validate!()
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = spec) do
    cond do
      not valid_id?(spec.id) ->
        {:error, {:invalid_operation_id, spec.id}}

      spec.kind not in @kinds ->
        {:error, {:invalid_operation_kind, spec.kind}}

      not valid_executor?(spec) ->
        {:error, {:invalid_operation_executor, spec.id, spec.executor}}

      not valid_validator?(spec.input) ->
        {:error, {:invalid_operation_input_validator, spec.id}}

      not valid_validator?(spec.output) ->
        {:error, {:invalid_operation_output_validator, spec.id}}

      not valid_executor_ref?(spec.reconcile, true) ->
        {:error, {:invalid_operation_reconcile, spec.id}}

      not valid_executor_ref?(spec.fallback, true) ->
        {:error, {:invalid_operation_fallback, spec.id}}

      not valid_policy?(spec.policy) ->
        {:error, {:invalid_operation_policy, spec.id}}

      not (is_integer(spec.timeout) and spec.timeout > 0) ->
        {:error, {:invalid_operation_timeout, spec.id, spec.timeout}}

      spec.side_effect not in @side_effects ->
        {:error, {:invalid_operation_side_effect, spec.id, spec.side_effect}}

      spec.side_effect == :reconcilable and is_nil(spec.reconcile) ->
        {:error, {:operation_reconcile_required, spec.id}}

      not is_nil(spec.domain) and not is_list(spec.domain) ->
        {:error, {:invalid_operation_domain, spec.id}}

      spec.kind == :cognitive and spec.domain == [] ->
        {:error, {:empty_cognitive_domain, spec.id}}

      is_list(spec.domain) and Enum.uniq(spec.domain) != spec.domain ->
        {:error, {:duplicate_operation_domain_value, spec.id}}

      spec.kind == :planner and spec.catalog == [] ->
        {:error, {:empty_operation_catalog, spec.id}}

      not is_list(spec.catalog) or Enum.any?(spec.catalog, &(not valid_id?(&1))) or
          Enum.uniq(spec.catalog) != spec.catalog ->
        {:error, {:invalid_operation_catalog, spec.id}}

      not is_map(spec.metadata) ->
        {:error, {:invalid_operation_metadata, spec.id}}

      spec.remember not in [true, false] and not is_map(spec.remember) ->
        {:error, {:invalid_operation_memory_policy, spec.id}}

      not is_nil(spec.risk) and not is_atom(spec.risk) ->
        {:error, {:invalid_operation_risk, spec.id}}

      not is_nil(spec.description) and not is_binary(spec.description) ->
        {:error, {:invalid_operation_description, spec.id}}

      true ->
        validate_portable_contract(spec)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = spec) do
    case validate(spec) do
      :ok -> spec
      {:error, reason} -> raise ArgumentError, "invalid operation spec: #{inspect(reason)}"
    end
  end

  defp valid_executor?(%__MODULE__{kind: kind, executor: executor})
       when kind in [:function, :cognitive, :planner],
       do: valid_executor_ref?(executor, false)

  defp valid_executor?(%__MODULE__{kind: :action, executor: executor}),
    do: is_map(executor) or is_list(executor)

  defp valid_executor?(%__MODULE__{kind: :effect, executor: executor}),
    do: is_nil(executor) or valid_executor_ref?(executor, false)

  defp valid_executor_ref?(nil, optional?), do: optional?

  defp valid_executor_ref?({module, function}, _optional?),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function)

  defp valid_executor_ref?(module, _optional?) when is_atom(module), do: true
  defp valid_executor_ref?(_value, _optional?), do: false

  defp valid_validator?(nil), do: true

  defp valid_validator?(validator)
       when validator in [:any, :map, :list, :binary, :integer, :number, :atom, :boolean],
       do: true

  defp valid_validator?(validator), do: valid_executor_ref?(validator, false)

  defp valid_policy?(:registered), do: true
  defp valid_policy?(value), do: valid_executor_ref?(value, false)

  defp valid_id?(value) when is_atom(value), do: not is_nil(value)
  defp valid_id?(value) when is_binary(value), do: value != ""
  defp valid_id?(_value), do: false

  defp default_side_effect(:action), do: :non_idempotent
  defp default_side_effect(:effect), do: :non_idempotent
  defp default_side_effect(_kind), do: :none

  defp validate_portable_contract(spec) do
    contract = %{
      id: spec.id,
      kind: spec.kind,
      domain: spec.domain,
      risk: spec.risk,
      description: spec.description,
      remember: spec.remember,
      catalog: spec.catalog,
      metadata: spec.metadata
    }

    case Value.validate(contract, [:operation_spec, spec.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_contract, spec.id, reason}}
    end
  end

  defp attr(map, key, default \\ nil),
    do: Map.get(map, key, default)
end
