defmodule Spectre.Execution.Rehearsal do
  @moduledoc """
  Deterministic replay of a data-driven Work from recorded operation results.

  Rehearsal drives the same `Spectre.Operation.Runtime` transitions used in
  production, but it never calls `Spectre.Operation.Executor`, starts a Runner,
  dispatches an Effect, or invokes an inference adapter. Every prepared request
  must match the next recording's operation and input digest.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref
  alias Spectre.Execution.PortableDigest
  alias Spectre.Execution.Program
  alias Spectre.Execution.Rehearsal.Report
  alias Spectre.Operation.Control
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Request
  alias Spectre.Operation.Result
  alias Spectre.Operation.Runtime
  alias Spectre.Run.Value, as: RunValue

  @recording_fields [
    :operation_ref,
    :operation,
    :input_digest,
    :request_input_digest,
    :status,
    :value,
    :error,
    :receipt,
    :usage,
    :metadata
  ]
  @statuses [:ok, :error, :ambiguous]

  @doc "Returns the stable privacy-safe digest used to bind a recording input."
  @spec input_digest(term()) :: {:ok, String.t()} | {:error, term()}
  def input_digest(value), do: portable_digest(value, :recording_input)

  @doc "Replays recorded boundaries without performing real external work."
  @spec run(Program.t(), term(), [map()], keyword()) ::
          {:ok, Report.t()} | {:error, term()}
  def run(program, input, recordings, opts \\ [])

  def run(%Program{} = program, input, recordings, opts)
      when is_list(recordings) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, agent} <- agent(Keyword.get(opts, :agent)),
         {:ok, program} <- Program.new(program),
         :ok <- Program.validate_bindings(program, agent),
         {:ok, recordings} <- normalize_recordings(recordings),
         {:ok, plans} <- map_option(Keyword.get(opts, :plans, %{}), :plans),
         {:ok, input_evidence_digest} <- portable_digest(input, :input),
         {:ok, materialization_digest} <-
           optional_digest(Keyword.get(opts, :materialization_digest), :materialization_digest),
         {:ok, definition_ref} <- optional_definition_ref(Keyword.get(opts, :definition_ref)),
         env <- environment(agent, opts),
         start_opts <-
           [
             id: rehearsal_loop_id(program, input_evidence_digest, materialization_digest),
             correlation_id:
               rehearsal_correlation_id(program, input_evidence_digest, materialization_digest),
             plans: plans,
             materialization_digest: materialization_digest,
             definition_ref: definition_ref,
             metadata: %{rehearsal?: true}
           ],
         {:ok, loop, control, _events} <- Runtime.start_program(program, input, start_opts, env),
         limit <- transition_limit(program, recordings),
         {:ok, result} <-
           replay(loop, control, recordings, 0, [], env, limit) do
      report(
        program,
        input_evidence_digest,
        materialization_digest,
        length(recordings),
        result
      )
    else
      false -> {:error, :invalid_execution_rehearsal_options}
      {:error, _reason} = error -> error
    end
  end

  def run(%Program{}, _input, recordings, opts),
    do: {:error, {:invalid_execution_rehearsal_input, shape(recordings), shape(opts)}}

  @spec replay(Loop.t(), Control.t(), [map()], non_neg_integer(), [map()], map(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  defp replay(_loop, _control, _recordings, _consumed, _trace, _env, 0),
    do: {:error, :execution_rehearsal_transition_limit_exceeded}

  defp replay(%Loop{status: :terminal} = loop, control, recordings, consumed, trace, _env, _limit) do
    if consumed == length(recordings) do
      {:ok, replay_result(loop, control, recordings, consumed, trace, terminal_status(loop))}
    else
      {:error, {:unused_execution_rehearsal_recordings, length(recordings) - consumed}}
    end
  end

  defp replay(%Loop{status: :evaluating} = loop, control, recordings, consumed, trace, env, limit) do
    case Runtime.evaluate(loop, control, tick(env, consumed)) do
      {:ok, next, next_control, _events} ->
        replay(next, next_control, recordings, consumed, trace, env, limit - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp replay(
         %Loop{status: :waiting, wait: %{kind: :retry}} = loop,
         control,
         recordings,
         consumed,
         trace,
         env,
         limit
       ) do
    trigger_opts = [wait_id: loop.wait.id, generation: loop.trigger_generation]

    trigger_env =
      Map.put(tick(env, consumed), :now, max(loop.wait.due_at || 0, env.now + consumed + 1))

    case Runtime.trigger(loop, control, {:timer, loop.wait.id}, trigger_opts, trigger_env) do
      {:ok, next, next_control, _events} ->
        replay(next, next_control, recordings, consumed, trace, env, limit - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp replay(%Loop{status: :waiting} = loop, control, recordings, consumed, trace, _env, _limit) do
    if consumed == length(recordings) do
      {:ok, replay_result(loop, control, recordings, consumed, trace, :boundary)}
    else
      {:error, {:unused_execution_rehearsal_recordings, length(recordings) - consumed}}
    end
  end

  defp replay(loop, control, recordings, consumed, trace, env, limit) do
    case Runtime.prepare(loop, control, tick(env, consumed)) do
      {:run, active, attempt, spec, request, reconcile?, _events} ->
        with {:ok, recording} <- fetch_recording(recordings, consumed, request),
             {:ok, result} <- recorded_result(attempt, request, recording, consumed),
             {:ok, next, next_control, _events} <-
               Runtime.apply_result(active, control, result, tick(env, consumed)),
             {:ok, entry} <- trace_entry(request, spec, recording, result, reconcile?) do
          replay(
            next,
            next_control,
            recordings,
            consumed + 1,
            [entry | trace],
            env,
            limit - 1
          )
        end

      {:transition, next, next_control, _events} ->
        replay(next, next_control, recordings, consumed, trace, env, limit - 1)

      {:error, _reason} = error ->
        error
    end
  end

  @spec normalize_recordings([term()]) :: {:ok, [map()]} | {:error, term()}
  defp normalize_recordings(recordings) do
    recordings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize_recording(value) do
        {:ok, recording} ->
          {:cont, {:ok, [recording | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_rehearsal_recording, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_recording(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_recording(value) when is_map(value) and not is_struct(value) do
    with :ok <- no_duplicate_key_forms(value),
         value <- atomize(value, @recording_fields),
         :ok <- known_recording_fields(value),
         {:ok, operation} <- one_recording_field(value, :operation_ref, :operation),
         :ok <- valid_recording_operation(operation),
         {:ok, input_digest} <-
           one_recording_field(value, :input_digest, :request_input_digest),
         :ok <- valid_recording_digest(input_digest),
         {:ok, status} <- normalize_status(Map.get(value, :status, :ok)),
         {:ok, result_value} <- recording_result(value, status),
         {:ok, usage} <- recording_map(Map.get(value, :usage, %{}), :usage),
         {:ok, metadata} <- recording_map(Map.get(value, :metadata, %{}), :metadata),
         :ok <- RunValue.validate(result_value, [:execution_rehearsal, :result]),
         :ok <- RunValue.validate(Map.get(value, :receipt), [:execution_rehearsal, :receipt]),
         :ok <- RunValue.validate(usage, [:execution_rehearsal, :usage]),
         :ok <- RunValue.validate(metadata, [:execution_rehearsal, :metadata]) do
      {:ok,
       %{
         operation_ref: operation,
         input_digest: input_digest,
         status: status,
         result: result_value,
         receipt: Map.get(value, :receipt),
         usage: usage,
         metadata: metadata
       }}
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_recording(value),
    do: {:error, {:invalid_execution_rehearsal_recording_shape, shape(value)}}

  @spec fetch_recording([map()], non_neg_integer(), Request.t()) ::
          {:ok, map()} | {:error, term()}
  defp fetch_recording(recordings, index, request) do
    with {:ok, recording} <- Enum.fetch(recordings, index),
         true <- same_ref?(recording.operation_ref, request.operation),
         {:ok, digest} <- input_digest(request.input),
         true <- digest == recording.input_digest do
      {:ok, recording}
    else
      :error -> {:error, {:execution_rehearsal_recording_missing, index, request.operation}}
      false -> {:error, {:execution_rehearsal_recording_mismatch, index, request.operation}}
      {:error, _reason} = error -> error
    end
  end

  @spec recorded_result(Spectre.Operation.Attempt.t(), Request.t(), map(), non_neg_integer()) ::
          {:ok, Result.t()} | {:error, term()}
  defp recorded_result(attempt, request, recording, index) do
    result =
      Result.new(attempt, recording.status, recording.result,
        id: "rehearsal-result:#{index}",
        receipt: recording.receipt,
        usage: recording.usage,
        finished_at: index + 1,
        metadata:
          Map.merge(recording.metadata, %{
            rehearsal?: true,
            request_input_digest: recording.input_digest,
            request_id: request.id
          })
      )

    {:ok, result}
  rescue
    error in ArgumentError ->
      {:error, {:invalid_execution_rehearsal_result, Exception.message(error)}}
  end

  @spec trace_entry(Request.t(), Spectre.Operation.Spec.t(), map(), Result.t(), boolean()) ::
          {:ok, map()} | {:error, term()}
  defp trace_entry(request, spec, recording, result, reconcile?) do
    with {:ok, result_digest} <- portable_digest(recording.result, :recorded_result),
         {:ok, receipt_digest} <- optional_value_digest(result.receipt) do
      {:ok,
       %{
         operation_ref: request.operation,
         request_input_digest: recording.input_digest,
         result_digest: result_digest,
         receipt_digest: receipt_digest,
         status: result.status,
         side_effect: spec.side_effect,
         reconciliation?: reconcile?,
         dispatched?: false
       }}
    end
  end

  @spec replay_result(Loop.t(), Control.t(), [map()], non_neg_integer(), [map()], atom()) :: map()
  defp replay_result(loop, control, recordings, consumed, trace, status) do
    %{
      loop: loop,
      control: control,
      recordings: recordings,
      consumed: consumed,
      trace: Enum.reverse(trace),
      status: status
    }
  end

  @spec report(Program.t(), String.t(), String.t() | nil, non_neg_integer(), map()) ::
          {:ok, Report.t()} | {:error, term()}
  defp report(program, input_digest, materialization_digest, count, result) do
    loop = result.loop

    with {:ok, final_state_digest} <- portable_digest(loop.state, :final_state),
         {:ok, outcome} <- outcome_summary(loop) do
      data = %{
        schema_version: 1,
        program_digest: program.digest,
        input_evidence_digest: input_digest,
        materialization_digest: materialization_digest,
        status: result.status,
        recordings: count,
        consumed_recordings: result.consumed,
        effect_dispatches: 0,
        trace: result.trace,
        final_state_digest: final_state_digest,
        outcome: outcome
      }

      {:ok, struct!(Report, Map.put(data, :digest, Value.digest!(data)))}
    end
  end

  @spec outcome_summary(Loop.t()) :: {:ok, map() | nil} | {:error, term()}
  defp outcome_summary(%Loop{outcome: nil}), do: {:ok, nil}

  defp outcome_summary(%Loop{outcome: outcome}) do
    with {:ok, result_digest} <- optional_value_digest(outcome.result),
         {:ok, reason_digest} <- optional_value_digest(outcome.reason) do
      {:ok,
       %{
         category: outcome.category,
         result_digest: result_digest,
         reason_digest: reason_digest
       }}
    end
  end

  @spec terminal_status(Loop.t()) :: :completed | :failed
  defp terminal_status(%Loop{outcome: %{category: :completed}}), do: :completed
  defp terminal_status(%Loop{}), do: :failed

  @spec environment(module(), keyword()) :: map()
  defp environment(agent, opts) do
    %{
      agent: agent,
      subject_id: Keyword.get(opts, :subject_id, "execution-rehearsal"),
      epoch: "execution-rehearsal",
      snapshot_id: "execution-rehearsal",
      canonical_revision: 0,
      committed: %{},
      now: 0
    }
  end

  @spec tick(map(), non_neg_integer()) :: map()
  defp tick(env, consumed), do: Map.put(env, :now, env.now + consumed + 1)

  @spec transition_limit(Program.t(), [map()]) :: pos_integer()
  defp transition_limit(program, recordings) do
    steps = trunc(program.budget.steps)
    attempts = trunc(program.budget.attempts)
    max(steps + attempts + length(recordings) * 4 + map_size(program.nodes) * 4, 16)
  end

  @spec rehearsal_loop_id(Program.t(), String.t(), String.t() | nil) :: String.t()
  defp rehearsal_loop_id(program, input_digest, materialization_digest) do
    id = Value.digest!({program.digest, input_digest, materialization_digest})
    "execution-rehearsal:" <> binary_part(id, 0, 32)
  end

  @spec rehearsal_correlation_id(Program.t(), String.t(), String.t() | nil) :: String.t()
  defp rehearsal_correlation_id(program, input_digest, materialization_digest) do
    id = Value.digest!({:correlation, program.digest, input_digest, materialization_digest})
    "execution-rehearsal-correlation:" <> binary_part(id, 0, 32)
  end

  @spec portable_digest(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp portable_digest(value, field),
    do: PortableDigest.digest(value, [:execution_rehearsal, field])

  @spec optional_value_digest(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_value_digest(nil), do: {:ok, nil}
  defp optional_value_digest(value), do: portable_digest(value, :optional_value)

  @spec optional_digest(term(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_digest(nil, _field), do: {:ok, nil}

  defp optional_digest(value, field) when is_binary(value) do
    if digest?(value),
      do: {:ok, String.downcase(value)},
      else: {:error, {:invalid_execution_rehearsal_digest, field, value}}
  end

  defp optional_digest(value, field),
    do: {:error, {:invalid_execution_rehearsal_digest, field, value}}

  @spec agent(term()) :: {:ok, module()} | {:error, term()}
  defp agent(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp agent(value), do: {:error, {:invalid_execution_rehearsal_agent, value}}

  @spec map_option(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp map_option(value, _field) when is_map(value) and not is_struct(value), do: {:ok, value}
  defp map_option(value, field), do: {:error, {:invalid_execution_rehearsal_option, field, value}}

  @spec normalize_status(term()) :: {:ok, atom()} | {:error, term()}
  defp normalize_status(value) when value in @statuses, do: {:ok, value}

  defp normalize_status(value) when is_binary(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_rehearsal_status, value}}
      status -> {:ok, status}
    end
  end

  defp normalize_status(value), do: {:error, {:invalid_execution_rehearsal_status, value}}

  @spec optional_definition_ref(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_definition_ref(nil), do: {:ok, nil}

  defp optional_definition_ref(value) when is_binary(value) do
    case Ref.parse(value) do
      {:ok, ref} -> {:ok, Ref.to_string(ref)}
      {:error, _reason} -> {:error, {:invalid_execution_rehearsal_definition_ref, value}}
    end
  end

  defp optional_definition_ref(value),
    do: {:error, {:invalid_execution_rehearsal_definition_ref, value}}

  @spec no_duplicate_key_forms(map()) :: :ok | {:error, term()}
  defp no_duplicate_key_forms(value) do
    if Enum.any?(@recording_fields, fn field ->
         Map.has_key?(value, field) and Map.has_key?(value, Atom.to_string(field))
       end),
       do: {:error, :duplicate_execution_rehearsal_recording_field},
       else: :ok
  end

  @spec known_recording_fields(map()) :: :ok | {:error, term()}
  defp known_recording_fields(value) do
    case Map.keys(value) -- @recording_fields do
      [] ->
        :ok

      unknown ->
        {:error,
         {:unknown_execution_rehearsal_recording_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec one_recording_field(map(), atom(), atom()) :: {:ok, term()} | {:error, term()}
  defp one_recording_field(value, canonical, alias_field) do
    case {Map.fetch(value, canonical), Map.fetch(value, alias_field)} do
      {{:ok, field}, :error} ->
        {:ok, field}

      {:error, {:ok, field}} ->
        {:ok, field}

      {{:ok, _field}, {:ok, _alias}} ->
        {:error, {:ambiguous_execution_rehearsal_recording_field, canonical, alias_field}}

      {:error, :error} ->
        {:error, {:missing_execution_rehearsal_recording_field, canonical}}
    end
  end

  @spec recording_result(map(), atom()) :: {:ok, term()} | {:error, term()}
  defp recording_result(value, :ok) do
    cond do
      Map.has_key?(value, :error) -> {:error, :ok_execution_rehearsal_recording_has_error}
      Map.has_key?(value, :value) -> {:ok, Map.get(value, :value)}
      true -> {:error, :execution_rehearsal_recording_requires_value}
    end
  end

  defp recording_result(value, status) when status in [:error, :ambiguous] do
    cond do
      Map.has_key?(value, :value) -> {:error, :failed_execution_rehearsal_recording_has_value}
      Map.has_key?(value, :error) -> {:ok, Map.get(value, :error)}
      true -> {:error, :execution_rehearsal_recording_requires_error}
    end
  end

  @spec valid_recording_operation(term()) :: :ok | {:error, term()}
  defp valid_recording_operation(operation) do
    if stable_ref?(operation),
      do: :ok,
      else: {:error, {:invalid_execution_rehearsal_operation, operation}}
  end

  @spec valid_recording_digest(term()) :: :ok | {:error, term()}
  defp valid_recording_digest(digest) do
    if digest?(digest),
      do: :ok,
      else: {:error, {:invalid_execution_rehearsal_input_digest, digest}}
  end

  @spec recording_map(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp recording_map(value, _field) when is_map(value) and not is_struct(value), do: {:ok, value}

  defp recording_map(value, field),
    do: {:error, {:invalid_execution_rehearsal_recording_map, field, shape(value)}}

  @spec stable_ref?(term()) :: boolean()
  defp stable_ref?(value),
    do: (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != "")

  @spec same_ref?(term(), term()) :: boolean()
  defp same_ref?(left, right) when is_atom(left), do: same_ref?(Atom.to_string(left), right)
  defp same_ref?(left, right) when is_atom(right), do: same_ref?(left, Atom.to_string(right))
  defp same_ref?(left, right), do: left == right

  @spec digest?(term()) :: boolean()
  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _bytes}, Base.decode16(value, case: :lower))

  defp digest?(_value), do: false

  @spec atomize(map(), [atom()]) :: map()
  defp atomize(value, fields) do
    Enum.reduce(fields, value, fn field, acc ->
      string = Atom.to_string(field)

      case Map.fetch(acc, string) do
        {:ok, item} -> acc |> Map.delete(string) |> Map.put_new(field, item)
        :error -> acc
      end
    end)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
