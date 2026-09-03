defmodule Spectre.Kernel.Decision.Context do
  @moduledoc """
  Snapshot metadata consumed by the pure Decision algebra.

  The container separates environmental facts from Candidate and authority
  inputs. It is not persisted and grants nothing; its revision fields are
  copied into the durable Decision so replay can verify the exact snapshot.
  """

  alias Spectre.Surface

  @enforce_keys [
    :meter_accounts,
    :surface,
    :host_profile_ref,
    :surface_revision,
    :authority_revision
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          meter_accounts: %{optional(String.t()) => map()},
          surface: Surface.t(),
          host_profile_ref: String.t(),
          surface_revision: pos_integer(),
          authority_revision: non_neg_integer()
        }
end
