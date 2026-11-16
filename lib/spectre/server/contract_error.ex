defmodule Spectre.Server.ContractError do
  @moduledoc "A payload-free application state or continuation contract failure."
  defexception [:details]

  @impl true
  @spec message(%__MODULE__{}) :: String.t()
  def message(%{details: details}), do: "Server contract violation: #{inspect(details)}"
end
