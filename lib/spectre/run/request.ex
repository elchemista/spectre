defmodule Spectre.Run.Request do
  @moduledoc """
  Transport-safe description of a Run policy request.

  The authoritative `Spectre.Awaitable` remains in Run state. This projection
  exposes only opaque identifiers and logical request data to a host adapter.
  """

  alias Spectre.Awaitable
  alias Spectre.Run.Value

  @enforce_keys [:id, :kind, :name]
  defstruct [
    :id,
    :kind,
    :name,
    :subject_id,
    :label,
    :max_attempts,
    status: :open,
    attempts: 0,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          name: term(),
          subject_id: String.t() | nil,
          label: atom() | nil,
          max_attempts: pos_integer() | nil,
          status: Awaitable.status(),
          attempts: non_neg_integer(),
          metadata: map()
        }

  @doc false
  @spec from_awaitable(Awaitable.t()) :: t()
  def from_awaitable(%Awaitable{} = awaitable) do
    {:ok, id} = Value.opaque_id(awaitable.id, "request")
    {:ok, subject_id} = Value.opaque_id(awaitable.subject_id, "subject")

    request =
      %__MODULE__{
        id: id,
        kind: awaitable.kind,
        name: awaitable.name,
        subject_id: subject_id,
        label: awaitable.label,
        max_attempts: awaitable.max_attempts,
        status: awaitable.status,
        attempts: awaitable.attempts,
        metadata: logical_metadata(awaitable.metadata)
      }

    case Value.validate(request, [:request]) do
      :ok -> request
      {:error, reason} -> raise ArgumentError, "non-portable Run request: #{inspect(reason)}"
    end
  end

  defp logical_metadata(metadata) when is_map(metadata) do
    case Value.validate(metadata, [:request, :metadata]) do
      :ok -> metadata
      {:error, _reason} -> %{}
    end
  end

  defp logical_metadata(_metadata), do: %{}
end
