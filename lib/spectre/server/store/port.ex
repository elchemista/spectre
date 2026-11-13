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

  defp invoke({:store, module, reference}, function, args) when is_atom(module),
    do: apply(module, function, [reference | args])

  defp invoke({module, reference} = store, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2),
      do: apply(module, function, [reference | args]),
      else: apply(Disk, function, [store | args])
  end

  defp invoke(store, function, args), do: apply(Disk, function, [store | args])
end
