defmodule Spectre.Inference do
  @moduledoc """
  Neutral per-invocation cognitive selection and completion boundary.

  The core supplies a compatibility selector. Optional packages contribute a
  selector and immutable profiles through `Spectre.Extension`.
  """

  alias Spectre.Inference.Profile
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Prepared
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.Selector.Default
  alias Spectre.Inference.StreamAdapter

  @doc false
  @spec prepare(module(), Request.t(), Spectre.Context.t()) ::
          {:ok, Prepared.t()} | {:error, term()}
  def prepare(agent, %Request{} = request, %Spectre.Context{} = ctx) when is_atom(agent) do
    with :ok <- validate_request(request),
         :ok <- validate_selection_mode(agent, request),
         {:ok, selection} <- select_attempt(agent, request, ctx),
         {:ok, provider_opts} <- llm_opts(request),
         {:ok, stream_binding} <- prepare_stream_binding(agent, request, selection, provider_opts) do
      descriptor =
        request
        |> put_stream_output_limit(provider_opts)
        |> Descriptor.from_request(
          ctx.opts
          |> Keyword.put(:route, ctx.route)
          |> Keyword.put(:recoverable?, recoverable_binding?(selection.model))
          |> Keyword.put(:recovery_reason, recovery_reason(selection.model))
        )

      {:ok,
       %Prepared{
         descriptor: descriptor,
         selection: selection,
         frozen_selection: FrozenSelection.from_selection(selection),
         provider_opts: put_provider_output_limit(provider_opts, descriptor),
         stream_adapter: stream_binding.adapter,
         stream_adapter_opts: stream_binding.opts,
         stream_capabilities: stream_binding.capabilities
       }}
    end
  end

  @doc false
  @spec execute(Prepared.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def execute(%Prepared{} = prepared, telemetry_opts \\ []) when is_list(telemetry_opts) do
    selection = prepared.selection
    descriptor = prepared.descriptor

    if FrozenSelection.matches_binding?(prepared.frozen_selection, selection.model) do
      request = request_from_descriptor(descriptor, selection.attempt)
      emit_selection(selection, request, telemetry_opts)
      started = System.monotonic_time()

      opts =
        prepared.provider_opts
        |> Keyword.put(:model, selection.model)
        |> Keyword.delete(:fallback)

      case Spectre.LLM.complete_once(descriptor.plan, opts) do
        {:ok, reply} ->
          response = normalize_response(reply, selection, elapsed_ms(started))
          emit_stop(response, request, telemetry_opts, :ok)
          {:ok, response}

        {:error, reason} = error ->
          emit_failure(selection, request, telemetry_opts, reason)
          error
      end
    else
      {:error, :inference_binding_selection_mismatch}
    end
  end

  @doc false
  @spec reconcile(Prepared.t(), term(), keyword()) ::
          {:ok, Response.t()} | :pending | :not_found | {:error, term()}
  def reconcile(%Prepared{} = prepared, provider_request_id, opts \\ []) when is_list(opts) do
    cond do
      is_nil(provider_request_id) ->
        {:error, :missing_inference_provider_request_id}

      not MapSet.member?(prepared.stream_capabilities, :reconcile) ->
        {:error, :inference_reconcile_capability_unavailable}

      true ->
        adapter_opts =
          prepared.provider_opts
          |> Keyword.merge(prepared.stream_adapter_opts)
          |> Keyword.merge(opts)

        case prepared.stream_adapter.reconcile(
               prepared.descriptor,
               provider_request_id,
               adapter_opts
             ) do
          {:ok, value} -> {:ok, Response.new(value)}
          result when result in [:pending, :not_found] -> result
          {:error, _reason} = error -> error
          reply -> {:error, {:invalid_inference_reconcile_reply, reply_class(reply)}}
        end
    end
  rescue
    exception -> {:error, {:inference_reconcile_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:inference_reconcile_failure, kind, error_class(reason)}}
  end

  @doc false
  @spec rebind(
          module(),
          Descriptor.t(),
          FrozenSelection.t(),
          Spectre.Input.t(),
          Spectre.State.t(),
          keyword()
        ) :: {:ok, Prepared.t()} | {:error, term()}
  def rebind(agent, descriptor, frozen, input, state, opts)
      when is_atom(agent) and is_list(opts) do
    request = request_from_descriptor(descriptor, frozen.attempt)

    request = %{
      request
      | metadata:
          request.metadata
          |> Map.put(:llm_opts, Keyword.merge(opts, Descriptor.options(descriptor)))
          |> Map.put(:model, Keyword.get(opts, :model) || Keyword.get(opts, :adapter))
          |> Map.put(:fallback, Keyword.get(opts, :fallback))
    }

    ctx = %Spectre.Context{
      agent: agent,
      input: input,
      state: state,
      route: descriptor.route,
      opts: Keyword.merge(opts, Descriptor.options(descriptor)),
      assigns: Keyword.get(opts, :assigns, %{})
    }

    with {:ok, %Prepared{} = prepared} <- prepare(agent, request, ctx),
         true <- prepared.frozen_selection == frozen do
      {:ok, %{prepared | descriptor: descriptor, frozen_selection: frozen}}
    else
      false -> {:error, :inference_recovery_selection_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec prepare_attempt(
          module(),
          Descriptor.t(),
          pos_integer(),
          Spectre.Input.t(),
          Spectre.State.t(),
          keyword()
        ) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare_attempt(agent, descriptor, attempt, input, state, opts)
      when is_atom(agent) and is_integer(attempt) and attempt > 0 and is_list(opts) do
    request = request_from_descriptor(descriptor, attempt)

    request = %{
      request
      | previous_errors: List.wrap(Keyword.get(opts, :inference_previous_errors, []))
    }

    request = %{
      request
      | metadata:
          request.metadata
          |> Map.put(:llm_opts, Keyword.merge(opts, Descriptor.options(descriptor)))
          |> Map.put(:model, Keyword.get(opts, :model) || Keyword.get(opts, :adapter))
          |> Map.put(:fallback, Keyword.get(opts, :fallback))
    }

    ctx = %Spectre.Context{
      agent: agent,
      input: input,
      state: state,
      route: descriptor.route,
      opts: Keyword.merge(opts, Descriptor.options(descriptor)),
      assigns: Keyword.get(opts, :assigns, %{})
    }

    case prepare(agent, request, ctx) do
      {:ok, %Prepared{} = prepared} -> {:ok, %{prepared | descriptor: descriptor}}
      {:error, _reason} = error -> error
    end
  end

  @spec complete(module(), Request.t(), Spectre.Context.t()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete(agent, %Request{} = request, %Spectre.Context{} = ctx) when is_atom(agent) do
    with :ok <- validate_request(request) do
      {selector, selector_opts} = selector(agent)
      profiles = Keyword.get(selector_opts, :profiles, [])
      required_profile = required_profile_ref(request)
      explicit_override? = explicit_model_override?(request)

      cond do
        explicit_override? and not is_nil(required_profile) ->
          {:error,
           {:inference_required_profile_forbids_model_override, stable_ref(required_profile)}}

        selector == Default and not is_nil(required_profile) ->
          {:error, {:inference_required_profile_unavailable, stable_ref(required_profile)}}

        selector == Default or explicit_override? ->
          complete_compatibility(request, ctx, selector_opts)

        true ->
          complete_selected(request, ctx, selector, profiles, selector_opts)
      end
    end
  end

  defp validate_selection_mode(agent, request) do
    {selector, _selector_opts} = selector(agent)
    required_profile = required_profile_ref(request)
    explicit_override? = explicit_model_override?(request)

    cond do
      explicit_override? and not is_nil(required_profile) ->
        {:error,
         {:inference_required_profile_forbids_model_override, stable_ref(required_profile)}}

      selector == Default and not is_nil(required_profile) ->
        {:error, {:inference_required_profile_unavailable, stable_ref(required_profile)}}

      true ->
        :ok
    end
  end

  defp select_attempt(agent, request, ctx) do
    {selector, selector_opts} = selector(agent)
    profiles = Keyword.get(selector_opts, :profiles, [])

    if selector == Default or explicit_model_override?(request) do
      Default.select(request, [], ctx, selector_opts)
    else
      with {:ok, profiles} <- normalize_profiles(profiles),
           :ok <- ensure_selector(selector),
           {:ok, selected} <- selector.select(request, profiles, ctx, selector_opts) do
        verified_selection(selected, request, profiles, selector)
      end
    end
  end

  defp request_from_descriptor(descriptor, attempt) do
    Request.new(%{
      id: descriptor.id,
      purpose: descriptor.purpose,
      plan: descriptor.plan,
      route: descriptor.route && descriptor.route.label,
      flow: descriptor.flow,
      modalities: descriptor.modalities,
      constraints: descriptor.constraints,
      attempt: attempt,
      metadata: descriptor.metadata
    })
  end

  defp recoverable_binding?(model) do
    not is_function(model) and match?(:ok, Spectre.Run.Value.validate(model))
  end

  defp reply_class(reply) when is_tuple(reply), do: elem(reply, 0)
  defp reply_class(reply) when is_atom(reply), do: reply
  defp reply_class(reply) when is_map(reply), do: :map
  defp reply_class(_reply), do: :other

  defp recovery_reason(model) do
    if recoverable_binding?(model), do: nil, else: :runtime_model_binding_not_portable
  end

  @spec selector(module()) :: {module(), keyword()}
  defp selector(agent) do
    Spectre.Extension.inference_selector(agent) || {Default, []}
  end

  @spec complete_compatibility(Request.t(), Spectre.Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  defp complete_compatibility(request, ctx, selector_opts) do
    with {:ok, opts} <- llm_opts(request),
         {:ok, selection} <- Default.select(request, [], ctx, selector_opts) do
      emit_selection(selection, request, ctx.opts)
      started = System.monotonic_time()

      case Spectre.LLM.complete(request.plan, opts) do
        {:ok, reply} ->
          response = normalize_response(reply, selection, elapsed_ms(started))
          emit_stop(response, request, ctx.opts, :ok)
          {:ok, response}

        {:error, reason} = error ->
          emit_failure(selection, request, ctx.opts, reason)
          error
      end
    end
  end

  @spec complete_selected(
          Request.t(),
          Spectre.Context.t(),
          module(),
          [Spectre.Inference.Profile.t()],
          keyword()
        ) :: {:ok, Response.t()} | {:error, term()}
  defp complete_selected(request, ctx, selector, profiles, selector_opts) do
    with {:ok, profiles} <- normalize_profiles(profiles) do
      max_attempts =
        request.constraints.max_attempts ||
          Keyword.get(selector_opts, :max_attempts, 2)

      attempt(request, ctx, selector, profiles, selector_opts, max(max_attempts, 1))
    end
  end

  @spec attempt(Request.t(), Spectre.Context.t(), module(), list(), keyword(), pos_integer()) ::
          {:ok, Response.t()} | {:error, term()}
  defp attempt(request, ctx, selector, profiles, selector_opts, max_attempts) do
    with :ok <- ensure_selector(selector),
         {:ok, opts} <- llm_opts(request),
         {:ok, selected} <- selector.select(request, profiles, ctx, selector_opts),
         {:ok, selection} <- verified_selection(selected, request, profiles, selector) do
      emit_selection(selection, request, ctx.opts)
      started = System.monotonic_time()

      opts = opts |> Keyword.put(:model, selection.model) |> Keyword.delete(:fallback)

      case Spectre.LLM.complete_once(request.plan, opts) do
        {:ok, reply} ->
          response = normalize_response(reply, selection, elapsed_ms(started))
          emit_stop(response, request, ctx.opts, :ok)
          {:ok, response}

        {:error, reason} ->
          retry_or_error(
            request,
            ctx,
            selector,
            profiles,
            selector_opts,
            max_attempts,
            selection,
            reason
          )
      end
    end
  end

  @spec retry_or_error(
          Request.t(),
          Spectre.Context.t(),
          module(),
          list(),
          keyword(),
          pos_integer(),
          Selection.t(),
          term()
        ) :: {:ok, Response.t()} | {:error, term()}
  defp retry_or_error(
         request,
         ctx,
         selector,
         profiles,
         selector_opts,
         max_attempts,
         selection,
         reason
       ) do
    cond do
      request.constraints.strict? ->
        emit_failure(selection, request, ctx.opts, reason)
        {:error, reason}

      request.attempt >= max_attempts ->
        emit_failure(selection, request, ctx.opts, reason)
        {:error, {:inference_attempts_exhausted, request.attempt, reason}}

      true ->
        Spectre.Telemetry.emit(
          [:inference, :fallback],
          %{attempt: request.attempt},
          safe_selection_metadata(selection, request, :fallback),
          ctx.opts
        )

        previous_levels =
          [selection.level | Map.get(request.metadata, :previous_levels, [])]

        next = %{
          request
          | attempt: request.attempt + 1,
            previous_errors: request.previous_errors ++ [error_class(reason)],
            metadata: Map.put(request.metadata, :previous_levels, previous_levels)
        }

        attempt(next, ctx, selector, profiles, selector_opts, max_attempts)
    end
  end

  @spec normalize_response(term(), Selection.t(), non_neg_integer()) :: Response.t()
  defp normalize_response(%Response{} = response, selection, latency_ms) do
    response
    |> Map.put(:selection, response.selection || selection)
    |> Map.put(:latency_ms, response.latency_ms || latency_ms)
    |> Response.new()
  end

  defp normalize_response(text, selection, latency_ms) when is_binary(text) do
    Response.new(text: text, selection: selection, latency_ms: latency_ms)
  end

  defp normalize_response(reply, selection, latency_ms) when is_map(reply) do
    reply
    |> Map.put_new(:selection, selection)
    |> Map.put_new(:latency_ms, latency_ms)
    |> Response.new()
  end

  @spec ensure_selector(module()) :: :ok | {:error, term()}
  defp ensure_selector(selector) do
    if Code.ensure_loaded?(selector) and function_exported?(selector, :select, 4),
      do: :ok,
      else: {:error, {:invalid_inference_selector, selector}}
  end

  @spec normalize_profiles(term()) :: {:ok, [Profile.t()]} | {:error, term()}
  defp normalize_profiles(profiles) when is_list(profiles) do
    normalized = Enum.map(profiles, &Profile.new/1)

    case duplicate_profile(normalized) do
      nil -> {:ok, normalized}
      id -> {:error, {:duplicate_inference_profile, id}}
    end
  rescue
    error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_inference_profiles, Exception.message(error)}}
  end

  defp normalize_profiles(value), do: {:error, {:invalid_inference_profiles, shape(value)}}

  @spec verified_selection(term(), Request.t(), [Profile.t()], module()) ::
          {:ok, Selection.t()} | {:error, term()}
  defp verified_selection(selected, request, profiles, selector) do
    selection = Selection.new(selected)

    with :ok <- exact(selection.request_id, request.id, :inference_selection_request_mismatch),
         :ok <- exact(selection.attempt, request.attempt, :inference_selection_attempt_mismatch),
         :ok <- exact(selection.selector, selector, :inference_selection_selector_mismatch),
         {:ok, profile} <- selected_profile(selection, profiles),
         :ok <- exact(selection.model, profile.model, :inference_selection_model_mismatch),
         :ok <-
           exact(
             selection.profile_hash,
             profile.profile_hash,
             :inference_selection_profile_hash_mismatch
           ),
         true <- Profile.compatible?(profile, request, profiles),
         :ok <- required_profile(selection, request) do
      selection = %{
        selection
        | metadata:
            Map.put(
              selection.metadata,
              :profile_supports,
              profile.supports |> MapSet.to_list() |> Enum.sort()
            )
      }

      {:ok, selection}
    else
      false -> {:error, {:inference_profile_incompatible, stable_ref(selection.level)}}
      {:error, _reason} = error -> error
    end
  rescue
    error in ArgumentError ->
      {:error, {:invalid_inference_selection, Exception.message(error)}}
  end

  @spec selected_profile(Selection.t(), [Profile.t()]) ::
          {:ok, Profile.t()} | {:error, term()}
  defp selected_profile(selection, profiles) do
    case Enum.find(profiles, &same_ref?(&1.id, selection.level)) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, {:inference_profile_not_registered, stable_ref(selection.level)}}
    end
  end

  @spec required_profile(Selection.t(), Request.t()) :: :ok | {:error, term()}
  defp required_profile(selection, request) do
    required = required_profile_ref(request)

    if is_nil(required) or same_ref?(required, selection.level) do
      :ok
    else
      {:error,
       {:inference_required_profile_mismatch, stable_ref(required), stable_ref(selection.level)}}
    end
  end

  @spec required_profile_ref(Request.t()) :: term()
  defp required_profile_ref(request) do
    Map.get(
      request.metadata,
      :required_profile_ref,
      Map.get(request.metadata, "required_profile_ref")
    )
  end

  @spec explicit_model_override?(Request.t()) :: boolean()
  defp explicit_model_override?(request) do
    Map.get(
      request.metadata,
      :explicit_model_override?,
      Map.get(request.metadata, "explicit_model_override?", false)
    ) == true
  end

  @spec validate_request(Request.t()) :: :ok | {:error, term()}
  defp validate_request(%Request{} = request) do
    cond do
      not is_map(request.metadata) ->
        {:error, :invalid_inference_request_metadata}

      not match?(%Spectre.Inference.Constraints{}, request.constraints) ->
        {:error, :invalid_inference_request_constraints}

      not is_list(request.previous_errors) ->
        {:error, :invalid_inference_request_previous_errors}

      true ->
        :ok
    end
  end

  @spec llm_opts(Request.t()) :: {:ok, keyword()} | {:error, atom()}
  defp llm_opts(request) do
    opts = Map.get(request.metadata, :llm_opts, Map.get(request.metadata, "llm_opts", []))

    if is_list(opts) and Keyword.keyword?(opts),
      do: {:ok, opts},
      else: {:error, :invalid_inference_llm_options}
  end

  defp prepare_stream_binding(agent, request, selection, provider_opts) do
    if Keyword.get(provider_opts, :streaming?, false) do
      with :ok <- stream_request_supported(request, provider_opts),
           :ok <- stream_profile_supported(selection),
           :ok <- incremental_cleaner_supported(agent, provider_opts),
           {:ok, adapter, adapter_opts} <- stream_adapter_config(provider_opts),
           {:ok, capabilities} <-
             StreamAdapter.validate(adapter, selection.level, adapter_opts) do
        {:ok, %{adapter: adapter, opts: adapter_opts, capabilities: capabilities}}
      end
    else
      {:ok, %{adapter: nil, opts: [], capabilities: MapSet.new()}}
    end
  end

  defp stream_request_supported(request, provider_opts) do
    cond do
      request.purpose != :response_generation ->
        {:error, {:streaming_unsupported, :purpose}}

      Keyword.get(provider_opts, :plan_actions?, true) ->
        {:error, {:streaming_unsupported, :action_planning}}

      request.constraints.structured_output? ->
        {:error, {:streaming_unsupported, :structured_output}}

      request.modalities != [:text] ->
        {:error, {:streaming_unsupported, :modality}}

      true ->
        :ok
    end
  end

  # The default selector has no profile catalog from which to derive
  # `profile_supports`. Its adapter is therefore the sole capability source;
  # StreamAdapter.validate/3 still requires the explicit `:stream` capability.
  defp stream_profile_supported(%Selection{selector: Default}), do: :ok

  defp stream_profile_supported(%Selection{metadata: metadata}) do
    if :stream in Map.get(metadata, :profile_supports, []),
      do: :ok,
      else: {:error, {:streaming_unsupported, :profile}}
  end

  defp incremental_cleaner_supported(agent, provider_opts) do
    case Spectre.ActionConfig.planner(agent) do
      {planner, _opts} ->
        planner_incremental_cleaner_supported(planner)

      nil ->
        if Keyword.get(provider_opts, :sanitize_reply, true) in [true, false],
          do: :ok,
          else: {:error, {:streaming_unsupported, :invalid_sanitizer_configuration}}
    end
  rescue
    _exception -> {:error, {:streaming_unsupported, :planner_cleaner}}
  end

  defp planner_incremental_cleaner_supported(planner) do
    if Code.ensure_loaded?(planner) and function_exported?(planner, :clean_reply, 3) do
      require_incremental_cleaner(planner)
    else
      :ok
    end
  end

  defp require_incremental_cleaner(planner) do
    if function_exported?(planner, :incremental_cleaner?, 0) and
         planner.incremental_cleaner?() == true do
      :ok
    else
      {:error, {:streaming_unsupported, :planner_cleaner_not_incremental}}
    end
  end

  defp stream_adapter_config(provider_opts) do
    case Keyword.get(provider_opts, :stream_adapter) do
      module when is_atom(module) and not is_nil(module) ->
        normalize_stream_adapter_opts(
          module,
          Keyword.get(provider_opts, :stream_adapter_opts, [])
        )

      {module, opts} when is_atom(module) and not is_nil(module) and is_list(opts) ->
        normalize_stream_adapter_opts(module, opts)

      nil ->
        {:error, {:streaming_unsupported, :adapter}}

      _invalid ->
        {:error, {:streaming_unsupported, :adapter_configuration}}
    end
  end

  defp normalize_stream_adapter_opts(module, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, module, opts},
      else: {:error, {:streaming_unsupported, :adapter_configuration}}
  end

  defp normalize_stream_adapter_opts(_module, _opts),
    do: {:error, {:streaming_unsupported, :adapter_configuration}}

  defp put_stream_output_limit(request, provider_opts) do
    if Keyword.get(provider_opts, :streaming?, false) and
         is_nil(request.constraints.maximum_output_tokens) do
      default = Keyword.get(provider_opts, :stream_default_max_output_tokens, 2_048)
      %{request | constraints: %{request.constraints | maximum_output_tokens: default}}
    else
      request
    end
  end

  defp put_provider_output_limit(provider_opts, descriptor) do
    case descriptor.constraints.maximum_output_tokens do
      limit when is_integer(limit) and limit > 0 ->
        Keyword.put(provider_opts, :maximum_output_tokens, limit)

      _none ->
        provider_opts
    end
  end

  @spec exact(term(), term(), atom()) :: :ok | {:error, atom()}
  defp exact(value, value, _reason), do: :ok
  defp exact(_actual, _expected, reason), do: {:error, reason}

  @spec duplicate_profile([Profile.t()]) :: term() | nil
  defp duplicate_profile(profiles) do
    profiles
    |> Enum.group_by(&stable_ref(&1.id))
    |> Enum.find_value(fn {id, entries} -> if length(entries) > 1, do: id end)
  end

  @spec same_ref?(term(), term()) :: boolean()
  defp same_ref?(left, right), do: stable_ref(left) == stable_ref(right)

  @spec stable_ref(term()) :: String.t()
  defp stable_ref(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_ref(value) when is_binary(value), do: value
  defp stable_ref(value), do: inspect(value)

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other

  @spec emit_selection(Selection.t(), Request.t(), keyword()) :: :ok
  defp emit_selection(selection, request, opts) do
    Spectre.Telemetry.emit(
      [:inference, :selection],
      %{attempt: selection.attempt},
      safe_selection_metadata(selection, request, :selected),
      opts
    )
  end

  @spec emit_stop(Response.t(), Request.t(), keyword(), atom()) :: :ok
  defp emit_stop(response, request, opts, outcome) do
    Spectre.Telemetry.emit(
      [:inference, :stop],
      %{latency_ms: response.latency_ms || 0},
      safe_selection_metadata(response.selection, request, outcome),
      opts
    )
  end

  @spec emit_failure(Selection.t(), Request.t(), keyword(), term()) :: :ok
  defp emit_failure(selection, request, opts, reason) do
    Spectre.Telemetry.emit(
      [:inference, :exception],
      %{attempt: selection.attempt},
      safe_selection_metadata(selection, request, error_class(reason)),
      opts
    )
  end

  @spec safe_selection_metadata(Selection.t(), Request.t(), term()) :: map()
  defp safe_selection_metadata(selection, request, outcome) do
    %{
      request_id: request.id,
      purpose: request.purpose,
      level: selection.level,
      profile_hash: selection.profile_hash,
      selector: selection.selector,
      reason: selection.reason,
      attempt: selection.attempt,
      outcome: outcome
    }
  end

  @spec elapsed_ms(integer()) :: non_neg_integer()
  defp elapsed_ms(started) do
    started
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :millisecond)
    |> max(0)
  end

  @spec error_class(term()) :: term()
  defp error_class(%{kind: kind}) when is_atom(kind), do: kind
  defp error_class({kind, _detail}) when is_atom(kind), do: kind
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class(_reason), do: :provider_error
end
