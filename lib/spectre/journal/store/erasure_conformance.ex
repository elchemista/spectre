defmodule Spectre.Journal.Store.ErasureConformance do
  @moduledoc """
  Executable conformance gate for exact-Ref Journal erasure.

  The runner appends records for a target and a derived neighboring Instance,
  erases the target twice, then erases the neighbor. This proves observable
  idempotency and rejects adapters that erase a broader namespace. It has no
  ExUnit dependency and must run against a fresh, isolated Instance Ref.
  """

  alias Spectre.Instance.Ref
  alias Spectre.Journal.Record
  alias Spectre.Journal.Store

  @contract_version 1

  @type report :: %{
          required(:contract_version) => pos_integer(),
          required(:append) => :verified,
          required(:idempotency) => :verified,
          required(:neighbor_isolation) => :verified
        }

  @doc "Returns the Journal erasure contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Runs the exact-Ref erasure contract using a fresh Instance Ref."
  @spec run(Store.config(), Ref.t()) :: {:ok, report()} | {:error, term()}
  def run(store, %Ref{} = ref) do
    neighbor_ref = Ref.new(ref.agent_ref, {:journal_erasure_neighbor, ref.key})

    with {:ok, store} <- normalize_store(store),
         :ok <- capability(store),
         :ok <- append(store, fixture(ref, "target"), :append_target),
         :ok <- append(store, fixture(neighbor_ref, "neighbor"), :append_neighbor),
         :ok <- erase(store, ref, :erased, :target_erasure),
         :ok <- erase(store, ref, :already_erased, :idempotency),
         :ok <- erase(store, neighbor_ref, :erased, :neighbor_isolation) do
      {:ok,
       %{
         contract_version: @contract_version,
         append: :verified,
         idempotency: :verified,
         neighbor_isolation: :verified
       }}
    end
  end

  def run(_store, _ref), do: failure(:arguments, :invalid_ref)

  defp normalize_store(store) do
    case Store.normalize(store) do
      {:ok, {module, opts} = normalized} when is_atom(module) and is_list(opts) ->
        {:ok, normalized}

      _invalid ->
        failure(:configuration, :invalid_store)
    end
  end

  defp capability(store) do
    case Store.erasure_capability(store) do
      :ok -> :ok
      {:error, _reason} -> failure(:configuration, :erasure_unsupported)
    end
  end

  defp append({module, opts}, record, phase) do
    result =
      try do
        module.append(record, opts)
      rescue
        _exception -> :callback_failure
      catch
        _kind, _reason -> :callback_failure
      end

    case result do
      :ok -> :ok
      {:ok, _value} -> :ok
      _other -> failure(phase, :append_rejected)
    end
  end

  defp erase(store, ref, expected, phase) do
    case Store.erase_instance(store, ref, []) do
      {:ok, ^expected} -> :ok
      _other -> failure(phase, :unexpected_outcome)
    end
  end

  defp fixture(ref, label) do
    Record.new(%{
      agent: ref.agent_ref.definition,
      agent_version: ref.agent_ref.version,
      conversation_id: ref.key,
      turn_id: "journal-erasure-conformance:#{label}:#{ref.key}",
      trace_id: "journal-erasure-conformance:#{ref.key}",
      sequence: 1,
      phase: :lifecycle,
      decision: %{kind: :journal_erasure_conformance},
      reason: %{code: label},
      occurred_at: ~U[2000-01-01 00:00:00Z]
    })
  end

  defp failure(phase, code),
    do: {:error, {:journal_store_erasure_conformance_failed, phase, code}}
end
