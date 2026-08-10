defmodule Spectre.Execution.Rehearsal.Report do
  @moduledoc "Privacy-safe receipt for a data-driven execution rehearsal."

  @enforce_keys [
    :program_digest,
    :input_evidence_digest,
    :status,
    :recordings,
    :consumed_recordings,
    :effect_dispatches,
    :trace,
    :final_state_digest,
    :outcome,
    :digest
  ]
  defstruct schema_version: 1,
            program_digest: nil,
            input_evidence_digest: nil,
            materialization_digest: nil,
            status: nil,
            recordings: 0,
            consumed_recordings: 0,
            effect_dispatches: 0,
            trace: [],
            final_state_digest: nil,
            outcome: nil,
            digest: nil

  @type t :: %__MODULE__{}
end
