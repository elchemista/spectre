defmodule Spectre.Domain.Command.Scope do
  @moduledoc """
  Opens direct session or child Scopes as exact durable transactions.

  Work and Vigil Scopes remain governed consequences and are therefore rejected
  here; they can only be created through normal Candidate Admission. Context,
  ingress, generation and acquisition-time bindings are checked before append.
  """

  alias Spectre.Domain.Command.Commit
  alias Spectre.Domain.Command.Record, as: CommandRecord
  alias Spectre.Domain.{Context, Event, Transaction}
  alias Spectre.Domain.Sequencer.State
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
    with {:ok, context} <- Context.validate_current(state, context),
         {:ok, opening} <- Opening.new(input),
         :ok <- validate_direct_scope_opening(opening),
         {:ok, now} <- Transaction.trusted_recorded_at(state),
         :ok <- validate_scope_opening_boundary(context, opening, now) do
      case CommandRecord.lookup(state.projection.scopes, opening, :scope_identity_conflict) do
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

  defp validate_scope_opening_boundary(context, opening, now) do
    if opening.opened_at > now do
      {:error, {:scope_opening_from_future, opening.ref}}
    else
      Opening.validate_context(opening, context)
    end
  end

  defp append_scope_opening(
         state,
         context,
         opening,
         conflicts_left,
         recorded_at
       ) do
    case Event.scope_opened(opening) do
      {:ok, payload} ->
        Commit.append(
          state,
          [payload],
          recorded_at,
          conflicts_left,
          &recovered_scope(state, &1, opening),
          &open_with_retries(&1, context, opening, &2)
        )

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  defp recovered_scope(state, projection, opening) do
    CommandRecord.recover(
      state,
      projection,
      :scopes,
      opening,
      :scope_identity_conflict,
      :scope_opening_not_recovered
    )
  end
end
