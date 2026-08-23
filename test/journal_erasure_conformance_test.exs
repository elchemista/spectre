defmodule SpectreJournalErasureConformanceTest.Store do
  @moduledoc false

  @behaviour Spectre.Journal.Store

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end)

  @impl true
  def append(record, opts) do
    case Keyword.get(opts, :append_reply, :ok) do
      :raise -> raise "journal conformance append failed"
      :throw -> throw(:journal_conformance_append_failed)
      {:fail_conversation, id} when id == record.conversation_id -> {:error, :offline}
      {:fail_conversation, _id} -> store(record, opts, :ok)
      reply when reply in [:ok, {:ok, :stored}] -> store(record, opts, reply)
      reply -> reply
    end
  end

  @impl true
  def erase_instance(ref, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :server), fn records ->
      present? = Map.has_key?(records, ref.key)
      expected = if present?, do: :erased, else: :already_erased

      case Keyword.get(opts, :erase_mode, :exact) do
        :exact -> {{:ok, expected}, Map.delete(records, ref.key)}
        :broad -> {{:ok, expected}, %{}}
        :non_idempotent -> {{:ok, :erased}, Map.delete(records, ref.key)}
        :error -> {{:error, :offline}, records}
      end
    end)
  end

  defp store(record, opts, reply) do
    Agent.update(Keyword.fetch!(opts, :server), fn records ->
      Map.update(records, record.conversation_id, MapSet.new([record.id]), fn ids ->
        MapSet.put(ids, record.id)
      end)
    end)

    reply
  end
end

defmodule SpectreJournalErasureConformanceTest.UnsupportedStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store
  @impl true
  def append(_record, _opts), do: :ok
end

defmodule SpectreJournalErasureConformanceTest.AgentDefinition do
  @moduledoc false
  use Spectre.Agent, id: :journal_erasure_conformance_agent
end

defmodule SpectreJournalErasureConformanceTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Ref
  alias Spectre.Journal.Store.ErasureConformance

  alias SpectreJournalErasureConformanceTest.AgentDefinition
  alias SpectreJournalErasureConformanceTest.Store
  alias SpectreJournalErasureConformanceTest.UnsupportedStore

  test "proves idempotency and neighboring-Ref isolation" do
    store = start_store(:exact)
    ref = fresh_ref("exact")

    assert ErasureConformance.contract_version() == 1

    assert {:ok,
            %{
              contract_version: 1,
              append: :verified,
              idempotency: :verified,
              neighbor_isolation: :verified
            }} = ErasureConformance.run({Store, server: store}, ref)

    acknowledged = start_store(:acknowledged)

    assert {:ok, %{neighbor_isolation: :verified}} =
             ErasureConformance.run(
               {Store, server: acknowledged, append_reply: {:ok, :stored}},
               fresh_ref("acknowledged")
             )
  end

  test "rejects broad deletion and false idempotency" do
    broad = start_store(:broad)

    assert ErasureConformance.run(
             {Store, server: broad, erase_mode: :broad},
             fresh_ref("broad")
           ) == failure(:neighbor_isolation, :unexpected_outcome)

    non_idempotent = start_store(:non_idempotent)

    assert ErasureConformance.run(
             {Store, server: non_idempotent, erase_mode: :non_idempotent},
             fresh_ref("non-idempotent")
           ) == failure(:idempotency, :unexpected_outcome)
  end

  test "contains configuration, append, and erase failures by phase" do
    ref = fresh_ref("failures")

    assert ErasureConformance.run(nil, ref) == failure(:configuration, :invalid_store)
    assert ErasureConformance.run({false, []}, ref) == failure(:configuration, :invalid_store)

    assert ErasureConformance.run(UnsupportedStore, ref) ==
             failure(:configuration, :erasure_unsupported)

    assert ErasureConformance.run(Store, :invalid) == failure(:arguments, :invalid_ref)

    for reply <- [:invalid, {:error, :offline}, :raise, :throw] do
      store = start_store({:append_failure, reply})

      assert ErasureConformance.run({Store, server: store, append_reply: reply}, ref) ==
               failure(:append_target, :append_rejected)
    end

    neighbor_ref = Ref.new(ref.agent_ref, {:journal_erasure_neighbor, ref.key})
    neighbor_failure = start_store(:neighbor_append_failure)

    assert ErasureConformance.run(
             {Store,
              server: neighbor_failure, append_reply: {:fail_conversation, neighbor_ref.key}},
             ref
           ) == failure(:append_neighbor, :append_rejected)

    erase_failure = start_store(:erase_failure)

    assert ErasureConformance.run(
             {Store, server: erase_failure, erase_mode: :error},
             ref
           ) == failure(:target_erasure, :unexpected_outcome)
  end

  defp fresh_ref(label) do
    Ref.new(AgentDefinition, "journal-erasure-#{label}-#{System.unique_integer([:positive])}")
  end

  defp start_store(id) do
    start_supervised!(Supervisor.child_spec({Store, []}, id: {Store, id}))
  end

  defp failure(phase, code),
    do: {:error, {:journal_store_erasure_conformance_failed, phase, code}}
end
