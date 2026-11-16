defmodule Spectre.GAM.Id.UUIDv7 do
  @moduledoc false

  @behaviour Spectre.GAM.Id.Source

  @impl true
  def generate, do: UUIDv7.generate()
end
