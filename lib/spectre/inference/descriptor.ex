defmodule Spectre.Inference.Descriptor do
  @moduledoc """
  Portable description of one logical inference.

  It contains the prompt plan and the deterministic post-processing context,
  but never an adapter process, callback, credential, HTTP handle, or provider
  request identifier. Runtime bindings are resolved separately and checked
  against the frozen selection before dispatch.
  """

  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request
  alias Spectre.Prompt.Plan
  alias Spectre.Route
  alias Spectre.Run.Value

  @portable_option_keys [
    :plan_actions?,
    :policy_prompt?,
    :sanitize_reply,
    :model_reply_max_bytes,
    :prompt_format,
    :effect_owner,
    :effect_scope,
    :maximum_output_tokens,
    :structured_output?,
    :streaming?,
    :stream_attach_timeout,
    :stream_open_timeout,
    :stream_provider_stall_timeout,
    :stream_consumer_idle_timeout,
    :stream_max_duration_ms,
    :stream_terminal_retention,
    :stream_result_timeout,
    :stream_max_transport_chunk_bytes,
    :stream_max_parser_residual_bytes,
    :stream_max_delta_bytes,
    :stream_max_buffer_events,
    :stream_max_buffer_bytes,
    :stream_max_events_per_transport_item,
    :stream_checkpoint_max_bytes,
    :max_sanitizer_lookahead_bytes,
    :inference_heartbeat_interval,
    :stream_max_awaiters
  ]

  @enforce_keys [:id, :purpose, :plan, :constraints]
  defstruct [
    :id,
    :purpose,
    :plan,
    :constraints,
    :route,
    :flow,
    modalities: [:text],
    options: %{},
    metadata: %{},
    recoverable?: true,
    recovery_reason: nil
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          purpose: atom(),
          plan: Plan.t(),
          constraints: Constraints.t(),
          route: Route.t() | nil,
          flow: term(),
          modalities: [atom()],
          options: map(),
          metadata: map(),
          recoverable?: boolean(),
          recovery_reason: term()
        }

  @doc false
  @spec from_request(Request.t(), keyword()) :: t()
  def from_request(%Request{} = request, opts \\ []) when is_list(opts) do
    route = route_projection(Keyword.get(opts, :route))
    selected_options = opts |> Keyword.take(@portable_option_keys) |> Map.new()
    {portable_options, portable_options?} = portable_options(selected_options)
    requested_recoverable? = Keyword.get(opts, :recoverable?, true)

    recoverable? = requested_recoverable? and portable_options?

    recovery_reason =
      cond do
        not portable_options? -> :runtime_descriptor_options_not_portable
        not requested_recoverable? -> Keyword.get(opts, :recovery_reason)
        true -> nil
      end

    descriptor = %__MODULE__{
      id: request.id,
      purpose: normalize_purpose(request.purpose),
      plan: request.plan,
      constraints: request.constraints,
      route: route,
      flow: request.flow,
      modalities: request.modalities,
      options: portable_options,
      metadata: request_metadata(request.metadata),
      recoverable?: recoverable?,
      recovery_reason: recovery_reason
    }

    case validate(descriptor) do
      :ok -> descriptor
      {:error, reason} -> raise ArgumentError, "invalid inference descriptor: #{inspect(reason)}"
    end
  end

  @doc false
  @spec options(t()) :: keyword()
  def options(%__MODULE__{options: options}) do
    options
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
  end

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  # A descriptor crosses the provider boundary. Its independent portability
  # and identity fences are intentionally reviewed together.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def validate(%__MODULE__{} = descriptor) do
    cond do
      not nonempty_binary?(descriptor.id) ->
        {:error, :invalid_inference_descriptor_id}

      not is_atom(descriptor.purpose) or is_nil(descriptor.purpose) ->
        {:error, :invalid_inference_descriptor_purpose}

      not match?(%Plan{}, descriptor.plan) ->
        {:error, :invalid_inference_descriptor_plan}

      not match?(%Constraints{}, descriptor.constraints) ->
        {:error, :invalid_inference_descriptor_constraints}

      not is_nil(descriptor.route) and not match?(%Route{}, descriptor.route) ->
        {:error, :invalid_inference_descriptor_route}

      not is_list(descriptor.modalities) or
          not Enum.all?(descriptor.modalities, &is_atom/1) ->
        {:error, :invalid_inference_descriptor_modalities}

      not plain_map?(descriptor.options) or not plain_map?(descriptor.metadata) ->
        {:error, :invalid_inference_descriptor_metadata}

      not is_boolean(descriptor.recoverable?) ->
        {:error, :invalid_inference_descriptor_recoverability}

      descriptor.recoverable? and not is_nil(descriptor.recovery_reason) ->
        {:error, :invalid_inference_descriptor_recovery_reason}

      true ->
        Value.validate(descriptor, [:inference_descriptor])
    end
  end

  # The full Route can contain handler functions and raw provider evidence.
  # Post-processing only needs the stable decision and ownership projection.
  defp route_projection(nil), do: nil

  defp route_projection(%Route{} = route) do
    %Route{
      label: route.label,
      flow: route.flow,
      owner: route.owner,
      scope: route.scope,
      strategy: route.strategy,
      confidence: route.confidence,
      margin: route.margin,
      accepted?: route.accepted?,
      scores: portable_or_empty(route.scores),
      labels: portable_or_empty(route.labels),
      terminal?: route.terminal?,
      escalation_reason: route.escalation_reason
    }
  end

  defp route_projection(_route), do: nil

  defp request_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([
      :flow_constraints,
      :required_profile_ref,
      :explicit_model_override?,
      "required_profile_ref",
      "explicit_model_override?"
    ])
    |> portable_or_empty()
  end

  defp request_metadata(_metadata), do: %{}

  defp portable_or_empty(value) do
    case Value.validate(value) do
      :ok -> value
      {:error, _reason} -> empty_same_shape(value)
    end
  end

  defp portable_options(value) do
    case Value.validate(value) do
      :ok -> {value, true}
      {:error, _reason} -> {%{}, false}
    end
  end

  defp empty_same_shape(value) when is_list(value), do: []
  defp empty_same_shape(_value), do: %{}

  defp normalize_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: purpose
  defp normalize_purpose(_purpose), do: :inference
  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
