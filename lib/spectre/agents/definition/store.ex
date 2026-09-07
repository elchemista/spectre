defmodule Spectre.Definition.Store do
  @moduledoc """
  Immutable Definition publication over any `Spectre.Store` adapter.

  Publication verifies bytes and the exact lookup reference on readback. It
  never chooses a head or activates a revision: that requires a governance Act
  in the Domain. Definitions and their assets can be prepared outside a running
  Domain; losing this cache cannot rewrite the copies already in its ledger.
  """

  alias Spectre.{Definition, Portable, Store}

  @doc "Stores a validated immutable Definition and verifies its publication."
  @spec publish(Store.config(), Definition.t()) :: {:ok, String.t()} | {:error, term()}
  def publish(store, definition) do
    with {:ok, definition} <- Definition.new(definition),
         :ok <- Store.put_new(store, key(definition.ref), Definition.canonical(definition)),
         {:ok, restored} <- fetch(store, definition.ref),
         true <- restored === definition do
      {:ok, definition.ref}
    else
      false -> {:error, :definition_store_readback_mismatch}
      :not_found -> {:error, :definition_store_write_not_visible}
      {:error, _} = error -> error
    end
  end

  @doc "Fetches by immutable reference, rejecting wrong-key, malformed or tampered content."
  @spec fetch(Store.config(), String.t()) :: {:ok, Definition.t()} | :not_found | {:error, term()}
  def fetch(store, ref) do
    with :ok <- Portable.validate_content_ref(ref, :definition, :definition_ref),
         {:ok, _revision, value} <- Store.get(store, key(ref)),
         {:ok, definition} <- Definition.from_canonical(value),
         true <- definition.ref === ref do
      {:ok, definition}
    else
      false -> {:error, :definition_store_lookup_mismatch}
      {:deleted, _revision} -> :not_found
      :not_found -> :not_found
      {:error, _} = error -> error
    end
  end

  defp key(ref), do: "definition/" <> ref
end
