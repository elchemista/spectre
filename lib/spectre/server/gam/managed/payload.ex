defmodule Spectre.Server.GAM.Managed.Payload do
  @moduledoc false

  alias Spectre.Payload.Store
  alias Spectre.Server.Checkpoint

  def protect(nil, value, _context), do: {:ok, value}

  def protect(config, value, context) do
    with {:ok, bytes} <- Checkpoint.encode_value(value),
         {:ok, reference} <- Store.put(config, bytes, context) do
      {:ok, %{"spectre_payload" => 1, "reference" => reference}}
    end
  end

  def restore(config, %{"spectre_payload" => 1, "reference" => reference} = marker, context)
      when map_size(marker) == 2 do
    with {:ok, bytes} <- Store.fetch(config, reference, context) do
      Checkpoint.decode_snapshot(bytes)
    end
  end

  def restore(_config, value, _context), do: {:ok, value}

  def restore_evidence(records, opts, domain_ref) do
    config = opts |> Keyword.get(:ingress_opts, []) |> Keyword.get(:payload_store)
    context = %{kind: :evidence, domain_ref: domain_ref}

    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, restored} ->
      case restore(config, record.payload, context) do
        {:ok, payload} -> {:cont, {:ok, [%{record | payload: payload} | restored]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end
end
