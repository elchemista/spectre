defmodule Spectre.GAM.Genesis.Verifier do
  @moduledoc """
  Host attestation boundary for the external root of authority.

  Verification happens before a Domain with a non-empty governed surface is
  allowed to boot. The verifier does not issue Mandates; it only verifies the
  Genesis supplied by the host.
  """

  alias Spectre.GAM.Genesis

  @callback verify(Genesis.t(), keyword()) :: :ok | {:error, term()}
end
