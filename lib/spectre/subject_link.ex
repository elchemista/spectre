defmodule Spectre.SubjectLink do
  @moduledoc """
  Explicit, auditable association between a Subject and an external identity.

  Revocation stops future resolution through the identity but never deletes
  the Subject or its Agent Instance state.
  """

  alias Spectre.AgentRef
  alias Spectre.ExternalIdentity
  alias Spectre.Subject

  @enforce_keys [:id, :agent_ref, :subject, :external_identity, :receipt_ref, :committed_at]
  defstruct [
    :id,
    :agent_ref,
    :subject,
    :external_identity,
    :receipt_ref,
    :committed_at,
    :revoked_at,
    status: :active,
    revision: 1,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          agent_ref: AgentRef.t(),
          subject: Subject.t(),
          external_identity: ExternalIdentity.t(),
          receipt_ref: String.t(),
          committed_at: integer(),
          revoked_at: integer() | nil,
          status: :active | :revoked,
          revision: pos_integer(),
          metadata: map()
        }
end
