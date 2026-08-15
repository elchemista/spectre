defmodule Spectre.Inference.ProviderProtocol do
  @moduledoc false

  alias Spectre.Inference.ProviderEvent

  @spec validate_batch([ProviderEvent.t()], pos_integer()) :: :ok | {:error, term()}
  def validate_batch(events, limit) when is_list(events) and is_integer(limit) and limit > 0 do
    cond do
      length(events) > limit ->
        {:error, :provider_stream_overflow}

      invalid = Enum.find_value(events, &invalid_event/1) ->
        {:error, {:invalid_provider_event_batch, invalid}}

      not valid_terminal_order?(events) ->
        {:error, :invalid_provider_terminal_order}

      not valid_started_order?(events) ->
        {:error, :invalid_provider_started_order}

      true ->
        :ok
    end
  end

  def validate_batch(_events, _limit), do: {:error, :invalid_provider_event_batch}

  @spec validate_sequence(non_neg_integer() | nil, non_neg_integer() | nil) ::
          :ok | {:error, :provider_sequence_violation}
  def validate_sequence(nil, nil), do: :ok
  def validate_sequence(nil, value) when is_integer(value) and value >= 0, do: :ok
  def validate_sequence(current, value) when value == current + 1, do: :ok
  def validate_sequence(_current, _value), do: {:error, :provider_sequence_violation}

  @spec next_sequence(non_neg_integer() | nil, non_neg_integer() | nil) ::
          non_neg_integer() | nil
  def next_sequence(current, nil), do: current
  def next_sequence(_current, value), do: value

  defp invalid_event(%ProviderEvent{} = event) do
    case ProviderEvent.validate(event) do
      :ok -> false
      {:error, reason} -> reason
    end
  end

  defp invalid_event(_event), do: :invalid_provider_event

  defp valid_terminal_order?(events) do
    terminal_indexes =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%ProviderEvent{kind: kind}, index} when kind in [:completed, :failed] -> [index]
        _event -> []
      end)

    case terminal_indexes do
      [] -> true
      [index] -> index == length(events) - 1
      _multiple -> false
    end
  end

  defp valid_started_order?(events) do
    started_indexes =
      events
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {%ProviderEvent{kind: :started}, index} -> [index]
        _event -> []
      end)

    started_indexes in [[], [0]]
  end
end
