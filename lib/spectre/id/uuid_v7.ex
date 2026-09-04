defmodule Spectre.Id.UUIDv7 do
  @moduledoc false

  @behaviour Spectre.Id.Source

  @impl true
  def generate, do: UUIDv7.generate()
end
