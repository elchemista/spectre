defmodule Spectre.Server.Store.Payload do
  @moduledoc false
  @behaviour Spectre.Server.Store

  alias Spectre.Payload.Store, as: PayloadStore
  alias Spectre.Server.Checkpoint
  alias Spectre.Server.Store.{Page, Port}

  @impl true
  def fetch(config, key) do
    with {:ok, entry} <- Port.fetch(config.store, key),
         {:ok, value} <- restore(config, key, entry.value) do
      {:ok, %{entry | value: value}}
    end
  end

  @impl true
  def put_new(config, key, value) do
    with {:ok, saved} <- protect(config, key, value),
         do: Port.put_new(config.store, key, saved)
  end

  @impl true
  def compare_and_swap(config, key, revision, value) do
    with {:ok, saved} <- protect(config, key, value),
         do: Port.compare_and_swap(config.store, key, revision, saved)
  end

  @impl true
  def delete(config, key, revision), do: Port.delete(config.store, key, revision)

  @impl true
  def list(config, prefix, opts \\ []) do
    with {:ok, page} <- Page.options(prefix, opts),
         {:ok, entries, cursor} <- Port.list(config.store, prefix, opts) do
      restore_page(config, entries, page, cursor)
    end
  end

  defp protect(config, key, value) do
    if protected?(key) do
      with {:ok, bytes} <- Checkpoint.encode_value(value),
           {:ok, reference} <- PayloadStore.put(config.payload_store, bytes, context(config, key)) do
        {:ok, %{"spectre_payload_record" => 1, "reference" => reference}}
      end
    else
      {:ok, value}
    end
  end

  defp restore(
         config,
         key,
         %{"spectre_payload_record" => 1, "reference" => reference} = marker
       )
       when map_size(marker) == 2 do
    if protected?(key) do
      with {:ok, bytes} <-
             PayloadStore.fetch(config.payload_store, reference, context(config, key)),
           do: Checkpoint.decode_snapshot(bytes)
    else
      {:ok, marker}
    end
  end

  defp restore(_, _, value), do: {:ok, value}

  defp restore_page(_, [], _, cursor), do: {:ok, [], cursor}

  defp restore_page(config, entries, page, cursor) do
    entries
    |> Enum.reduce_while({:ok, [], 0, cursor}, &restore_entry(config, &1, page, &2))
    |> case do
      {:ok, values, _, next} -> {:ok, Enum.reverse(values), next}
      error -> error
    end
  end

  defp restore_entry(config, {key, entry}, page, accumulation) do
    case restore(config, key, entry.value) do
      {:ok, value} -> take_entry({key, %{entry | value: value}}, page, accumulation)
      error -> {:halt, error}
    end
  end

  defp take_entry(restored, page, {:ok, acc, bytes, tail}) do
    size = :erlang.external_size(restored)

    cond do
      bytes + size <= page.max_bytes ->
        {:cont, {:ok, [restored | acc], bytes + size, tail}}

      acc == [] ->
        {:halt, {:error, :store_page_entry_too_large}}

      true ->
        last = acc |> hd() |> elem(0) |> Page.key()
        {:halt, {:ok, acc, bytes, Page.cursor(page, last)}}
    end
  end

  defp protected?(key) when is_tuple(key) and tuple_size(key) > 0,
    do: elem(key, 0) in [:external_approval, :spectre_gam_command]

  defp protected?(_), do: false

  defp context(config, key), do: %{domain: config.domain, kind: :coordination, key: key}
end
