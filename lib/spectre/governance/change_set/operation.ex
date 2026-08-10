defmodule Spectre.Governance.ChangeSet.Operation do
  @moduledoc """
  One inert operation in a governed Definition ChangeSet.

  Operations carry only a stable textual type and JSON-shaped payload. The
  type is resolved against a registry assembled by trusted host code; authored
  data never selects a module, function, evaluator, or policy implementation.
  """

  alias Spectre.Governance.Data
  @enforce_keys [:type, :payload]
  defstruct [:type, :payload]

  @type t :: %__MODULE__{type: String.t(), payload: map()}

  @doc "Builds a transport-stable, non-executable operation."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = operation), do: operation |> to_data() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_governance_operation, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         {:ok, type} <- required_type(value(attrs, :type)),
         {:ok, payload} <- normalize_payload(value(attrs, :payload, %{})) do
      {:ok, %__MODULE__{type: type, payload: payload}}
    end
  end

  def new(value), do: {:error, {:invalid_governance_operation, shape(value)}}

  @doc "Returns the JSON-shaped representation sealed into ChangeSet identity."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = operation) do
    %{"type" => operation.type, "payload" => operation.payload}
  end

  @spec exact_fields(map()) :: :ok | {:error, term()}
  defp exact_fields(attrs) do
    allowed = [:type, :payload, "type", "payload"]
    collisions = Data.alias_collisions(attrs, [:type, :payload])

    case {Map.keys(attrs) -- allowed, collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_governance_operation_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_governance_operation_fields, collisions}}
    end
  end

  @spec required_type(term()) :: {:ok, String.t()} | {:error, term()}
  defp required_type(type) when is_atom(type) and not is_nil(type),
    do: required_type(Atom.to_string(type))

  defp required_type(type) when is_binary(type) and type != "" do
    if valid_name?(type),
      do: {:ok, type},
      else: {:error, {:invalid_governance_operation_type, type}}
  end

  defp required_type(type), do: {:error, {:invalid_governance_operation_type, type}}

  @spec normalize_payload(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_payload(payload) when is_map(payload) and not is_struct(payload) do
    case Data.normalize_map(payload) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_governance_operation_payload, reason}}
    end
  end

  defp normalize_payload(value),
    do: {:error, {:invalid_governance_operation_payload, shape(value)}}

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  @spec valid_name?(String.t()) :: boolean()
  defp valid_name?(value), do: Regex.match?(~r/^[a-z][a-z0-9_]{0,63}\z/, value)

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_function(value), do: :function
  defp shape(value) when is_pid(value), do: :pid
  defp shape(value) when is_reference(value), do: :reference
  defp shape(_value), do: :other
end
