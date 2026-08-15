defmodule SpectreEcosystemIntegrationTest.EcoProvider do
  @moduledoc false
  @behaviour Spectre.Action.Provider

  alias Spectre.Action.Spec

  @impl true
  def actions(_opts), do: [Spec.new(name: :sync_crm, via: :eco, schema: %{version: 1})]

  @impl true
  def execute(action, context, _opts) do
    if pid = Keyword.get(context.opts, :test_pid),
      do: send(pid, {:provider_executed, action.name, action.args})

    {:ok, "crm synced"}
  end

  @impl true
  def schema_hash(_action, _opts), do: nil
end

defmodule SpectreEcosystemIntegrationTest.EcoExtension do
  @moduledoc false

  def id, do: :eco
  def api_version, do: 1
  def compile(_owner, opts), do: {:ok, opts}
  def action_providers(_config), do: [{:eco, SpectreEcosystemIntegrationTest.EcoProvider, []}]
end

defmodule SpectreEcosystemIntegrationTest.Guards do
  @moduledoc false

  def deny_when_locked(_action, ctx) do
    if ctx.state.data[:locked], do: {:suppress, "workspace locked"}, else: :allow
  end
end

defmodule SpectreEcosystemIntegrationTest.Summarizer do
  @moduledoc false

  def fold(current, evicted) do
    evicted
    |> Enum.map(& &1.user)
    |> then(&Enum.join(List.wrap(current) ++ &1, "|"))
  end
end

defmodule SpectreEcosystemIntegrationTest.Renderer do
  @moduledoc false

  def render(prompt, input, _ctx), do: "#{prompt}:#{input.text}"
end

defmodule SpectreEcosystemIntegrationTest.EcoAgent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreEcosystemIntegrationTest.Guards
  alias SpectreEcosystemIntegrationTest.Renderer
  alias SpectreEcosystemIntegrationTest.Summarizer

  Spectre.Extension.register!(__MODULE__, SpectreEcosystemIntegrationTest.EcoExtension)

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  history(2, summary: {Summarizer, :fold})

  before_action(:sync_crm, run: {Guards, :deny_when_locked})

  flow :operations do
    flow :crm do
      on :SYNC, regex: ~r/^sync crm$/i, cache: false do
        action(:sync_crm, via: :eco, args: %{scope: :all})
      end
    end

    on :HELLO, regex: ~r/^hello$/i, cache: false do
      reply(:hello, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreEcosystemIntegrationTest.EcoDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end

  @impl true
  def action_result(completion, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:action_result, completion})
    {:ok, :action_result}
  end
end

defmodule SpectreEcosystemIntegrationTest.PlainDelivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:delivered, text})
    {:ok, {:sent, text}}
  end
end

defmodule SpectreEcosystemIntegrationTest.SummaryStore do
  @moduledoc false
  @behaviour Spectre.State.Store

  alias Spectre.State
  alias Spectre.State.Codec

  @impl Spectre.State.Store
  def load(_input, _agent, opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    store = Keyword.fetch!(opts, :store)

    case Elixir.Agent.get(store, &Map.get(&1, conversation_id)) do
      nil -> {:ok, %State{conversation_id: conversation_id}}
      payload -> Codec.decode(payload)
    end
  end

  @impl Spectre.State.Store
  def compare_and_swap(%State{} = state, expected, _input, _agent, opts) do
    store = Keyword.fetch!(opts, :store)
    conversation_id = state.conversation_id || Keyword.fetch!(opts, :conversation_id)

    with {:ok, payload} <- Codec.encode(state) do
      Elixir.Agent.get_and_update(store, &swap(&1, conversation_id, expected, payload))
    end
  end

  defp swap(persisted, conversation_id, expected, payload) do
    case persisted_revision(Map.get(persisted, conversation_id)) do
      ^expected -> {{:ok, payload}, Map.put(persisted, conversation_id, payload)}
      actual -> {{:error, {:stale_state, actual}}, persisted}
    end
  end

  defp persisted_revision(nil), do: 0

  defp persisted_revision(payload) do
    {:ok, decoded} = Codec.decode(payload)
    decoded.revision
  end
end

defmodule SpectreEcosystemIntegrationTest.SummaryAgent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreEcosystemIntegrationTest.Renderer
  alias SpectreEcosystemIntegrationTest.Summarizer

  state(SpectreEcosystemIntegrationTest.SummaryStore)
  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  history(1, summary: {Summarizer, :fold})

  flow :conversation do
    on :MESSAGE, regex: ~r/\S/u, cache: false do
      reply(:message, renderer: {Renderer, :render})
    end
  end
end

defmodule SpectreEcosystemIntegrationTest do
  @moduledoc """
  Integration coverage for the surfaces the satellite libraries build on
  (spectre_kinetic, spectre_lens, spectre_mnemonic, spectre_directive,
  spectre_pulse): extension-contributed action providers, host-state guards,
  the turn dispatcher, and state-store persistence of the rolling summary.
  """

  use ExUnit.Case, async: false

  alias Spectre.Effect
  alias Spectre.State
  alias Spectre.State.Codec
  alias Spectre.Turn
  alias Spectre.Turn.Dispatcher
  alias SpectreEcosystemIntegrationTest.EcoAgent
  alias SpectreEcosystemIntegrationTest.EcoDelivery
  alias SpectreEcosystemIntegrationTest.PlainDelivery
  alias SpectreEcosystemIntegrationTest.SummaryAgent

  describe "extension-provided action providers (Kinetic/Lens pattern)" do
    test "a nested-flow route stages an effect bound to the extension provider" do
      assert {:ok, %Turn{decision: {:needs, %Effect{name: :sync_crm} = effect, result}}} =
               Spectre.turn(EcoAgent, "sync crm", test_pid: self())

      assert Effect.via(effect) == :eco
      assert result.route.rule.flow_path == [:operations, :crm]
    end

    test "the dispatcher executes the provider and completes the turn" do
      assert {:ok, %Turn{decision: {:needs, _effect, _result}} = turn} =
               Spectre.turn(EcoAgent, "sync crm", test_pid: self())

      assert {:ok, :action_result} = Dispatcher.dispatch(turn, EcoDelivery, test_pid: self())

      assert_receive {:provider_executed, :sync_crm, %{scope: :all}}
      assert_receive {:action_result, %Effect{status: :completed, result: "crm synced"}}
    end

    test "a before_action guard reading host state suppresses the provider call" do
      seeded = %State{data: %{locked: true}}

      assert {:ok, %Turn{decision: {:needs, _effect, result}}} =
               Spectre.turn(EcoAgent, "sync crm", state: seeded, test_pid: self())

      assert {:ok, executed} = Spectre.execute(EcoAgent, result, test_pid: self())

      assert executed.reply_text == "workspace locked"
      assert [%Effect{name: :sync_crm, status: :cancelled}] = executed.effects
      assert Enum.any?(executed.events, &(&1.type == :effect_suppressed))
      refute_receive {:provider_executed, _name, _args}
    end

    test "the dispatcher delivers the suppression reply end to end" do
      seeded = %State{data: %{locked: true}}

      assert {:ok, %Turn{decision: {:needs, _effect, _result}} = turn} =
               Spectre.turn(EcoAgent, "sync crm", state: seeded, test_pid: self())

      assert {:ok, {:sent, "workspace locked"}} =
               Dispatcher.dispatch(turn, PlainDelivery, test_pid: self())

      assert_receive {:delivered, "workspace locked"}
      refute_receive {:provider_executed, _name, _args}
    end

    test "an unlocked state lets the same guard allow execution" do
      seeded = %State{data: %{locked: false}}

      assert {:ok, %Turn{} = turn} =
               Spectre.turn(EcoAgent, "sync crm", state: seeded, test_pid: self())

      assert {:ok, :action_result} = Dispatcher.dispatch(turn, EcoDelivery, test_pid: self())
      assert_receive {:provider_executed, :sync_crm, _args}
    end
  end

  describe "LLM adapter boundary" do
    test "provider_opts strips runtime context and spectre_* keys" do
      opts = [
        temperature: 0.2,
        max_tokens: 64,
        state: %State{},
        route: :fake,
        model: "x",
        reply_sanitizer: {MyApp.ReplySanitizer, model_family: :reasoning},
        classifier: [model: "classifier"],
        embedding: :embedder,
        journal: :audit,
        chat_summary: "older turns",
        router_timeout: 100,
        effect_result_max_bytes: 1_000,
        spectre_rules: [],
        spectre_bounds: [max_transport_chunk_bytes: 256_000],
        max_transport_chunk_bytes: 256_000,
        max_parser_residual_bytes: 256_000,
        recent_chat: [],
        test_pid: self()
      ]

      assert Spectre.LLM.provider_opts(opts, [:test_pid]) == [temperature: 0.2, max_tokens: 64]
      assert :state in Spectre.LLM.runtime_opt_keys()
      assert :reply_sanitizer in Spectre.LLM.runtime_opt_keys()
      assert :spectre_bounds in Spectre.LLM.runtime_opt_keys()
      assert :max_transport_chunk_bytes in Spectre.LLM.runtime_opt_keys()
      assert :max_parser_residual_bytes in Spectre.LLM.runtime_opt_keys()
    end
  end

  describe "instance host ergonomics" do
    test "ensure_instance normalizes start shapes and trace_id is stable per generation" do
      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      subject = "eco-conversation-#{System.unique_integer([:positive])}"

      assert {:ok, pid} = Spectre.ensure_instance(supervisor, EcoAgent, subject, idle: false)
      assert {:ok, ^pid} = Spectre.ensure_instance(supervisor, EcoAgent, subject, idle: false)

      assert {:ok, trace_id} = Spectre.Instance.trace_id(pid)
      assert is_binary(trace_id)
      assert {:ok, ^trace_id} = Spectre.Instance.trace_id(pid)

      :ok = DynamicSupervisor.terminate_child(supervisor, pid)
      assert {:error, {:instance_unreachable, _reason}} = Spectre.Instance.trace_id(pid)
    end
  end

  describe "journal store boundary" do
    test "to_json_map produces a JSON-encodable string-keyed map" do
      record =
        Spectre.Journal.Record.new(%{
          agent: EcoAgent,
          phase: :execution,
          decision: %{outcome: :ok, tuple: {:a, 1}},
          effect: %{name: :sync_crm, args: %{scope: :all}},
          metadata: %{pid_like: self()}
        })

      map = Spectre.Journal.Record.to_json_map(record)

      assert map["phase"] == "execution"
      assert map["agent"] == "Elixir.SpectreEcosystemIntegrationTest.EcoAgent"
      assert map["decision"] == %{"outcome" => "ok", "tuple" => ["a", 1]}
      assert is_binary(map["occurred_at"])
      assert is_binary(map["metadata"]["pid_like"])
      assert {:ok, _json} = Jason.encode(map)
    end
  end

  describe "release-boot contracts" do
    test "classifier artifact schema atoms are interned by loading the module" do
      atoms = Spectre.Classifier.artifact_schema_atoms()

      assert :example_index in atoms
      assert :centroids in atoms

      artifact = Map.new(atoms, &{&1, :ok})
      binary = :erlang.term_to_binary(artifact)
      assert ^artifact = :erlang.binary_to_term(binary, [:safe])
    end
  end

  describe "rolling summary across persistence (Pulse/Mnemonic pattern)" do
    test "chat_summary survives a State.Codec round-trip" do
      state = %State{data: %{chat_summary: "user wants a crm", chat_history: []}}

      assert {:ok, payload} = Codec.encode(state)
      assert {:ok, decoded} = Codec.decode(payload)
      assert decoded.data.chat_summary == "user wants a crm"
    end

    test "a store-backed session keeps folding the summary across restarts" do
      conversation_id = "eco-summary-#{System.unique_integer([:positive])}"
      store = start_supervised!({Elixir.Agent, fn -> %{} end})
      first_child_id = {:eco_summary_session, conversation_id, :first}

      first_session =
        start_supervised!(
          {Spectre.Session,
           agent: SummaryAgent,
           id: first_child_id,
           conversation_id: conversation_id,
           idle: false,
           opts: [store: store]}
        )

      assert {:ok, _first} = Spectre.ask(first_session, "first")
      assert {:ok, second} = Spectre.ask(first_session, "second")

      assert second.state.data.chat_summary == "first"
      assert Enum.map(second.state.data.chat_history, & &1.user) == ["second"]

      assert :ok = stop_supervised(first_child_id)

      restarted_session =
        start_supervised!(
          {Spectre.Session,
           agent: SummaryAgent,
           id: {:eco_summary_session, conversation_id, :restarted},
           conversation_id: conversation_id,
           idle: false,
           opts: [store: store]}
        )

      restored = Spectre.state(restarted_session)
      assert restored.data.chat_summary == "first"

      assert {:ok, third} = Spectre.ask(restarted_session, "third")
      assert third.state.data.chat_summary == "first|second"
      assert Enum.map(third.state.data.chat_history, & &1.user) == ["third"]
    end
  end
end
