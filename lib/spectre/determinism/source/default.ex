defmodule Spectre.Determinism.Source.Default do
  @moduledoc false

  @behaviour Spectre.Determinism.Source

  @impl true
  def system_time(unit, _opts), do: System.system_time(unit)

  @impl true
  def monotonic_time(:native, _opts), do: System.monotonic_time()
  def monotonic_time(unit, _opts), do: System.monotonic_time(unit)

  @impl true
  def random_bytes(count, _opts), do: :crypto.strong_rand_bytes(count)
end
