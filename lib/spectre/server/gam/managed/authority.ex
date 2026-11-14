defmodule Spectre.Server.GAM.Managed.Authority do
  @moduledoc false
  @behaviour Spectre.GAM.Genesis.Verifier

  alias Spectre.GAM.Genesis

  # The application configuration is the external authority boundary. The
  # expected digest is computed from that trusted configuration before Domain
  # startup, never from an agent proposal or from the recovered ledger.
  @doc false
  @spec verify(Genesis.t(), keyword()) :: :ok | {:error, :application_authority_mismatch}
  @impl true
  def verify(%Genesis{} = genesis, opts) do
    if Genesis.digest(genesis) == Keyword.get(opts, :genesis_digest),
      do: :ok,
      else: {:error, :application_authority_mismatch}
  end
end
