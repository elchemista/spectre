defmodule Spectre.Operation.Runtime.Support do
  @moduledoc """
  Shared vocabulary for the operation runtime modules.

  Small pure helpers used across `Spectre.Operation.Runtime` and its
  Contract/Transitions/Results/Controls/Recovery submodules: controller
  callback invocation, reduced controller contexts, event-spec builders and
  option/portability utilities. Intended to be `import`ed by those modules.
  """

  alias Spectre.Execution.Controller
  alias Spectre.Operation.Loop
  alias Spectre.Run.Value

  @result_limit 128
  @artifact_limit 256
  @update_limit 128
  @invalidation_limit 256

  @doc "Maximum retained loop results."
  @spec result_limit() :: pos_integer()
  def result_limit, do: @result_limit

  @doc "Default maximum retained loop artifacts."
  @spec artifact_limit() :: pos_integer()
  def artifact_limit, do: @artifact_limit

  @doc "Maximum retained applied updates."
  @spec update_limit() :: pos_integer()
  def update_limit, do: @update_limit

  @doc "Maximum retained invalidation entries."
  @spec invalidation_limit() :: pos_integer()
  def invalidation_limit, do: @invalidation_limit

  @doc "Invokes a controller callback, capturing crashes as tagged errors."
  @spec callback(module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def callback(module, function, args) do
    arity = length(args)

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:controller_not_loaded, module}}

      not function_exported?(module, function, arity) ->
        {:error, {:controller_callback_missing, module, function, arity}}

      true ->
        {:ok, apply(module, function, args)}
    end
  rescue
    error -> {:error, {:controller_callback_exception, module, function, error.__struct__}}
  catch
    kind, reason -> {:error, {:controller_callback_failure, module, function, kind, reason}}
  end

  @doc "Builds the reduced context passed to controller callbacks."
  @spec controller_context(Loop.t() | nil, map()) :: map()
  def controller_context(nil, env) do
    %{
      agent: Map.get(env, :agent),
      subject_id: Map.get(env, :subject_id),
      canonical_revision: Map.get(env, :canonical_revision, 0),
      committed: Map.get(env, :committed, %{}),
      execution_program: Map.get(env, :spectre_execution_program),
      execution_plans: Map.get(env, :spectre_execution_plans, %{}),
      execution_definition_ref: Map.get(env, :spectre_execution_definition_ref),
      execution_materialization_digest: Map.get(env, :spectre_execution_materialization_digest),
      execution_migration: Map.get(env, :spectre_execution_migration),
      now: now(env)
    }
  end

  def controller_context(loop, env) do
    %{
      agent: Map.get(env, :agent),
      subject_id: loop.subject_id,
      loop_id: loop.id,
      loop_kind: loop.kind,
      input: loop.effective_input,
      base_input: loop.base_input,
      context_revision: loop.context_revision,
      loop_revision: loop.revision,
      phase: loop.phase,
      budget: loop.budget,
      cognitive: loop.cognitive,
      artifacts: loop.artifacts,
      results: loop.results,
      last_result: loop.last_result,
      committed: Map.get(env, :committed, %{}),
      trigger: Map.get(env, :trigger),
      execution_program: Map.get(loop.metadata, Controller.program_key()),
      execution_plans: Map.get(loop.metadata, Controller.plans_key(), %{}),
      execution_definition_ref: Map.get(loop.metadata, :spectre_execution_definition_ref),
      execution_materialization_digest: Map.get(loop.metadata, Controller.materialization_key()),
      execution_migration: Map.get(loop.metadata, Controller.migration_key()),
      now: now(env)
    }
  end

  @doc "Builds one event spec."
  @spec event(atom(), map()) :: %{type: atom(), payload: map()}
  def event(type, payload \\ %{}), do: %{type: type, payload: payload}

  @doc "Builds the payload for wait-related events."
  @spec wait_event(Spectre.Operation.Wait.t(), Loop.t(), map()) :: map()
  def wait_event(wait, loop, extra \\ %{}) do
    Map.merge(
      %{
        kind: wait.kind,
        wait_id: wait.id,
        generation: loop.trigger_generation
      },
      extra
    )
  end

  @doc "Builds the payload for attempt-started events."
  @spec attempt_event(Spectre.Operation.Attempt.t()) :: map()
  def attempt_event(attempt) do
    %{
      attempt_id: attempt.id,
      operation: attempt.operation,
      number: attempt.number,
      context_revision: attempt.context_revision
    }
  end

  @doc "Builds the payload for budget-exhaustion events."
  @spec budget_event(atom(), term(), term()) :: map()
  def budget_event(dimension, consumed, limit),
    do: %{dimension: dimension, consumed: consumed, limit: limit}

  @doc "Reads one option from a map with a default."
  @spec option(map(), term(), term()) :: term()
  def option(opts, key, default \\ nil) when is_map(opts),
    do: Map.get(opts, key, default)

  @doc "Normalizes a keyword list to a map, dropping invalid shapes."
  @spec normalize_map(term()) :: map()
  def normalize_map(value) when is_map(value), do: value

  def normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value), do: Map.new(value), else: %{}
  end

  @doc "Accepts a map or keyword option, tagging invalid shapes with the field."
  @spec map_option(term(), atom()) :: {:ok, map()} | {:error, term()}
  def map_option(value, _field) when is_map(value), do: {:ok, value}

  def map_option(value, field) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, Map.new(value)},
      else: {:error, {:invalid_operational_map_option, field}}
  end

  def map_option(_value, field), do: {:error, {:invalid_operational_map_option, field}}

  @doc "Puts a key only when the value is present."
  @spec maybe_put_map(map(), term(), term()) :: map()
  def maybe_put_map(map, _key, nil), do: map
  def maybe_put_map(map, key, value), do: Map.put(map, key, value)

  @doc "Validates a value as portable, tagging failures as operational."
  @spec portable(term(), [term()]) :: :ok | {:error, term()}
  def portable(value, path) do
    case Value.validate(value, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operational_value, reason}}
    end
  end

  @doc "Reduces an arbitrary failure term to a privacy-safe atom class."
  @spec reason_class(term()) :: atom()
  def reason_class(%{kind: kind}) when is_atom(kind), do: kind
  def reason_class({kind, _detail}) when is_atom(kind), do: kind
  def reason_class(reason) when is_atom(reason), do: reason
  def reason_class(_reason), do: :error

  @doc "Classifies a trigger value into its declared trigger type."
  @spec trigger_class(term()) :: atom()
  def trigger_class(%{type: type}) when is_atom(type), do: type
  def trigger_class({type, _value}) when is_atom(type), do: type
  def trigger_class(type) when is_atom(type), do: type
  def trigger_class(_trigger), do: :external

  @doc "Reads the deterministic clock from the environment."
  @spec now(map()) :: integer()
  def now(env), do: Map.get(env, :now, System.system_time(:millisecond))
end
