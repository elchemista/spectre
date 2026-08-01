defmodule Spectre.Operation.Wait do
  @moduledoc "Portable wait boundary retained by an operational loop without a live Runner."

  alias Spectre.Run.Value

  @kinds [:human, :timer, :event, :retry, :reconciliation, :external]

  @enforce_keys [:id, :kind]
  defstruct [:id, :kind, :key, :due_at, :payload, :reason, :generation, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          key: term(),
          due_at: non_neg_integer() | nil,
          payload: term(),
          reason: term(),
          generation: non_neg_integer() | nil,
          metadata: map()
        }

  @spec new(atom(), keyword()) :: t()
  def new(kind, opts \\ []) when kind in @kinds and is_list(opts) do
    due_at = Keyword.get(opts, :due_at)

    unless is_nil(due_at) or (is_integer(due_at) and due_at >= 0),
      do: raise(ArgumentError, "operation wait due_at must be a timestamp")

    wait = %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      kind: kind,
      key: Keyword.get(opts, :key),
      due_at: due_at,
      payload: Keyword.get(opts, :payload),
      reason: Keyword.get(opts, :reason),
      generation: Keyword.get(opts, :generation),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate!(wait)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = wait) do
    cond do
      not (is_binary(wait.id) and wait.id != "") ->
        {:error, :invalid_operation_wait_id}

      wait.kind not in @kinds ->
        {:error, {:invalid_operation_wait_kind, wait.kind}}

      not is_nil(wait.due_at) and (not is_integer(wait.due_at) or wait.due_at < 0) ->
        {:error, :invalid_operation_wait_due_at}

      not is_nil(wait.generation) and
          (not is_integer(wait.generation) or wait.generation < 0) ->
        {:error, :invalid_operation_wait_generation}

      not is_map(wait.metadata) ->
        {:error, :invalid_operation_wait_metadata}

      true ->
        portable(wait)
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = wait) do
    case validate(wait) do
      :ok -> wait
      {:error, reason} -> raise ArgumentError, "invalid operation wait: #{inspect(reason)}"
    end
  end

  defp portable(wait) do
    case Value.validate(wait, [:operation_wait, wait.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_wait, reason}}
    end
  end
end
