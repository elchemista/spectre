defmodule SpectreBranchMatrixTest.PlainActions do
  @moduledoc false
  def perform(value), do: {:ok, value}
end

defmodule SpectreBranchMatrixTest.RegisteredActions do
  @moduledoc false
  def perform(value), do: {:ok, value}
  def unregistered(value), do: {:ok, value}

  def __spectre_tools__ do
    [
      %{function: :perform, arity: 1},
      %{"function" => "perform", "arity" => "1"},
      :invalid_entry
    ]
  end
end

defmodule SpectreBranchMatrixTest.BadRegistryAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: {SpectreBranchMatrixTest.BadRegistryActions, []}]
end

defmodule SpectreBranchMatrixTest.RaisingRegistryAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: {SpectreBranchMatrixTest.RaisingRegistryActions, []}]
end

defmodule SpectreBranchMatrixTest.ThrowingRegistryAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: {SpectreBranchMatrixTest.ThrowingRegistryActions, []}]
end

defmodule SpectreBranchMatrixTest.BadRegistryActions do
  @moduledoc false
  def perform(value), do: value
  def __spectre_tools__, do: :invalid
end

defmodule SpectreBranchMatrixTest.RaisingRegistryActions do
  @moduledoc false
  def perform(value), do: value
  def __spectre_tools__, do: raise("registry")
end

defmodule SpectreBranchMatrixTest.ThrowingRegistryActions do
  @moduledoc false
  def perform(value), do: value
  def __spectre_tools__, do: throw(:registry)
end

defmodule SpectreBranchMatrixTest.ActionAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: {SpectreBranchMatrixTest.PlainActions, [source: :agent]}]
end

defmodule SpectreBranchMatrixTest.BareActionAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: SpectreBranchMatrixTest.PlainActions]
end

defmodule SpectreBranchMatrixTest.RegisteredActionAgent do
  @moduledoc false

  def __spectre_config__,
    do: [actions: {SpectreBranchMatrixTest.RegisteredActions, []}]
end

defmodule SpectreBranchMatrixTest.BadConfigAgent do
  @moduledoc false
  def __spectre_config__, do: [actions: "invalid"]
end

defmodule SpectreBranchMatrixTest.RaisingConfigAgent do
  @moduledoc false
  def __spectre_config__, do: raise("config")
end

defmodule SpectreBranchMatrixTest.ThrowingConfigAgent do
  @moduledoc false
  def __spectre_config__, do: throw(:config)
end

defmodule SpectreBranchMatrixTest.InputPlug do
  @moduledoc false
  def init(opts), do: Keyword.get(opts, :mode, :continue)

  def call(input, _context, :continue),
    do: {:cont, Spectre.Input.put_meta(input, :continued, true)}

  def call(input, _context, :halt), do: {:halt, Spectre.Input.put_meta(input, :halted, true)}
  def call(_input, _context, :error), do: {:error, :plug_error}
  def call(_input, _context, :invalid), do: :invalid
  def call(_input, _context, :raise), do: raise("input plug")
end

defmodule SpectreBranchMatrixTest.InitFailInputPlug do
  @moduledoc false
  def init(_opts), do: raise("input init")
  def call(input, _context, state), do: {:cont, {input, state}}
end

defmodule SpectreBranchMatrixTest.RouterPlug do
  @moduledoc false
  def init(opts), do: Keyword.get(opts, :mode, :continue)

  def call(context, :continue),
    do: {:cont, Spectre.Router.Context.put_trace(context, :continued)}

  def call(context, :halt), do: {:halt, Spectre.Router.Context.put_trace(context, :halted)}
  def call(_context, :error), do: {:error, :plug_error}
  def call(_context, :invalid), do: :invalid
  def call(_context, :raise), do: raise("router plug")
end

defmodule SpectreBranchMatrixTest.CustomPipeline do
  @moduledoc false
  use Spectre.Pipeline

  pipeline do
    plug(SpectreBranchMatrixTest.RouterPlug, mode: :continue)
  end
end

defmodule SpectreBranchMatrixTest.EmbeddingCallbacks do
  @moduledoc false
  def download(value), do: {:ok, byte_size(value)}
  def load(value, opts), do: {:ok, byte_size(value) + Keyword.get(opts, :extra, 0)}
  def embed(value), do: {:ok, [byte_size(value) / 1]}
end

defmodule SpectreBranchMatrixTest.FullSemanticCache do
  @moduledoc false
  @behaviour Spectre.Router.SemanticCache

  def lookup(text, _opts), do: {:ok, %{label: :ALPHA, accepted?: true, matched: text}}
  def put(_text, _result, _opts), do: :ok
  def examples(_agent, _opts), do: {:ok, [%{id: "one", label: :ALPHA}]}
  def get_example(_agent, id, _opts), do: {:ok, %{id: id, label: :ALPHA}}
  def relabel(_agent, id, label, _opts), do: {:ok, %{id: id, label: label}}
  def delete(_agent, _id, _opts), do: {:ok, :deleted}
  def verify(_agent, id, _opts), do: {:ok, %{id: id, verified?: true}}
  def snapshot(_agent, _opts), do: {:ok, [%{id: "one"}]}
  def load_snapshot(_agent, _snapshot, _opts), do: {:ok, %{loaded: 1}}
  def clear(_agent, _opts), do: {:ok, :cleared}
end

defmodule SpectreBranchMatrixTest.LookupOnlySemanticCache do
  @moduledoc false
  def lookup(_text, _opts), do: {:error, :miss}
end

defmodule SpectreBranchMatrixTest.InvalidSemanticCache do
  @moduledoc false
  def lookup(_text, _opts), do: :invalid
  def put(_text, _result, _opts), do: :invalid
  def clear(_agent, _opts), do: :invalid
end

defmodule SpectreBranchMatrixTest.RaisingSemanticCache do
  @moduledoc false
  def lookup(_text, _opts), do: raise("cache")
  def put(_text, _result, _opts), do: raise("cache")
  def clear(_agent, _opts), do: raise("cache")
end

defmodule SpectreBranchMatrixTest.ThrowingSemanticCache do
  @moduledoc false
  def lookup(_text, _opts), do: throw(:cache)
  def put(_text, _result, _opts), do: throw(:cache)
  def clear(_agent, _opts), do: throw(:cache)
end

defmodule SpectreBranchMatrixTest.ExitingSemanticCache do
  @moduledoc false
  def lookup(_text, _opts), do: exit(:cache)
  def put(_text, _result, _opts), do: exit(:cache)
  def clear(_agent, _opts), do: exit(:cache)
end

defmodule SpectreBranchMatrixTest.ErrorSemanticCache do
  @moduledoc false
  def examples(_agent, _opts), do: {:error, :examples_failed}
  def get_example(_agent, _id, _opts), do: {:error, :get_failed}
  def relabel(_agent, _id, _label, _opts), do: {:error, :relabel_failed}
  def delete(_agent, _id, _opts), do: {:error, :delete_failed}
  def snapshot(_agent, _opts), do: {:error, :snapshot_failed}
  def load_snapshot(_agent, _snapshot, _opts), do: {:error, :load_failed}
end

defmodule SpectreBranchMatrixTest.RaisingRouterAgent do
  @moduledoc false
  def __spectre_router__, do: raise("router configuration")
end

defmodule SpectreBranchMatrixTest.ThrowingRouterAgent do
  @moduledoc false
  def __spectre_router__, do: throw(:router_configuration)
end

defmodule SpectreBranchMatrixTest.ExitingRouterAgent do
  @moduledoc false
  def __spectre_router__, do: exit(:router_configuration)
end

defmodule SpectreBranchMatrixTest.CacheAgent do
  @moduledoc false
  use Spectre.Agent

  router(semantic_cache?: true, classification_log?: false)

  flow :coverage do
    on :ALPHA, regex: ~r/^alpha$/, embedding: ["alpha example"], cache: true do
      reply(:alpha)
    end

    on :BETA, regex: ~r/^beta$/, embedding: ["beta example"], cache: true do
      reply(:beta)
    end
  end
end

defmodule SpectreBranchMatrixTest do
  use ExUnit.Case, async: true

  alias Spectre.ActionConfig
  alias Spectre.Awaitable
  alias Spectre.Classifier.Encoder
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Pipeline, as: InputPipeline
  alias Spectre.Lifecycle
  alias Spectre.Result
  alias Spectre.Router.Context, as: RouterContext
  alias Spectre.Router.SemanticCache
  alias Spectre.Rule
  alias Spectre.State
  alias Spectre.Training.Dataset

  describe "state and effect compatibility branches" do
    test "normalizes nil, keyword, string-keyed, current, and legacy state" do
      assert %State{} = State.new(nil)
      assert %State{revision: 2} = State.new(revision: 2)

      assert %State{revision: 3, current_flow: :flow} =
               State.new(%{"revision" => 3, "current_flow" => :flow, "pending_effects" => []})

      current =
        State.new(%{
          pending_effects: [%{name: :perform}],
          planned_effects: %{name: :old, status: :completed},
          awaitables: [%{kind: :policy, name: :confirm, subject_id: "id"}]
        })

      assert [%Effect{name: :perform}] = current.pending_effects
      assert [%Effect{name: :old}] = current.planned_effects
      assert [%Awaitable{name: :confirm}] = current.awaitables

      legacy =
        State.new(%{
          pending_action: %{id: "legacy", name: :perform},
          planned_actions: [%{id: "old", name: :old, status: :completed}],
          awaiting: %{policy: :confirm, attempts: 2}
        })

      assert [%Effect{id: "legacy"}] = legacy.pending_effects
      assert [%Awaitable{attempts: 2, subject_id: "legacy"}] = legacy.awaitables
      assert length(legacy.planned_effects) == 2

      no_effect = State.new(%{awaiting: %{policy: :confirm}})
      assert no_effect.awaitables == []
    end

    test "covers state convenience APIs for success, replay, and invalid transitions" do
      effect = Effect.stage(%{id: "effect", name: :perform})
      waiting = State.put_pending_effect(%State{}, effect, :confirm)
      assert State.awaiting_policy?(waiting)

      assert_raise ArgumentError, fn ->
        State.put_pending_effect(waiting, Effect.stage(%{name: :second}), nil)
      end

      awaitable = State.open_policy_awaitable(waiting)
      replaced = State.replace_awaitable(waiting, Awaitable.increment(awaitable))
      assert State.open_policy_awaitable(replaced).attempts == 1

      assert {:ok, approved_state, %Effect{status: :approved}} =
               State.approve_pending_effect(replaced, effect.id)

      assert {:error, {:effect_not_waiting_policy, _, :approved}} =
               State.approve_pending_effect(approved_state, effect.id)

      assert {:error, :pending_effect_not_found} =
               State.approve_pending_effect(%State{}, "missing")

      {completed_state, completed} = State.complete_pending_effect(approved_state, :done)
      assert completed.status == :completed
      assert State.resolved_effect(completed_state, effect.id) == completed

      assert {%State{}, nil} = State.complete_pending_effect(%State{}, :done)

      invalid_waiting = %{waiting | awaitables: []}
      assert {^invalid_waiting, nil} = State.complete_pending_effect(invalid_waiting, :done)

      pending = State.put_pending_effect(%State{}, Effect.stage(%{name: :fail}), nil)
      {failed_state, failed} = State.fail_pending_effect(pending, :down)
      assert failed.status == :failed
      assert State.resolved_effect(failed_state, failed.id) == failed
      assert {%State{}, nil} = State.fail_pending_effect(%State{}, :down)

      assert State.clear_open_awaitables(waiting).awaitables == []
      assert State.clear_pending(waiting).pending_effects == []
      assert State.cancel_pending(waiting).pending_effects == []
    end

    test "records bounded history and exercises all Effect accessors" do
      input = Input.new("hello")
      route = Spectre.Route.new(%{label: :HELLO})
      result = %Result{reply_text: "hi", route: route, events: [%{type: :replied}]}

      state = %State{}
      assert State.record_turn(state, input, result, false) == state
      assert State.record_turn(state, input, result, nil) == state
      assert State.record_turn(state, input, result, 0) == state

      recorded =
        state |> State.record_turn(input, result, 1) |> State.record_turn(input, result, 1)

      assert [%{user: "hello", assistant: "hi", route: :HELLO, events: [:replied]}] =
               recorded.data.chat_history

      assert State.bump_revision(%State{revision: 4}).revision == 5
      assert length(Enum.reduce(1..300, %State{}, &State.trace(&2, &1)).trace) == 256

      selected =
        Effect.restore(%{
          id: "selected",
          selected_tool: "Elixir.SpectreBranchMatrixTest.PlainActions.perform/1",
          hooks: [%{phase: :before}],
          owner: SpectreBranchMatrixTest.PlainActions,
          scope: {:skill, :mounted}
        })

      assert Effect.effect_key(selected) == :perform
      assert Effect.effect_key(%{selected_tool: "tool/1"}) == "tool/1"
      assert Effect.effect_key(%{name: "perform"}) == "perform"
      assert Effect.effect_key(:perform) == :perform
      assert Effect.effect_key(123) == nil
      assert Effect.hooks(selected) == [%{phase: :before}]
      assert Effect.selected_tool(selected) =~ "perform/1"
      assert Effect.source(selected) == :al
      assert Effect.owner(selected) == SpectreBranchMatrixTest.PlainActions
      assert Effect.scope(selected) == {:skill, :mounted}

      assert is_binary(Effect.idempotency_key(%{selected | idempotency_key: nil}))
      assert Effect.approve(selected) == selected
      assert Effect.cancel(selected).metadata[:cancel_reason] == nil
      assert Effect.cancel(selected, :user).metadata.cancel_reason == :user
      assert Effect.outcome(Effect.complete(selected, {:error, :bad})) == {:error, :bad}
      assert Effect.outcome(selected) == nil
    end
  end

  describe "input and rule branch matrix" do
    test "normalizes every supported input shape and metadata key" do
      input = Input.new(%{"text" => "hello", "meta" => %{"locale" => "it"}})
      assert input.text == "hello"
      assert Input.fetch_meta(input, :locale) == {:ok, "it"}
      assert Input.fetch_meta(input, :missing) == :error

      atom_input = Input.new(%{text: "atom", meta: %{channel: :web}})
      assert Input.new(atom_input) == atom_input
      assert Input.new(123).text == "123"

      enriched = atom_input |> Input.put_meta("new_unknown_key", 1) |> Input.merge_meta(foo: 2)
      assert Input.fetch_meta(enriched, "new_unknown_key") == {:ok, 1}
      assert Input.fetch_meta(enriched, :foo) == {:ok, 2}
    end

    test "normalizes regex and checks while rejecting training metadata" do
      assert Rule.new(%{label: :NONE, regex: nil}).regex == []
      assert [%Regex{}] = Rule.new(%{label: :ONE, regex: ~r/one/}).regex
      assert Rule.new(%{label: :LIST, regex: [~r/a/, ~r/b/]}).regex |> length() == 2
      refute Rule.match?(Rule.new(%{label: :NONE}), "text")
      assert Rule.match?(Rule.new(%{label: :ONE, regex: ~r/one/}), "one")

      input = Input.new(%{text: " Hello ", meta: %{channel: "WEB", count: 2}})
      rule = Rule.new(%{label: :CHECK, checks: [text: "hello", channel: :web, count: [1, 2]]})
      assert Rule.checks_match?(rule, input)
      refute Rule.checks_match?(Rule.new(%{label: :MISS, check: {:missing, true}}), input)
      refute Rule.checks_match?(Rule.new(%{label: :MISS, check: {:count, 3}}), input)

      assert_raise ArgumentError, fn -> Rule.new(%{label: :BAD, check: :invalid}) end
      assert_raise ArgumentError, fn -> Rule.new(%{label: :BAD, train: ["inline"]}) end
      assert_raise ArgumentError, fn -> Rule.new(%{label: :BAD, training: true}) end
    end

    test "input normalization covers unicode, case, whitespace, halt, and failures" do
      context = %{agent: __MODULE__, opts: []}

      assert {:ok, normalized} =
               InputPipeline.run(Input.new("  CAFÉ\tTEST  "), context, [
                 {Spectre.Input.Plugs.NormalizeText,
                  unicode: :nfd, case: :downcase, collapse_whitespace: true, trim: true}
               ])

      assert normalized.text == "café test"

      assert {:ok, unchanged} =
               InputPipeline.run(Input.new("  MiXeD  "), context, [
                 {Spectre.Input.Plugs.NormalizeText,
                  unicode: false, case: nil, collapse_whitespace: false, trim: false}
               ])

      assert unchanged.text == "  MiXeD  "

      assert {:ok, upper} =
               InputPipeline.run(Input.new("hello"), context, [
                 {Spectre.Input.Plugs.NormalizeText, unicode: nil, case: :upcase}
               ])

      assert upper.text == "HELLO"

      assert {:ok, halted} =
               InputPipeline.run(Input.new("x"), context, [
                 {SpectreBranchMatrixTest.InputPlug, mode: :halt},
                 {SpectreBranchMatrixTest.InputPlug, mode: :continue}
               ])

      assert halted.meta.halted
      refute Map.has_key?(halted.meta, :continued)

      for mode <- [:error, :invalid, :raise] do
        assert {:error, {SpectreBranchMatrixTest.InputPlug, _reason}} =
                 InputPipeline.run(Input.new("x"), context, [
                   {SpectreBranchMatrixTest.InputPlug, mode: mode}
                 ])
      end

      assert {:error, {:invalid_input_plug_spec, {:invalid, :not_options}}} =
               InputPipeline.init_specs([{:invalid, :not_options}])

      assert {:error, _reason} =
               InputPipeline.init_specs([SpectreBranchMatrixTest.InitFailInputPlug])
    end
  end

  describe "router pipeline executor" do
    test "initializes modules, tuples, specs and handles halt/error/invalid/raise" do
      context = router_context()
      assert {:ok, specs} = Spectre.Pipeline.init_specs([SpectreBranchMatrixTest.RouterPlug])
      assert [%Spectre.Pipeline.Spec{}] = specs

      assert [%Spectre.Pipeline.Spec{}] =
               Spectre.Pipeline.init_specs!([SpectreBranchMatrixTest.RouterPlug])

      assert {:ok, continued} = Spectre.Pipeline.run(context, specs)
      assert :continued in continued.traces
      assert {:ok, custom} = SpectreBranchMatrixTest.CustomPipeline.call(context)
      assert :continued in custom.traces

      assert {:ok, halted} =
               Spectre.Pipeline.run(context, [
                 {SpectreBranchMatrixTest.RouterPlug, mode: :halt},
                 {SpectreBranchMatrixTest.RouterPlug, mode: :continue}
               ])

      assert halted.halted?
      refute :continued in halted.traces

      for mode <- [:error, :invalid, :raise] do
        assert {:error, {SpectreBranchMatrixTest.RouterPlug, _reason}} =
                 Spectre.Pipeline.run(context, [{SpectreBranchMatrixTest.RouterPlug, mode: mode}])
      end

      assert {:error, {:invalid_plug_spec, 123}} = Spectre.Pipeline.init_specs([123])

      assert_raise ArgumentError, fn ->
        Spectre.Pipeline.init_specs!([123])
      end
    end
  end

  describe "action configuration boundary" do
    test "normalizes action declarations and safely contains broken configs" do
      plain = SpectreBranchMatrixTest.PlainActions

      assert {^plain, [source: :agent]} =
               ActionConfig.actions(SpectreBranchMatrixTest.ActionAgent)

      assert {^plain, []} = ActionConfig.actions(SpectreBranchMatrixTest.BareActionAgent)
      assert ActionConfig.actions(SpectreBranchMatrixTest.BadConfigAgent) == nil
      assert ActionConfig.actions(SpectreBranchMatrixTest.RaisingConfigAgent) == nil
      assert ActionConfig.actions(SpectreBranchMatrixTest.ThrowingConfigAgent) == nil
      assert ActionConfig.actions(:missing_agent) == nil
      assert ActionConfig.actions(nil) == nil

      planner =
        ActionConfig.planner_opts(%{agent: SpectreBranchMatrixTest.ActionAgent}, timeout: 10)

      assert planner[:timeout] == 10
      assert planner[:source] == :agent
      assert planner[:actions_module] == plain

      assert ActionConfig.planner_opts(%{agent: :missing_agent}, timeout: 10) == [timeout: 10]
    end

    test "authorizes plain and registered tools and rejects every registry failure" do
      plain = SpectreBranchMatrixTest.PlainActions

      assert :ok =
               ActionConfig.authorize_tool(
                 SpectreBranchMatrixTest.ActionAgent,
                 plain,
                 :perform,
                 1
               )

      assert {:error, :missing_actions_module} =
               ActionConfig.authorize_tool(:missing_agent, plain, :perform, 1)

      assert {:error, {:unauthorized_action_module, _, ^plain}} =
               ActionConfig.authorize_tool(
                 SpectreBranchMatrixTest.ActionAgent,
                 SpectreBranchMatrixTest.RegisteredActions,
                 :perform,
                 1
               )

      assert {:error, {:undefined_action, ^plain, :missing, 1}} =
               ActionConfig.authorize_tool(
                 SpectreBranchMatrixTest.ActionAgent,
                 plain,
                 :missing,
                 1
               )

      registered = SpectreBranchMatrixTest.RegisteredActions

      assert :ok =
               ActionConfig.authorize_tool(
                 SpectreBranchMatrixTest.RegisteredActionAgent,
                 registered,
                 :perform,
                 1
               )

      assert {:error, {:unregistered_action_tool, ^registered, :unregistered, 1}} =
               ActionConfig.authorize_tool(
                 SpectreBranchMatrixTest.RegisteredActionAgent,
                 registered,
                 :unregistered,
                 1
               )

      for {agent, module, expected} <- [
            {SpectreBranchMatrixTest.BadRegistryAgent, SpectreBranchMatrixTest.BadRegistryActions,
             :invalid_action_registry},
            {SpectreBranchMatrixTest.RaisingRegistryAgent,
             SpectreBranchMatrixTest.RaisingRegistryActions, :action_registry_exception},
            {SpectreBranchMatrixTest.ThrowingRegistryAgent,
             SpectreBranchMatrixTest.ThrowingRegistryActions, :action_registry_failure}
          ] do
        assert {:error, reason} = ActionConfig.authorize_tool(agent, module, :perform, 1)
        assert elem(reason, 0) == expected
      end
    end
  end

  describe "encoder and training dataset adapters" do
    @tag :tmp_dir
    test "supports every callback form and contains invalid callbacks", %{tmp_dir: tmp} do
      assert {:ok, 3} =
               Encoder.download("abc", download: fn value -> {:ok, String.length(value)} end)

      assert {:ok, 4} =
               Encoder.load("abc",
                 load_embedding: fn value, _opts -> {:ok, byte_size(value) + 1} end
               )

      assert {:ok, [3.0]} =
               Encoder.embed("abc", embed: &SpectreBranchMatrixTest.EmbeddingCallbacks.embed/1)

      assert {:ok, 3} =
               Encoder.download("abc",
                 download: {SpectreBranchMatrixTest.EmbeddingCallbacks, :download}
               )

      assert {:ok, 5} =
               Encoder.load("abc",
                 load_embedding: SpectreBranchMatrixTest.EmbeddingCallbacks,
                 extra: 2
               )

      assert {:error, {:invalid_embedding_callback, 123}} = Encoder.embed("abc", embed: 123)

      assert {:error, {:missing_embedding_adapter, MissingEmbeddingAdapter}} =
               Encoder.embed("abc", embedding_adapter: MissingEmbeddingAdapter)

      assert {:error, {:missing_embedding_callback, URI, :embed}} =
               Encoder.embed("abc", embedding_adapter: URI)

      source = Path.join(tmp, "rows.jsonl")

      File.write!(
        source,
        "# comment\n" <> Jason.encode!(%{text: "alpha", label: "ALPHA"}) <> "\n"
      )

      assert {:ok, [%{label: "ALPHA", text: "alpha"}]} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: source)
    end

    @tag :tmp_dir
    test "dataset reports invalid agents, sources, formats, and JSONL", %{tmp_dir: tmp} do
      assert {:error, {:invalid_agent, URI}} = Dataset.from_agent(URI)

      assert {:error, {:invalid_training_source, 123}} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: 123)

      missing = Path.join(tmp, "missing.json")

      assert {:error, {:missing_dataset_source, ^missing}} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: missing)

      unsupported = Path.join(tmp, "rows.txt")
      File.write!(unsupported, "rows")

      assert {:error, {:unsupported_dataset_source, ^unsupported}} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: unsupported)

      invalid_json = Path.join(tmp, "rows.json")
      File.write!(invalid_json, Jason.encode!(%{text: "not-a-list"}))

      assert {:error, {:invalid_dataset_json, ^invalid_json}} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: invalid_json)

      invalid_jsonl = Path.join(tmp, "rows.jsonl")
      File.write!(invalid_jsonl, "{bad-json}\n")

      assert {:error, {:invalid_jsonl_row, ^invalid_jsonl, _reason}} =
               Dataset.from_agent(SpectreBranchMatrixTest.CacheAgent, source: invalid_jsonl)
    end
  end

  describe "semantic cache adapter boundary" do
    test "normalizes lookup callback forms, routes, and failures" do
      assert {:ok, %{label: :ALPHA}} =
               SemanticCache.lookup("alpha",
                 semantic_lookup: fn _text -> {:ok, %{label: :ALPHA, accepted?: true}} end
               )

      assert {:ok, %{label: :ALPHA}} =
               SemanticCache.lookup("alpha",
                 semantic_lookup: fn _text, _opts ->
                   {:ok, %{label: :ALPHA, accepted?: true}}
                 end
               )

      assert {:ok, %{label: :ALPHA}} =
               SemanticCache.lookup("alpha",
                 semantic_cache: SpectreBranchMatrixTest.FullSemanticCache
               )

      assert {:ok, %{label: :ALPHA}} =
               SemanticCache.lookup("alpha",
                 semantic_cache: {SpectreBranchMatrixTest.FullSemanticCache, :lookup}
               )

      assert {:error, {:invalid_semantic_cache_adapter, 123}} =
               SemanticCache.lookup("alpha", semantic_cache: 123)

      assert {:error, :missing_semantic_cache_adapter} = SemanticCache.lookup("alpha", [])

      for {adapter, code} <- [
            {SpectreBranchMatrixTest.InvalidSemanticCache, :invalid_reply},
            {SpectreBranchMatrixTest.RaisingSemanticCache, :exception},
            {SpectreBranchMatrixTest.ThrowingSemanticCache, :throw},
            {SpectreBranchMatrixTest.ExitingSemanticCache, :exit}
          ] do
        assert {:error, reason} = SemanticCache.lookup("alpha", semantic_cache: adapter)
        assert semantic_failure_code(reason) == code
      end
    end

    test "dispatches the complete optional review API and sanitizes adapter options" do
      opts = [semantic_cache: SpectreBranchMatrixTest.FullSemanticCache, secret: "remove"]
      agent = SpectreBranchMatrixTest.CacheAgent

      assert {:ok, [%{id: "one"}]} =
               SemanticCache.examples(agent, opts)

      assert {:ok, %{id: "one"}} =
               SemanticCache.get_example(agent, "one", opts)

      assert {:ok, %{label: :BETA}} =
               SemanticCache.relabel(agent, "one", :BETA, opts)

      assert {:ok, :deleted} =
               SemanticCache.delete(agent, "one", opts)

      assert {:ok, %{verified?: true}} =
               SemanticCache.verify(agent, "one", opts)

      assert {:ok, [%{id: "one"}]} =
               SemanticCache.snapshot(agent, opts)

      assert {:ok, %{loaded: 1}} =
               SemanticCache.load_snapshot(
                 agent,
                 [rows: [%{id: "one"}]],
                 opts
               )

      assert :ok = SemanticCache.clear(agent, opts)

      assert :ok =
               SemanticCache.clear(agent,
                 semantic_cache: {SpectreBranchMatrixTest.FullSemanticCache, :lookup}
               )
    end

    test "handles missing optional callbacks and learning failure policy" do
      result = %{label: :ALPHA, accepted?: true}
      agent = SpectreBranchMatrixTest.CacheAgent

      assert :ok =
               SemanticCache.put("alpha", result,
                 semantic_lookup: fn _text -> {:error, :miss} end
               )

      assert {:error, :unwritable_semantic_lookup} =
               SemanticCache.put("alpha", result,
                 semantic_lookup: fn _text -> {:error, :miss} end,
                 semantic_learn_failure: :error
               )

      assert :ok =
               SemanticCache.put("alpha", result,
                 semantic_cache: SpectreBranchMatrixTest.LookupOnlySemanticCache
               )

      assert {:error, {:missing_semantic_cache_callback, _, :put}} =
               SemanticCache.put("alpha", result,
                 semantic_cache: SpectreBranchMatrixTest.LookupOnlySemanticCache,
                 semantic_learn_failure: :error
               )

      assert {:error, {:invalid_semantic_cache_result, :bad}} =
               SemanticCache.put("alpha", :bad, [])

      assert {:error, {:invalid_agent, URI}} = SemanticCache.examples(URI)

      assert {:error, :unclearable_semantic_lookup} =
               SemanticCache.clear(agent,
                 semantic_lookup: fn _text -> {:error, :miss} end
               )

      assert {:error, {:missing_semantic_cache_callback, _, :clear}} =
               SemanticCache.clear(agent,
                 semantic_cache: SpectreBranchMatrixTest.LookupOnlySemanticCache
               )

      assert {:error, {:invalid_semantic_cache_adapter, 123}} =
               SemanticCache.clear(agent, semantic_cache: 123)

      assert {:error, {:invalid_agent, "bad"}} = SemanticCache.clear("bad")
    end

    test "contains optional callback exceptions, throws, exits, and invalid replies" do
      result = %{label: :ALPHA, accepted?: true}
      agent = SpectreBranchMatrixTest.CacheAgent

      for {adapter, code} <- [
            {SpectreBranchMatrixTest.InvalidSemanticCache, :invalid_reply},
            {SpectreBranchMatrixTest.RaisingSemanticCache, :exception},
            {SpectreBranchMatrixTest.ThrowingSemanticCache, :throw},
            {SpectreBranchMatrixTest.ExitingSemanticCache, :exit}
          ] do
        assert {:error, put_reason} =
                 SemanticCache.put("alpha", result,
                   semantic_cache: adapter,
                   semantic_learn_failure: :error
                 )

        assert semantic_failure_code(put_reason) == code

        assert {:error, clear_reason} =
                 SemanticCache.clear(agent, semantic_cache: adapter)

        assert semantic_failure_code(clear_reason) == code
      end
    end

    test "review API default arities, missing modules, tuples, and declared errors stay distinct" do
      agent = SpectreBranchMatrixTest.CacheAgent

      assert {:error, :not_found} = SemanticCache.get_example(agent, "missing")
      assert {:error, :not_found} = SemanticCache.relabel(agent, "missing", :ALPHA)
      assert {:error, :not_found} = SemanticCache.delete(agent, "missing")
      assert {:ok, []} = SemanticCache.snapshot(agent)

      assert {:error, {:invalid_agent, URI}} =
               SemanticCache.put("alpha", %{label: :ALPHA}, spectre_agent: URI)

      missing = SpectreBranchMatrixTest.ModuleThatDoesNotExist

      assert {:error, {:invalid_semantic_cache_adapter, ^missing}} =
               SemanticCache.examples(agent, semantic_cache: missing)

      assert {:error, {:invalid_semantic_cache_adapter, ^missing}} =
               SemanticCache.clear(agent, semantic_cache: missing)

      assert {:ok, [%{id: "one"}]} =
               SemanticCache.examples(agent,
                 semantic_cache: {SpectreBranchMatrixTest.FullSemanticCache, :lookup}
               )

      assert {:error, {:invalid_semantic_cache_adapter, 123}} =
               SemanticCache.examples(agent, semantic_cache: 123)

      errors = SpectreBranchMatrixTest.ErrorSemanticCache
      assert {:error, :examples_failed} = SemanticCache.examples(agent, semantic_cache: errors)

      assert {:error, :get_failed} =
               SemanticCache.get_example(agent, "id", semantic_cache: errors)

      assert {:error, :relabel_failed} =
               SemanticCache.relabel(agent, "id", :BETA, semantic_cache: errors)

      assert {:error, :delete_failed} = SemanticCache.delete(agent, "id", semantic_cache: errors)
      assert {:error, :snapshot_failed} = SemanticCache.snapshot(agent, semantic_cache: errors)

      assert {:error, :load_failed} =
               SemanticCache.load_snapshot(agent, [%{}], semantic_cache: errors)

      assert {:error, :load_failed} =
               SemanticCache.load_snapshot(agent, :opaque, semantic_cache: errors)
    end

    test "runtime option exceptions, throws, and exits are sanitized for review and learning" do
      for {agent, code} <- [
            {SpectreBranchMatrixTest.RaisingRouterAgent, :semantic_cache_exception},
            {SpectreBranchMatrixTest.ThrowingRouterAgent, :semantic_cache_failure},
            {SpectreBranchMatrixTest.ExitingRouterAgent, :semantic_cache_exit}
          ] do
        assert {:error, reason} = SemanticCache.examples(agent)
        assert elem(reason, 0) == code

        assert {:error, put_reason} =
                 SemanticCache.put("alpha", %{label: :ALPHA}, spectre_agent: agent)

        assert elem(put_reason, 0) == code
      end
    end
  end

  describe "remaining lifecycle branches" do
    test "covers replay, missing ids, invalid resolutions, and absent awaitables" do
      effect = Effect.stage(%{id: "effect", name: :perform})
      assert {:error, :pending_effect_not_found} = Lifecycle.approve_effect(%State{}, effect.id)

      assert {:error, :pending_effect_not_found} =
               Lifecycle.complete_effect(%State{}, effect.id, :ok)

      assert {:error, :pending_effect_not_found} =
               Lifecycle.fail_effect(%State{}, effect.id, :bad)

      assert {:error, :resolved_effect_not_found} = Lifecycle.replay_effect(%State{}, effect.id)
      assert {:error, :no_open_policy} = Lifecycle.resolve_policy(%State{}, :accept, :yes)

      assert {:error, {:invalid_policy_resolution, :maybe, "yes"}} =
               Lifecycle.resolve_policy(%State{}, :maybe, "yes")

      assert {:error, :awaitable_not_found} = Lifecycle.policy_attempt(%State{}, "missing")
      assert {:error, :awaitable_not_found} = Lifecycle.expire_policy(%State{}, "missing")

      assert {:error, :awaitable_not_found} =
               Lifecycle.replace_awaitable_transition(%State{}, %Awaitable{id: "missing"})

      completed = Effect.complete(effect, :done)
      replay_state = %State{planned_effects: [completed]}
      assert {:ok, %{replayed?: true}} = Lifecycle.replay_effect(replay_state, effect.id)

      assert {:ok, %{replayed?: true}} =
               Lifecycle.complete_effect(replay_state, effect.id, :other)

      assert {:ok, %{replayed?: true}} = Lifecycle.fail_effect(replay_state, effect.id, :other)
      assert {:ok, %{replayed?: true}} = Lifecycle.approve_effect(replay_state, effect.id)
    end

    test "covers policy resolution when the gated effect is missing or has wrong status" do
      open = Awaitable.open_policy(:confirm, "missing", id: "awaitable")
      state = %State{awaitables: [open]}
      assert {:error, :pending_effect_not_found} = Lifecycle.resolve_policy(state, :accept, :yes)
      assert {:error, :pending_effect_not_found} = Lifecycle.resolve_policy(state, :reject, :no)

      pending = Effect.stage(%{id: "pending", name: :perform})

      mismatched = %{
        state
        | awaitables: [%{open | subject_id: pending.id}],
          pending_effects: [pending]
      }

      assert {:error, {:invalid_effect_transition, "pending", :unknown, :approved}} =
               Lifecycle.resolve_policy(mismatched, :accept, :yes)

      assert {:error, {:invalid_effect_transition, "pending", :unknown, :cancelled}} =
               Lifecycle.resolve_policy(mismatched, :reject, :no)

      terminal = %{open | status: :accepted}

      assert {:error, {:invalid_awaitable_transition, "awaitable", :accepted, :attempted}} =
               Lifecycle.policy_attempt(%State{awaitables: [terminal]}, terminal.id)

      assert {:error, {:invalid_awaitable_transition, "awaitable", :accepted, :expired}} =
               Lifecycle.expire_policy(%State{awaitables: [terminal]}, terminal.id)
    end

    test "expires policies without effects and preserves terminal awaitables on cancellation" do
      open = Awaitable.open_policy(:confirm, "missing")
      accepted = Awaitable.accept(Awaitable.open_policy(:other, "other"), :yes)
      state = %State{awaitables: [open, accepted]}

      assert {:ok, expired} = Lifecycle.expire_policy(state, open.id)
      assert expired.effect == nil
      assert expired.awaitable.status == :expired

      assert {:ok, cancelled} = Lifecycle.cancel_pending(state, :shutdown)
      assert Enum.any?(cancelled.to.awaitables, &(&1.status == :cancelled))
      assert Enum.any?(cancelled.to.awaitables, &(&1.status == :accepted))
    end
  end

  defp router_context do
    %RouterContext{
      input: Input.new("text"),
      opts: [],
      labels: [],
      rules: [],
      candidates: [],
      traces: [],
      errors: []
    }
  end

  defp semantic_failure_code(%Spectre.Provider.Failure{kind: kind}), do: kind
  defp semantic_failure_code({:semantic_cache_exception, _, _}), do: :exception
  defp semantic_failure_code({:semantic_cache_exit, _}), do: :exit
  defp semantic_failure_code({:semantic_cache_failure, kind, _}), do: kind
  defp semantic_failure_code(other) when is_tuple(other), do: elem(other, 0)
  defp semantic_failure_code(other), do: other
end
