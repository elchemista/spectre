defmodule Spectre.Skill.Runtime.Response do
  @moduledoc """
  Public result of one declarative runtime Skill response.

  Operation responses contain a portable `Spectre.Operation.Request`; Work
  responses contain only a canonical program reference and closed input. The
  runtime never executes either boundary. The host completes it and releases
  the associated continuation explicitly.
  """

  alias Spectre.Definition.Ref
  alias Spectre.Operation.Request
  alias Spectre.Prompt.Plan
  alias Spectre.Prompt.Receipt

  @enforce_keys [:kind, :mount_id, :definition_ref, :route_label]
  defstruct [
    :kind,
    :mount_id,
    :definition_ref,
    :route_label,
    :output,
    :prompt_plan,
    :prompt_receipt,
    :operation_request,
    :work_ref,
    :work_input,
    :program_digest,
    :continuation_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: :reply | :operation | :work,
          mount_id: term(),
          definition_ref: Ref.t(),
          route_label: term(),
          output: String.t() | nil,
          prompt_plan: Plan.t() | nil,
          prompt_receipt: Receipt.t() | nil,
          operation_request: Request.t() | nil,
          work_ref: String.t() | nil,
          work_input: term(),
          program_digest: String.t() | nil,
          continuation_id: String.t() | nil,
          metadata: map()
        }
end
