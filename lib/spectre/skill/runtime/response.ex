defmodule Spectre.Skill.Runtime.Response do
  @moduledoc """
  Public result of one declarative runtime Skill response.

  Operation responses contain a portable `Spectre.Operation.Request`; the
  runtime never executes it. The host completes the boundary and releases the
  associated continuation explicitly.
  """

  alias Spectre.Definition.Ref
  alias Spectre.Operation.Request

  @enforce_keys [:kind, :mount_id, :definition_ref, :route_label]
  defstruct [
    :kind,
    :mount_id,
    :definition_ref,
    :route_label,
    :output,
    :operation_request,
    :continuation_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: :reply | :operation,
          mount_id: term(),
          definition_ref: Ref.t(),
          route_label: term(),
          output: String.t() | nil,
          operation_request: Request.t() | nil,
          continuation_id: String.t() | nil,
          metadata: map()
        }
end
