defmodule Spectre.Clock.System do
  @moduledoc false

  @behaviour Spectre.Clock

  @impl true
  def now, do: System.system_time(:millisecond)
end
