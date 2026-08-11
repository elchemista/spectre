defmodule Spectre.Inference do
  @moduledoc """
  Neutral per-invocation cognitive selection and completion boundary.

  The core supplies a compatibility selector. Optional packages contribute a
  selector and immutable profiles through `Spectre.Extension`.
  """

  alias Spectre.Inference.Profile
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.Selector.Default

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
    %{
      response
      | selection: response.selection || selection,
        latency_ms: response.latency_ms || latency_ms
    }
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
