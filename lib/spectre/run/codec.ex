defmodule Spectre.Run.Codec do
  @moduledoc false

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Invocation
  alias Spectre.Result
  alias Spectre.Route
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.Value
  alias Spectre.State

  @format "spectre/run"
  @version 1
  @default_max_bytes 2_000_000

  @spec encode(Run.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def encode(%Run{} = run, opts) when is_list(opts) do
    max_bytes = max_bytes(opts)
    checkpoint = checkpoint_projection(run)

    with :ok <- validate_run(checkpoint),
         :ok <- Value.validate(checkpoint, [:run]),
         {:ok, encoded_run} <- Value.encode(checkpoint) do
      binary =
        :erlang.term_to_binary(
          %{"format" => @format, "version" => @version, "run" => encoded_run},
          [:deterministic]
        )

      if byte_size(binary) <= max_bytes do
        {:ok, binary}
      else
        {:error, {:run_checkpoint_too_large, byte_size(binary), max_bytes}}
      end
    end
  rescue
    exception -> {:error, {:run_checkpoint_encode_failed, exception.__struct__}}
  end

  @spec decode(binary(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def decode(binary, opts) when is_binary(binary) and is_list(opts) do
    max_bytes = max_bytes(opts)

    with :ok <- validate_binary_size(binary, max_bytes),
         {:ok, envelope} <- decode_term(binary),
         {:ok, encoded_run} <- decode_envelope(envelope),
         :ok <- Value.prepare(encoded_run),
         {:ok, run} <- Value.decode(encoded_run),
         :ok <- validate_run(run),
         :ok <- Value.validate(run, [:run]) do
      {:ok, run}
    end
  end

  defp checkpoint_projection(%Run{} = run) do
    input = checkpoint_input(run.input)
    result = checkpoint_result(run.result, input)

    %{run | input: input, result: result}
  end

  @doc false
  @spec logical_input(Input.t()) :: Input.t()
  def logical_input(%Input{} = input) do
    %{
      input
      | raw: nil,
        meta: portable_metadata(input.meta),
        source: checkpoint_source(input.source)
    }
  end

  defp checkpoint_input(%Input{} = input), do: logical_input(input)

  defp checkpoint_source(nil), do: nil

  defp checkpoint_source(%Source{} = source) do
    %{
      source
      | mount: identity_value(source.mount),
        conversation_id: identity_value(source.conversation_id),
        actor_id: identity_value(source.actor_id),
        reply_to: identity_value(source.reply_to),
        metadata: portable_metadata(source.metadata)
    }
  end

  defp checkpoint_result(nil, _input), do: nil

  defp checkpoint_result(%Result{} = result, input) do
    %{
      result
      | input: input,
        route: route_projection(result.route),
        metadata: portable_metadata(result.metadata)
    }
  end

  defp route_projection(nil), do: nil

  defp route_projection(%Route{} = route) do
    struct(Route, %{
      label: route.label,
      flow: route.flow,
      owner: route.owner,
      scope: route.scope,
      strategy: route.strategy,
      confidence: route.confidence,
      margin: route.margin,
      accepted?: route.accepted?,
      terminal?: route.terminal?,
      escalation_reason: route.escalation_reason
    })
  end

  defp route_projection(route) when is_map(route),
    do: route |> portable_metadata() |> Route.new()

  defp route_projection(_route), do: nil

  defp portable_metadata(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, item}, acc ->
      with {:ok, projected_key} <- portable_projection(key),
           {:ok, projected_item} <- portable_projection(item) do
        Map.put(acc, projected_key, projected_item)
      else
        :drop -> acc
      end
    end)
  end

  defp portable_metadata(_value), do: %{}

  defp identity_value(value) do
    case Value.validate(value, [:source_identity]) do
      :ok -> value
      {:error, _reason} -> nil
    end
  end

  defp portable_projection(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: :drop

  defp portable_projection(value) when is_list(value) do
    {:ok,
     Enum.reduce(value, [], fn item, acc ->
       case portable_projection(item) do
         {:ok, projected} -> [projected | acc]
         :drop -> acc
       end
     end)
     |> Enum.reverse()}
  end

  defp portable_projection(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case portable_projection(item) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        :drop -> {:halt, :drop}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, items |> Enum.reverse() |> List.to_tuple()}
      :drop -> :drop
    end
  end

  defp portable_projection(%{__struct__: _module} = value) do
    if match?(:ok, Value.validate(value, [:metadata])), do: {:ok, value}, else: :drop
  end

  defp portable_projection(value) when is_map(value), do: {:ok, portable_metadata(value)}
  defp portable_projection(value), do: {:ok, value}

  defp validate_binary_size(binary, max_bytes) when byte_size(binary) <= max_bytes, do: :ok

  defp validate_binary_size(binary, max_bytes),
    do: {:error, {:run_checkpoint_too_large, byte_size(binary), max_bytes}}

  defp decode_term(<<131, 80, _compressed::binary>>),
    do: {:error, :compressed_run_checkpoint_not_supported}

  defp decode_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _exception -> {:error, :invalid_run_checkpoint}
  end

  defp decode_envelope(%{"format" => @format, "version" => @version, "run" => encoded_run}),
    do: {:ok, encoded_run}

  defp decode_envelope(%{"format" => @format, "version" => version}),
    do: {:error, {:unsupported_run_checkpoint_version, version, [@version]}}

  defp decode_envelope(_envelope), do: {:error, :invalid_run_checkpoint}

  defp validate_run(%Run{run_version: @version} = run) do
    with :ok <- validate_run_shape(run), do: validate_run_invariants(run)
  end

  defp validate_run(%Run{run_version: version}) when version != @version,
    do: {:error, {:unsupported_run_version, version, [@version]}}

  defp validate_run(_run), do: {:error, :invalid_run}

  defp validate_run_shape(%Run{input: %Input{}, state: %State{}} = run) do
    with :ok <- validate_run_identity(run),
         :ok <- validate_run_position(run),
         :ok <- validate_run_revision(run),
         :ok <- validate_run_lineage(run) do
      validate_run_metadata(run)
    end
  end

  defp validate_run_shape(_run), do: {:error, :invalid_run}

  defp validate_run_identity(%Run{id: id, agent: agent, trace_id: trace_id})
       when is_binary(id) and id != "" and is_atom(agent) and not is_nil(agent) and
              is_binary(trace_id) and trace_id != "",
       do: :ok

  defp validate_run_identity(_run), do: {:error, :invalid_run_identity}

  defp validate_run_position(%Run{status: status, cursor: cursor})
       when status in [:ready, :boundary, :awaiting, :complete, :failed] and
              cursor in [:turn, :policy, :effect, :complete],
       do: :ok

  defp validate_run_position(_run), do: {:error, :invalid_run_position}

  defp validate_run_revision(%Run{revision: revision, step_id: step_id})
       when is_integer(revision) and revision >= 0 and
              (is_nil(step_id) or is_binary(step_id)),
       do: :ok

  defp validate_run_revision(_run), do: {:error, :invalid_run_revision}

  defp validate_run_lineage(%Run{causation_id: causation_id, correlation_id: correlation_id})
       when (is_nil(causation_id) or is_binary(causation_id)) and
              (is_nil(correlation_id) or is_binary(correlation_id)),
       do: :ok

  defp validate_run_lineage(_run), do: {:error, :invalid_run_lineage}

  defp validate_run_metadata(%Run{metadata: metadata}) when is_map(metadata), do: :ok
  defp validate_run_metadata(_run), do: {:error, :invalid_run_metadata}

  defp validate_run_invariants(%Run{
         status: :ready,
         cursor: :turn,
         revision: 0,
         step_id: nil,
         waiting: nil,
         result: nil,
         last_error: nil
       }),
       do: :ok

  defp validate_run_invariants(
         %Run{
           status: :boundary,
           cursor: :policy,
           last_error: nil,
           waiting: %Boundary{
             id: boundary_id,
             kind: :needs,
             ref: %Ref{kind: :policy} = ref,
             request: %Request{} = request
           },
           result: %Result{} = result
         } = run
       ) do
    with :ok <- validate_result(run, result),
         :ok <- validate_ref(run, ref),
         true <- boundary_id == ref.boundary_id,
         true <- boundary_id == expected_boundary_id(run, :policy, active_awaitable_id(result)),
         true <- result_ref(result) == ref,
         true <- result.reply_text == run.waiting.output,
         %Awaitable{} = awaitable <- Result.open_awaitable(result),
         %Effect{} = effect <- Result.pending_effect(result),
         true <- effect.id == awaitable.subject_id and effect.status == :waiting_policy,
         {:ok, awaitable_id} <- Value.opaque_id(awaitable.id, "subject"),
         {:ok, request_id} <- Value.opaque_id(awaitable.id, "request"),
         {:ok, subject_id} <- Value.opaque_id(awaitable.subject_id, "subject"),
         true <- ref.subject_id == awaitable_id,
         true <- request.id == request_id and request.subject_id == subject_id,
         true <- request_matches_awaitable?(request, awaitable) do
      :ok
    else
      nil -> {:error, :invalid_run_policy_boundary}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_run_policy_boundary}
    end
  end

  defp validate_run_invariants(
         %Run{
           status: :awaiting,
           cursor: :effect,
           last_error: nil,
           waiting: %Invocation{ref: %Ref{kind: :invocation} = ref} = invocation,
           result: %Result{} = result
         } = run
       ) do
    with :ok <- validate_result(run, result),
         :ok <- validate_ref(run, ref),
         true <- invocation.id == ref.boundary_id,
         true <- invocation.id == expected_boundary_id(run, :invocation, active_effect_id(result)),
         true <- invocation.run_id == run.id and invocation.run_revision == run.revision,
         true <- result_ref(result) == ref,
         nil <- Result.open_awaitable(result),
         %Effect{} = effect <- Result.pending_effect(result),
         true <- Effect.executable?(effect),
         {:ok, subject_id} <- Value.opaque_id(effect.id, "subject"),
         true <- invocation.subject_id == subject_id and ref.subject_id == subject_id,
         true <- invocation_matches_effect?(invocation, effect) do
      :ok
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_run_effect_boundary}
    end
  end

  defp validate_run_invariants(
         %Run{
           status: :boundary,
           cursor: :complete,
           last_error: nil,
           waiting: %Boundary{id: boundary_id, kind: :reply, ref: %Ref{kind: :reply} = ref},
           result: %Result{} = result
         } = run
       ) do
    with :ok <- validate_result(run, result),
         :ok <- validate_ref(run, ref),
         true <- boundary_id == ref.boundary_id,
         true <- boundary_id == expected_boundary_id(run, :reply, nil),
         true <- result_ref(result) == ref,
         true <- is_nil(ref.subject_id),
         true <- run.waiting.output == result.reply_text,
         true <- Result.visible_reply?(result),
         :ok <- validate_no_open_work(result) do
      :ok
    else
      false -> {:error, :invalid_run_reply_boundary}
      {:error, _reason} = error -> error
    end
  end

  defp validate_run_invariants(
         %Run{
           status: :complete,
           cursor: :complete,
           last_error: nil,
           waiting: nil,
           result: %Result{} = result
         } = run
       ) do
    with :ok <- validate_result(run, result),
         %Ref{kind: :complete} = ref <- result_ref(result),
         true <- ref.boundary_id == expected_boundary_id(run, :complete, nil),
         true <- is_nil(ref.subject_id) do
      validate_no_open_work(result)
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_run_completion}
    end
  end

  defp validate_run_invariants(%Run{
         status: :failed,
         cursor: :complete,
         revision: revision,
         waiting: nil,
         result: nil,
         last_error: last_error
       })
       when revision > 0,
       do: if(is_nil(last_error), do: {:error, :invalid_run_failure}, else: :ok)

  defp validate_run_invariants(
         %Run{
           status: :failed,
           cursor: :complete,
           revision: revision,
           waiting: nil,
           result: %Result{} = result,
           last_error: last_error
         } = run
       )
       when revision > 0 do
    with false <- is_nil(last_error),
         :ok <- validate_result(run, result),
         %Ref{kind: :error, subject_id: nil} <- result_ref(result) do
      :ok
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_run_failure}
    end
  end

  defp validate_run_invariants(_run), do: {:error, :invalid_run_lifecycle}

  defp validate_result(%Run{input: input, state: state} = run, %Result{} = result) do
    cond do
      result.input != input ->
        {:error, :invalid_run_result_input}

      result.state != state ->
        {:error, :invalid_run_result_state}

      true ->
        validate_result_identity(run, result)
    end
  end

  defp validate_result_identity(
         %Run{} = run,
         %Result{
           metadata: %{
             run: %{
               id: id,
               revision: revision,
               status: status,
               cursor: cursor,
               step_id: step_id,
               trace_id: trace_id,
               ref: %Ref{} = ref
             }
           }
         }
       ) do
    if id == run.id and revision == run.revision and status == run.status and
         cursor == run.cursor and step_id == run.step_id and trace_id == run.trace_id do
      validate_ref(run, ref)
    else
      {:error, :invalid_run_result_identity}
    end
  end

  defp validate_result_identity(_run, _result), do: {:error, :invalid_run_result_identity}

  defp result_ref(%Result{} = result), do: get_in(result.metadata, [:run, :ref])

  defp validate_no_open_work(%Result{} = result) do
    if is_nil(Result.open_awaitable(result)) and is_nil(Result.pending_effect(result)),
      do: :ok,
      else: {:error, :invalid_run_terminal_work}
  end

  defp request_matches_awaitable?(%Request{} = request, %Awaitable{} = awaitable) do
    request.kind == awaitable.kind and request.name == awaitable.name and
      request.label == awaitable.label and request.max_attempts == awaitable.max_attempts and
      request.status == awaitable.status and request.attempts == awaitable.attempts and
      request.metadata == awaitable.metadata
  end

  defp invocation_matches_effect?(%Invocation{} = invocation, %Effect{} = effect) do
    invocation.kind == :effect and invocation.operation == {effect.kind, effect.name} and
      invocation.idempotency_key == Effect.idempotency_key(effect) and
      invocation.owner == effect.owner and invocation.scope == effect.scope and
      invocation.status == :pending and invocation.attempt == 1 and
      invocation.metadata == %{mode: effect.mode, status: effect.status}
  end

  defp active_awaitable_id(%Result{} = result) do
    case Result.open_awaitable(result) do
      %Awaitable{id: id} -> id
      nil -> nil
    end
  end

  defp active_effect_id(%Result{} = result) do
    case Result.pending_effect(result) do
      %Effect{id: id} -> id
      nil -> nil
    end
  end

  defp expected_boundary_id(%Run{} = run, kind, subject_id) do
    digest =
      {run.id, run.revision, kind, subject_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Atom.to_string(kind) <> ":" <> binary_part(digest, 0, 32)
  end

  defp validate_ref(%Run{} = run, %Ref{} = ref) do
    if ref.run_id == run.id and ref.revision == run.revision and valid_ref_shape?(ref),
      do: :ok,
      else: {:error, :invalid_run_reference}
  end

  defp valid_ref_shape?(%Ref{} = ref) do
    nonempty_binary?(ref.run_id) and nonempty_binary?(ref.boundary_id) and
      is_integer(ref.revision) and ref.revision >= 0 and
      ref.kind in [:reply, :policy, :invocation, :complete, :error] and
      (is_nil(ref.subject_id) or is_binary(ref.subject_id))
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp max_bytes(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      value when is_integer(value) and value > 0 -> value
      _value -> @default_max_bytes
    end
  end
end
