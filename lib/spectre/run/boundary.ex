defmodule Spectre.Run.Boundary do
  @moduledoc """
  Observable boundary emitted while advancing a `Spectre.Run`.

  Reply boundaries carry user-visible output. Policy boundaries carry the
  transport-safe `Spectre.Run.Request` that must be resolved by a trusted
  host. The authoritative Awaitable stays in Run State. The accompanying
  `Spectre.Run.Ref` fences the response to the exact Run revision that
  produced it.
  """

  alias Spectre.Run.Ref
  alias Spectre.Run.Request

  @enforce_keys [:id, :kind, :ref]
  defstruct [:id, :kind, :ref, :output, :request, metadata: %{}]

  @type kind :: :reply | :needs

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          ref: Ref.t(),
          output: term(),
          request: Request.t() | nil,
          metadata: map()
        }
end
