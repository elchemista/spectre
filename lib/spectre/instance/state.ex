defmodule Spectre.Instance.State do
  @moduledoc false

  alias Spectre.AgentRef
  alias Spectre.Instance.Ref
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.State, as: AgentState
  alias Spectre.Subject

  defstruct [
    :agent,
    :agent_ref,
    :subject,
    :ref,
    :state,
    :last_result,
    :active,
    :state_lock,
    :idle_timeout,
    :idle_timer,
    :base_opts,
    :max_runs,
    :max_tombstones,
    :generation,
    :registry,
    :registry_monitor,
    scheduled: false,
    conversations: %{},
    runs: %{},
    ready: :queue.new(),
    queued: MapSet.new(),
    entries: %{},
    callers: %{},
    invocations: %{},
    workers: %{},
    completed: :queue.new(),
    terminal_recorded: MapSet.new(),
    tombstones: %{},
    idle_generation: 0
  ]

  @type t :: %__MODULE__{
          agent: module(),
          agent_ref: AgentRef.t(),
          subject: Subject.t(),
          ref: Ref.t(),
          state: AgentState.t(),
          last_result: Result.t() | nil,
          active: map() | nil,
          state_lock: map() | nil,
          idle_timeout: timeout() | false | nil,
          idle_timer: reference() | nil,
          base_opts: keyword(),
          max_runs: pos_integer(),
          max_tombstones: non_neg_integer(),
          generation: String.t(),
          registry: atom(),
          registry_monitor: reference() | nil,
          scheduled: boolean(),
          conversations: %{optional(String.t()) => map()},
          runs: %{optional(String.t()) => Run.t()},
          ready: :queue.queue(String.t()),
          queued: MapSet.t(String.t()),
          entries: %{optional(String.t()) => map()},
          callers: %{optional(String.t()) => GenServer.from()},
          invocations: %{optional(String.t()) => map()},
          workers: %{optional(pid()) => map()},
          completed: :queue.queue(String.t()),
          terminal_recorded: MapSet.t(String.t()),
          tombstones: %{optional(String.t()) => map()},
          idle_generation: non_neg_integer()
        }
end
