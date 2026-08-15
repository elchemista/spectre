defmodule Spectre.Run.Codec do
  @moduledoc """
  Serializes a `Spectre.Run` to and from its portable checkpoint binary.

  Encoding projects the run down to its logical, transport-safe form (raw
  input, PIDs, refs, and functions are dropped) and wraps it in a versioned
  envelope. Decoding validates the envelope, the run shape, and the lifecycle
  invariants of the checkpointed boundary before returning the run.
  """

  alias Spectre.Awaitable
  alias Spectre.Definition.Ref, as: DefinitionRef
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
  alias Spectre.Run.StartContinuation
  alias Spectre.Run.Value
  alias Spectre.State

  # A decoded run whose fields have not been validated yet: the struct is
  # guaranteed, the field types are not, so validators must not assume Run.t().
  @typep raw_run :: %Run{}

  @format "spectre/run"
  @version 3
  @supported_versions [1, 2, 3]
  @default_max_bytes 2_000_000
  @result_identity_fields [
    :id,
    :revision,
    :status,
    :cursor,
    :step_id,
    :trace_id,
    :definition_ref,
    :activation_generation,
    :authority_epoch,
    :closure_digest
  ]

  @doc """
  Encodes a run into a deterministic, versioned checkpoint binary.

  The run is validated before encoding and the resulting binary is rejected
  with `{:error, {:run_checkpoint_too_large, size, max}}` when it exceeds
  `:max_bytes` (default #{@default_max_bytes}).
  """
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

  @doc """
  Decodes a checkpoint binary produced by `encode/2` back into a `Spectre.Run`.

  Enforces the size limit, rejects compressed or unknown envelopes, and
  revalidates the run's shape and lifecycle invariants, so an untrusted
  checkpoint can never yield an inconsistent run.
  """
  @spec decode(binary(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def decode(binary, opts) when is_binary(binary) and is_list(opts) do
    max_bytes = max_bytes(opts)

    with :ok <- validate_binary_size(binary, max_bytes),
         {:ok, envelope} <- decode_term(binary),
         {:ok, checkpoint_version, encoded_run} <- decode_envelope(envelope),
         :ok <- Value.prepare(encoded_run),
         {:ok, decoded_run} <- Value.decode(encoded_run),
         {:ok, run} <- migrate_run(checkpoint_version, decoded_run),
         :ok <- validate_run(run),
         :ok <- Value.validate(run, [:run]) do
      {:ok, run}
    end
  end

  @spec checkpoint_projection(Run.t()) :: Run.t()
  defp checkpoint_projection(%Run{} = run) do
    input = checkpoint_input(run.input)
    result = checkpoint_result(run.result, input)
    start_continuation = checkpoint_start_continuation(run.start_continuation, input)

    %{run | input: input, result: result, start_continuation: start_continuation}
  end

  defp checkpoint_start_continuation(nil, _input), do: nil

  defp checkpoint_start_continuation(%StartContinuation{} = continuation, input),
    do: %{continuation | input: input}

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

  @spec checkpoint_input(Input.t()) :: Input.t()
  defp checkpoint_input(%Input{} = input), do: logical_input(input)

  @spec checkpoint_source(Source.t() | nil) :: Source.t() | nil
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

  # Preserve an invalid decoded shape long enough for `Input.validate/1` to
  # return a precise boundary error instead of crashing during projection.
  defp checkpoint_source(source), do: source

  @spec checkpoint_result(Result.t() | nil, Input.t()) :: Result.t() | nil
  defp checkpoint_result(nil, _input), do: nil

  defp checkpoint_result(%Result{} = result, input) do
    %{
      result
      | input: input,
        route: route_projection(result.route),
        metadata: portable_metadata(result.metadata)
    }
  end

  @spec route_projection(Route.t() | map() | term()) :: Route.t() | nil
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

  @spec portable_metadata(term()) :: map()
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

  @spec identity_value(term()) :: term() | nil
  defp identity_value(value) do
    case Value.validate(value, [:source_identity]) do
      :ok -> value
      {:error, _reason} -> nil
    end
  end

  @spec portable_projection(term()) :: {:ok, term()} | :drop
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

  @spec validate_binary_size(binary(), pos_integer()) ::
          :ok | {:error, {:run_checkpoint_too_large, non_neg_integer(), pos_integer()}}
  defp validate_binary_size(binary, max_bytes) when byte_size(binary) <= max_bytes, do: :ok

  defp validate_binary_size(binary, max_bytes),
    do: {:error, {:run_checkpoint_too_large, byte_size(binary), max_bytes}}

  @spec decode_term(binary()) :: {:ok, term()} | {:error, term()}
  defp decode_term(<<131, 80, _compressed::binary>>),
    do: {:error, :compressed_run_checkpoint_not_supported}

  defp decode_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    _exception -> {:error, :invalid_run_checkpoint}
  end

  @spec decode_envelope(term()) :: {:ok, pos_integer(), term()} | {:error, term()}
  defp decode_envelope(%{"format" => @format, "version" => version, "run" => encoded_run})
       when version in @supported_versions,
       do: {:ok, version, encoded_run}

  defp decode_envelope(%{"format" => @format, "version" => version}),
    do: {:error, {:unsupported_run_checkpoint_version, version, @supported_versions}}

  defp decode_envelope(_envelope), do: {:error, :invalid_run_checkpoint}

  @spec validate_run(term()) :: :ok | {:error, term()}
  defp validate_run(%Run{run_version: @version} = run) do
    with :ok <- validate_run_shape(run), do: validate_run_invariants(run)
  end

  defp validate_run(%Run{run_version: version}) when version != @version,
    do: {:error, {:unsupported_run_version, version, [@version]}}

  defp validate_run(_run), do: {:error, :invalid_run}

  @spec validate_run_shape(raw_run()) :: :ok | {:error, term()}
  defp validate_run_shape(%Run{} = run) do
    case {untrusted_field(run, :input), untrusted_field(run, :state)} do
      {%Input{}, %State{}} ->
        with :ok <- Input.validate(run.input),
             :ok <- validate_run_identity(run),
             :ok <- validate_run_position(run),
             :ok <- validate_run_revision(run),
             :ok <- validate_run_lineage(run),
             :ok <- validate_run_pin(run),
             :ok <- validate_start_continuation(run),
             :ok <- validate_inference_continuation(run) do
          validate_run_metadata(run)
        end

      _other ->
        {:error, :invalid_run}
    end
  end

  @spec validate_run_identity(raw_run()) :: :ok | {:error, :invalid_run_identity}
  defp validate_run_identity(%Run{id: id, agent: agent, trace_id: trace_id})
       when is_binary(id) and id != "" and is_atom(agent) and not is_nil(agent) and
              is_binary(trace_id) and trace_id != "",
       do: :ok

  defp validate_run_identity(_run), do: {:error, :invalid_run_identity}

  @spec validate_run_position(raw_run()) :: :ok | {:error, :invalid_run_position}
  defp validate_run_position(%Run{status: status, cursor: cursor})
       when status in [:ready, :boundary, :awaiting, :complete, :failed] and
              cursor in [:turn, :policy, :effect, :inference, :complete],
       do: :ok

  defp validate_run_position(_run), do: {:error, :invalid_run_position}

  @spec validate_run_revision(raw_run()) :: :ok | {:error, :invalid_run_revision}
  defp validate_run_revision(%Run{revision: revision, step_id: step_id})
       when is_integer(revision) and revision >= 0 and
              (is_nil(step_id) or is_binary(step_id)),
       do: :ok

  defp validate_run_revision(_run), do: {:error, :invalid_run_revision}

  @spec validate_run_lineage(raw_run()) :: :ok | {:error, :invalid_run_lineage}
  defp validate_run_lineage(%Run{causation_id: causation_id, correlation_id: correlation_id})
       when (is_nil(causation_id) or is_binary(causation_id)) and
              (is_nil(correlation_id) or is_binary(correlation_id)),
       do: :ok

  defp validate_run_lineage(_run), do: {:error, :invalid_run_lineage}

  @spec validate_run_pin(raw_run()) :: :ok | {:error, :invalid_run_definition_pin}
  defp validate_run_pin(%Run{} = run) do
    if DefinitionRef.valid?(run.definition_ref) and
         is_integer(run.activation_generation) and run.activation_generation >= 0 and
         is_integer(run.authority_epoch) and run.authority_epoch >= 0 and
         is_binary(run.closure_digest) and run.closure_digest != "" do
      :ok
    else
      {:error, :invalid_run_definition_pin}
    end
  end

  @spec validate_start_continuation(raw_run()) :: :ok | {:error, term()}
  defp validate_start_continuation(%Run{} = run) do
    case untrusted_field(run, :start_continuation) do
      nil -> :ok
      %StartContinuation{} = start -> StartContinuation.validate(start)
      _invalid -> {:error, :invalid_run_start_continuation}
    end
  end

  @spec validate_inference_continuation(raw_run()) :: :ok | {:error, term()}
  defp validate_inference_continuation(%Run{} = run) do
    case untrusted_field(run, :inference_continuation) do
      nil ->
        :ok

      %Spectre.Run.InferenceContinuation{} = continuation ->
        Spectre.Run.InferenceContinuation.validate(continuation)

      _invalid ->
        {:error, :invalid_run_inference_continuation}
    end
  end

  # Run.t() promises a map, but decoded external structs can violate that
  # promise before this validator establishes trust.
  @dialyzer {:nowarn_function, validate_run_metadata: 1}
  @spec validate_run_metadata(raw_run()) :: :ok | {:error, :invalid_run_metadata}
  defp validate_run_metadata(%Run{} = run) do
    if is_map(untrusted_field(run, :metadata)),
      do: :ok,
      else: {:error, :invalid_run_metadata}
  end

  # `Value.decode/1` reconstructs structs at an untrusted persistence boundary.
  # Indirection prevents the static Run.t() contract from erasing these runtime
  # checks for forged or corrupt struct fields.
  @spec untrusted_field(map(), atom()) :: term()
  defp untrusted_field(container, field), do: Map.fetch!(container, field)

  @spec migrate_run(pos_integer(), term()) :: {:ok, Run.t()} | {:error, term()}
  defp migrate_run(3, %Run{run_version: 3} = run), do: {:ok, run}

  defp migrate_run(2, %Run{run_version: 2} = run) do
    {:ok,
     %{
       run
       | run_version: 3,
         start_continuation: legacy_start_continuation(run),
         inference_continuation: nil
     }}
  end

  defp migrate_run(1, %Run{run_version: 1} = run)
       when is_atom(run.agent) and not is_nil(run.agent) do
    definition_ref = Run.legacy_definition_ref(run.agent)

    {:ok,
     %{
       run
       | run_version: 3,
         definition_ref: definition_ref,
         activation_generation: 0,
         authority_epoch: 0,
         closure_digest: Run.legacy_closure_digest(run.agent, definition_ref),
         deployment_requirement: nil,
         start_continuation: legacy_start_continuation(run),
         inference_continuation: nil
     }}
  end

  defp migrate_run(checkpoint_version, %Run{run_version: run_version}),
    do: {:error, {:run_checkpoint_schema_mismatch, checkpoint_version, run_version}}

  defp migrate_run(_checkpoint_version, _value), do: {:error, :invalid_run}

  # Earlier writers persisted a ready Run but not the OTP queue entry carrying
  # its original runtime options. Such a Run remains readable, but recovery is
  # intentionally explicit about the missing continuation.
  defp legacy_start_continuation(%Run{status: :ready, cursor: :turn} = run) do
    %StartContinuation{
      input: run.input,
      recoverable?: false,
      reason: :legacy_ready_run_without_start_continuation,
      options: %{}
    }
  end

  defp legacy_start_continuation(%Run{}), do: nil

  @spec validate_run_invariants(raw_run()) :: :ok | {:error, term()}
  defp validate_run_invariants(
         %Run{
           status: :ready,
           cursor: :turn,
           revision: 0,
           step_id: nil,
           waiting: nil,
           result: nil,
           last_error: nil,
           inference_continuation: nil
         } = run
       ) do
    case run.start_continuation do
      %StartContinuation{input: input} when input == run.input -> :ok
      %StartContinuation{} -> {:error, :run_start_continuation_input_mismatch}
      nil -> {:error, :missing_run_start_continuation}
    end
  end

  defp validate_run_invariants(
         %Run{
           status: :boundary,
           cursor: :policy,
           last_error: nil,
           start_continuation: nil,
           inference_continuation: nil,
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
           start_continuation: nil,
           inference_continuation: nil,
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
           status: :awaiting,
           cursor: :inference,
           last_error: nil,
           start_continuation: nil,
           waiting:
             %Invocation{kind: :inference, ref: %Ref{kind: :invocation} = ref} =
               invocation,
           result: nil,
           inference_continuation: %Spectre.Run.InferenceContinuation{} = continuation
         } = run
       ) do
    with :ok <- validate_ref(run, ref),
         :ok <- Invocation.validate(invocation),
         :ok <- Spectre.Run.InferenceContinuation.validate(continuation),
         true <- invocation == continuation.invocation,
         true <- invocation.id == ref.boundary_id,
         true <- invocation.run_id == run.id and invocation.run_revision == run.revision,
         true <- invocation.inference_id == continuation.inference_id,
         {:ok, subject_id} <- Value.opaque_id(continuation.inference_id, "subject"),
         true <- invocation.subject_id == subject_id,
         true <- ref.subject_id == subject_id,
         true <- invocation.stream_epoch == continuation.stream_epoch do
      :ok
    else
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_run_inference_boundary}
    end
  end

  defp validate_run_invariants(
         %Run{
           status: :boundary,
           cursor: :complete,
           last_error: nil,
           start_continuation: nil,
           inference_continuation: nil,
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
           start_continuation: nil,
           inference_continuation: nil,
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
         start_continuation: nil,
         inference_continuation: nil,
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
           start_continuation: nil,
           inference_continuation: nil,
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

  @spec validate_result(Run.t(), Result.t()) :: :ok | {:error, term()}
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

  @spec validate_result_identity(Run.t(), Result.t()) ::
          :ok | {:error, :invalid_run_result_identity | :invalid_run_reference}
  defp validate_result_identity(
         %Run{} = run,
         %Result{
           metadata: %{run: %{ref: %Ref{} = ref} = identity}
         }
       ) do
    expected = run |> Map.from_struct() |> Map.take(@result_identity_fields)

    if Map.take(identity, @result_identity_fields) == expected do
      validate_ref(run, ref)
    else
      {:error, :invalid_run_result_identity}
    end
  end

  defp validate_result_identity(_run, _result), do: {:error, :invalid_run_result_identity}

  @spec result_ref(Result.t()) :: Ref.t() | term() | nil
  defp result_ref(%Result{} = result), do: get_in(result.metadata, [:run, :ref])

  @spec validate_no_open_work(Result.t()) :: :ok | {:error, :invalid_run_terminal_work}
  defp validate_no_open_work(%Result{} = result) do
    if is_nil(Result.open_awaitable(result)) and is_nil(Result.pending_effect(result)),
      do: :ok,
      else: {:error, :invalid_run_terminal_work}
  end

  @spec request_matches_awaitable?(Request.t(), Awaitable.t()) :: boolean()
  defp request_matches_awaitable?(%Request{} = request, %Awaitable{} = awaitable) do
    request.kind == awaitable.kind and request.name == awaitable.name and
      request.label == awaitable.label and request.max_attempts == awaitable.max_attempts and
      request.status == awaitable.status and request.attempts == awaitable.attempts and
      request.metadata == awaitable.metadata
  end

  @spec invocation_matches_effect?(Invocation.t(), Effect.t()) :: boolean()
  defp invocation_matches_effect?(%Invocation{} = invocation, %Effect{} = effect) do
    invocation.kind == :effect and invocation.operation == {effect.kind, effect.name} and
      invocation.idempotency_key == Effect.idempotency_key(effect) and
      invocation.owner == effect.owner and invocation.scope == effect.scope and
      invocation.status == :pending and invocation.attempt == 1 and
      invocation.metadata == %{mode: effect.mode, status: effect.status}
  end

  @spec active_awaitable_id(Result.t()) :: term() | nil
  defp active_awaitable_id(%Result{} = result) do
    case Result.open_awaitable(result) do
      %Awaitable{id: id} -> id
      nil -> nil
    end
  end

  @spec active_effect_id(Result.t()) :: term() | nil
  defp active_effect_id(%Result{} = result) do
    case Result.pending_effect(result) do
      %Effect{id: id} -> id
      nil -> nil
    end
  end

  @spec expected_boundary_id(Run.t(), atom(), term()) :: String.t()
  defp expected_boundary_id(%Run{} = run, kind, subject_id) do
    digest =
      {run.id, run.revision, kind, subject_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Atom.to_string(kind) <> ":" <> binary_part(digest, 0, 32)
  end

  @spec validate_ref(Run.t(), Ref.t()) :: :ok | {:error, :invalid_run_reference}
  defp validate_ref(%Run{} = run, %Ref{} = ref) do
    if ref.run_id == run.id and ref.revision == run.revision and valid_ref_shape?(ref),
      do: :ok,
      else: {:error, :invalid_run_reference}
  end

  @spec valid_ref_shape?(Ref.t()) :: boolean()
  defp valid_ref_shape?(%Ref{} = ref) do
    nonempty_binary?(ref.run_id) and nonempty_binary?(ref.boundary_id) and
      is_integer(ref.revision) and ref.revision >= 0 and
      ref.kind in [:reply, :policy, :invocation, :complete, :error] and
      (is_nil(ref.subject_id) or is_binary(ref.subject_id))
  end

  @spec nonempty_binary?(term()) :: boolean()
  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  @spec max_bytes(keyword()) :: pos_integer()
  defp max_bytes(opts) do
    case Keyword.get(opts, :max_bytes, @default_max_bytes) do
      value when is_integer(value) and value > 0 -> value
      _value -> @default_max_bytes
    end
  end
end
