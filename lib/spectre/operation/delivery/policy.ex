defmodule Spectre.Operation.Delivery.Policy do
  @moduledoc "Deterministic consent, deduplication, rate and quiet-hours policy."

  alias Spectre.Run.Value

  defstruct consent_required: true,
            event_types: [],
            channels: [],
            max_deliveries: 10,
            window_ms: 3_600_000,
            dedupe_ttl_ms: 86_400_000,
            quiet_hours: nil,
            utc_offset_minutes: 0,
            mode: :immediate,
            metadata: %{}

  @type t :: %__MODULE__{}

  @spec new(t() | map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: validate!(policy)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      consent_required: attr(attrs, :consent_required, true),
      event_types: List.wrap(attr(attrs, :event_types, [])),
      channels: List.wrap(attr(attrs, :channels, [])),
      max_deliveries: attr(attrs, :max_deliveries, 10),
      window_ms: attr(attrs, :window_ms, 3_600_000),
      dedupe_ttl_ms: attr(attrs, :dedupe_ttl_ms, 86_400_000),
      quiet_hours: attr(attrs, :quiet_hours),
      utc_offset_minutes: attr(attrs, :utc_offset_minutes, 0),
      mode: attr(attrs, :mode, :immediate),
      metadata: attr(attrs, :metadata, %{})
    }
    |> validate!()
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = policy) do
    cond do
      not is_boolean(policy.consent_required) ->
        {:error, :invalid_delivery_consent_policy}

      not valid_unique_list?(policy.event_types) ->
        {:error, :invalid_delivery_event_types}

      Enum.any?(policy.event_types, &(not is_atom(&1) or is_nil(&1))) ->
        {:error, :invalid_delivery_event_types}

      not valid_unique_list?(policy.channels) ->
        {:error, :invalid_delivery_channels}

      not is_integer(policy.max_deliveries) or policy.max_deliveries <= 0 or
        not is_integer(policy.window_ms) or policy.window_ms <= 0 or
        not is_integer(policy.dedupe_ttl_ms) or policy.dedupe_ttl_ms < 0 ->
        {:error, :invalid_delivery_rate_or_deduplication_limits}

      not valid_quiet_hours?(policy.quiet_hours) ->
        {:error, :invalid_delivery_quiet_hours}

      not is_integer(policy.utc_offset_minutes) or policy.utc_offset_minutes not in -840..840 ->
        {:error, :invalid_delivery_utc_offset}

      policy.mode not in [:immediate, :digest] ->
        {:error, :invalid_delivery_mode}

      not is_map(policy.metadata) ->
        {:error, :invalid_delivery_policy_metadata}

      true ->
        case Value.validate(policy, [:delivery, :policy]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:nonportable_delivery_policy, reason}}
        end
    end
  end

  defp validate!(policy) do
    case validate(policy) do
      :ok -> policy
      {:error, reason} -> raise ArgumentError, "invalid delivery policy: #{inspect(reason)}"
    end
  end

  defp valid_unique_list?(values),
    do: is_list(values) and Enum.uniq(values) == values and Enum.all?(values, &(not is_nil(&1)))

  defp valid_quiet_hours?(nil), do: true

  defp valid_quiet_hours?({start_minute, end_minute}),
    do: valid_minutes?(start_minute, end_minute)

  defp valid_quiet_hours?(%{start: start_minute, end: end_minute}),
    do: valid_minutes?(start_minute, end_minute)

  defp valid_quiet_hours?(_value), do: false

  defp valid_minutes?(start_minute, end_minute),
    do: start_minute in 0..1439 and end_minute in 0..1439 and start_minute != end_minute

  defp attr(map, key, default \\ nil),
    do: Map.get(map, key, default)
end
