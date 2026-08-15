defmodule Spectre.Run.StartContinuation do
  @moduledoc """
  Durable admission data required to start a conversational Run after restart.

  The continuation stores the already-normalized logical input and only the
  runtime options that are both portable and safe to checkpoint. Provider
  clients, functions, processes, references, and secret-bearing values stay in
  the local runtime binding. When one of those values is required by a call,
  `recoverable?` is false and recovery terminates the Run explicitly instead of
  guessing a replacement binding.
  """

  alias Spectre.Input
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Run.Value
  alias Spectre.SensitiveData

  @enforce_keys [:input, :recoverable?]
  defstruct [
    :input,
    :reason,
    :inference_request,
    entrypoint: :turn,
    recoverable?: true,
    options: %{}
  ]

  @type t :: %__MODULE__{
          input: Input.t(),
          entrypoint: :turn | :inference,
          inference_request: InferenceRequest.t() | nil,
          recoverable?: boolean(),
          reason: term() | nil,
          options: map()
        }

  # These values are reconstructed from the owning Instance or are merely call
  # transport controls. Persisting them would capture a process, duplicate the
  # canonical State, or make a client-side timeout part of Run semantics.
  @ephemeral_option_keys [
    :timeout,
    :state,
    :instance_pid,
    :subject,
    :subject_id,
    :instance_definition_store,
    :checkpoint_store,
    :receipt_sink,
    :runner_supervisor
  ]

  @doc false
  @spec new(Input.t(), keyword()) :: t()
  def new(%Input{} = input, opts) when is_list(opts) do
    build(input, :turn, nil, opts)
  end

  @doc false
  @spec for_inference(Input.t(), InferenceRequest.t(), keyword()) :: t()
  def for_inference(%Input{} = input, %InferenceRequest{} = request, opts)
      when is_list(opts) do
    build(input, :inference, request, opts)
  end

  defp build(input, entrypoint, request, opts) do
    selected = Keyword.drop(opts, @ephemeral_option_keys)
    request_result = portable_inference_request(request)

    case {request_result, portable_options(selected)} do
      {{:ok, portable_request}, {:ok, options}} ->
        %__MODULE__{
          input: input,
          entrypoint: entrypoint,
          inference_request: portable_request,
          recoverable?: true,
          options: options
        }

      {{:error, reason}, _options} ->
        %__MODULE__{
          input: input,
          entrypoint: entrypoint,
          inference_request: nil,
          recoverable?: false,
          reason: reason,
          options: %{}
        }

      {{:ok, portable_request}, {:error, reason}} ->
        %__MODULE__{
          input: input,
          entrypoint: entrypoint,
          inference_request: portable_request,
          recoverable?: false,
          reason: reason,
          options: %{}
        }
    end
  end

  @doc false
  @spec runtime_options(t()) :: keyword()
  def runtime_options(%__MODULE__{options: options}) do
    options
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # Start continuation is restored before runtime code executes. Its complete
  # kind-dependent portable shape is therefore one trust boundary.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = continuation) do
    cond do
      not match?(%Input{}, continuation.input) ->
        {:error, :invalid_start_continuation_input}

      continuation.entrypoint not in [:turn, :inference] ->
        {:error, :invalid_start_continuation_entrypoint}

      continuation.entrypoint == :turn and not is_nil(continuation.inference_request) ->
        {:error, :unexpected_start_inference_request}

      continuation.entrypoint == :inference and continuation.recoverable? and
          not match?(%InferenceRequest{}, continuation.inference_request) ->
        {:error, :missing_start_inference_request}

      not is_nil(continuation.inference_request) and
          not match?(%InferenceRequest{}, continuation.inference_request) ->
        {:error, :invalid_start_inference_request}

      not is_boolean(continuation.recoverable?) ->
        {:error, :invalid_start_continuation_recoverability}

      not is_map(continuation.options) or is_struct(continuation.options) ->
        {:error, :invalid_start_continuation_options}

      continuation.recoverable? and not is_nil(continuation.reason) ->
        {:error, :invalid_start_continuation_reason}

      true ->
        with :ok <- validate_portable_options(continuation.options) do
          validate_inference_request(continuation.inference_request)
        end
    end
  end

  defp portable_inference_request(nil), do: {:ok, nil}

  defp portable_inference_request(%InferenceRequest{} = request) do
    case validate_inference_request(request) do
      :ok -> {:ok, request}
      {:error, _reason} = error -> error
    end
  end

  defp validate_inference_request(nil), do: :ok

  # The embedded request has several independent portability requirements that
  # must all hold before restart can re-enter inference selection.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_inference_request(%InferenceRequest{} = request) do
    cond do
      not is_binary(request.id) or request.id == "" ->
        {:error, :invalid_start_inference_request_id}

      is_nil(request.purpose) or not match?(%Spectre.Prompt.Plan{}, request.plan) ->
        {:error, :invalid_start_inference_request}

      not match?(%Spectre.Inference.Constraints{}, request.constraints) or
        not is_list(request.previous_errors) or not is_map(request.metadata) ->
        {:error, :invalid_start_inference_request}

      true ->
        case Value.validate(request, [:start_continuation, :inference_request]) do
          :ok -> :ok
          {:error, _reason} -> {:error, :nonportable_start_inference_request}
        end
    end
  end

  defp portable_options(options) do
    value = Map.new(options)

    with :ok <- validate_portable_options(value) do
      {:ok, value}
    end
  end

  defp validate_portable_options(options) do
    if path = SensitiveData.sensitive_path(options) do
      {:error, {:sensitive_start_option, path}}
    else
      case Value.validate(options, [:start_continuation, :options]) do
        :ok -> :ok
        {:error, _reason} -> {:error, :nonportable_start_option}
      end
    end
  end
end
