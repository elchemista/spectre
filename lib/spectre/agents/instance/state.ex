defmodule Spectre.Instance.State do
  @moduledoc """
  Process-local state owned by one `Spectre.Instance`.

  The Scope and Definition reference identify the application runtime around a
  governed Domain. `domain_monitor` is process-local lifecycle state. `value`
  is deliberately opaque and non-canonical: losing or replacing it cannot
  authorize an Act, prove an Attempt or dispose a Duty. Only successful
  Mind deliberations that change the value advance `revision`. One temporary
  `job` owns in-flight work; the bounded FIFO holds requests, never a second
  authoritative copy of the application value.
  """

  alias Spectre.Scope

  @enforce_keys [:scope, :definition_ref, :value, :domain_monitor, :pending]
  defstruct @enforce_keys ++
              [
                revision: 0,
                job: nil,
                pending_count: 0,
                max_pending_operations: 32
              ]

  @type t :: %__MODULE__{
          scope: Scope.t(),
          definition_ref: String.t(),
          value: term(),
          domain_monitor: reference(),
          revision: non_neg_integer(),
          job: %{task: Task.t(), from: GenServer.from(), operation: atom()} | nil,
          pending: :queue.queue({tuple(), GenServer.from()}),
          pending_count: non_neg_integer(),
          max_pending_operations: non_neg_integer()
        }

  @doc false
  @spec new(Scope.t(), String.t(), term(), reference()) :: t()
  def new(%Scope{} = scope, definition_ref, value, domain_monitor)
      when is_binary(definition_ref) and definition_ref != "" and
             is_reference(domain_monitor) do
    %__MODULE__{
      scope: scope,
      definition_ref: definition_ref,
      value: value,
      domain_monitor: domain_monitor,
      pending: :queue.new()
    }
  end

  @doc false
  @spec advance(t(), term()) :: t()
  def advance(%__MODULE__{value: value} = state, value), do: state

  def advance(%__MODULE__{} = state, value),
    do: %{state | value: value, revision: state.revision + 1}

  @doc false
  @spec info(t()) :: map()
  def info(%__MODULE__{} = state) do
    %{
      ref: Scope.ref(state.scope),
      domain_ref: Scope.domain_ref(state.scope),
      definition_ref: state.definition_ref,
      state_revision: state.revision
    }
  end
end
