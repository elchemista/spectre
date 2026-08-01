defmodule Spectre.Operation.ExecutionContext do
  @moduledoc "Ephemeral context passed to one registered operation executor."

  defstruct [
    :agent,
    :subject,
    :loop_id,
    :loop_kind,
    :controller,
    :attempt,
    :input,
    :state,
    :cognitive,
    :progress,
    opts: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          agent: module(),
          subject: Spectre.Subject.t(),
          loop_id: String.t(),
          loop_kind: atom(),
          controller: module(),
          attempt: Spectre.Operation.Attempt.t(),
          input: term(),
          state: term(),
          cognitive: map(),
          progress: (term(), map() -> :ok),
          opts: keyword(),
          metadata: map()
        }

  @doc "Emits throttled progress for the current attempt."
  @spec progress(t(), term(), map()) :: :ok
  def progress(%__MODULE__{progress: progress}, value, metadata \\ %{})
      when is_function(progress, 2) and is_map(metadata),
      do: progress.(value, metadata)
end
