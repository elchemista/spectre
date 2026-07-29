defmodule Spectre.Turn do
  @moduledoc """
  High-level host-facing turn result.

  A turn wraps the raw `%Spectre.Result{}` and a lifecycle decision that tells
  the host what to do next without encoding capability-specific branches in the
  decision vocabulary. This is Spectre's canonical local host result whether
  the input was routed normally or claimed by a pre-route
  `Spectre.Turn.Handler`.

  Transport protocols should map their envelope into `Spectre.turn/3` and map
  this result back out. Addressing, correlation, remote task state, retries,
  and delivery guarantees remain transport concerns.
  """

  alias Spectre.Invocation
  alias Spectre.Result
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Codec
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.Value
  alias Spectre.Runtime
  alias Spectre.Turn.Decision

  defstruct [
    :agent,
    :input,
    :ref,
    :boundary,
    :observable,
    opts: [],
    result: nil,
    decision: nil,
    metadata: %{}
  ]

  @type decision ::
          {:awaiting, Spectre.Awaitable.t(), Spectre.Result.t()}
          | {:needs, Spectre.Effect.t(), Spectre.Result.t()}
          | {:completed, Spectre.Effect.t() | Spectre.Awaitable.t(), Spectre.Result.t()}
          | {:reply, Spectre.Result.t()}
          | {:no_response, Spectre.Result.t()}

  @type observable ::
          {:reply, term(), Ref.t()}
          | {:awaiting, Ref.t()}
          | {:needs, Boundary.t()}

  @type t :: %__MODULE__{
          agent: module() | GenServer.server(),
          input: Spectre.Input.t() | String.t() | map(),
          ref: Ref.t(),
          boundary: Boundary.t() | Invocation.t() | nil,
          observable: observable(),
          opts: keyword(),
          result: Spectre.Result.t(),
          decision: decision(),
          metadata: map()
        }

  @doc """
  Starts a Run and advances it to its first observable boundary.
  """
  @spec run(module(), Spectre.Input.t() | String.t() | map(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def run(agent, input, opts \\ []) when is_atom(agent) and is_list(opts) do
    case Runtime.start(agent, input, opts) do
      {:continue, %Run{} = run} ->
        case Runtime.advance(run, opts) do
          {:await, %Invocation{}, %Run{}} = step -> {:ok, from_step(agent, input, opts, step)}
          {:boundary, %Boundary{}, %Run{}} = step -> {:ok, from_step(agent, input, opts, step)}
          {:complete, %Result{}, %Run{}} = step -> {:ok, from_step(agent, input, opts, step)}
          {:error, reason, %Run{}} -> {:error, reason}
          {:continue, %Run{}} -> {:error, :run_did_not_reach_observable_boundary}
        end

      {:error, reason, %Run{}} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves this turn's active policy from a trusted host decision and returns
  the next lifecycle decision.

  This keeps application adapters from synthesizing user text or manually
  rebuilding approved effects.
  """
  @spec resolve_policy(t(), Spectre.Policy.resolution(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def resolve_policy(%__MODULE__{} = turn, resolution, opts \\ []) do
    opts = Keyword.merge(turn.opts, opts)

    with {:ok, %Result{} = result} <-
           Spectre.resolve_policy(turn.agent, turn.result, resolution, opts) do
      {:ok, from_result(turn.agent, turn.input, opts, result)}
    end
  end

  @doc """
  Builds a turn from an already available result.
  """
  @spec from_result(module() | GenServer.server(), term(), keyword(), Spectre.Result.t()) :: t()
  def from_result(agent, input, opts, %Result{} = result) do
    decision = Decision.decide(result)
    ref = result_ref(result, decision)
    {observable, boundary} = projection_from_result(result, decision, ref)

    %__MODULE__{
      agent: agent,
      input: logical_input(input),
      ref: ref,
      boundary: boundary,
      observable: observable,
      opts: logical_opts(opts),
      result: result,
      decision: decision,
      metadata: %{lifecycle: Result.lifecycle(result), run_ref: ref}
    }
  end

  @doc """
  Projects one closed Runtime step into the stable host-facing Turn.

  The continuation itself remains owned by the runtime/actor. The Turn exposes
  only a revision-fenced reference and the first observable request or reply.
  """
  @spec from_step(module() | GenServer.server(), term(), keyword(), Runtime.step_result()) :: t()
  def from_step(agent, input, opts, {:await, %Invocation{} = invocation, %Run{} = run}) do
    build_from_run(
      agent,
      input,
      opts,
      run,
      invocation.ref,
      invocation,
      {:awaiting, invocation.ref}
    )
  end

  def from_step(
        agent,
        input,
        opts,
        {:boundary, %Boundary{kind: :reply} = boundary, %Run{} = run}
      ) do
    build_from_run(
      agent,
      input,
      opts,
      run,
      boundary.ref,
      boundary,
      {:reply, boundary.output, boundary.ref}
    )
  end

  def from_step(
        agent,
        input,
        opts,
        {:boundary, %Boundary{} = boundary, %Run{} = run}
      ) do
    build_from_run(agent, input, opts, run, boundary.ref, boundary, {:needs, boundary})
  end

  def from_step(agent, input, opts, {:complete, %Result{} = result, %Run{} = run}) do
    ref = result_ref(result, Decision.decide(result))
    build_from_run(agent, input, opts, run, ref, nil, {:reply, nil, ref})
  end

  defp build_from_run(
         agent,
         _input,
         opts,
         %Run{result: %Result{} = result} = run,
         ref,
         boundary,
         observable
       ) do
    %__MODULE__{
      agent: agent,
      input: Codec.logical_input(run.input),
      ref: ref,
      boundary: boundary,
      observable: observable,
      opts: logical_opts(opts),
      result: result,
      decision: Decision.decide(result),
      metadata: %{
        lifecycle: Result.lifecycle(result),
        run_ref: ref,
        run_status: get_in(result.metadata, [:run, :status])
      }
    }
  end

  defp projection_from_result(result, {:reply, _result}, %Ref{kind: :reply} = ref),
    do: reply_projection(result.reply_text, ref)

  defp projection_from_result(_result, {:reply, _decision_result}, ref),
    do: {{:reply, nil, ref}, nil}

  defp projection_from_result(_result, {:awaiting, awaitable, _decision_result}, ref) do
    boundary = %Boundary{
      id: ref.boundary_id,
      kind: :needs,
      ref: ref,
      request: Request.from_awaitable(awaitable),
      metadata: %{request_kind: :policy}
    }

    {{:needs, boundary}, boundary}
  end

  defp projection_from_result(_result, {:needs, effect, _decision_result}, ref) do
    invocation = Invocation.from_effect(%{ref | kind: :invocation}, effect)
    {{:awaiting, invocation.ref}, invocation}
  end

  defp projection_from_result(result, _decision, ref) do
    if ref.kind == :reply and Result.visible_reply?(result),
      do: reply_projection(result.reply_text, ref),
      else: {{:reply, nil, ref}, nil}
  end

  defp reply_projection(output, ref) do
    boundary = %Boundary{
      id: ref.boundary_id,
      kind: :reply,
      ref: ref,
      output: output,
      metadata: %{content_type: :text}
    }

    {{:reply, output, ref}, boundary}
  end

  defp result_ref(%Result{} = result, decision) do
    case get_in(result.metadata, [:run, :ref]) do
      %Ref{} = ref ->
        if valid_result_ref?(result, ref, projection_kind(result, decision)),
          do: ref,
          else: legacy_result_ref(result, decision)

      _missing ->
        legacy_result_ref(result, decision)
    end
  end

  defp legacy_result_ref(%Result{} = result, decision) do
    run_id =
      get_in(result.metadata, [:run, :id]) ||
        get_in(result.metadata, [:runtime_identity, :trace_id]) ||
        get_in(result.metadata, [:runtime_identity, :turn_id]) ||
        Spectre.Identity.uuid7()

    run_id = Value.logical_id(run_id, "legacy-run") || Spectre.Identity.uuid7()
    revision = get_in(result.metadata, [:run, :revision]) || 0
    revision = if is_integer(revision) and revision >= 0, do: revision, else: 0
    kind = projection_kind(result, decision)
    subject_id = logical_subject(projection_subject(result, decision))
    boundary_id = legacy_boundary_id(run_id, revision, kind, subject_id)
    Ref.new(run_id, revision, kind, boundary_id, subject_id)
  end

  defp projection_kind(result, decision) do
    cond do
      get_in(result.metadata, [:run, :status]) == :failed -> :error
      get_in(result.metadata, [:run, :status]) == :complete -> :complete
      match?(%Spectre.Awaitable{}, Result.open_awaitable(result)) -> :policy
      match?(%Spectre.Effect{}, Result.pending_effect(result)) -> :invocation
      Result.visible_reply?(result) -> :reply
      true -> :complete
    end
  rescue
    _exception -> fallback_decision_kind(decision)
  end

  defp projection_subject(result, decision) do
    case projection_kind(result, decision) do
      :policy -> result |> Result.open_awaitable() |> Map.get(:id)
      :invocation -> result |> Result.pending_effect() |> Map.get(:id)
      _kind -> nil
    end
  end

  defp fallback_decision_kind({:reply, _result}), do: :reply
  defp fallback_decision_kind({:awaiting, _awaitable, _result}), do: :policy
  defp fallback_decision_kind({:needs, _effect, _result}), do: :invocation
  defp fallback_decision_kind(_decision), do: :complete

  defp legacy_boundary_id(run_id, revision, kind, subject_id) do
    digest =
      {run_id, revision, kind, subject_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "legacy:" <> binary_part(digest, 0, 32)
  end

  defp logical_input(%Spectre.Input{} = input), do: Codec.logical_input(input)
  defp logical_input(input), do: input |> Spectre.Input.new() |> Codec.logical_input()

  defp logical_opts(opts) do
    opts
    |> Keyword.take([
      :conversation_id,
      :correlation_id,
      :causation_id,
      :run_id,
      :trace_id,
      :run_metadata
    ])
    |> Enum.filter(fn {_key, value} -> match?(:ok, Value.validate(value)) end)
  end

  defp logical_subject(subject) do
    case Value.validate(subject) do
      :ok -> subject
      {:error, _reason} -> nil
    end
  end

  defp valid_result_ref?(%Result{} = result, %Ref{} = ref, expected_kind) do
    run_id = get_in(result.metadata, [:run, :id])
    revision = get_in(result.metadata, [:run, :revision])

    valid_ref_shape?(ref, expected_kind) and match?(:ok, Value.validate(ref)) and
      optional_identity_matches?(run_id, ref.run_id) and
      optional_identity_matches?(revision, ref.revision)
  end

  defp valid_ref_shape?(%Ref{} = ref, expected_kind) do
    nonempty_binary?(ref.run_id) and nonempty_binary?(ref.boundary_id) and
      is_integer(ref.revision) and ref.revision >= 0 and ref.kind == expected_kind and
      (is_nil(ref.subject_id) or is_binary(ref.subject_id))
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp optional_identity_matches?(nil, _expected), do: true
  defp optional_identity_matches?(value, expected), do: value == expected
end
