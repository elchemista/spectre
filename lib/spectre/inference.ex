defmodule Spectre.Inference do
  @moduledoc """
  Neutral per-invocation cognitive selection and completion boundary.

  The core supplies a compatibility selector. Optional packages contribute a
  selector and immutable profiles through `Spectre.Extension`.
  """

  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.Selector.Default

  @spec complete(module(), Request.t(), Spectre.Context.t()) ::
          {:ok, Response.t()} | {:error, term()}
  def complete(agent, %Request{} = request, %Spectre.Context{} = ctx) when is_atom(agent) do
    {selector, selector_opts} = selector(agent)
    profiles = Keyword.get(selector_opts, :profiles, [])

    if selector == Default or Map.get(request.metadata, :explicit_model_override?) do
      complete_compatibility(request, ctx, selector_opts)
    else
      complete_selected(request, ctx, selector, profiles, selector_opts)
    end
  end

  @spec selector(module()) :: {module(), keyword()}
  defp selector(agent) do
    Spectre.Extension.inference_selector(agent) || {Default, []}
  end

  @spec complete_compatibility(Request.t(), Spectre.Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  defp complete_compatibility(request, ctx, selector_opts) do
    with {:ok, selection} <- Default.select(request, [], ctx, selector_opts) do
      emit_selection(selection, request, ctx.opts)
      started = System.monotonic_time()
      opts = request.metadata.llm_opts

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
    max_attempts =
      request.constraints.max_attempts ||
        Keyword.get(selector_opts, :max_attempts, 2)

    attempt(request, ctx, selector, profiles, selector_opts, max(max_attempts, 1))
  end

  @spec attempt(Request.t(), Spectre.Context.t(), module(), list(), keyword(), pos_integer()) ::
          {:ok, Response.t()} | {:error, term()}
  defp attempt(request, ctx, selector, profiles, selector_opts, max_attempts) do
    with :ok <- ensure_selector(selector),
         {:ok, selection} <- selector.select(request, profiles, ctx, selector_opts) do
      selection = Selection.new(selection)
      emit_selection(selection, request, ctx.opts)
      started = System.monotonic_time()

      opts =
        request.metadata.llm_opts
        |> Keyword.put(:model, selection.model)
        |> Keyword.delete(:fallback)

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
