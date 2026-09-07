defmodule Spectre.Clock.Guard do
  @moduledoc """
  Boot-local plausibility fence for a host wall clock.

  An accepted initial wall reading is anchored to BEAM monotonic time. Later
  wall readings must remain within the configured drift tolerance. Idle time
  is legitimate elapsed time, not a forward jump; neither a bad reading nor a
  later correction moves the anchor. This is not an independent trusted clock:
  the initial reading and time across restarts still require host assurance.
  """

  @enforce_keys [:wall, :monotonic, :tolerance_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          wall: non_neg_integer(),
          monotonic: integer(),
          tolerance_ms: pos_integer()
        }

  @doc false
  @spec new(non_neg_integer(), pos_integer() | :infinity, integer()) ::
          {:ok, t() | nil} | {:error, term()}
  def new(wall, tolerance, monotonic \\ System.monotonic_time(:millisecond))
  def new(_wall, :infinity, _monotonic), do: {:ok, nil}

  def new(wall, tolerance, monotonic) when is_integer(tolerance) and tolerance > 0 do
    {:ok, %__MODULE__{wall: wall, monotonic: monotonic, tolerance_ms: tolerance}}
  end

  def new(_wall, _tolerance, _monotonic), do: {:error, :invalid_clock_tolerance_ms}

  @doc false
  @spec validate(t() | nil, non_neg_integer(), integer()) :: :ok | {:error, term()}
  def validate(guard, now, monotonic \\ System.monotonic_time(:millisecond))
  def validate(nil, _now, _monotonic), do: :ok

  def validate(%__MODULE__{} = guard, now, monotonic) do
    expected = guard.wall + monotonic - guard.monotonic
    drift = now - expected

    if abs(drift) <= guard.tolerance_ms,
      do: :ok,
      else: {:error, {:clock_drift_exceeded, drift, guard.tolerance_ms}}
  end
end
