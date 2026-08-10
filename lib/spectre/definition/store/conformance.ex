defmodule Spectre.Definition.Store.Conformance do
  @moduledoc """
  Adapter-neutral Definition Store conformance checks.

  Store implementations can call this module from their own test suites. It
  checks immutable publication, duplicate idempotency, verified read-back, and
  optional read-after-restart using only the public Store boundary and without
  depending on ExUnit in production code.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Store

  @type report :: %{
          required(:definition_ref) => String.t(),
          required(:publication_id) => String.t(),
          required(:initial_state) => :not_found | :existing,
          required(:duplicate) => :idempotent,
          required(:readback) => :verified
        }

  @doc "Runs the common publication and read-back contract."
  @spec run(Store.config(), Canonical.t(), Manifest.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def run(store, %Canonical{} = canonical, %Manifest{} = manifest, opts \\ []) do
    ref = Canonical.ref(canonical)

    with {:ok, initial_state} <- initial_state(Store.fetch(store, ref, opts)),
         {:ok, first} <- Store.publish(store, canonical, manifest, opts),
         {:ok, second} <- Store.publish(store, canonical, manifest, opts),
         :ok <- compare_receipts(first, second),
         {:ok, artifact} <- Store.fetch(store, ref, opts),
         :ok <- verify_artifact(artifact, canonical, manifest, first) do
      {:ok,
       %{
         definition_ref: first.definition_ref,
         publication_id: first.publication_id,
         initial_state: initial_state,
         duplicate: :idempotent,
         readback: :verified
       }}
    end
  end

  @doc """
  Verifies that a durable adapter configuration still resolves the same
  artifact after its process or connection has been recreated.
  """
  @spec read_after_restart(Store.config(), Store.config(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def read_after_restart(before, after_restart, ref, opts \\ []) do
    with {:ok, before_artifact} <- Store.fetch(before, ref, opts),
         {:ok, after_artifact} <- Store.fetch(after_restart, ref, opts) do
      if before_artifact == after_artifact,
        do: :ok,
        else: {:error, :definition_store_restart_mismatch}
    else
      :not_found -> {:error, :definition_store_missing_after_restart}
      {:error, _reason} = error -> error
    end
  end

  @spec initial_state(:not_found | {:ok, Store.artifact()} | {:error, term()}) ::
          {:ok, :not_found | :existing} | {:error, term()}
  defp initial_state(:not_found), do: {:ok, :not_found}
  defp initial_state({:ok, _artifact}), do: {:ok, :existing}
  defp initial_state({:error, _reason} = error), do: error

  @spec compare_receipts(Store.receipt(), Store.receipt()) :: :ok | {:error, term()}
  defp compare_receipts(receipt, receipt), do: :ok

  defp compare_receipts(_first, _second),
    do: {:error, :definition_store_duplicate_changed_receipt}

  @spec verify_artifact(Store.artifact(), Canonical.t(), Manifest.t(), Store.receipt()) ::
          :ok | {:error, term()}
  defp verify_artifact(artifact, canonical, manifest, receipt) do
    if artifact == %{definition: canonical, manifest: manifest, receipt: receipt},
      do: :ok,
      else: {:error, :definition_store_readback_mismatch}
  end
end
