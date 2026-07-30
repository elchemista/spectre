defmodule Spectre.LinkIntent do
  @moduledoc """
  One bounded, explicit attempt to link a destination identity to a Subject.

  Only the challenge digest is retained. The one-time challenge is returned to
  the trusted caller when the intent is opened and must be delivered through
  the destination channel.
  """

  alias Spectre.AgentRef
  alias Spectre.ExternalIdentity
  alias Spectre.Subject

  @enforce_keys [
    :id,
    :agent_ref,
    :subject,
    :source_identity,
    :destination_identity,
    :challenge_digest,
    :expires_at,
    :attempts_remaining
  ]
  defstruct [
    :id,
    :agent_ref,
    :subject,
    :source_identity,
    :destination_identity,
    :challenge_digest,
    :expires_at,
    :attempts_remaining,
    :receipt_ref,
    status: :pending,
    source_confirmation?: false,
    revision: 0
  ]

  @type status :: :pending | :awaiting_source | :committed | :expired | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          agent_ref: AgentRef.t(),
          subject: Subject.t(),
          source_identity: ExternalIdentity.t(),
          destination_identity: ExternalIdentity.t(),
          challenge_digest: binary(),
          expires_at: integer(),
          attempts_remaining: non_neg_integer(),
          receipt_ref: String.t() | nil,
          status: status(),
          source_confirmation?: boolean(),
          revision: non_neg_integer()
        }
end
