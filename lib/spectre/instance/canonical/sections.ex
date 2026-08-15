defmodule Spectre.Instance.Canonical.Sections do
  @moduledoc false

  alias Spectre.Instance.Canonical.Section

  @names [
    :flow,
    :work,
    :vigil,
    :directive,
    :control,
    :correlations,
    :events,
    :activation,
    :runs,
    :lifecycles,
    :event_admissions,
    :event_quarantine,
    :skill_states,
    :inference_control,
    :inference_progress,
    :receipt_outbox
  ]

  defstruct flow: %Section{},
            work: %Section{},
            vigil: %Section{},
            directive: %Section{},
            control: %Section{},
            correlations: %Section{},
            events: %Section{},
            activation: %Section{value: nil},
            runs: %Section{},
            lifecycles: %Section{},
            event_admissions: %Section{value: %{records: [], ids: %{}}},
            event_quarantine: %Section{value: %{records: [], ids: %{}}},
            skill_states: %Section{},
            inference_control: %Section{},
            inference_progress: %Section{},
            receipt_outbox: %Section{value: %{entries: [], ids: %{}}}

  @type name ::
          :flow
          | :work
          | :vigil
          | :directive
          | :control
          | :correlations
          | :events
          | :activation
          | :runs
          | :lifecycles
          | :event_admissions
          | :event_quarantine
          | :skill_states
          | :inference_control
          | :inference_progress
          | :receipt_outbox

  @type t :: %__MODULE__{
          flow: Section.t(),
          work: Section.t(),
          vigil: Section.t(),
          directive: Section.t(),
          control: Section.t(),
          correlations: Section.t(),
          events: Section.t(),
          activation: Section.t(),
          runs: Section.t(),
          lifecycles: Section.t(),
          event_admissions: Section.t(),
          event_quarantine: Section.t(),
          skill_states: Section.t(),
          inference_control: Section.t(),
          inference_progress: Section.t(),
          receipt_outbox: Section.t()
        }

  @spec names() :: [name()]
  def names, do: @names

  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: name in @names

  @spec fetch(t(), term()) :: {:ok, Section.t()} | :error
  def fetch(%__MODULE__{} = sections, name) when name in @names,
    do: {:ok, Map.fetch!(sections, name)}

  def fetch(%__MODULE__{}, _name), do: :error

  @spec put(t(), name(), Section.t()) :: t()
  def put(%__MODULE__{} = sections, name, %Section{} = section) when name in @names,
    do: Map.put(sections, name, section)
end
