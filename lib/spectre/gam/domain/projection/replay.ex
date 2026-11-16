defmodule Spectre.GAM.Domain.Projection.Replay do
  @moduledoc false
  alias Spectre.GAM.Domain.Projection.{Persistence, Rows, Store, WorkingSet}
  alias Spectre.GAM.GovernedAct.{Fold, State}
  alias Spectre.GAM.Ledger
  alias Spectre.GAM.Payload.Store, as: PayloadStore

  def recover(config) do
    with {:ok, _head} <- Ledger.Store.head(config.store, config.domain_ref, config.ledger_opts),
         {:ok, handle} <- Store.open(config.projection_store, config.domain_ref),
         initial = State.new(config.domain_ref, config.constitution),
         runtime = %{
           projection: initial,
           projection_store: config.projection_store,
           projection_handle: handle
         },
         {:ok, runtime} <- reduce(config.store, runtime, config.ledger_opts),
         {:ok, projection} <-
           WorkingSet.extend(runtime, :foundation, runtime.projection.recorded_at),
         :ok <- verify_payloads(config, %{runtime | projection: projection}) do
      {:ok, projection, handle}
    end
  end

  def resume(state) do
    with {:ok, runtime} <- reduce(state.store, state, state.ledger_opts),
         :ok <- verify_suffix_payloads(state, runtime) do
      WorkingSet.extend(runtime, state.working_intent, runtime.projection.recorded_at)
    else
      :not_found -> {:error, :domain_ledger_disappeared}
      error -> error
    end
  end

  defp verify_suffix_payloads(prefix, runtime) do
    Ledger.Reader.reduce_to(
      prefix.store,
      prefix.projection.domain_ref,
      Rows.cursor(prefix.projection),
      Rows.cursor(runtime.projection),
      :ok,
      fn entries, :ok ->
        payloads = Enum.map(entries, & &1.payload)

        with {:ok, projection} <-
               WorkingSet.extend(runtime, payloads, runtime.projection.recorded_at),
             :ok <-
               PayloadStore.verify_references(
                 prefix.payload_store,
                 projection,
                 PayloadStore.recovered_refs(projection, payloads)
               ),
             do: {:ok, :ok}
      end,
      prefix.ledger_opts
    )
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp reduce(store, runtime, opts) do
    Ledger.Reader.reduce(
      store,
      runtime.projection.domain_ref,
      Rows.cursor(runtime.projection),
      runtime,
      fn entries, current ->
        [first | _] = entries
        intent = Enum.map(entries, & &1.payload)
        current = %{current | projection: Rows.empty(current.projection)}

        with {:ok, before} <- WorkingSet.extend(current, intent, first.recorded_at),
             {:ok, before} <-
               WorkingSet.include_batch(%{current | projection: before}, first.batch_id),
             {:ok, next} <- Fold.append_batch(before, entries),
             :ok <- Persistence.advance(%{current | projection: before}, next) do
          {:ok, %{current | projection: Rows.empty(next)}}
        end
      end,
      opts
    )
  end

  defp verify_payloads(config, runtime, after_key \\ nil) do
    case Store.page(
           runtime.projection_store,
           runtime.projection_handle,
           Rows.cursor(runtime.projection),
           :payload_refs,
           after: after_key
         ) do
      {:ok, rows, next} ->
        refs = Enum.map(rows, fn {{:payload_refs, ref}, _} -> ref end)

        result =
          with {:ok, projection} <-
                 WorkingSet.extend(
                   runtime,
                   Enum.map(refs, &%{"erasure_target" => &1}),
                   runtime.projection.recorded_at
                 ),
               do: PayloadStore.verify_references(config.payload_store, projection, refs)

        if result == :ok and next != nil, do: verify_payloads(config, runtime, next), else: result

      error ->
        error
    end
  end
end
