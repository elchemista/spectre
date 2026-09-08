defmodule Spectre.Agents.ContextContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Agent.Context
  alias Spectre.{History, Memory}

  # These adapters intentionally return hostile replies. The tests exercise
  # Spectre's boundary, not a made-up database's persistence guarantees.
  defmodule HistoryBackend do
    @behaviour Spectre.History

    @impl true
    def load(binding, window, opts) do
      send(opts[:test_pid], {:history_load, binding, window})
      opts[:page]
    end

    @impl true
    def append(_binding, message, opts), do: {:ok, Keyword.get(opts, :saved, message)}

    @impl true
    def record_delivery(_binding, receipt, opts) do
      send(opts[:test_pid], {:delivery, receipt})
      opts[:delivery]
    end

    @impl true
    def load_summary(_binding, opts), do: opts[:summary]

    @impl true
    def save_summary(binding, summary, expected, opts) do
      send(opts[:test_pid], {:summary_save, expected})
      Keyword.get(opts, :saved_summary, {:ok, %{binding: binding, summary: summary}})
    end

    @impl true
    def erase(binding, selector, opts) do
      send(opts[:test_pid], {:erase, binding, selector})
      :ok
    end
  end

  defmodule Retrieval do
    @behaviour Spectre.Memory

    @impl true
    def retrieve(binding, query, opts) do
      send(opts[:observer], {:retrieval, binding, query})
      opts[:reply]
    end
  end

  setup do
    binding = %{tenant_id: "shop:eu", conversation_id: "conversation:order-2041"}

    message = %{
      ref: "message:customer-1",
      revision: 0,
      role: :user,
      status: :received,
      content:
        "My order ORD-2041 arrived damaged. Can I return it rather than get a replacement?",
      evidence_refs: ["evidence:received-customer-1"]
    }

    item = %{
      ref: "memory:return-policy",
      source_ref: "document:returns-eu-2026",
      content: "Damaged deliveries can be returned. Do not promise a refund before approval.",
      evidence_refs: ["evidence:returns-policy"]
    }

    %{binding: binding, message: message, item: item}
  end

  test "history forwards count, byte and cursor limits with exact tenant binding", c do
    page = %{binding: c.binding, messages: [c.message], cursor: "page:2", truncated?: true}
    history = bind(c, page: {:ok, page})
    assert {:ok, ^page} = History.load(history, keep: 2, max_bytes: 2048, before: "message:last")
    assert_receive {:history_load, binding, %{keep: 2, max_bytes: 2048, before: "message:last"}}
    assert binding == c.binding
    assert History.binding(history) == c.binding
  end

  test "foreign history, overflow and duplicate message identities are rejected", c do
    page = %{binding: c.binding, messages: [c.message], cursor: nil, truncated?: false}

    for invalid <- [
          %{page | binding: %{c.binding | tenant_id: "shop:other"}},
          %{page | binding: %{c.binding | conversation_id: "conversation:other"}},
          %{page | messages: [c.message, c.message]},
          %{page | messages: [%{c.message | revision: 0.0}]},
          %{page | messages: [%{c.message | status: :succeeded}]},
          %{page | messages: [%{c.message | content: <<255>>}]},
          %{page | truncated?: nil}
        ] do
      assert {:error, _} = History.load(bind(c, page: {:ok, invalid}), keep: 2)
    end

    oversized = %{page | messages: [c.message, %{c.message | ref: "message:2"}]}
    assert {:error, _} = History.load(bind(c, page: {:ok, oversized}), keep: 1)
    assert {:error, _} = History.load(bind(c, page: {:ok, page}), max_bytes: 32)
  end

  test "invalid history windows fail before touching the adapter", c do
    history = bind(c)

    for window <- [[keep: 0], [keep: 1.0], [max_bytes: 0], [max_bytes: 1_048_577], [before: 42]] do
      assert {:error, _} = History.load(history, window)
    end

    refute_received {:history_load, _, _}
  end

  test "an append receipt cannot relabel a draft as delivered or rewrite its content", c do
    draft = %{c.message | role: :assistant, status: :draft}
    assert {:ok, ^draft} = History.append(bind(c), draft)

    for saved <- [%{draft | status: :delivered}, %{draft | content: "Refund completed."}] do
      assert {:error, :history_append_receipt_mismatch} =
               History.append(bind(c, saved: saved), draft)
    end
  end

  test "delivery requires Evidence and an exact successor revision", c do
    receipt = %{
      ref: "delivery:42",
      message_ref: c.message.ref,
      expected_revision: 0,
      status: :delivered,
      evidence_refs: ["evidence:delivery-42"]
    }

    saved = %{
      c.message
      | revision: 1,
        role: :assistant,
        status: :delivered,
        evidence_refs: receipt.evidence_refs
    }

    assert {:ok, ^saved} = History.record_delivery(bind(c, delivery: {:ok, saved}), receipt)

    for invalid <- [
          %{saved | revision: 1.0},
          %{saved | status: :draft},
          %{saved | evidence_refs: []}
        ] do
      assert {:error, _} = History.record_delivery(bind(c, delivery: {:ok, invalid}), receipt)
    end

    assert {:error, _} = History.record_delivery(bind(c), %{receipt | evidence_refs: []})
  end

  test "summary CAS receipts cannot cross conversations or ignore the requested revision", c do
    summary = %{
      ref: "summary:order-2041",
      revision: 1,
      content: "Customer requests a return, not replacement.",
      evidence_refs: c.message.evidence_refs
    }

    assert {:ok, ^summary} = History.save_summary(bind(c), summary, 0)
    assert_receive {:summary_save, 0}
    assert {:error, :history_summary_receipt_mismatch} = History.save_summary(bind(c), summary, 1)
    assert :not_found = History.load_summary(bind(c, summary: :not_found))

    foreign = %{binding: %{c.binding | conversation_id: "conversation:other"}, summary: summary}

    assert {:error, :history_summary_binding_mismatch} =
             History.load_summary(bind(c, summary: {:ok, foreign}))
  end

  test "erasure requires an explicit selection and stays bound to the chat store", c do
    history = bind(c)
    assert {:error, :explicit_history_erasure_selector_required} = History.erase(history, %{})
    refute_received {:erase, _, _}
    selector = %{message_refs: [c.message.ref]}
    assert :ok = History.erase(history, selector)
    assert_receive {:erase, binding, ^selector}
    assert binding == c.binding
  end

  test "memory forwards query limits and preserves source attribution", c do
    binding = Map.take(c.binding, [:tenant_id])
    query = "What is the return policy for damaged deliveries?"
    adapter = {Retrieval, observer: self(), reply: {:ok, %{binding: binding, items: [c.item]}}}
    assert {:ok, [item]} = Memory.retrieve(adapter, binding, query, limit: 2, max_bytes: 2048)
    assert item == c.item
    assert_receive {:retrieval, ^binding, %{query: ^query, limit: 2, max_bytes: 2048}}
  end

  test "memory rejects cross-tenant, malformed and oversized replies", c do
    binding = Map.take(c.binding, [:tenant_id])

    for reply <- [
          {:ok, %{binding: %{tenant_id: "shop:other"}, items: [c.item]}},
          {:ok, %{binding: binding, items: [c.item, c.item]}},
          {:ok, %{binding: binding, items: [Map.delete(c.item, :source_ref)]}},
          {:ok, %{binding: binding, items: [%{c.item | content: <<255>>}]}},
          {:ok,
           %{binding: binding, items: [%{c.item | content: String.duplicate("private", 1000)}]}},
          :unrecognized
        ] do
      assert {:error, _} =
               Memory.retrieve({Retrieval, observer: self(), reply: reply}, binding, "returns",
                 limit: 1,
                 max_bytes: 1024
               )
    end
  end

  test "memory returns adapter failures without hiding them behind empty results", c do
    binding = Map.take(c.binding, [:tenant_id])

    assert {:error, :unavailable} =
             Memory.retrieve(
               {Retrieval, observer: self(), reply: {:error, :unavailable}},
               binding,
               "returns"
             )

    assert {:error, _} =
             Memory.retrieve({Retrieval, observer: self()}, binding, "returns", limit: 0)
  end

  test "invalid memory adapter handles return errors rather than crashing the caller", c do
    for adapter <- [nil, Retrieval, {Retrieval, :invalid}, {Retrieval, [], :extra}] do
      assert {:error, _} = Memory.retrieve(adapter, Map.take(c.binding, [:tenant_id]), "returns")
    end
  end

  test "agent context composes explicitly wired history and memory windows", c do
    owner = context_owner(%{
      "history/chat" => %{keep: 2, max_bytes: 2048},
      "memory/policy" => %{limit: 2, max_bytes: 2048},
      "prompt/ignored" => %{max_bytes: 2048}
    })

    page = %{binding: c.binding, messages: [c.message], cursor: nil, truncated?: false}
    memory_binding = Map.take(c.binding, [:tenant_id])

    wiring = %{
      ports: %{
        "history/chat" =>
          {HistoryBackend,
           tenant_id: c.binding.tenant_id,
           conversation_id: c.binding.conversation_id,
           test_pid: self(),
           page: {:ok, page}},
        "memory/policy" =>
          {Retrieval,
           tenant_id: c.binding.tenant_id,
           observer: self(),
           reply: {:ok, %{binding: memory_binding, items: [c.item]}}}
      }
    }

    assert {:ok, %{history: [message], memory: [item]}} =
             Context.load(owner, wiring, "damaged order")

    assert message == c.message
    assert item == c.item
  end

  test "agent context refuses unwired sources and cumulative context overflow", c do
    assert {:error, {:unwired_history, "chat"}} =
             Context.load(context_owner(%{"history/chat" => %{keep: 1}}), %{ports: %{}}, "input")

    assert {:error, {:unwired_memory, "policy"}} =
             Context.load(context_owner(%{"memory/policy" => %{limit: 1}}), %{ports: %{}}, "input")

    huge_message = %{c.message | content: String.duplicate("h", 33_000)}
    huge_item = %{c.item | content: String.duplicate("m", 33_000)}
    page = %{binding: c.binding, messages: [huge_message], cursor: nil, truncated?: false}
    memory_binding = Map.take(c.binding, [:tenant_id])

    wiring = %{
      ports: %{
        "history/chat" =>
          {HistoryBackend,
           tenant_id: c.binding.tenant_id,
           conversation_id: c.binding.conversation_id,
           test_pid: self(),
           page: {:ok, page}},
        "memory/policy" =>
          {Retrieval,
           tenant_id: c.binding.tenant_id,
           observer: self(),
           reply: {:ok, %{binding: memory_binding, items: [huge_item]}}}
      }
    }

    owner =
      context_owner(%{
        "history/chat" => %{keep: 1, max_bytes: 40_000},
        "memory/policy" => %{limit: 1, max_bytes: 40_000}
      })

    assert {:error, :agent_context_budget_exceeded} = Context.load(owner, wiring, "input")
  end

  defp bind(c, opts \\ []) do
    assert {:ok, history} = History.bind({HistoryBackend, [test_pid: self()] ++ opts}, c.binding)
    history
  end

  defp context_owner(settings) do
    %{prefix: "", definition_ref: "definition:context-test", plan: %{settings: settings}}
  end

  test "summary loading validates the payload as strictly as summary writes", c do
    summary = %{
      ref: "summary:latest",
      revision: 1,
      content: "Customer requested a return.",
      evidence_refs: c.message.evidence_refs
    }

    reply = %{binding: c.binding, summary: summary}
    assert {:ok, ^summary} = History.load_summary(bind(c, summary: {:ok, reply}))

    assert {:error, :invalid_history_summary_reply} =
             History.load_summary(bind(c, summary: {:ok, %{}}))

    assert {:error, :invalid_history_summary_reply} =
             History.save_summary(bind(c, saved_summary: {:ok, %{}}), summary, 0)

    assert {:error, :invalid_summary_revision} = History.save_summary(bind(c), summary, 0.0)

    for change <- [%{revision: 0}, %{content: <<255>>}, %{ref: nil}, %{evidence_refs: [42]}] do
      invalid = Map.merge(summary, change)
      assert {:error, _} = History.save_summary(bind(c), invalid, 0)

      assert {:error, _} =
               History.load_summary(bind(c, summary: {:ok, %{reply | summary: invalid}}))
    end
  end

  test "malformed callback replies and missing handles cannot become empty successful history",
       c do
    assert {:error, :invalid_history_adapter} = History.bind(HistoryBackend, c.binding)
    assert {:error, _} = History.bind({String, []}, c.binding)
    assert {:error, _} = History.bind({HistoryBackend, []}, %{c.binding | tenant_id: nil})
    assert {:error, :invalid_history_handle} = History.load(nil)
    assert {:error, {:invalid_history_reply, :load}} = History.load(bind(c, page: :unrecognized))

    assert {:error, :backend_unavailable} =
             History.load(bind(c, page: {:error, :backend_unavailable}))

    assert {:error, _} = History.append(bind(c), %{c.message | evidence_refs: [42]})
    assert {:error, _} = History.append(bind(c, saved: %{}), c.message)
    assert {:error, _} = History.load(bind(c), keep: 10, imaginary: true)
  end
end
