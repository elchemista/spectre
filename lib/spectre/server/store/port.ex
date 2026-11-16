defmodule Spectre.Server.Store.Port do
  @moduledoc """
  Dispatches coordination storage to a host-selected `Spectre.Server.Store`.

  Pass `{AdapterModule, reference}` for an adapter, or an existing Disk server
  reference for backwards compatibility. Tagged `{:store, module, reference}`
  also works when a tuple could otherwise be interpreted as an OTP server name.
  """
  alias Spectre.Server.Store.Disk

  def fetch(store, key), do: invoke(store, :fetch, [key])
  def put_new(store, key, value), do: invoke(store, :put_new, [key, value])

  def compare_and_swap(store, key, revision, value),
    do: invoke(store, :compare_and_swap, [key, revision, value])

  def delete(store, key, revision), do: invoke(store, :delete, [key, revision])

  @doc "Reads a namespace page when the selected adapter supports listing."
  def list(store, prefix, opts \\ []) do
    {module, reference} = adapter(store)

    if Code.ensure_loaded?(module) and function_exported?(module, :list, 3),
      do: module.list(reference, prefix, opts),
      else: {:error, :store_list_unavailable}
  end

  @doc false
  def adapter({:store, module, reference}) when is_atom(module), do: {module, reference}

  def adapter({module, reference} = store) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2),
      do: {module, reference},
      else: {Disk, store}
  end

  def adapter(store), do: {Disk, store}

  defp invoke(store, function, args) do
    {module, reference} = adapter(store)
    apply(module, function, [reference | args])
  end
end
