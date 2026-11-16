defmodule Spectre.GAM.Clock.System do
  @moduledoc false

  @behaviour Spectre.GAM.Clock

  @impl true
  def now, do: System.system_time(:millisecond)
end
