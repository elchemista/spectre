defmodule Spectre.Instance.Checkpoint do
  @moduledoc """
  Portable checkpoints of application Mind state, backed by `Spectre.Store`.

  A checkpoint binds the Domain identity and exact Definition revision, but
  deliberately contains no Scope, authentication, process identity, Grant or
  execution status. Restoring an Instance still requires a separately supplied,
  currently authenticated Scope. Checkpoints cannot undo Acts, reset Meter,
  forget an Attempt or close a Duty. Store revisions fence competing checkpoint
  writers; `state_revision` is only the Mind's local state counter.
  """

  alias Spectre.{Portable, Store}

  @doc "Saves one exact application-state snapshot with optimistic concurrency."
  @spec save(Store.config(), String.t(), non_neg_integer(), String.t(), String.t(), map()) ::
          {:ok, pos_integer()} | {:error, term()}
  def save(store, key, expected, domain_ref, definition_ref, state) do
    with {:ok, %{revision: revision, value: value}} <-
           Portable.normalize_attrs(state, [:revision, :value], :instance_checkpoint),
         :ok <- bindings(domain_ref, definition_ref, revision) do
      Store.compare_and_swap(store, key, expected, %{
        "format" => "spectre-mind-checkpoint-v1",
        "domain_ref" => domain_ref,
        "definition_ref" => definition_ref,
        "state_revision" => revision,
        "value" => value
      })
    else
      {:ok, _} -> {:error, :invalid_instance_checkpoint}
      {:error, _} = error -> error
    end
  end

  @doc "Restores only application data for the explicitly selected Domain and Definition."
  @spec load(Store.config(), String.t(), String.t(), String.t()) ::
          {:ok, %{revision: non_neg_integer(), value: term()}} | {:error, term()}
  def load(store, key, domain_ref, definition_ref) do
    case Store.get(store, key) do
      {:ok, _store_revision, value} -> restore(value, domain_ref, definition_ref)
      :not_found -> {:error, :instance_checkpoint_not_found}
      {:deleted, _revision} -> {:error, :instance_checkpoint_not_found}
      {:error, _} = error -> error
    end
  end

  defp restore(
         %{
           "format" => "spectre-mind-checkpoint-v1",
           "domain_ref" => domain,
           "definition_ref" => definition,
           "state_revision" => revision,
           "value" => value
         } = record,
         domain,
         definition
       )
       when map_size(record) == 5 do
    with :ok <- bindings(domain, definition, revision),
         do: {:ok, %{revision: revision, value: value}}
  end

  defp restore(_value, _domain, _definition), do: {:error, :instance_checkpoint_binding_mismatch}

  defp bindings(domain, definition, revision) do
    with :ok <- Portable.validate_ref(domain, :domain_ref),
         :ok <- Portable.validate_content_ref(definition, :definition, :definition_ref) do
      if is_integer(revision) and revision >= 0,
        do: :ok,
        else: {:error, :invalid_checkpoint_state_revision}
    end
  end
end
