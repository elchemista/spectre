defmodule Spectre.Morph.Change do
  @moduledoc """
  Transient pipeline value for one governed Agent change.

  Durable truth remains the published Candidate chain in the Definition Store;
  this value only carries ergonomic host context between explicit commits.
  """

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Instance.Activation
  alias Spectre.Morph.Surface

  @enforce_keys [:instance, :store, :agent, :activation, :surface, :actor_ref, :reason]
  defstruct [
    :instance,
    :store,
    :agent,
    :activation,
    :surface,
    :actor_ref,
    :reason,
    :ref,
    :report,
    :delta,
    :error,
    operations: [],
    mount_ids: [],
    evidence: %{},
    state: :draft
  ]

  @type state :: :draft | :evaluated | :approved | :rejected
  @type t :: %__MODULE__{
          instance: GenServer.server(),
          store: term(),
          agent: module(),
          activation: Activation.t(),
          surface: Surface.t(),
          actor_ref: String.t(),
          reason: String.t(),
          ref: CandidateRef.t() | nil,
          report: term(),
          delta: term(),
          error: term() | nil,
          operations: [map()],
          mount_ids: [String.t()],
          evidence: map(),
          state: state()
        }
end
