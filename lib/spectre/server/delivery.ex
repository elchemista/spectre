defmodule Spectre.Server.Delivery do
  @moduledoc false
  alias Spectre.Server.GAM

  @doc false
  @spec session(map(), term(), keyword()) :: :ok | {:error, atom()}
  def session(state, tag, opts) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) or Keyword.keys(opts) -- [:session] != [] ->
        {:error, :invalid_delivery_options}

      Keyword.has_key?(opts, :session) and opts[:session] != state.submission_epoch ->
        {:error, :stale_session}

      Map.get(state, :session_required, false) and not Keyword.has_key?(opts, :session) and
          not match?({:command, _}, tag) ->
        {:error, :session_required}

      true ->
        :ok
    end
  end

  def session(_, _, _), do: {:error, :invalid_delivery_options}

  def validate(_state, _tag, {:governed, _payload}), do: {:error, :unverified_governed_result}

  def validate(state, {:pending, id}, result) do
    case Map.get(state.pending, id) do
      %{kind: :consent} ->
        if match?({:governed_ref, reference} when is_map(reference), result),
          do: :ok,
          else: {:error, :durable_result_reference_required}

      _ ->
        :ok
    end
  end

  def validate(state, {:command, id}, result) do
    if lifecycle_command?(Map.get(state.outbox, id)),
      do: {:error, :lifecycle_delivery_not_supported},
      else: validate_command_result(state, id, result)
  end

  def validate(_state, _tag, _result), do: :ok

  defp lifecycle_command?(%{lifecycle: _}), do: true
  defp lifecycle_command?(%{lifecycle_authorized: true}), do: true
  defp lifecycle_command?(%{blocked_by: _}), do: true

  defp lifecycle_command?(%{command: %{kind: kind}}),
    do: kind in [:close_pending, :close_pending_after, :cancel_pending_close]

  defp lifecycle_command?(_), do: false

  defp validate_command_result(state, id, result) do
    if governed_command?(state, id) do
      if match?({:governed_ref, reference} when is_map(reference), result),
        do: :ok,
        else: {:error, :durable_result_reference_required}
    else
      :ok
    end
  end

  defp governed_command?(state, id) do
    Map.has_key?(state.operations, id) or governed_outbox?(Map.get(state.outbox, id))
  end

  defp governed_outbox?(%{command: %{kind: kind}}),
    do: kind in [:propose, :confirm_pending, :explain_pending, :resume_pending]

  defp governed_outbox?(_entry), do: false

  def result_key(result, fallback) do
    case GAM.result_key(result) do
      {:ok, key} -> key
      {:error, _} -> fallback
    end
  end

  def matching_pending(state, {:pending, id}, {:governed, %{act: act}}) do
    case Map.get(state.pending, id) do
      %{kind: :consent, candidate: candidate} ->
        if act.candidate_identity_key == candidate.identity_key and
             act.scope_ref == candidate.scope_ref,
           do: :ok,
           else: {:error, :result_continuation_mismatch}

      _ ->
        :ok
    end
  end

  def matching_pending(_state, _tag, _result), do: :ok
end
