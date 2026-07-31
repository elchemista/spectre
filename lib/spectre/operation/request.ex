defmodule Spectre.Operation.Request do
  @moduledoc "One portable request for a registered operation."

  alias Spectre.Run.Value

  @enforce_keys [:id, :operation]
  defstruct [:id, :operation, :input, :phase, :branch, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          operation: atom() | String.t(),
          input: term(),
          phase: atom() | String.t() | nil,
          branch: atom() | String.t() | nil,
          metadata: map()
        }

  @spec new(atom() | String.t(), term(), keyword()) :: t()
  def new(operation, input \\ nil, opts \\ []) do
    unless (is_atom(operation) and not is_nil(operation)) or
             (is_binary(operation) and operation != "") do
      raise ArgumentError, "operation request requires a stable operation id"
    end

    metadata = Keyword.get(opts, :metadata, %{})
    unless is_map(metadata), do: raise(ArgumentError, "operation request metadata must be a map")

    request = %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      operation: operation,
      input: input,
      phase: Keyword.get(opts, :phase),
      branch: Keyword.get(opts, :branch),
      metadata: metadata
    }

    validate!(request)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = request) do
    cond do
      not valid_binary?(request.id) -> {:error, :invalid_operation_request_id}
      not valid_name?(request.operation) -> {:error, :invalid_operation_request_operation}
      not optional_name?(request.phase) -> {:error, :invalid_operation_request_phase}
      not optional_name?(request.branch) -> {:error, :invalid_operation_request_branch}
      not is_map(request.metadata) -> {:error, :invalid_operation_request_metadata}
      true -> portable(request)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = request) do
    case validate(request) do
      :ok -> request
      {:error, reason} -> raise ArgumentError, "invalid operation request: #{inspect(reason)}"
    end
  end

  defp portable(request) do
    case Value.validate(request, [:operation_request, request.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_request, reason}}
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""
  defp valid_name?(value), do: (is_atom(value) and not is_nil(value)) or valid_binary?(value)
  defp optional_name?(nil), do: true
  defp optional_name?(value), do: valid_name?(value)
end
