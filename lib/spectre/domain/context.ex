defmodule Spectre.Domain.Context do
  @moduledoc """
  Authenticates and validates host-supplied SubmissionContexts.

  The ingress input is intentionally opaque: an application adapter may accept
  text, decoded audio, telephony metadata or any other transport-specific
  value. Spectre requires only that the adapter return a context bound to the
  configured Domain, Scope, ingress identity and host generation; the sealed
  result is then safe to present at the governed Admission boundary.
  """

  alias Spectre.{Adapter, Portable, SubmissionContext}
  alias Spectre.Domain.Sequencer.State

  @authentication_options [:timeout, :ingress_opts]

  @doc "Authenticates opaque ingress input and seals the resulting context."
  @spec authenticate(State.t(), String.t(), term(), keyword()) ::
          {:ok, SubmissionContext.t()} | {:error, term()}
  def authenticate(%State{} = state, scope_ref, input, opts) do
    with :ok <- validate_options(opts),
         :ok <- Portable.validate_ref(scope_ref, :scope_ref),
         {:ok, context} <- call_adapter(state, scope_ref, input, opts),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- validate_binding(state, scope_ref, context),
         {:ok, sealed} <- SubmissionContext.seal(context, state.grant_secret) do
      {:ok, sealed}
    end
  end

  @doc "Checks that a context names the ingress fixed for the running Domain."
  @spec validate_ingress(State.t(), SubmissionContext.t()) :: :ok | {:error, term()}
  def validate_ingress(%State{} = state, %SubmissionContext{} = context) do
    if context.ingress_ref == state.ingress_ref,
      do: :ok,
      else: {:error, :submission_context_ingress_mismatch}
  end

  defp call_adapter(state, scope_ref, input, opts) do
    arguments = [
      state.domain_ref,
      scope_ref,
      input,
      state.generation,
      Keyword.get(opts, :ingress_opts, [])
    ]

    case Adapter.invoke(state.ingress, :authenticate, arguments) do
      {:ok, {:ok, context}} ->
        {:ok, context}

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, _invalid} ->
        {:error, :invalid_ingress_authentication_response}

      {:error, {:adapter_callback_exception, _, _, exception}} ->
        {:error, {:ingress_authentication_failed, exception}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {:ingress_authentication_failed, kind}}
    end
  end

  defp validate_binding(state, scope_ref, context) do
    cond do
      context.domain_ref != state.domain_ref ->
        {:error, :authenticated_context_domain_mismatch}

      context.scope_ref != scope_ref ->
        {:error, :authenticated_context_scope_mismatch}

      context.ingress_ref != state.ingress_ref ->
        {:error, :authenticated_context_ingress_mismatch}

      context.host_generation != state.generation ->
        {:error, :authenticated_context_generation_mismatch}

      true ->
        :ok
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: validate_keyword_options(opts),
      else: {:error, :invalid_authentication_options}
  end

  defp validate_options(_opts), do: {:error, :invalid_authentication_options}

  defp validate_keyword_options(opts) do
    with [] <- Keyword.keys(opts) -- @authentication_options do
      case Keyword.get(opts, :ingress_opts, []) do
        value when is_list(value) ->
          if Keyword.keyword?(value), do: :ok, else: {:error, :invalid_ingress_options}

        _invalid ->
          {:error, :invalid_ingress_options}
      end
    else
      unknown -> {:error, {:unknown_options, :authentication, unknown}}
    end
  end
end
