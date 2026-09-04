defmodule Spectre.Domain.Command.Scope do
  @moduledoc """
  Opens direct session or child Scopes as exact durable transactions.

  Work and Vigil Scopes remain governed consequences and are therefore rejected
  here; they can only be created through normal Candidate Admission. Context,
  ingress, generation and acquisition-time bindings are checked before append.
  """

  alias Spectre.Domain.{Event, Transaction}
  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Sequencer.{Control, State}
  alias Spectre.Scope.Opening
  alias Spectre.SubmissionContext

  @doc "Validates and durably records one direct Scope opening."
  @spec open(
          State.t(),
          SubmissionContext.t() | term(),
          Opening.t() | term()
        ) ::
          {:ok, State.t(), Opening.t()} | {:error, State.t(), term()}

  def open(state, context, input) do
    open_with_retries(state, context, input, state.conflict_retries)
  end

  defp open_with_retries(state, context, input, conflicts_left) do
    with {:ok, context} <- SubmissionContext.new(context),
         :ok <- SubmissionContext.verify_seal(context, state.grant_secret),
         {:ok, opening} <- Opening.new(input),
         :ok <- validate_direct_scope_opening(opening),
         {:ok, now} <- Transaction.trusted_recorded_at(state),
         :ok <- validate_scope_opening_boundary(state, context, opening, now) do
      case existing_scope(state.projection, opening) do
        {:ok, durable} ->
          {:ok, state, durable}

        :not_found ->
          append_scope_opening(
            state,
            context,
            opening,
            conflicts_left,
            now
          )

        {:error, reason} ->
          {:error, state, reason}
      end
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp validate_direct_scope_opening(%Opening{kind: kind, source_act_ref: nil})
       when kind in [:session, :child],
       do: :ok

  defp validate_direct_scope_opening(%Opening{kind: kind}) when kind in [:work, :vigil],
    do: {:error, {:governed_scope_opening_required, kind}}

  defp validate_direct_scope_opening(%Opening{}),
    do: {:error, :invalid_direct_scope_opening}

  defp validate_scope_opening_boundary(state, context, opening, now) do
    cond do
      context.domain_ref != state.projection.domain_ref or
          opening.domain_ref != state.projection.domain_ref ->
        {:error, :scope_opening_domain_mismatch}

      context.ingress_ref != state.ingress_ref or opening.ingress_ref != state.ingress_ref ->
        {:error, :scope_opening_ingress_mismatch}

      context.scope_ref != opening.ref ->
        {:error, :scope_opening_context_scope_mismatch}

      context.authenticated_principal_ref != opening.opened_by_ref ->
        {:error, :scope_opening_principal_mismatch}

      context.ref != opening.submission_context_ref ->
        {:error, :scope_opening_context_ref_mismatch}

      context.authentication_ref != opening.authentication_ref or
        context.ingress_ref != opening.ingress_ref or
        context.channel_ref != opening.channel_ref or
          context.session_ref != opening.session_ref ->
        {:error, :scope_opening_context_binding_mismatch}

      context.host_generation != state.generation or
          opening.host_generation != state.generation ->
        {:error, :scope_opening_generation_mismatch}

      opening.opened_at > now ->
        {:error, {:scope_opening_from_future, opening.ref}}

      true ->
        :ok
    end
  end

  defp existing_scope(projection, opening) do
    case Map.fetch(projection.scopes, opening.ref) do
      {:ok, existing} ->
        if existing == opening,
          do: {:ok, existing},
          else: {:error, {:scope_identity_conflict, opening.ref}}

      :error ->
        :not_found
    end
  end

  defp append_scope_opening(
         state,
         context,
         opening,
         conflicts_left,
         recorded_at
       ) do
    with {:ok, payload} <- Event.scope_opened(opening),
         {:ok, _provisional} <- Transaction.apply_payloads(state.projection, [payload]) do
      Commit.append(
        state,
        [payload],
        recorded_at,
        conflicts_left,
        &recovered_scope(state, &1, opening),
        &open_with_retries(&1, context, opening, &2)
      )
    else
      {:error, reason} -> {:error, state, reason}
    end
  end

  defp recovered_scope(state, projection, opening) do
    case existing_scope(projection, opening) do
      {:ok, durable} ->
        {:ok, %{state | projection: projection}, durable}

      :not_found ->
        halted = Control.halt(state, :scope_opening_not_recovered)
        {:error, halted, :scope_opening_not_recovered}

      {:error, reason} ->
        halted = Control.halt(state, reason)
        {:error, halted, reason}
    end
  end
end
