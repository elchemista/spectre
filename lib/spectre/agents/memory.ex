defmodule Spectre.Memory do
  @moduledoc """
  Bounded host retrieval, separate from chat history and authority state.

  Backends receive an explicit tenant binding and query limits. Each item
  names its source and durable Evidence. The host prepares protected remote
  retrieval through an Act; implementing this behaviour does not authorize
  network I/O inside a Router or make retrieved content trusted instructions.
  """
  alias Spectre.{Adapter, Portable}
  alias Spectre.Canonical.Value

  @callback retrieve(map(), map(), keyword()) ::
              {:ok, %{binding: map(), items: [map()]}} | {:error, term()}

  @doc "Requests a bounded, source-labelled result; rejects backend overflow rather than copying all history."
  @spec retrieve({module(), keyword()}, map() | keyword(), term(), map() | keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def retrieve(adapter, binding, query, limits \\ [])

  def retrieve({module, opts}, binding, query, limits) do
    with true <- Portable.keyword?(opts),
         {:ok, binding} <- Portable.normalize_attrs(binding, [:tenant_id], :memory_binding),
         :ok <- Portable.validate_ref(binding[:tenant_id], :tenant_id),
         {:ok, limits} <- Portable.normalize_attrs(limits, [:limit, :max_bytes], :memory_limits),
         limit = Map.get(limits, :limit, 5),
         bytes = Map.get(limits, :max_bytes, 8000),
         true <- is_integer(limit) and limit in 1..100,
         true <- is_integer(bytes) and bytes in 1..1_048_576,
         :ok <- Adapter.validate(module, retrieve: 3),
         {:ok, {:ok, %{binding: reported, items: items}}} <-
           Adapter.invoke(module, :retrieve, [
             binding,
             %{query: query, limit: limit, max_bytes: bytes},
             opts
           ]),
         true <- reported === binding,
         true <- is_list(items) and length(items) <= limit,
         :ok <- Value.validate(items, max_bytes: bytes),
         :ok <- Spectre.Validation.all(items, &item/1) do
      {:ok, items}
    else
      false -> {:error, :invalid_memory_window}
      {:ok, {:error, _} = error} -> error
      {:ok, _invalid} -> {:error, :invalid_memory_reply}
      {:error, _} = error -> error
    end
  end

  def retrieve(_adapter, _binding, _query, _limits), do: {:error, :invalid_memory_adapter}

  defp item(%{ref: ref, source_ref: source, evidence_refs: refs, content: content})
       when is_binary(content) do
    with :ok <- Portable.validate_ref(ref, :memory_ref),
         :ok <- Portable.validate_ref(source, :source_ref),
         {:ok, _refs} <- Portable.normalize_refs(refs, :memory_evidence_refs),
         true <- String.valid?(content),
         do: :ok,
         else: (
           false -> {:error, :invalid_memory_content}
           error -> error
         )
  end

  defp item(_item), do: {:error, :invalid_memory_item}
end
