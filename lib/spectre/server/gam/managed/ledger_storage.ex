defmodule Spectre.Server.GAM.Managed.LedgerStorage do
  @moduledoc false
  alias Spectre.GAM.{Adapter, Ledger}
  alias Spectre.Server.Store.Port

  # Keep the foundation's issuance time with the coordination journal. It is
  # immutable configuration, not a projection or a replacement for the ledger.
  def open(selection, journal, domain, digest) when not is_nil(journal) do
    with {:ok, %{ledger: selected, projection: projection}} <- select(selection, journal),
         {:ok, projection} <- Spectre.GAM.Domain.Projection.Store.normalize(projection),
         {:ok, {module, opts} = store} <- Ledger.Store.normalize(selected),
         :ok <- Adapter.validate(module, append: 5, load: 2, head: 2),
         key = {:managed_authority, domain},
         {:ok, entry} <- profile(journal, key, digest, domain),
         :ok <- history(store, domain, entry.value.ready) do
      {:ok,
       %{
         domain: domain,
         issued_at: entry.value.issued_at,
         digest: digest,
         ledger: nil,
         store: {module, opts},
         projection_store: projection,
         journal: journal,
         owned: [],
         ephemeral: false,
         authority_profile: {key, entry}
       }}
    end
  end

  def open(_, nil, _, _), do: {:error, :managed_ledger_requires_coordination_store}

  def ready(%{authority_profile: {key, %{value: %{ready: false}} = entry}} = host) do
    value = %{entry.value | ready: true}

    case Port.compare_and_swap(host.journal, key, entry.revision, value) do
      {:ok, _} -> :ok
      {:error, :conflict} -> ready_conflict(host.journal, key, value)
      error -> error
    end
  end

  def ready(_host), do: :ok

  defp ready_conflict(journal, key, value) do
    case Port.fetch(journal, key) do
      {:ok, %{value: ^value}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :managed_authority_configuration_changed}
    end
  end

  defp select({:ledger, store}, _journal), do: {:ok, %{ledger: store, projection: nil}}

  defp select(:ledger, {module, ref}) do
    if function_exported?(module, :gam_domain, 1) do
      case Adapter.invoke(module, :gam_domain, [ref]) do
        {:ok, {:ok, %{ledger: _, projection: _} = storage}} -> {:ok, storage}
        {:ok, :not_configured} -> select_ledger(module, ref)
        {:ok, {:error, _} = error} -> error
        {:error, _} = error -> error
        _ -> {:error, :managed_gam_domain_unavailable}
      end
    else
      select_ledger(module, ref)
    end
  end

  defp select_ledger(module, ref) do
    with true <- function_exported?(module, :gam_ledger, 1),
         {:ok, result} <- Adapter.invoke(module, :gam_ledger, [ref]) do
      case result do
        {:ok, ledger} -> {:ok, %{ledger: ledger, projection: nil}}
        {:error, _} = error -> error
        _ -> {:error, :managed_gam_ledger_unavailable}
      end
    else
      false -> {:error, :managed_gam_ledger_unavailable}
      error -> error
    end
  end

  defp profile(journal, key, digest, domain) do
    case Port.fetch(journal, key) do
      :not_found ->
        with :ok <- fresh_checkpoint(journal, domain) do
          create_profile(journal, key, digest)
        end

      entry ->
        validate_profile(entry, digest)
    end
  end

  defp create_profile(journal, key, digest) do
    value = %{digest: digest, issued_at: System.system_time(:millisecond), ready: false}

    case Port.put_new(journal, key, value) do
      {:ok, revision} -> {:ok, %{revision: revision, value: value}}
      {:error, :exists} -> existing_profile(journal, key, digest)
      error -> error
    end
  end

  defp fresh_checkpoint(journal, domain) do
    case Port.fetch(journal, {:managed_agent, domain}) do
      :not_found -> :ok
      {:ok, _} -> {:error, :managed_authority_migration_required}
      error -> error
    end
  end

  defp existing_profile(journal, key, digest),
    do: validate_profile(Port.fetch(journal, key), digest)

  defp validate_profile(
         {:ok, %{value: %{digest: digest, issued_at: time, ready: ready}}} = entry,
         digest
       )
       when is_integer(time) and time > 0 and is_boolean(ready),
       do: entry

  defp validate_profile({:error, _} = error, _), do: error
  defp validate_profile(_, _), do: {:error, :managed_authority_configuration_changed}

  # Never recreate authority from an empty backend after a completed bootstrap.
  defp history(store, domain, true) do
    case Ledger.Store.head(store, domain) do
      {:ok, _} -> :ok
      :not_found -> {:error, :managed_authority_history_missing}
      error -> error
    end
  end

  defp history(_store, _domain, false), do: :ok
end
