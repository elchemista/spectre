defmodule Spectre.Server.GAM.Managed.Mind do
  @moduledoc false
  use Spectre.GAM.Mind, ref: "spectre:managed:mind:v1"
  @impl true
  def deliberate(_turn, _opts), do: {:ok, []}
end
