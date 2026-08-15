defmodule Spectre.Invocation do
  @moduledoc """
  A concrete, revision-fenced request to execute one nondeterministic boundary.

  Invocations describe work without embedding executable clients or callbacks.
  Effect and inference attempts share the same lifecycle vocabulary. A direct
  Runtime caller may resume an effect descriptor explicitly; a
  `Spectre.Instance` retains the owning Run, dispatches work outside its
  mailbox, and accepts only a correlated worker receipt before applying the
  returned continuation.
  """

  alias Spectre.Effect
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Run
  alias Spectre.Run.InferenceContinuation
  alias Spectre.Run.Ref
  alias Spectre.Run.Value

  @enforce_keys [
    :id,
    :run_id,
    :run_revision,
    :ref,
    :kind,
    :operation,
    :subject_id,
    :idempotency_key
  ]
  defstruct [
    :id,
    :run_id,
    :run_revision,
    :ref,
    :kind,
    :operation,
    :subject_id,
    :idempotency_key,
    :inference_id,
    :attempt_id,
    :stream_epoch,
    :owner,
    :scope,
    status: :pending,
    attempt: 1,
    control_revision: 0,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          run_revision: non_neg_integer(),
          ref: Ref.t(),
          kind: :effect | :inference,
          operation: {atom(), atom() | String.t() | nil},
          subject_id: String.t(),
          idempotency_key: String.t(),
          inference_id: String.t() | nil,
          attempt_id: String.t() | nil,
          stream_epoch: String.t() | nil,
          owner: module() | nil,
          scope: Spectre.Definition.scope() | nil,
          status: :pending,
          attempt: pos_integer(),
          control_revision: non_neg_integer(),
          metadata: map()
        }

  @doc false
  @spec from_effect(Run.t(), Effect.t(), String.t()) :: t()
  def from_effect(%Run{} = run, %Effect{} = effect, id) when is_binary(id) do
    ref = Run.ref(run, :invocation, id, effect.id)
    from_effect(ref, effect)
  end

  @doc false
  @spec from_effect(Ref.t(), Effect.t()) :: t()
  def from_effect(%Ref{kind: :invocation} = ref, %Effect{} = effect) do
    invocation =
      %__MODULE__{
        id: ref.boundary_id,
        run_id: ref.run_id,
        run_revision: ref.revision,
        ref: ref,
        kind: :effect,
        operation: {effect.kind, effect.name},
        subject_id: ref.subject_id,
        idempotency_key: Effect.idempotency_key(effect),
        owner: effect.owner,
        scope: effect.scope,
        metadata: %{mode: effect.mode, status: effect.status}
      }

    case validate(invocation) do
      :ok -> invocation
      {:error, reason} -> raise ArgumentError, "non-portable Invocation: #{inspect(reason)}"
    end
  end

  @doc false
  @spec from_inference(Run.t(), InferenceContinuation.t(), keyword()) :: t()
  def from_inference(
        %Run{} = run,
        %InferenceContinuation{frozen_selection: %FrozenSelection{}} = continuation,
        opts \\ []
      )
      when is_list(opts) do
    attempt = Keyword.get(opts, :attempt, continuation.attempt)
    control_revision = Keyword.get(opts, :control_revision, continuation.control_revision)

    attempt_id =
      Keyword.get_lazy(opts, :attempt_id, fn ->
        Value.token("inference-attempt", {
          run.id,
          continuation.inference_id,
          attempt,
          control_revision
        })
      end)

    id =
      Keyword.get_lazy(opts, :id, fn ->
        Value.token("inference-invocation", {
          run.id,
          run.revision,
          continuation.inference_id,
          attempt_id,
          control_revision
        })
      end)

    stream_epoch =
      Keyword.get_lazy(opts, :stream_epoch, fn ->
        Value.token("stream-epoch", {id, control_revision})
      end)

    ref = Run.ref(run, :invocation, id, continuation.inference_id)

    invocation = %__MODULE__{
      id: id,
      run_id: run.id,
      run_revision: run.revision,
      ref: ref,
      kind: :inference,
      operation: {:inference, continuation.purpose},
      # Run references deliberately pseudonymize boundary subjects. Keep the
      # logical inference id in its dedicated field and bind the generic
      # subject field to the exact value carried by the public Ref.
      subject_id: ref.subject_id,
      idempotency_key: Value.token("inference-idempotency", {run.id, attempt_id}),
      inference_id: continuation.inference_id,
      attempt_id: attempt_id,
      stream_epoch: stream_epoch,
      attempt: attempt,
      control_revision: control_revision,
      metadata: %{
        model_ref: continuation.frozen_selection.model_ref,
        profile_hash: continuation.frozen_selection.profile_hash,
        streaming?: Keyword.get(opts, :streaming?, false)
      }
    }

    case validate(invocation) do
      :ok -> invocation
      {:error, reason} -> raise ArgumentError, "non-portable Invocation: #{inspect(reason)}"
    end
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # Invocation is the durable dispatch authority. Validate every identity,
  # revision, and kind-specific fence together before execution.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = invocation) do
    cond do
      not Enum.all?(
        [invocation.id, invocation.run_id, invocation.subject_id, invocation.idempotency_key],
        &nonempty_binary?/1
      ) ->
        {:error, :invalid_invocation_identity}

      not is_integer(invocation.run_revision) or invocation.run_revision < 0 ->
        {:error, :invalid_invocation_run_revision}

      invocation.kind not in [:effect, :inference] ->
        {:error, :invalid_invocation_kind}

      invocation.status != :pending ->
        {:error, :invalid_invocation_status}

      not valid_operation?(invocation.operation) ->
        {:error, :invalid_invocation_operation}

      not is_map(invocation.metadata) or is_struct(invocation.metadata) ->
        {:error, :invalid_invocation_metadata}

      not valid_ref?(invocation) ->
        {:error, :invalid_invocation_ref}

      invocation.kind == :inference and
          (not nonempty_binary?(invocation.inference_id) or
             not nonempty_binary?(invocation.attempt_id) or
             not nonempty_binary?(invocation.stream_epoch)) ->
        {:error, :invalid_inference_invocation_identity}

      invocation.kind == :inference and not valid_inference_binding?(invocation) ->
        {:error, :invalid_inference_invocation_binding}

      invocation.kind == :inference and not valid_inference_metadata?(invocation.metadata) ->
        {:error, :invalid_inference_invocation_metadata}

      invocation.kind == :effect and
          Enum.any?(
            [invocation.inference_id, invocation.attempt_id, invocation.stream_epoch],
            &(not is_nil(&1))
          ) ->
        {:error, :invalid_effect_invocation_fences}

      not is_integer(invocation.attempt) or invocation.attempt < 1 ->
        {:error, :invalid_invocation_attempt}

      not is_integer(invocation.control_revision) or invocation.control_revision < 0 ->
        {:error, :invalid_invocation_control_revision}

      true ->
        Value.validate(invocation, [:invocation])
    end
  end

  def validate(_invocation), do: {:error, :invalid_invocation}

  defp valid_ref?(%__MODULE__{ref: %Ref{} = ref} = invocation) do
    ref.kind == :invocation and ref.run_id == invocation.run_id and
      ref.revision == invocation.run_revision and ref.boundary_id == invocation.id and
      ref.subject_id == invocation.subject_id
  end

  defp valid_ref?(_invocation), do: false

  defp valid_operation?({kind, name}) when is_atom(kind) and not is_nil(kind),
    do: is_nil(name) or is_atom(name) or is_binary(name)

  defp valid_operation?(_operation), do: false

  defp valid_inference_metadata?(metadata) do
    nonempty_binary?(Map.get(metadata, :model_ref)) and
      optional_binary?(Map.get(metadata, :profile_hash)) and
      is_boolean(Map.get(metadata, :streaming?))
  end

  defp valid_inference_binding?(invocation) do
    case Value.opaque_id(invocation.inference_id, "subject") do
      {:ok, expected_subject} ->
        invocation.subject_id == expected_subject and
          match?(
            {:inference, purpose} when is_atom(purpose) and not is_nil(purpose),
            invocation.operation
          ) and is_nil(invocation.owner) and is_nil(invocation.scope)

      {:error, _reason} ->
        false
    end
  end

  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: nonempty_binary?(value)
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
