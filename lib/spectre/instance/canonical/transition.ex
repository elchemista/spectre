defmodule Spectre.Instance.Canonical.Transition do
  @moduledoc false

  alias Spectre.Instance.Canonical.Change
  alias Spectre.Instance.Canonical.Sections

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            change_id: nil,
            snapshot_id: nil,
            status: :committed,
            from_revision: 0,
            to_revision: 0,
            base_revision: 0,
            changed_sections: [],
            correlation_id: nil,
            causation_id: nil,
            provenance: %{},
            metadata: %{},
            committed_at: nil

  @type status :: :committed | :duplicate

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          change_id: String.t(),
          snapshot_id: String.t(),
          status: status(),
          from_revision: non_neg_integer(),
          to_revision: non_neg_integer(),
          base_revision: non_neg_integer(),
          changed_sections: [Sections.name()],
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          provenance: map(),
          metadata: map(),
          committed_at: integer()
        }

  @spec committed(Change.t(), non_neg_integer(), non_neg_integer()) :: t()
  def committed(%Change{} = change, from_revision, to_revision) do
    %__MODULE__{
      id: Spectre.Identity.uuid7(),
      change_id: change.id,
      snapshot_id: change.snapshot_id,
      status: :committed,
      from_revision: from_revision,
      to_revision: to_revision,
      base_revision: change.base_revision,
      changed_sections: change.writes |> Map.keys() |> Enum.sort(),
      correlation_id: change.correlation_id,
      causation_id: change.causation_id,
      provenance: change.provenance,
      metadata: change.metadata,
      committed_at: System.system_time(:millisecond)
    }
  end

  @spec duplicate(Change.t(), non_neg_integer()) :: t()
  def duplicate(%Change{} = change, current_revision) do
    %__MODULE__{
      id: Spectre.Identity.uuid7(),
      change_id: change.id,
      snapshot_id: change.snapshot_id,
      status: :duplicate,
      from_revision: current_revision,
      to_revision: current_revision,
      base_revision: change.base_revision,
      changed_sections: change.writes |> Map.keys() |> Enum.sort(),
      correlation_id: change.correlation_id,
      causation_id: change.causation_id,
      provenance: change.provenance,
      metadata: change.metadata,
      committed_at: System.system_time(:millisecond)
    }
  end
end
