defmodule Spectre.Operation.Loop do
  @moduledoc """
  Canonical portable state of one operational loop.

  The struct intentionally contains no PID, function, client, port or process
  reference. A temporary Runner is represented only by its fenced Attempt.
  """

  alias Spectre.Operation.Attempt
  alias Spectre.Operation.Budget
  alias Spectre.Operation.Outcome
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Update
  alias Spectre.Operation.Wait

  @schema_version 1
  @kinds [:work, :vigil, :directive]
  @statuses [
    :queued,
    :active,
    :evaluating,
    :waiting,
    :pause_requested,
    :paused,
    :reconciling,
    :terminal
  ]
  @update_limit 128
  @result_limit 128
  @artifact_limit 256
  @invalidation_limit 256
  @event_limit 512

  @enforce_keys [
    :id,
    :kind,
    :controller,
    :controller_id,
    :controller_version,
    :base_input,
    :effective_input,
    :state,
    :subject_id,
    :correlation_id,
    :created_at,
    :updated_at,
    :budget
  ]
  # This portable checkpoint envelope keeps every fenced loop dimension explicit.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct [
    :id,
    :kind,
    :controller,
    :controller_id,
    :controller_version,
    :base_input,
    :effective_input,
    :state,
    :subject_id,
    :origin,
    :provenance,
    :source_turn_id,
    :correlation_id,
    :causation_id,
    :phase,
    :operation,
    :next_operation,
    :attempt,
    :wait,
    :blocker,
    :outcome,
    :last_result,
    :last_error,
    :last_crash,
    :last_progress,
    :last_update,
    :receipt,
    :created_at,
    :updated_at,
    :expires_at,
    :budget,
    schema_version: @schema_version,
    revision: 0,
    context_revision: 0,
    trigger_generation: 0,
    status: :queued,
    cycles: 0,
    attempts: 0,
    retries: 0,
    observations: 0,
    progress_sequence: 0,
    updates: [],
    invalidations: [],
    results: [],
    artifacts: [],
    events: [],
    authorized_origins: [],
    visibility: :origin,
    destinations: [],
    cognitive: %{},
    metadata: %{}
  ]

  @type kind :: :work | :vigil | :directive
  @type status ::
          :queued
          | :active
          | :evaluating
          | :waiting
          | :pause_requested
          | :paused
          | :reconciling
          | :terminal

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          controller: module(),
          controller_id: atom() | String.t(),
          controller_version: pos_integer() | String.t(),
          base_input: term(),
          effective_input: term(),
          state: term(),
          subject_id: String.t(),
          origin: term(),
          provenance: map(),
          source_turn_id: term(),
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          schema_version: pos_integer(),
          revision: non_neg_integer(),
          context_revision: non_neg_integer(),
          trigger_generation: non_neg_integer(),
          status: status(),
          phase: term(),
          operation: term(),
          next_operation: term(),
          attempt: Attempt.t() | nil,
          wait: Wait.t() | nil,
          blocker: term(),
          outcome: Outcome.t() | nil,
          cycles: non_neg_integer(),
          attempts: non_neg_integer(),
          retries: non_neg_integer(),
          observations: non_neg_integer(),
          progress_sequence: non_neg_integer(),
          updates: [Update.t()],
          invalidations: [term()],
          results: [term()],
          artifacts: [term()],
          events: [String.t()],
          authorized_origins: [term()],
          visibility: atom(),
          destinations: [term()],
          cognitive: map(),
          last_result: term(),
          last_error: term(),
          last_crash: term(),
          last_progress: term(),
          last_update: term(),
          receipt: term(),
          created_at: non_neg_integer(),
          updated_at: non_neg_integer(),
          expires_at: non_neg_integer() | nil,
          budget: Budget.t(),
          metadata: map()
        }

  @doc """
  Returns `true` when the loop has reached terminal status with a committed
  outcome.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: :terminal, outcome: %Outcome{}}), do: true
  def terminal?(%__MODULE__{}), do: false

  @doc """
  Returns `true` when no fenced Attempt is in flight, i.e. no temporary
  Runner exists for this loop.
  """
  @spec quiescent?(t()) :: boolean()
  def quiescent?(%__MODULE__{attempt: nil}), do: true
  def quiescent?(%__MODULE__{}), do: false

  @doc """
  Returns `true` when the loop may start a new attempt: it is quiescent,
  has no outcome, and sits in `:queued`, `:evaluating` or `:reconciling`.
  """
  @spec runnable?(t()) :: boolean()
  def runnable?(%__MODULE__{status: status, attempt: nil, outcome: nil}),
    do: status in [:queued, :evaluating, :reconciling]

  def runnable?(%__MODULE__{}), do: false

  @doc """
  Bumps the revision and refreshes `updated_at`.

  Accepts `:at` (milliseconds) to override the timestamp; defaults to the
  current system time.
  """
  @spec touch(t(), keyword()) :: t()
  def touch(%__MODULE__{} = loop, opts \\ []) do
    %{
      loop
      | revision: loop.revision + 1,
        updated_at: Keyword.get(opts, :at, System.system_time(:millisecond))
    }
  end

  @doc """
  Checks every invariant of the checkpoint envelope: status/field coherence,
  identity, counters, timestamps, collection limits, nested structs and
  portability of the whole value.

  Returns `:ok` or `{:error, reason}` naming the first violated invariant.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = loop) do
    cond do
      loop.schema_version != @schema_version ->
        {:error, {:unsupported_operational_loop_version, loop.schema_version}}

      not (is_binary(loop.id) and loop.id != "") ->
        {:error, :invalid_operational_loop_id}

      loop.kind not in @kinds ->
        {:error, {:invalid_operational_loop_kind, loop.kind}}

      not (is_atom(loop.controller) and not is_nil(loop.controller)) ->
        {:error, :invalid_operational_controller}

      loop.status not in @statuses ->
        {:error, {:invalid_operational_loop_status, loop.status}}

      not (is_integer(loop.revision) and loop.revision >= 0) ->
        {:error, :invalid_operational_loop_revision}

      not (is_integer(loop.context_revision) and loop.context_revision >= 0) ->
        {:error, :invalid_operational_context_revision}

      loop.status == :terminal and is_nil(loop.outcome) ->
        {:error, :terminal_operational_loop_without_outcome}

      loop.status != :terminal and not is_nil(loop.outcome) ->
        {:error, :nonterminal_operational_loop_with_outcome}

      loop.status == :active and is_nil(loop.attempt) ->
        {:error, :active_operational_loop_without_attempt}

      loop.status == :reconciling and not match?(%Request{}, loop.next_operation) ->
        {:error, :reconciling_operational_loop_without_request}

      not valid_identity?(loop) ->
        {:error, :invalid_operational_loop_identity}

      not valid_version?(loop.controller_version) or not valid_name?(loop.controller_id) ->
        {:error, :invalid_operational_loop_definition}

      not valid_counters?(loop) ->
        {:error, :invalid_operational_loop_counters}

      not valid_timestamps?(loop) ->
        {:error, :invalid_operational_loop_timestamps}

      loop.visibility not in [:origin, :subject] ->
        {:error, :invalid_operational_loop_visibility}

      not is_list(loop.authorized_origins) or not is_list(loop.destinations) ->
        {:error, :invalid_operational_loop_authorization}

      not valid_collections?(loop) ->
        {:error, :invalid_operational_loop_collections}

      not match?(%Budget{}, loop.budget) ->
        {:error, :invalid_operational_loop_budget}

      loop.status == :waiting and not match?(%Wait{}, loop.wait) ->
        {:error, :waiting_operational_loop_without_boundary}

      not is_nil(loop.wait) and loop.status not in [:waiting, :paused] ->
        {:error, :operational_loop_wait_outside_waiting_state}

      not is_nil(loop.wait) and not is_nil(loop.wait.generation) and
          loop.wait.generation != loop.trigger_generation ->
        {:error, :operational_loop_wait_generation_mismatch}

      not is_nil(loop.attempt) and loop.status not in [:active, :reconciling, :pause_requested] ->
        {:error, :operational_loop_attempt_outside_active_state}

      loop.status == :pause_requested and is_nil(loop.attempt) ->
        {:error, :pause_requested_operational_loop_without_attempt}

      not is_nil(loop.blocker) and
          (is_nil(loop.wait) or loop.wait.kind != :human or loop.status not in [:waiting, :paused]) ->
        {:error, :operational_loop_blocker_outside_human_wait}

      match?(%Result{}, loop.last_result) and loop.last_result.loop_id != loop.id ->
        {:error, :operational_loop_last_result_target_mismatch}

      match?(%Outcome{last_revision: revision} when not is_nil(revision), loop.outcome) and
          loop.outcome.last_revision != loop.revision ->
        {:error, :operational_loop_outcome_revision_mismatch}

      not is_map(loop.metadata) or not is_map(loop.cognitive) or not is_map(loop.provenance) ->
        {:error, :invalid_operational_loop_metadata}

      true ->
        validate_nested(loop)
    end
  end

  @spec validate_nested(%__MODULE__{}) :: :ok | {:error, term()}
  defp validate_nested(loop) do
    with :ok <- Budget.validate(loop.budget),
         :ok <- validate_optional(loop.attempt, &Attempt.validate/1, :attempt),
         :ok <- validate_optional(loop.next_operation, &Request.validate/1, :next_operation),
         :ok <- validate_optional(loop.wait, &Wait.validate/1, :wait),
         :ok <- validate_optional(loop.outcome, &Outcome.validate/1, :outcome),
         :ok <- validate_optional(loop.last_result, &Result.validate/1, :last_result),
         :ok <- validate_optional(loop.last_update, &Update.validate/1, :last_update),
         :ok <- validate_updates(loop.updates),
         :ok <- validate_update_consistency(loop),
         :ok <- validate_attempt_consistency(loop) do
      Spectre.Run.Value.validate(loop, [:operational_loop, loop.id])
    end
  end

  @spec validate_optional(term(), (term() -> :ok | {:error, term()}), atom()) ::
          :ok | {:error, term()}
  defp validate_optional(nil, _validator, _field), do: :ok

  defp validate_optional(value, validator, field) do
    case validator.(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_operational_loop_field, field, reason}}
    end
  rescue
    FunctionClauseError -> {:error, {:invalid_operational_loop_field, field}}
  end

  @spec validate_updates([term()]) :: :ok | {:error, term()}
  defp validate_updates(updates) do
    ids =
      Enum.map(updates, fn
        %Update{id: id} -> id
        _invalid -> nil
      end)

    if Enum.uniq(ids) != ids do
      {:error, :duplicate_operational_loop_update}
    else
      Enum.reduce_while(updates, :ok, fn
        %Update{} = update, :ok ->
          case Update.validate(update) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_operational_loop_update, reason}}}
          end

        _invalid, :ok ->
          {:halt, {:error, :invalid_operational_loop_update}}
      end)
    end
  end

  @spec validate_update_consistency(%__MODULE__{}) :: :ok | {:error, term()}
  defp validate_update_consistency(%__MODULE__{updates: [], last_update: nil}), do: :ok

  defp validate_update_consistency(%__MODULE__{updates: [latest | _], last_update: latest}),
    do: :ok

  defp validate_update_consistency(%__MODULE__{}),
    do: {:error, :operational_loop_last_update_mismatch}

  @spec validate_attempt_consistency(%__MODULE__{}) :: :ok | {:error, term()}
  defp validate_attempt_consistency(%__MODULE__{attempt: nil}), do: :ok

  defp validate_attempt_consistency(%__MODULE__{attempt: attempt} = loop) do
    cond do
      attempt.loop_id != loop.id or attempt.loop_kind != loop.kind ->
        {:error, :operational_loop_attempt_target_mismatch}

      attempt.context_revision != loop.context_revision ->
        {:error, :operational_loop_attempt_context_mismatch}

      attempt.trigger_generation != loop.trigger_generation ->
        {:error, :operational_loop_attempt_trigger_mismatch}

      attempt.operation != loop.operation ->
        {:error, :operational_loop_attempt_operation_mismatch}

      attempt.number != loop.attempts ->
        {:error, :operational_loop_attempt_number_mismatch}

      attempt.started_at < loop.created_at ->
        {:error, :operational_loop_attempt_timestamp_mismatch}

      not match?(%Request{}, loop.next_operation) ->
        {:error, :operational_loop_attempt_without_request}

      match?(%Request{}, loop.next_operation) and
          loop.next_operation.id != attempt.request_id ->
        {:error, :operational_loop_attempt_request_mismatch}

      true ->
        :ok
    end
  end

  @spec valid_identity?(%__MODULE__{}) :: boolean()
  defp valid_identity?(loop) do
    Enum.all?([loop.id, loop.subject_id, loop.correlation_id], &(is_binary(&1) and &1 != "")) and
      (is_nil(loop.causation_id) or (is_binary(loop.causation_id) and loop.causation_id != ""))
  end

  @spec valid_version?(term()) :: boolean()
  defp valid_version?(value),
    do: (is_integer(value) and value > 0) or (is_binary(value) and value != "")

  @spec valid_name?(term()) :: boolean()
  defp valid_name?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  @spec valid_counters?(%__MODULE__{}) :: boolean()
  defp valid_counters?(loop) do
    Enum.all?(
      [
        loop.revision,
        loop.context_revision,
        loop.trigger_generation,
        loop.cycles,
        loop.attempts,
        loop.retries,
        loop.observations,
        loop.progress_sequence
      ],
      &(is_integer(&1) and &1 >= 0)
    )
  end

  @spec valid_timestamps?(%__MODULE__{}) :: boolean()
  defp valid_timestamps?(loop) do
    is_integer(loop.created_at) and loop.created_at >= 0 and is_integer(loop.updated_at) and
      loop.updated_at >= loop.created_at and
      (is_nil(loop.expires_at) or (is_integer(loop.expires_at) and loop.expires_at >= 0))
  end

  @spec valid_collections?(%__MODULE__{}) :: boolean()
  defp valid_collections?(loop) do
    is_list(loop.updates) and length(loop.updates) <= @update_limit and
      is_list(loop.invalidations) and length(loop.invalidations) <= @invalidation_limit and
      is_list(loop.results) and length(loop.results) <= @result_limit and
      is_list(loop.artifacts) and length(loop.artifacts) <= @artifact_limit and
      is_list(loop.events) and length(loop.events) <= @event_limit and
      Enum.all?(loop.events, &(is_binary(&1) and &1 != "")) and
      Enum.uniq(loop.events) == loop.events and
      Enum.uniq(loop.authorized_origins) == loop.authorized_origins and
      Enum.uniq(loop.destinations) == loop.destinations
  end
end
