defmodule Spectre.Inference.Prepared do
  @moduledoc """
  Immutable handoff produced after inference selection.

  A prepared inference binds the portable descriptor and frozen selection to
  the provider options and optional streaming adapter selected for the current
  process. It can appear in the return value of routing and runner APIs when an
  Instance owns the remaining lifecycle.

  This value is process-local dispatch material, not a durable checkpoint.
  `Spectre.Run.InferenceContinuation` stores the portable descriptor and frozen
  selection needed to reconstruct it during recovery.
  """

  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Selection

  @enforce_keys [:descriptor, :selection, :frozen_selection, :provider_opts]
  defstruct [
    :descriptor,
    :selection,
    :frozen_selection,
    :provider_opts,
    :state,
    :stream_adapter,
    stream_adapter_opts: [],
    stream_capabilities: MapSet.new()
  ]

  @type t :: %__MODULE__{
          descriptor: Descriptor.t(),
          selection: Selection.t(),
          frozen_selection: FrozenSelection.t(),
          provider_opts: keyword(),
          state: Spectre.State.t() | nil,
          stream_adapter: module() | nil,
          stream_adapter_opts: keyword(),
          stream_capabilities: MapSet.t(atom())
        }
end
