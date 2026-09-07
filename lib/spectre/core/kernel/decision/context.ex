defmodule Spectre.Kernel.Decision.Context do
  @moduledoc """
  Minimal snapshot metadata consumed by the pure Decision algebra.

  The kernel classifies the Candidate before this boundary, so the full Surface
  is deliberately absent. `meter_accounts` contains only the physical accounts
  owned by the one resolved authority, never a Domain-wide Meter view. The
  container is not persisted and grants nothing; its remaining fields are
  copied into the durable Decision so replay can verify the exact snapshot.
  """

  alias Spectre.Kernel.Meter

  @enforce_keys [
    :meter_accounts,
    :host_profile_ref,
    :surface_revision,
    :authority_revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          meter_accounts: Meter.accounts(),
          host_profile_ref: String.t(),
          surface_revision: pos_integer(),
          authority_revision: non_neg_integer()
        }
end
