defmodule Spectre.Operation.Runtime.Transitions do
  @moduledoc """
  Pure loop-state transition builders for the operation runtime.

  Terminal outcomes (completion, failure, budget exhaustion), wait placement,
  attempt clearing, pause/reconciliation markers and bounded appends of
  results, artifacts and invalidations. Every function takes a committed
  `Spectre.Operation.Loop` and returns the next value without side effects.
  """

  import Spectre.Operation.Runtime.Support

  alias Spectre.Operation.Budget
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Outcome
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime.Contract

  @doc "Terminates a loop with a completed outcome."
  @spec complete(Loop.t(), term(), map()) :: Loop.t()
  def complete(loop, value, env) do
    outcome =
      Outcome.new(:completed,
        result: value,
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Map.put(:wait, nil)
    |> Map.put(:blocker, nil)
    |> Loop.touch(at: now(env))
  end

  @doc "Terminates a loop with a failed outcome."
  @spec fail(Loop.t(), term(), map()) :: Loop.t()
  def fail(loop, reason, env) do
    outcome =
      Outcome.new(:failed,
        reason: reason,
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Map.put(:last_error, reason)
    |> Loop.touch(at: now(env))
  end

  @doc "Terminates a loop whose budget dimension is exhausted or expired."
  @spec terminal_budget(Loop.t(), atom(), term(), term(), map()) :: Loop.t()
  def terminal_budget(loop, dimension, consumed, limit, env) do
    category = if consumed == :expired, do: :expired, else: :budget_exhausted
    exhaustion = budget_event(dimension, consumed, limit)
    {reason, metadata} = budget_outcome_behavior(loop, category, exhaustion, env)

    outcome =
      Outcome.new(category,
        reason: reason,
        limit: %{dimension: dimension, value: limit},
        consumed: %{dimension: dimension, value: consumed},
        partial: %{state: loop.state, results: loop.results},
        artifacts: loop.artifacts,
        last_revision: loop.revision + 1,
        metadata: metadata
      )

    loop
    |> clear_attempt()
    |> clear_reconciliation_marker()
    |> Map.put(:status, :terminal)
    |> Map.put(:outcome, outcome)
    |> Loop.touch(at: now(env))
  end

  @doc "Returns the exhausted budget dimension, checking expiry first."
  @spec budget_exhaustion(Loop.t(), map()) :: {atom(), term(), term()} | nil
  def budget_exhaustion(%Loop{expires_at: expires_at} = loop, env) do
    current_time = now(env)

    if is_integer(expires_at) and expires_at <= current_time,
      do: {:duration_ms, :expired, expires_at},
      else: Budget.exhausted(loop.budget, current_time)
  end

  @doc """
  Terminalizes the control plane, rejecting a racing pending command.

  A terminal transition can race with a pending safe pause/update command.
  The command can no longer be applied, so it is rejected in the same
  transition; otherwise the terminal control plane would fail validation and
  the terminal outcome could never be committed.
  """
  @spec terminal_control(Control.t()) :: {Control.t(), [map()]}
  def terminal_control(%Control{pending: nil} = control),
    do: {%{control | state: :terminal}, []}

  def terminal_control(%Control{pending: %Command{} = pending} = control) do
    {Control.terminalize(control, :loop_terminal),
     [event(:control_rejected, %{action: pending.action, reason: :loop_terminal})]}
  end

  @doc "Clears the active attempt and operation."
  @spec clear_attempt(Loop.t()) :: Loop.t()
  def clear_attempt(loop) do
    %{loop | attempt: nil, operation: nil}
  end

  @doc "Places the loop into a waiting state, inheriting the trigger generation."
  @spec put_wait(Loop.t(), Spectre.Operation.Wait.t()) :: Loop.t()
  def put_wait(loop, wait) do
    wait =
      if is_nil(wait.generation),
        do: %{wait | generation: loop.trigger_generation},
        else: wait

    %{loop | status: :waiting, wait: wait, attempt: nil, operation: nil}
  end

  @doc "Remembers the pre-pause status a resume should return to."
  @spec put_resume_status(Loop.t(), atom()) :: Loop.t()
  def put_resume_status(loop, status)
      when status in [:queued, :evaluating, :waiting, :reconciling] do
    put_in(loop, [Access.key!(:metadata), :paused_from_status], status)
  end

  def put_resume_status(loop, _status), do: put_resume_status(loop, :queued)

  @doc "Reads the status a paused loop should resume into."
  @spec resume_status(Loop.t()) :: atom()
  def resume_status(%Loop{metadata: metadata}) do
    case Map.get(metadata, :paused_from_status, Map.get(metadata, "paused_from_status")) do
      status when status in [:queued, :evaluating, :waiting, :reconciling] -> status
      _unknown -> :queued
    end
  end

  @doc "Drops the remembered resume status."
  @spec clear_resume_status(Loop.t()) :: Loop.t()
  def clear_resume_status(%Loop{} = loop) do
    metadata =
      loop.metadata |> Map.delete(:paused_from_status) |> Map.delete("paused_from_status")

    %{loop | metadata: metadata}
  end

  @doc "Marks or clears the reconciliation request the loop must run next."
  @spec put_reconciliation_marker(Loop.t(), Request.t() | nil, boolean()) :: Loop.t()
  def put_reconciliation_marker(%Loop{} = loop, %Request{} = request, true) do
    %{loop | metadata: Map.put(loop.metadata, :reconciliation_request_id, request.id)}
  end

  def put_reconciliation_marker(%Loop{} = loop, _request, false),
    do: clear_reconciliation_marker(loop)

  @doc "Drops any reconciliation marker."
  @spec clear_reconciliation_marker(Loop.t()) :: Loop.t()
  def clear_reconciliation_marker(%Loop{} = loop) do
    metadata =
      loop.metadata
      |> Map.delete(:reconciliation_request_id)
      |> Map.delete("reconciliation_request_id")
      |> Map.delete(:reconcile?)
      |> Map.delete("reconcile?")

    %{loop | metadata: metadata}
  end

  @doc "Returns true when the request is the marked reconciliation request."
  @spec reconciliation_request?(Loop.t(), Request.t()) :: boolean()
  def reconciliation_request?(%Loop{} = loop, %Request{} = request) do
    marker =
      Map.get(
        loop.metadata,
        :reconciliation_request_id,
        Map.get(loop.metadata, "reconciliation_request_id")
      )

    marker == request.id
  end

  @doc "Counts one Vigil observation."
  @spec maybe_increment_observations(Loop.t()) :: Loop.t()
  def maybe_increment_observations(%Loop{kind: :vigil} = loop),
    do: %{loop | observations: loop.observations + 1}

  def maybe_increment_observations(loop), do: loop

  @doc "Prepends result values within the bounded window."
  @spec append_results(Loop.t(), term()) :: Loop.t()
  def append_results(loop, values) do
    values = Enum.reject(List.wrap(values), &is_nil/1)
    %{loop | results: Enum.take(values ++ loop.results, result_limit())}
  end

  @doc "Prepends artifacts within the declared and absolute limits."
  @spec append_artifacts(Loop.t(), term(), pos_integer()) :: Loop.t()
  def append_artifacts(loop, artifacts, limit) do
    artifacts = Enum.reject(List.wrap(artifacts), &is_nil/1)
    %{loop | artifacts: Enum.take(artifacts ++ loop.artifacts, min(limit, artifact_limit()))}
  end

  @doc "Merges invalidation entries within the bounded window."
  @spec append_invalidations(Loop.t(), term()) :: Loop.t()
  def append_invalidations(loop, invalidations) do
    invalidations =
      invalidations
      |> List.wrap()
      |> Kernel.++(loop.invalidations)
      |> Enum.uniq()
      |> Enum.take(invalidation_limit())

    %{loop | invalidations: invalidations}
  end

  @doc "Builds the effective budget from the definition default or an override."
  @spec effective_budget(Budget.t() | map(), term(), integer()) ::
          {:ok, Budget.t()} | {:error, term()}
  def effective_budget(default, nil, now) do
    {:ok, Budget.new(%{limits: default.limits, resources: default.resources}, now)}
  rescue
    exception -> {:error, {:invalid_operational_budget, Exception.message(exception)}}
  end

  def effective_budget(_default, configured, now) do
    {:ok, Budget.new(configured, now)}
  rescue
    exception -> {:error, {:invalid_operational_budget, Exception.message(exception)}}
  end

  @doc "Builds provenance for an explicit origin."
  @spec origin_provenance(term()) :: map()
  def origin_provenance(nil), do: %{}
  def origin_provenance(origin), do: %{origin: origin}

  @doc "Merges the loop origin into the authorized origins."
  @spec authorized_origins(term(), keyword()) :: [term()]
  def authorized_origins(nil, opts), do: List.wrap(Keyword.get(opts, :authorized_origins, []))

  def authorized_origins(origin, opts),
    do: Enum.uniq([origin | List.wrap(Keyword.get(opts, :authorized_origins, []))])

  @doc "Vigil updates invalidate outstanding triggers; other kinds do not."
  @spec trigger_generation_increment(Loop.kind()) :: 0 | 1
  def trigger_generation_increment(:vigil), do: 1
  def trigger_generation_increment(_kind), do: 0

  @doc "Normalizes a declared Vigil significance value."
  @spec normalize_significance(Loop.kind(), term()) :: :significant | :silent | nil
  def normalize_significance(:vigil, value) when value in [:significant, true],
    do: :significant

  def normalize_significance(:vigil, value) when value in [:silent, false, nil], do: :silent
  def normalize_significance(:vigil, _value), do: :silent
  def normalize_significance(_kind, _value), do: nil

  @doc "Builds the Vigil observation event, or nil for other kinds."
  @spec observation_event(Loop.kind(), :significant | :silent | nil, Result.t()) :: map() | nil
  def observation_event(:vigil, :significant, result),
    do: event(:observation_significant, %{attempt_id: result.attempt_id})

  def observation_event(:vigil, :silent, result),
    do: event(:observation_committed, %{attempt_id: result.attempt_id, significance: :silent})

  def observation_event(_kind, _significance, _result), do: nil

  @doc "Records the last significant Vigil change in loop metadata."
  @spec put_significance(Loop.t(), :significant | :silent | nil, Result.t(), map()) :: Loop.t()
  def put_significance(loop, :significant, result, env) do
    metadata =
      Map.put(loop.metadata, :last_significant_change, %{
        at: now(env),
        result_id: result.id,
        revision: loop.revision + 1
      })

    %{loop | metadata: metadata}
  end

  def put_significance(loop, _significance, _result, _env), do: loop

  @doc "Mirrors cognitive fallback and selection metadata from a result."
  @spec put_cognitive_result(Loop.t(), Result.t()) :: Loop.t()
  def put_cognitive_result(loop, %Result{} = result) do
    fallback? = Map.get(result.metadata, :cognitive_fallback, false)

    selection =
      case result.value do
        %{selection: selection} -> selection
        _other -> nil
      end

    cognitive =
      loop.cognitive
      |> Map.put(:fallback?, fallback?)
      |> maybe_put_map(:effective_selection, selection)

    %{loop | cognitive: cognitive}
  end

  defp budget_outcome_behavior(loop, category, exhaustion, env) do
    default = {{category, exhaustion.dimension}, %{behavior: :terminate}}

    case Contract.current_definition(loop) do
      {:ok, %Definition{on_budget_exhausted: :terminate}} ->
        default

      {:ok, %Definition{on_budget_exhausted: :controller}} ->
        case callback(loop.controller, :budget_exhausted, [
               loop.state,
               exhaustion,
               controller_context(loop, env)
             ]) do
          {:ok, decision} -> normalize_budget_decision(decision, default)
          {:error, reason} -> budget_behavior_error(default, reason)
        end

      {:error, reason} ->
        budget_behavior_error(default, reason)
    end
  end

  defp normalize_budget_decision(:terminate, default), do: default

  defp normalize_budget_decision({:terminate, reason}, {_default_reason, metadata} = default) do
    case portable(reason, [:loop, :budget_exhausted, :reason]) do
      :ok -> {reason, Map.put(metadata, :behavior, :controller)}
      {:error, invalid} -> budget_behavior_error(default, invalid)
    end
  end

  defp normalize_budget_decision(
         {:terminate, reason, extra_metadata},
         {_default_reason, metadata} = default
       )
       when is_map(extra_metadata) or is_list(extra_metadata) do
    extra_metadata = normalize_map(extra_metadata)

    case portable({reason, extra_metadata}, [:loop, :budget_exhausted]) do
      :ok -> {reason, metadata |> Map.merge(extra_metadata) |> Map.put(:behavior, :controller)}
      {:error, invalid} -> budget_behavior_error(default, invalid)
    end
  end

  defp normalize_budget_decision(invalid, default),
    do: budget_behavior_error(default, {:invalid_budget_exhaustion_decision, invalid})

  defp budget_behavior_error({reason, metadata}, error) do
    {reason, Map.merge(metadata, %{behavior_error: reason_class(error)})}
  end
end
