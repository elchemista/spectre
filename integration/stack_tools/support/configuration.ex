defmodule Outreach.Configuration do
  @moduledoc "Application permissions for the automatic AgentServer GAM domain."

  @doc "The application selects operations and consent rules; Spectre owns the protocol."
  @spec gam(String.t(), pid()) :: keyword()
  def gam(path, journal) do
    [
      storage: {:disk, path},
      store: {Spectre.Ledger.ServerStore, journal},
      operations: %{
        {:kinetic, :send_email} => [class: "email.send"],
        :send_notice => [class: "notice.send"],
        :save_report => [
          class: "report.save",
          confirm: true,
          message: "Save the outreach report?"
        ]
      }
    ]
  end
end
