defmodule Spectre.Operation.Update do
  @moduledoc "One committed update to a loop's effective context."

  alias Spectre.Run.Value

  @statuses [:pending, :applied, :rejected]
  @invalidation_limit 256

  @enforce_keys [:id, :payload, :correlation_id, :provenance, :requested_at]
  defstruct [
    :id,
    :payload,
    :correlation_id,
    :causation_id,
    :provenance,
    :base_context_revision,
    :applied_context_revision,
    :requested_at,
    :applied_at,
    status: :pending,
    invalidations: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          payload: term(),
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          provenance: map(),
          base_context_revision: non_neg_integer() | nil,
          applied_context_revision: non_neg_integer() | nil,
          requested_at: non_neg_integer(),
          applied_at: non_neg_integer() | nil,
          status: :pending | :applied | :rejected,
          invalidations: [term()],
          metadata: map()
        }

  @spec new(term(), keyword()) :: t()
  def new(payload, opts \\ []) when is_list(opts) do
    %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      payload: payload,
      correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
      causation_id: Keyword.get(opts, :causation_id),
      provenance: Keyword.get(opts, :provenance, %{}),
      base_context_revision: Keyword.get(opts, :base_context_revision),
      requested_at: Keyword.get(opts, :requested_at, System.system_time(:millisecond)),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec applied(t(), non_neg_integer(), [term()]) :: t()
  def applied(%__MODULE__{} = update, revision, invalidations \\ []) do
    %{
      update
      | status: :applied,
        applied_context_revision: revision,
        applied_at: System.system_time(:millisecond),
        invalidations: invalidations
    }
  end

  @spec rejected(t(), term()) :: t()
  def rejected(%__MODULE__{} = update, reason) do
    %{
      update
      | status: :rejected,
        applied_at: System.system_time(:millisecond),
        metadata: Map.put(update.metadata, :rejection, reason)
    }
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = update) do
    cond do
      not valid_binary?(update.id) ->
        {:error, :invalid_operation_update_id}

      not valid_binary?(update.correlation_id) ->
        {:error, :invalid_operation_update_correlation}

      not is_nil(update.causation_id) and not valid_binary?(update.causation_id) ->
        {:error, :invalid_operation_update_causation}

      not is_map(update.provenance) ->
        {:error, :invalid_operation_update_provenance}

      not optional_revision?(update.base_context_revision) ->
        {:error, :invalid_operation_update_base_revision}

      not optional_revision?(update.applied_context_revision) ->
        {:error, :invalid_operation_update_applied_revision}

      not non_negative_integer?(update.requested_at) ->
        {:error, :invalid_operation_update_requested_at}

      not is_nil(update.applied_at) and not non_negative_integer?(update.applied_at) ->
        {:error, :invalid_operation_update_applied_at}

      update.status not in @statuses ->
        {:error, :invalid_operation_update_status}

      not is_list(update.invalidations) or length(update.invalidations) > @invalidation_limit or
          Enum.uniq(update.invalidations) != update.invalidations ->
        {:error, :invalid_operation_update_invalidations}

      not is_map(update.metadata) ->
        {:error, :invalid_operation_update_metadata}

      true ->
        with :ok <- validate_status_fields(update) do
          portable(update)
        end
    end
  end

  defp validate_status_fields(%__MODULE__{status: :pending} = update) do
    if is_nil(update.applied_at) and is_nil(update.applied_context_revision) and
         update.invalidations == [] and is_nil(rejection(update)),
       do: :ok,
       else: {:error, :invalid_pending_operation_update}
  end

  defp validate_status_fields(%__MODULE__{status: :applied} = update) do
    if ordered_time?(update.applied_at, update.requested_at) and
         not is_nil(update.applied_context_revision) and is_nil(rejection(update)),
       do: :ok,
       else: {:error, :invalid_applied_operation_update}
  end

  defp validate_status_fields(%__MODULE__{status: :rejected} = update) do
    if ordered_time?(update.applied_at, update.requested_at) and
         is_nil(update.applied_context_revision) and update.invalidations == [] and
         not is_nil(rejection(update)),
       do: :ok,
       else: {:error, :invalid_rejected_operation_update}
  end

  defp rejection(update),
    do: Map.get(update.metadata, :rejection, Map.get(update.metadata, "rejection"))

  defp ordered_time?(value, floor),
    do: is_integer(value) and is_integer(floor) and value >= floor

  defp portable(update) do
    case Value.validate(update, [:operation_update, update.id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_update, reason}}
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""
  defp optional_revision?(nil), do: true
  defp optional_revision?(value), do: non_negative_integer?(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
