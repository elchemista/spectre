defmodule Spectre.Morph.Surface.Mutation do
  @moduledoc """
  Describes one immutable Skill-mount difference between two Agent Definitions.

  The value is derived from canonical parent and candidate bytes. It never
  trusts the transient Morph pipeline, so governance can repeat the same check
  during composition, activation, and recovery.
  """

  @type operation :: :mount_skill | :replace_skill | :disable_skill

  @enforce_keys [:mount_id, :operation, :parent, :candidate]
  defstruct [:mount_id, :operation, :parent, :candidate]

  @type t :: %__MODULE__{
          mount_id: String.t() | integer(),
          operation: operation(),
          parent: map() | nil,
          candidate: map() | nil
        }
end
