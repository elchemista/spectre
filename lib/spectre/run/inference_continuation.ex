defmodule Spectre.Run.InferenceContinuation do
  @moduledoc """
  Portable control-plane state for one logical inference.

  Provider processes, credentials, HTTP handles, and callbacks never enter
  this struct. Each provider attempt is represented by a revision-fenced
  `Spectre.Invocation`; restart recovery decides from the persisted provider
  status and declared adapter capabilities whether a new stream may be opened.
  """

  alias Spectre.Inference.Budget
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Response
  alias Spectre.Inference.Usage
  alias Spectre.Invocation
  alias Spectre.Run.Value

  @provider_statuses [
    :not_started,
    :selected,
    :dispatching,
    :streaming,
    :terminal,
    :superseded,
    :interrupted,
    :ambiguous
  ]
  @postprocessors [
    :response_generation,
    :route_classification,
    :policy_interrupt_classification,
    :cognitive_operation
  ]

  @enforce_keys [:inference_id, :purpose, :descriptor]
  defstruct [
    :inference_id,
    :purpose,
    :descriptor,
    :frozen_selection,
    :invocation,
    :stream_epoch,
    :provider_request_id,
    :provider_request_digest,
    :resume_cursor,
    :consumer_token_digest,
    :stream_recovery,
    :stream_provider_sequence,
    :budget,
    :recovery,
    :last_response,
    attempt: 1,
    previous_attempts: [],
    control_revision: 0,
    provider_status: :not_started,
    stream_usage: %Usage{},
    stream_usage_quality: :unavailable,
    stream_output_bytes: 0,
    postprocessor: :response_generation,
    recoverable?: true
  ]

  @type t :: %__MODULE__{
          inference_id: String.t(),
          purpose: atom(),
          descriptor: Descriptor.t(),
          frozen_selection: FrozenSelection.t() | nil,
          invocation: Invocation.t() | nil,
          stream_epoch: String.t() | nil,
          provider_request_id: term(),
          provider_request_digest: String.t() | nil,
          resume_cursor: term(),
          consumer_token_digest: String.t() | nil,
          stream_recovery: map() | nil,
          stream_provider_sequence: non_neg_integer() | nil,
          stream_usage: Usage.t(),
          stream_usage_quality: :provider | :estimated | :unavailable,
          stream_output_bytes: non_neg_integer(),
          budget: Budget.t() | nil,
          recovery: map() | nil,
          last_response: Spectre.Inference.Response.t() | nil,
          attempt: pos_integer(),
          previous_attempts: [map()],
          control_revision: non_neg_integer(),
          provider_status: atom(),
          postprocessor: atom(),
          recoverable?: boolean()
        }

  @doc false
  @spec new(Descriptor.t(), keyword()) :: t()
  def new(%Descriptor{} = descriptor, opts \\ []) do
    continuation = %__MODULE__{
      inference_id: Keyword.get(opts, :inference_id, descriptor.id),
      purpose: descriptor.purpose,
      descriptor: descriptor,
      frozen_selection: Keyword.get(opts, :frozen_selection),
      budget: Keyword.get(opts, :budget),
      recovery: Keyword.get(opts, :recovery, %{status: :not_dispatched}),
      postprocessor: Keyword.get(opts, :postprocessor, :response_generation),
      recoverable?: Keyword.get(opts, :recoverable?, descriptor.recoverable?)
    }

    case validate(continuation) do
      :ok ->
        continuation

      {:error, reason} ->
        raise ArgumentError, "invalid inference continuation: #{inspect(reason)}"
    end
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # The continuation is the canonical recovery contract. Keeping all state,
  # ordering, and attempt invariants together avoids validating partial state.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = continuation) do
    cond do
      not nonempty_binary?(continuation.inference_id) ->
        {:error, :invalid_inference_id}

      not is_atom(continuation.purpose) or is_nil(continuation.purpose) ->
        {:error, :invalid_inference_purpose}

      not match?(%Descriptor{}, continuation.descriptor) ->
        {:error, :invalid_inference_descriptor}

      not is_nil(continuation.frozen_selection) and
          not match?(%FrozenSelection{}, continuation.frozen_selection) ->
        {:error, :invalid_frozen_inference_selection}

      not is_nil(continuation.invocation) and
          not match?(%Invocation{kind: :inference}, continuation.invocation) ->
        {:error, :invalid_inference_invocation}

      not is_nil(continuation.invocation) and is_nil(continuation.frozen_selection) ->
        {:error, :missing_frozen_inference_selection}

      continuation.descriptor.id != continuation.inference_id ->
        {:error, :inference_descriptor_id_mismatch}

      continuation.descriptor.purpose != continuation.purpose ->
        {:error, :inference_descriptor_purpose_mismatch}

      not is_integer(continuation.attempt) or continuation.attempt < 1 ->
        {:error, :invalid_inference_attempt}

      not is_integer(continuation.control_revision) or continuation.control_revision < 0 ->
        {:error, :invalid_inference_control_revision}

      continuation.provider_status not in @provider_statuses ->
        {:error, :invalid_inference_provider_status}

      continuation.postprocessor not in @postprocessors ->
        {:error, :invalid_inference_postprocessor}

      not is_boolean(continuation.recoverable?) ->
        {:error, :invalid_inference_recoverability}

      continuation.recoverable? and not continuation.descriptor.recoverable? ->
        {:error, :inference_recoverability_upgrade}

      not optional_binary?(continuation.provider_request_digest) or
          not optional_binary?(continuation.consumer_token_digest) ->
        {:error, :invalid_inference_recovery_digest}

      not is_nil(continuation.stream_recovery) and
          (not is_map(continuation.stream_recovery) or is_struct(continuation.stream_recovery)) ->
        {:error, :invalid_inference_stream_recovery}

      not is_nil(continuation.recovery) and
          (not is_map(continuation.recovery) or is_struct(continuation.recovery)) ->
        {:error, :invalid_inference_recovery}

      not valid_previous_attempts?(continuation.previous_attempts) ->
        {:error, :invalid_inference_previous_attempts}

      not is_nil(continuation.last_response) and
          not match?(%Response{}, continuation.last_response) ->
        {:error, :invalid_inference_last_response}

      not is_nil(continuation.stream_provider_sequence) and
          (not is_integer(continuation.stream_provider_sequence) or
             continuation.stream_provider_sequence < 0) ->
        {:error, :invalid_inference_stream_provider_sequence}

      not match?(%Usage{}, continuation.stream_usage) or
        continuation.stream_usage_quality not in [:provider, :estimated, :unavailable] or
        not is_integer(continuation.stream_output_bytes) or
          continuation.stream_output_bytes < 0 ->
        {:error, :invalid_inference_stream_usage}

      continuation.stream_usage.output_bytes != continuation.stream_output_bytes ->
        {:error, :inference_stream_output_bytes_mismatch}

      continuation.provider_request_digest != provider_digest(continuation.provider_request_id) ->
        {:error, :inference_provider_request_digest_mismatch}

      is_nil(continuation.invocation) and not is_nil(continuation.stream_epoch) ->
        {:error, :inference_epoch_without_invocation}

      true ->
        with :ok <- Descriptor.validate(continuation.descriptor),
             :ok <- validate_selection(continuation),
             :ok <- validate_budget(continuation),
             :ok <- validate_last_response(continuation.last_response),
             :ok <- Usage.validate(continuation.stream_usage),
             :ok <- validate_invocation(continuation) do
          Value.validate(continuation, [:inference_continuation])
        end
    end
  end

  defp validate_selection(%__MODULE__{frozen_selection: nil}), do: :ok

  defp validate_selection(
         %__MODULE__{frozen_selection: %FrozenSelection{} = selection} = continuation
       ) do
    with :ok <- FrozenSelection.validate(selection),
         true <- selection.request_id == continuation.inference_id,
         true <- selection.attempt == continuation.attempt do
      :ok
    else
      false -> {:error, :inference_selection_fence_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_budget(%__MODULE__{budget: nil}), do: :ok

  defp validate_budget(%__MODULE__{budget: %Budget{} = budget, inference_id: inference_id}) do
    if budget.inference_id == inference_id do
      Budget.validate(budget)
    else
      {:error, :inference_budget_id_mismatch}
    end
  end

  defp validate_budget(_continuation), do: {:error, :invalid_inference_budget}

  defp validate_last_response(nil), do: :ok
  defp validate_last_response(%Response{} = response), do: Response.validate(response)

  defp validate_invocation(%__MODULE__{invocation: nil}), do: :ok

  # Invocation and continuation identifiers are derived from one another; this
  # clause intentionally audits the full derivation as a single fence.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_invocation(%__MODULE__{} = continuation) do
    invocation = continuation.invocation

    expected_attempt_id =
      Value.token("inference-attempt", {
        invocation.run_id,
        continuation.inference_id,
        continuation.attempt,
        continuation.control_revision
      })

    expected_id =
      Value.token("inference-invocation", {
        invocation.run_id,
        invocation.run_revision,
        continuation.inference_id,
        expected_attempt_id,
        continuation.control_revision
      })

    expected_stream_epoch =
      Value.token("stream-epoch", {expected_id, continuation.control_revision})

    expected_idempotency_key =
      Value.token("inference-idempotency", {invocation.run_id, expected_attempt_id})

    with :ok <- Invocation.validate(invocation) do
      cond do
        invocation.inference_id != continuation.inference_id ->
          {:error, :inference_invocation_id_mismatch}

        invocation.attempt != continuation.attempt ->
          {:error, :inference_invocation_attempt_mismatch}

        invocation.control_revision != continuation.control_revision ->
          {:error, :inference_invocation_control_revision_mismatch}

        invocation.stream_epoch != continuation.stream_epoch ->
          {:error, :inference_invocation_epoch_mismatch}

        invocation.attempt_id != expected_attempt_id ->
          {:error, :inference_invocation_attempt_id_mismatch}

        invocation.id != expected_id ->
          {:error, :inference_invocation_identity_mismatch}

        invocation.stream_epoch != expected_stream_epoch ->
          {:error, :inference_invocation_epoch_identity_mismatch}

        invocation.idempotency_key != expected_idempotency_key ->
          {:error, :inference_invocation_idempotency_mismatch}

        invocation.operation != {:inference, continuation.purpose} ->
          {:error, :inference_invocation_purpose_mismatch}

        Map.get(invocation.metadata, :model_ref) != continuation.frozen_selection.model_ref or
            Map.get(invocation.metadata, :profile_hash) !=
              continuation.frozen_selection.profile_hash ->
          {:error, :inference_invocation_selection_mismatch}

        true ->
          :ok
      end
    end
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""
  defp optional_binary?(nil), do: true
  defp optional_binary?(value), do: nonempty_binary?(value)

  defp valid_previous_attempts?(attempts) when is_list(attempts) and length(attempts) <= 32 do
    Enum.all?(attempts, &(is_map(&1) and not is_struct(&1)))
  end

  defp valid_previous_attempts?(_attempts), do: false
  defp provider_digest(nil), do: nil
  defp provider_digest(value), do: Value.token("provider", value)
end
