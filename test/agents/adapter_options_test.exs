defmodule Spectre.Agents.AdapterOptionsTest do
  use ExUnit.Case, async: true

  alias Spectre.Adapter.Options
  alias Spectre.Agent.{RequestBuilder, Wiring}

  defmodule Request do
    @behaviour Spectre.Adapter.Options
    @behaviour Spectre.Agent.RequestBuilder
    @impl true
    def prepare(operation, data, turn, opts),
      do: RequestBuilder.prepare(operation, data, turn, opts)

    @impl true
    def validate_options(opts) do
      send(opts[:observer], {:validated, opts})

      case opts[:action] do
        :raise -> raise "PRIVATE CREDENTIAL"
        :exit -> exit("PRIVATE CREDENTIAL")
        :throw -> throw("PRIVATE CREDENTIAL")
        _normal -> Keyword.get(opts, :reply, :ok)
      end
    end
  end

  defmodule Legacy do
    def prepare(_, _, _, _), do: raise("not invoked by wiring")
    def validate_options(_opts), do: raise("a coincidental callback is not opt-in")
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "options-test", name: "assistant"
    adapter(:request, :writer, Request, format: :plain)
  end

  defmodule OldAssistant do
    use Spectre.Agent, namespace: "options-test", name: "legacy"
    adapter(:request, :writer, Legacy)
  end

  defmodule Shared do
    use Spectre.Agent, namespace: "options-test", name: "shared"
    adapter(:request, :writer, Request, format: :plain)
    classifier(:intent, class: "model.classify", via: :writer)

    flow :support do
      router(via: [:llm_classifier], classifier: :intent)
      route(:hello, classify: true)
    end
  end

  defmodule Cache do
    @behaviour Spectre.Adapter.Options
    @behaviour Spectre.Router.SemanticCache
    @impl true
    def validate_options(opts) do
      send(opts[:recipient], {:cache_validated, opts})
      :ok
    end

    @impl true
    def info(_opts), do: raise("validation must not query a backend")
    @impl true
    def lookup(_, _, _), do: raise("validation must not look up routes")
  end

  defmodule WithCache do
    use Spectre.Agent, namespace: "options-test", name: "cached"
    adapter(:semantic_cache, :routing, Cache, max_entries: 2_000)
  end

  defmodule History do
    @behaviour Spectre.Adapter.Options
    @behaviour Spectre.History
    @impl true
    def validate_options(opts) do
      send(opts[:recipient], {:history_validated, opts})

      if Keyword.keys(opts) |> Enum.sort() == [:recipient, :repo],
        do: :ok,
        else: {:error, :invalid_options}
    end

    @impl true
    def load(binding, _window, opts) do
      send(opts[:recipient], {:history_loaded, opts})
      {:ok, %{binding: binding, messages: [], cursor: nil, truncated?: false}}
    end

    @impl true
    def append(_, _, _), do: raise("not a validation operation")
    @impl true
    def record_delivery(_, _, _), do: raise("not a validation operation")
  end

  defmodule WithHistory do
    use Spectre.Agent, namespace: "options-test", name: "chat"
    history(:chat, keep: 4)
    adapter(:history, :chat, History, repo: __MODULE__)
  end

  test "merged static/host options are checked once, without normalization or execution" do
    opts = [observer: self()]
    assert {:ok, wiring} = Wiring.resolve(Assistant, request: [writer: opts])
    assert_receive {:validated, validated}
    assert validated == [format: :plain, observer: self()]
    assert wiring.ports["request/writer"] == {Request, validated}
    refute_receive {:validated, _}

    assert {:error, {:invalid_port, "request/writer", :semantic_port_options_overridden}} =
             Wiring.resolve(Assistant, request: [writer: [format: :html, observer: self()]])

    refute_receive {:validated, _}
    assert {:ok, _} = Wiring.resolve(OldAssistant, request: [writer: [anything: :host_owned]])
  end

  test "a classifier alias reuses its target's checked options without invoking it twice" do
    assert {:ok, wiring} = Wiring.resolve(Shared, request: [writer: [observer: self()]])
    assert_receive {:validated, opts}
    assert wiring.ports["request/writer"] === {Request, opts}
    assert wiring.ports["classifier/intent"] === {Request, opts}
    refute_receive {:validated, _}

    assert {:error, {:aliased_port_override, "classifier/intent"}} =
             Wiring.resolve(Shared,
               request: [writer: [observer: self()]],
               classifier: [intent: Request]
             )
  end

  test "cache binding is separated from backend options without info or lookup I/O" do
    opts = [
      namespace: "tenant:cache",
      profile_ref: "encoder:one",
      server: :not_started,
      recipient: self()
    ]

    assert {:ok, wiring} = Wiring.resolve(WithCache, semantic_cache: [routing: opts])
    assert_receive {:cache_validated, validated}
    assert validated == [max_entries: 2_000, server: :not_started, recipient: self()]
    {Cache, configured} = wiring.ports["semantic_cache/routing"]
    {binding, backend} = Wiring.split_options(:semantic_cache, configured)
    assert binding == [namespace: "tenant:cache", profile_ref: "encoder:one"]
    assert backend === validated

    assert {:error, {:invalid_port, "semantic_cache/routing", _}} =
             Wiring.resolve(WithCache,
               semantic_cache: [routing: Keyword.put(opts, :namespace, nil)]
             )

    refute_receive {:cache_validated, _}
  end

  test "callback errors are explicit and malformed or sensitive reasons cannot leak" do
    for {reply, expected} <- [
          {{:error, {:missing_option, :repo}}, {:missing_option, :repo}},
          {{:error, {:invalid_option, :timeout}}, {:invalid_option, :timeout}},
          {{:error, {:unknown_options, [:typo]}}, {:unknown_options, [:typo]}},
          {{:error, "PRIVATE CREDENTIAL"}, :invalid_options},
          {{:error, {:invalid_option, "PRIVATE CREDENTIAL"}}, :invalid_options},
          {{:error, {:unknown_options, ["PRIVATE CREDENTIAL"]}}, :invalid_options},
          {{:ok, "PRIVATE CREDENTIAL"}, :invalid_validator_reply},
          {false, :invalid_validator_reply}
        ] do
      assert {:error, {:invalid_port, "request/writer", ^expected}} =
               Wiring.resolve(Assistant, request: [writer: [observer: self(), reply: reply]])
    end

    for action <- [:raise, :exit, :throw] do
      assert {:error, {:invalid_port, "request/writer", reason}} =
               Wiring.resolve(Assistant, request: [writer: [observer: self(), action: action]])

      refute inspect(reason) =~ "PRIVATE"
    end
  end

  test "the default request adapter has no host options, including injected declarations" do
    assert :ok = Options.validate(RequestBuilder, [])
    assert {:error, {:unknown_options, [:timeout]}} = Options.validate(RequestBuilder, timeout: 1)
    assert {:error, :invalid_options} = Options.validate(RequestBuilder, [:invalid])
    assert {:error, _} = Options.validate(:missing_options_adapter, [])
  end

  test "history validation sees exactly callback options, not tenant or observer bindings" do
    opts = [tenant_id: "tenant:a", conversation_id: "chat:1", recipient: self(), observer: nil]
    assert {:ok, wiring} = Wiring.resolve(WithHistory, history: [chat: opts])
    assert_receive {:history_validated, checked}
    assert checked == [repo: WithHistory, recipient: self()]

    {module, configured} = wiring.ports["history/chat"]
    {binding, backend} = Wiring.split_options(:history, configured)
    assert {:ok, history} = Spectre.History.bind({module, backend}, binding)
    assert {:ok, %{messages: []}} = Spectre.History.load(history)
    assert_receive {:history_loaded, received}
    assert received === checked
    refute_receive {:history_validated, _}

    assert {:error, {:invalid_port, "history/chat", _}} =
             Wiring.resolve(WithHistory, history: [chat: Keyword.delete(opts, :tenant_id)])

    refute_receive {:history_validated, _}
  end
end
