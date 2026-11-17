defmodule Spectre.Server.Store.Ledger do
  @moduledoc false
  @behaviour Spectre.GAM.Ledger.Store
  alias Spectre.GAM.Ledger

  # Translates the kernel port to the host's single Server.Store behaviour.
  # The kernel facade remains responsible for guarded calls and verification.
  @impl true
  @spec append(Ledger.domain_ref(), Ledger.batch_id(), [map()], non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def append(domain, batch, payloads, revision, opts),
    do: invoke(opts, :ledger_append, [domain, batch, payloads, revision])

  @impl true
  @spec load(Ledger.domain_ref(), keyword()) ::
          :not_found | {:ok, Ledger.snapshot()} | {:error, term()}
  def load(domain, opts), do: invoke(opts, :ledger_load, [domain])

  @impl true
  @spec load_from(Ledger.domain_ref(), non_neg_integer(), keyword()) ::
          :not_found | {:ok, Ledger.snapshot()} | {:error, term()}
  def load_from(domain, revision, opts) do
    {module, _reference} = Keyword.fetch!(opts, :store)

    if function_exported?(module, :ledger_load_from, 4) do
      invoke(opts, :ledger_load_from, [domain, revision])
    else
      with {:ok, snapshot} <- Ledger.load({__MODULE__, opts}, domain) do
        {:ok, %{snapshot | entries: Enum.drop(snapshot.entries, revision)}}
      end
    end
  end

  @impl true
  @spec head(Ledger.domain_ref(), keyword()) ::
          :not_found | {:ok, Ledger.cursor()} | {:error, term()}
  def head(domain, opts), do: invoke(opts, :ledger_head, [domain])

  @impl true
  @spec read_batch(Ledger.domain_ref(), pos_integer(), keyword()) ::
          :not_found | {:ok, Ledger.snapshot()} | {:error, term()}
  def read_batch(domain, revision, opts), do: invoke(opts, :ledger_read_batch, [domain, revision])

  @impl true
  @spec lookup_batch(Ledger.domain_ref(), Ledger.batch_id(), keyword()) ::
          :not_found | {:ok, Ledger.batch_info()} | {:error, term()}
  def lookup_batch(domain, batch, opts), do: invoke(opts, :ledger_lookup_batch, [domain, batch])

  @impl true
  @spec export(Ledger.domain_ref(), keyword()) ::
          :not_found | {:ok, map()} | {:error, term()}
  def export(domain, opts), do: invoke(opts, :ledger_export, [domain])

  defp invoke(opts, callback, args) do
    {{module, reference}, opts} = Keyword.pop!(opts, :store)
    apply(module, callback, [reference | args] ++ [opts])
  end
end
