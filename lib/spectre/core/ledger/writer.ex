defmodule Spectre.Ledger.Writer do
  @moduledoc false

  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store

  @doc "Validates batch identity and explicit acquisition time before invoking the configured store; does not grant authority."
  @spec append(
          Store.config(),
          String.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          keyword()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(store, domain_ref, batch_id, payloads, expected_revision, opts) do
    with true <- is_list(opts) and Keyword.keyword?(opts),
         :ok <- validate_recorded_at(Keyword.get(opts, :recorded_at)),
         {:ok, _identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision) do
      Store.append(store, domain_ref, batch_id, payloads, expected_revision, opts)
    else
      false ->
        {:error, :invalid_ledger_options}

      {:error, _reason} = error ->
        error
    end
  end

  # Tag validation failures before the with boundary: a malformed time must
  # never be confused with a batch validation error (or vice versa).
  defp validate_recorded_at(time) when is_integer(time) and time >= 0, do: :ok
  defp validate_recorded_at(_time), do: {:error, :ledger_recorded_at_required}
end
