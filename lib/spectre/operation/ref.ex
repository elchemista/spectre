defmodule Spectre.Operation.Ref do
  @moduledoc "Stable, portable reference to a Work, Vigil or external controller loop."

  alias Spectre.Run.Value

  @kinds [:work, :vigil, :directive]

  @enforce_keys [:id, :kind, :subject_id]
  defstruct [:id, :kind, :subject_id, :controller, :correlation_id]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :work | :vigil | :directive,
          subject_id: String.t(),
          controller: module() | nil,
          correlation_id: String.t() | nil
        }

  @spec from_loop(Spectre.Operation.Loop.t()) :: t()
  def from_loop(%Spectre.Operation.Loop{} = loop) do
    ref = %__MODULE__{
      id: loop.id,
      kind: loop.kind,
      subject_id: loop.subject_id,
      controller: loop.controller,
      correlation_id: loop.correlation_id
    }

    validate!(ref)
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = ref) do
    cond do
      not valid_binary?(ref.id) or not valid_binary?(ref.subject_id) ->
        {:error, :invalid_operation_ref_identity}

      ref.kind not in @kinds ->
        {:error, :invalid_operation_ref_kind}

      not is_nil(ref.controller) and not is_atom(ref.controller) ->
        {:error, :invalid_operation_ref_controller}

      not is_nil(ref.correlation_id) and not valid_binary?(ref.correlation_id) ->
        {:error, :invalid_operation_ref_correlation}

      true ->
        case Value.validate(ref, [:operation_ref, ref.id]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:nonportable_operation_ref, reason}}
        end
    end
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = ref) do
    case validate(ref) do
      :ok -> ref
      {:error, reason} -> raise ArgumentError, "invalid operation ref: #{inspect(reason)}"
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""
end
