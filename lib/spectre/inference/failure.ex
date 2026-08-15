defmodule Spectre.Inference.Failure do
  @moduledoc false

  @semantic_details [
    :inference_budget_exceeded,
    :inference_budget_exhausted,
    :inference_budget_settlement_failed,
    :inference_worker_down,
    :stream_interrupted,
    :stream_session_start_failed,
    :inference_rebind_failed,
    :inference_reconciliation_failed
  ]

  @doc "Returns a bounded, portable representation with no provider payload."
  @spec sanitize(term()) :: atom() | tuple() | %{class: atom()}
  def sanitize(reason) when is_atom(reason) and not is_nil(reason), do: reason

  def sanitize({:cancelled, reason}),
    do: {:cancelled, class(reason)}

  def sanitize({tag, detail}) when tag in @semantic_details,
    do: {tag, safe_detail(detail)}

  def sanitize(reason), do: %{class: class(reason)}

  @doc false
  @spec sanitize_outcome(term()) :: term()
  def sanitize_outcome({:error, reason}), do: {:error, sanitize(reason)}
  def sanitize_outcome(outcome), do: outcome

  @doc "Returns the stable class of an arbitrary failure without retaining its value."
  @spec class(term()) :: atom()
  def class(reason) when is_atom(reason) and not is_nil(reason), do: reason
  def class({reason, _detail}) when is_atom(reason) and not is_nil(reason), do: reason
  def class({reason, _first, _second}) when is_atom(reason) and not is_nil(reason), do: reason
  def class(%{class: reason}) when is_atom(reason) and not is_nil(reason), do: reason
  def class(_reason), do: :error

  defp safe_detail(detail) when is_atom(detail) and not is_nil(detail), do: detail
  defp safe_detail(%{class: class}) when is_atom(class) and not is_nil(class), do: %{class: class}
  defp safe_detail(detail), do: %{class: class(detail)}
end
