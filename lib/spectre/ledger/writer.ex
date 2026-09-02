defmodule Spectre.Ledger.Writer do
  @moduledoc false

  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store

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
         recorded_at when is_integer(recorded_at) and recorded_at >= 0 <-
           Keyword.get(opts, :recorded_at),
         {:ok, _identity} <-
           Entry.batch_identity(domain_ref, batch_id, payloads, expected_revision) do
      Store.append(store, domain_ref, batch_id, payloads, expected_revision, opts)
    else
      false ->
        {:error, :invalid_ledger_options}

      nil ->
        {:error, :ledger_recorded_at_required}

      recorded_at when not is_integer(recorded_at) or recorded_at < 0 ->
        {:error, :ledger_recorded_at_required}

      {:error, _reason} = error ->
        error
    end
  end
end
