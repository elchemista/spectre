defmodule Spectre.Governance.GC.InventoryProvider do
  @moduledoc "Trusted host contract for a fenced, complete GC inventory snapshot."

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Store
  alias Spectre.Governance.Data

  @fields ~w(
    snapshot_id revision fencing_token candidate_refs definition_refs
    protected_candidate_refs protected_definition_refs
  )

  @type config :: module() | {module(), keyword()}

  @callback snapshot(Store.config(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec load(config(), Store.config(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(config, store, opts) do
    with {:ok, module, provider_opts} <- normalize(config),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :snapshot, 2),
         {:ok, snapshot} <- invoke(module, store, Keyword.merge(provider_opts, opts)),
         {:ok, normalized} <- Data.normalize(snapshot),
         :ok <- validate(normalized) do
      {:ok, Map.put(normalized, "digest", Value.digest!(normalized))}
    else
      false -> {:error, :governance_gc_inventory_provider_not_loaded}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, module, []}

  defp normalize({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, module, opts},
      else: {:error, :invalid_governance_gc_inventory_provider}
  end

  defp normalize(_value), do: {:error, :governance_gc_inventory_provider_required}

  defp invoke(module, store, opts) do
    case module.snapshot(store, opts) do
      {:ok, snapshot} when is_map(snapshot) and not is_struct(snapshot) -> {:ok, snapshot}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_gc_inventory_reply, module, value}}
    end
  rescue
    exception -> {:error, {:governance_gc_inventory_exception, module, exception.__struct__}}
  catch
    kind, reason -> {:error, {:governance_gc_inventory_failure, module, kind, reason}}
  end

  defp validate(snapshot) do
    with :ok <- exact_fields(snapshot),
         :ok <- nonempty_snapshot_id(snapshot["snapshot_id"]),
         :ok <- non_negative_revision(snapshot["revision"]),
         :ok <- positive_fencing_token(snapshot["fencing_token"]) do
      validate_ref_lists(snapshot)
    end
  end

  defp exact_fields(snapshot) do
    if Map.keys(snapshot) |> Enum.sort() == Enum.sort(@fields),
      do: :ok,
      else: {:error, :invalid_governance_gc_inventory_fields}
  end

  defp nonempty_snapshot_id(value) when is_binary(value) and value != "", do: :ok
  defp nonempty_snapshot_id(_value), do: {:error, :invalid_governance_gc_inventory_snapshot_id}

  defp non_negative_revision(value) when is_integer(value) and value >= 0, do: :ok
  defp non_negative_revision(_value), do: {:error, :invalid_governance_gc_inventory_revision}

  defp positive_fencing_token(value) when is_integer(value) and value > 0, do: :ok

  defp positive_fencing_token(_value),
    do: {:error, :invalid_governance_gc_inventory_fencing_token}

  defp validate_ref_lists(snapshot) do
    if Enum.all?(list_fields(), &ref_list?(snapshot[&1])),
      do: :ok,
      else: {:error, :invalid_governance_gc_inventory_refs}
  end

  defp list_fields,
    do: ~w(candidate_refs definition_refs protected_candidate_refs protected_definition_refs)

  defp ref_list?(values) when is_list(values),
    do: values == Enum.sort(Enum.uniq(values)) and Enum.all?(values, &is_binary/1)

  defp ref_list?(_values), do: false
end
