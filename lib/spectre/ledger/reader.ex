defmodule Spectre.Ledger.Reader do
  @moduledoc """
  Verified, pull-based batch traversal of a captured ledger prefix.

  Native adapters read one atomic batch at a time. The captured head fences
  traversal, so concurrent appends neither extend a recovery indefinitely nor
  change its result. Memory for ledger input is bounded by a batch, not by the
  age of the Domain; the reducer's accumulated state is a separate concern.

  A missing page before the captured head is corruption, never end-of-stream.
  This reader does not trust checkpoint state: a caller starting after genesis
  must already possess a verified predecessor. Full audit remains independent.
  Reducers must not publish authority or perform external effects: only a
  successful result establishes agreement with the entire captured prefix.
  """

  alias Spectre.Ledger
  alias Spectre.Ledger.{Entry, Store}

  @spec reduce(Store.config(), String.t(), Ledger.cursor(), term(), function(), keyword()) ::
          :not_found | {:ok, term()} | {:error, term()}
  def reduce(store, domain_ref, cursor, initial, reducer, opts \\ []) do
    with true <- Entry.valid_identifier?(domain_ref),
         :ok <- validate_cursor(cursor),
         cursor = Map.take(cursor, [:revision, :head_digest]),
         {:ok, target} <- Store.head(store, domain_ref, opts),
         true <- target.revision >= cursor.revision do
      context = %{
        store: store,
        domain_ref: domain_ref,
        target: target,
        opts: opts,
        recorded_at: nil
      }

      read_next(context, cursor, initial, reducer)
    else
      false -> {:error, :invalid_ledger_read_range}
      other -> other
    end
  end

  defp read_next(%{target: target}, %{revision: revision} = cursor, acc, _reducer)
       when revision == target.revision do
    if cursor === target,
      do: {:ok, acc},
      else: {:error, :ledger_read_head_mismatch}
  end

  defp read_next(context, cursor, acc, reducer) do
    with {:ok, page} <-
           Store.read_batch(
             context.store,
             context.domain_ref,
             cursor.revision + 1,
             context.opts
           ),
         {:ok, verified} <- Ledger.verify_suffix(page, context.domain_ref, cursor),
         :ok <- validate_page(verified, cursor, context.target),
         :ok <- validate_time(context.recorded_at, hd(verified.entries).recorded_at),
         {:ok, next} <- reducer.(verified.entries, acc) do
      next_cursor = Map.take(verified, [:revision, :head_digest])
      context = %{context | recorded_at: List.last(verified.entries).recorded_at}
      read_next(context, next_cursor, next, reducer)
    else
      :not_found -> {:error, {:ledger_read_missing_batch, cursor.revision + 1}}
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_ledger_reducer_result}
    end
  end

  defp validate_page(%{entries: [first | _]} = page, cursor, target) do
    cond do
      page.revision > target.revision ->
        {:error, :ledger_read_beyond_head}

      page.revision - cursor.revision !== first.batch_size ->
        {:error, :ledger_read_multiple_batches}

      page.revision === target.revision and page.head_digest !== target.head_digest ->
        {:error, :ledger_read_head_mismatch}

      true ->
        :ok
    end
  end

  defp validate_page(_page, _cursor, _target), do: {:error, :ledger_read_empty_batch}

  defp validate_time(nil, _current), do: :ok
  defp validate_time(previous, current) when current >= previous, do: :ok

  defp validate_time(previous, current),
    do: {:error, {:ledger_time_regression, current, previous}}

  defp validate_cursor(%{revision: revision, head_digest: digest})
       when is_integer(revision) and revision >= 0 do
    if Spectre.Portable.sha256_digest?(digest), do: :ok, else: {:error, :invalid_ledger_cursor}
  end

  defp validate_cursor(_), do: {:error, :invalid_ledger_cursor}
end
