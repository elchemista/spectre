defmodule SpectreSmallModuleBranchTest.TelemetryHandler do
  @moduledoc false

  def handle(event, measurements, metadata) do
    send(self(), {:telemetry_module, event, measurements, metadata})
  end
end

defmodule SpectreSmallModuleBranchTest.ProtectionAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :protection_agent,
      owner: __MODULE__,
      protections: [
        %{action: :physical_read, policy: :atom_policy},
        %{action: "Actions.selected/2", policy: :tool_policy},
        %{action: {:al, " DELETE   ACCOUNT "}, policy: :al_policy}
      ]
    }
  end
end

defmodule SpectreSmallModuleBranchTest.LegacyLLM do
  @moduledoc false
  def complete(prompt, opts), do: {:ok, "legacy:#{prompt}:#{Keyword.get(opts, :tag, "none")}"}
  def fail(_prompt, _opts), do: {:error, :fallback_failed}
  def invalid(_prompt, _opts), do: :invalid
end

defmodule SpectreSmallModuleBranchTest.StructuredLLM do
  @moduledoc false
  def complete(prompt, _opts), do: {:ok, "string:#{prompt}"}
  def complete_plan(%Spectre.Prompt.Plan{} = plan, _opts), do: {:ok, "plan:#{plan.rendered}"}
end

defmodule SpectreSmallModuleBranchTest.HookCallbacks do
  @moduledoc false

  def zero do
    :ok
  end

  def one(_result) do
    :ok
  end

  def two(_result, _ctx) do
    :ok
  end

  def three(_result, _ctx, _hook) do
    :ok
  end
end

defmodule SpectreSmallModuleBranchTest.HookAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :hook_agent,
      owner: SpectreSmallModuleBranchTest.HookCallbacks,
      after_actions: [
        %{action: :perform, on: :delivered, run: :zero},
        %{action: :perform, on: :delivered, run: :one},
        %{action: :perform, on: :delivered, run: :two},
        %{action: :perform, on: :delivered, run: :three},
        %{action: "perform", on: :ignored, run: :zero}
      ]
    }
  end
end

defmodule SpectreSmallModuleBranchTest.PromptAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :prompt_agent,
      owner: __MODULE__,
      prompt_root: "test/fixtures/strategy_matrix/prompts"
    }
  end
end

defmodule SpectreSmallModuleBranchTest.PromptProviders do
  @moduledoc false
  def zero, do: "zero"
  def one(ctx), do: "one:#{ctx.input.text}"
  def two(ctx, opts), do: "two:#{ctx.input.text}:#{Keyword.get(opts, :suffix)}"
  def invalid(_ctx), do: [:invalid]
end

defmodule SpectreSmallModuleBranchTest.SessionAgent do
  @moduledoc false
  use Spectre.Agent

  flow :session do
    on :HELLO, regex: ~r/^hello$/ do
      run(:respond)
    end
  end

  def respond(_input, _ctx), do: {:ok, "hello"}
end

defmodule SpectreSmallModuleBranchTest.MountSkill do
  @moduledoc false

  def definition do
    %Spectre.Definition{kind: :skill, id: :mount_skill, owner: __MODULE__}
  end
end

defmodule SpectreSmallModuleBranchTest do
  use ExUnit.Case, async: false

  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Provider.Failure
  alias Spectre.Provider.Reply

  test "context helpers are immutable and prepend diagnostics" do
    original = %Context{}

    changed =
      original |> Context.put_trace(:routed) |> Context.put_error(:failed) |> Context.halt()

    refute original.halted?
    assert changed.halted?
    assert changed.traces == [:routed]
    assert changed.errors == [:failed]
  end

  test "identity returns UUIDv7 and stable keys for binary and arbitrary terms" do
    assert Spectre.Identity.uuid7() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    assert Spectre.Identity.idempotency_key("known") == "effect:known"

    assert Spectre.Identity.idempotency_key({:composite, 1}) ==
             Spectre.Identity.idempotency_key({:composite, 1})

    assert String.length(Spectre.Identity.idempotency_key({:composite, 1})) == 39
  end

  test "provider failures sanitize every reason and reply shape" do
    assert %Failure{kind: :crash, reason: :boom, retryable?: true} =
             Failure.caught(:llm, :error, {:boom, "private"})

    assert %Failure{reason: :provider_failure} = Failure.crash(:llm, {"private", :data})
    assert %Failure{reason: :timeout} = Failure.crash(:llm, %{reason: {:timeout, "private"}})
    assert %Failure{reason: :provider_failure} = Failure.crash(:llm, %{private: true})
    assert %Failure{reason: {:missing_field, :label}} = Failure.missing_reply_field(:llm, :label)

    shapes = [
      {[], :list},
      {%URI{}, {:struct, URI}},
      {fn -> :secret end, :function},
      {self(), :unknown}
    ]

    Enum.each(shapes, fn {value, shape} ->
      assert %Failure{reason: ^shape} = Failure.invalid_reply(:llm, value)
    end)

    assert %Failure{reason: {:invalid_timeout, :invalid}} =
             Failure.invalid_timeout(:llm, "secret")
  end

  test "provider route replies distinguish missing, malformed and optional fields" do
    valid = %{accepted?: true, label: :ALPHA}
    assert {:ok, ^valid} = Reply.route(:classifier, valid)

    assert {:ok, %{accepted?: false}} =
             Reply.route(:classifier, %{accepted?: false}, label: :accepted)

    assert {:ok, _} =
             Reply.route(:classifier, Map.merge(valid, %{confidence: nil, scores: %{ALPHA: 1}}))

    invalid = [
      %{},
      %{accepted?: :yes, label: :ALPHA},
      %{accepted?: true},
      %{accepted?: true, label: "  "},
      %{accepted?: true, label: 123},
      %{accepted?: true, label: :ALPHA, confidence: "high"},
      %{accepted?: true, label: :ALPHA, terminal?: nil},
      %{accepted?: true, label: :ALPHA, strategy: "classifier"},
      %{accepted?: true, label: :ALPHA, metadata: []},
      %{accepted?: true, label: :ALPHA, scores: []},
      %{accepted?: true, label: :ALPHA, scores: %{nil => 1.0}},
      %{accepted?: true, label: :ALPHA, scores: %{"" => 1.0}},
      %{accepted?: true, label: :ALPHA, scores: %{ALPHA: :high}}
    ]

    Enum.each(invalid, fn reply ->
      assert {:error, %Failure{kind: :invalid_reply}} = Reply.route(:classifier, reply)
    end)
  end

  test "telemetry accepts function and MFA handlers and contains their failures" do
    parent = self()

    assert :ok =
             Spectre.Telemetry.emit([:coverage], %{count: 1}, %{safe: true},
               telemetry_handler: fn event, measurements, metadata ->
                 send(parent, {:telemetry_fun, event, measurements, metadata})
               end
             )

    assert_receive {:telemetry_fun, [:spectre, :coverage], %{count: 1}, %{safe: true}}

    assert :ok =
             Spectre.Telemetry.emit([:coverage], %{}, %{},
               telemetry_handler: {SpectreSmallModuleBranchTest.TelemetryHandler, :handle}
             )

    assert_receive {:telemetry_module, [:spectre, :coverage], %{}, %{}}
    assert :ok = Spectre.Telemetry.emit([:coverage], %{}, %{}, telemetry_handler: :invalid)
    assert :ok = Spectre.Telemetry.emit(:invalid, [], [], :invalid)

    assert :ok =
             Spectre.Telemetry.emit([:coverage], %{}, %{},
               telemetry_handler: fn _, _, _ -> raise "handler" end
             )

    assert :ok =
             Spectre.Telemetry.emit([:coverage], %{}, %{},
               telemetry_handler: fn _, _, _ -> throw(:handler) end
             )
  end

  test "effect normalization handles selected tools, AL, structs and unknown atoms" do
    assert "Remote.delete/1" ==
             Effect.effect_key(%Effect{payload: %{selected_tool: "Remote.delete/1"}})

    from_struct = Effect.stage(%Effect{name: "binary_action", scope: :agent})
    assert from_struct.name == "binary_action"

    assert %Effect{name: nil} =
             Effect.stage(%{
               selected_tool: "Unknown.Coverage.spectre_coverage_missing_action/1",
               scope: :agent
             })

    assert %Effect{name: nil} = Effect.stage(%{al: "   ", scope: :agent})
    assert %Effect{name: nil} = Effect.stage(%{scope: :agent})
  end

  test "action protection matches logical atoms, selected tools, AL and scope isolation" do
    agent = SpectreSmallModuleBranchTest.ProtectionAgent

    assert :atom_policy ==
             Spectre.ActionProtection.protected_by(
               agent,
               %Effect{name: :physical_read, scope: :agent}
             )

    assert :atom_policy ==
             Spectre.ActionProtection.protected_by(
               agent,
               %Effect{
                 name: nil,
                 scope: :agent,
                 payload: %{selected_tool: "Actions.physical_read/2"}
               }
             )

    assert :tool_policy ==
             Spectre.ActionProtection.protected_by(
               agent,
               %Effect{
                 name: nil,
                 scope: :agent,
                 payload: %{selected_tool: "Actions.selected/2"}
               }
             )

    assert :al_policy ==
             Spectre.ActionProtection.protected_by(
               agent,
               %Effect{name: nil, scope: :agent, payload: %{al: "delete account"}}
             )

    assert nil ==
             Spectre.ActionProtection.protected_by(
               agent,
               %Effect{name: :other, scope: {:skill, :missing}}
             )
  end

  test "evaluation cases reject invalid values independently and canonicalize labels" do
    valid = %{id: "case", input: "hello"}
    assert {:ok, evaluation_case} = EvalCase.new(valid)
    assert {:ok, ^evaluation_case} = EvalCase.new(evaluation_case)
    assert nil == EvalCase.canonical(nil)
    assert "HELLO_WORLD" == EvalCase.canonical(" hello-world ")

    assert {:ok, enriched} =
             EvalCase.new(%{
               "id" => "full",
               "input" => %{text: "hello"},
               "expected_outcome" => "clarify",
               "llm" => :required,
               "expected_route" => :alpha,
               "allowed_routes" => [:beta, "gamma"],
               "expected_strategy" => :regex,
               "state" => [flow: :one],
               "tags" => ["one", "one"],
               "max_duration_us" => 1
             })

    assert EvalCase.expected_routes(enriched) == ["ALPHA", "BETA", "GAMMA"]

    invalid = [
      :not_a_map,
      %{},
      %{id: 1, input: "x"},
      %{id: "x"},
      %{id: "x", input: 1},
      Map.put(valid, :expected_outcome, %{bad: true}),
      Map.put(valid, :expected_outcome, :unsupported),
      Map.put(valid, :llm, 123),
      Map.put(valid, :llm, "unsupported"),
      Map.put(valid, :expected_route, 1),
      Map.put(valid, :allowed_routes, :alpha),
      Map.put(valid, :allowed_routes, [1]),
      Map.put(valid, :expected_strategy, []),
      Map.put(valid, :state, :bad),
      Map.put(valid, :tags, :bad),
      Map.put(valid, :tags, [:bad]),
      Map.put(valid, :max_duration_us, 0),
      Map.put(valid, :max_duration_us, "fast")
    ]

    Enum.each(invalid, fn item -> assert {:error, _reason} = EvalCase.new(item) end)
  end

  test "LLM boundary negotiates adapter sources, plans, functions and fallback failures" do
    alias Spectre.LLM
    alias Spectre.Prompt.Plan

    assert {:error, :missing_llm_adapter} = LLM.complete("missing")

    assert {:ok, "legacy:adapter:none"} =
             LLM.complete("adapter", adapter: SpectreSmallModuleBranchTest.LegacyLLM)

    previous = Application.get_env(:spectre, :llm_adapter)
    Application.put_env(:spectre, :llm_adapter, SpectreSmallModuleBranchTest.LegacyLLM)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spectre, :llm_adapter, previous),
        else: Application.delete_env(:spectre, :llm_adapter)
    end)

    assert {:ok, "legacy:configured:none"} = LLM.complete("configured")
    assert {:ok, plan} = Plan.compose("TASK", [], [:agent])

    assert {:ok, "plan:TASK"} =
             LLM.complete(plan, model: SpectreSmallModuleBranchTest.StructuredLLM)

    assert {:ok, "string:TASK"} =
             LLM.complete(plan,
               model: SpectreSmallModuleBranchTest.StructuredLLM,
               prompt_format: :string
             )

    assert {:error, {:unsupported_prompt_format, _, :plan}} =
             LLM.complete(plan,
               model: SpectreSmallModuleBranchTest.LegacyLLM,
               prompt_format: :plan
             )

    assert {:ok, "function:TASK"} =
             LLM.complete(plan,
               model: fn %Plan{rendered: rendered}, _opts -> {:ok, "function:#{rendered}"} end,
               prompt_format: :plan
             )

    assert {:ok, "one:plain"} =
             LLM.complete("plain", model: fn prompt -> {:ok, "one:#{prompt}"} end)

    assert {:error, {:invalid_model, 123}} = LLM.complete("plain", model: 123)

    assert {:error, :invalid_prompt_format} =
             LLM.complete(plan, model: fn _ -> {:ok, "x"} end, prompt_format: :invalid)

    assert {:error, {:llm_fallback_failed, :primary, :fallback_failed}} =
             LLM.complete("fallback",
               model: fn _ -> {:error, :primary} end,
               fallback: {SpectreSmallModuleBranchTest.LegacyLLM, :fail}
             )

    assert {:error, %Failure{kind: :invalid_reply}} =
             LLM.complete("invalid", model: {SpectreSmallModuleBranchTest.LegacyLLM, :invalid})
  end

  test "execution rejects invalid durable origins and replays terminal effects" do
    agent = SpectreSmallModuleBranchTest.ProtectionAgent
    context = %{agent: agent, input: Spectre.Input.new(""), opts: []}
    base = Effect.stage_action(%{id: "effect", name: :perform}, agent, :agent)

    assert {:ok, %{events: [%{type: :effect_missing}]}} =
             Spectre.Execution.execute_pending(%Spectre.State{}, context)

    cases = [
      {%{base | status: :completed}, {:effect_not_executable, "effect", :completed}, context},
      {%{base | kind: :retrieval}, {:unsupported_effect_kind, :retrieval}, context},
      {%{base | scope: nil}, {:effect_scope_missing, "effect"}, context},
      {base, {:effect_agent_missing, "effect"}, %{}},
      {%{base | scope: {:skill, :missing}}, :effect_scope_unresolvable, context},
      {%{base | owner: String}, {:effect_owner_mismatch, "effect", String, agent}, context}
    ]

    Enum.each(cases, fn {effect, expected, ctx} ->
      state = %Spectre.State{pending_effects: [effect], planned_effects: [effect]}
      assert {:error, reason} = Spectre.Execution.execute_pending(state, ctx)

      if expected == :effect_scope_unresolvable,
        do: assert(match?({:effect_scope_unresolvable, "effect", {:skill, :missing}, _}, reason)),
        else: assert(reason == expected)
    end)

    terminal = Effect.complete(base, {:ok, "already done"})
    replay_state = %Spectre.State{pending_effects: [base], planned_effects: [terminal]}

    assert {:ok, %{reply_text: "already done", events: [%{type: :effect_already_resolved}]}} =
             Spectre.Execution.execute_pending(replay_state, context)
  end

  test "action hooks execute module and function arities and aggregate invalid replies" do
    agent = SpectreSmallModuleBranchTest.HookAgent

    function_hooks = [
      %{action: :perform, on: :delivered, run: fn -> :ok end},
      %{action: :perform, on: :delivered, run: fn _result -> {:ok, :done} end},
      %{action: :perform, on: :delivered, run: fn _result, _ctx -> :ok end},
      %{action: :perform, on: :delivered, run: fn _result, _ctx, _hook -> :ok end}
    ]

    completed =
      Effect.stage_action(
        %{name: :perform, payload: %{hooks: function_hooks}},
        agent,
        :agent
      )
      |> Effect.complete({:ok, :value})

    ignored = %Effect{kind: :retrieval, status: :completed}
    result = %Spectre.Result{effects: [completed, ignored], input: Spectre.Input.new("input")}

    assert :ok = Spectre.ActionHooks.run(agent, :delivered, result, %{}, hook_timeout: 100)

    bad = %{completed | payload: %{hooks: [%{action: :perform, on: :delivered, run: :invalid}]}}

    assert {:error, [{:invalid_after_action_hook, :invalid}]} =
             Spectre.ActionHooks.run(agent, :delivered, %{result | effects: [bad]}, %Context{})
  end

  test "prompt boundary resolves assets and provider arities while containing malformed operations" do
    alias Spectre.Prompt
    alias Spectre.Prompt.Operation

    agent = SpectreSmallModuleBranchTest.PromptAgent
    providers = SpectreSmallModuleBranchTest.PromptProviders
    ctx = %{input: Spectre.Input.new("hello"), state: %Spectre.State{}, assigns: %{}}

    assert {:ok, rendered} = Prompt.render(agent, :base, ctx)
    assert rendered =~ "BASE"
    assert {:ok, asset} = Prompt.render_asset(agent, :base, ctx)
    assert asset =~ "BASE"
    assert {:ok, %Spectre.Prompt.Plan{}} = Prompt.build(agent, :base, ctx)

    assert {:error, {:invalid_prompt, 123}} = Prompt.resolve(agent, 123, ctx)
    assert {:error, {:prompt_outside_root, _, _}} = Prompt.resolve(agent, "../outside", ctx)

    operations = [
      Operation.new(:zero, into: :context, from: {providers, :zero}),
      Operation.new(:one, into: :context, from: {providers, :one}),
      Operation.new(:two, into: :context, from: {providers, :two}, suffix: "ok"),
      Operation.new(:condition_zero,
        into: :context,
        from: {providers, :zero},
        when: fn -> true end
      ),
      Operation.new(:condition_one,
        into: :context,
        from: {providers, :zero},
        when: fn received -> received.input.text == "hello" end
      ),
      Operation.new(:condition_two,
        into: :context,
        from: {providers, :zero},
        when: fn _received, opts -> Keyword.keyword?(opts) end
      ),
      Operation.new(:skipped, into: :context, from: {providers, :zero}, when: fn -> false end)
    ]

    assert {:ok, plan} = Prompt.build(agent, :base, ctx, runtime_inject: operations)
    assert plan.rendered =~ "zero"
    assert plan.rendered =~ "one:hello"
    assert plan.rendered =~ "two:hello:ok"
    assert Enum.any?(plan.operations, &(&1.id == :skipped and &1.status == :skipped))

    duplicate = Operation.new(:duplicate, into: :context, from: {providers, :zero})

    assert {:error, {:duplicate_prompt_operation, :runtime, :duplicate}} =
             Prompt.build(agent, :base, ctx, runtime_inject: [duplicate, duplicate])

    assert {:error, {:invalid_prompt_operation, _message}} =
             Prompt.build(agent, :base, ctx, runtime_inject: 123)

    missing = Operation.new(:missing, into: :context, from: {providers, :missing})

    assert {:error,
            {:prompt_operation_failed, :missing, {:undefined_prompt_provider, _, :missing}}} =
             Prompt.build(agent, :base, ctx, runtime_inject: missing)

    optional_invalid =
      Operation.new(:optional_invalid,
        into: :context,
        from: {providers, :invalid},
        required: false
      )

    assert {:ok, optional_plan} =
             Prompt.build(agent, :base, ctx, runtime_inject: optional_invalid)

    assert Enum.any?(
             optional_plan.operations,
             &(&1.id == :optional_invalid and &1.status == :skipped)
           )

    oversized = Operation.new(:oversized, into: :context, from: {providers, :zero}, max_bytes: 1)

    assert {:error, {:prompt_operation_failed, :oversized, {:prompt_fragment_too_large, _, 1}}} =
             Prompt.build(agent, :base, ctx, runtime_inject: oversized)

    assert {:error, {:prompt_too_large, _, 1}} =
             Prompt.build(agent, :base, ctx, prompt_max_bytes: 1)

    protected = Operation.new(:replace_task, into: :task, position: :replace)

    assert {:ok, protected_plan} =
             Prompt.build(agent, "base.text.heex", ctx,
               runtime_inject: protected,
               policy_prompt?: true,
               policy: :safe
             )

    assert Enum.any?(protected_plan.operations, &(&1.reason == :protected_policy_prompt))
  end

  test "prompt conditions sanitize all non-boolean reply shapes" do
    alias Spectre.Prompt
    alias Spectre.Prompt.Operation

    agent = SpectreSmallModuleBranchTest.PromptAgent
    ctx = %{input: Spectre.Input.new("hello"), state: %Spectre.State{}}

    invalid_replies = [
      "binary",
      :atom,
      [:list],
      %URI{},
      %{map: true},
      {:tuple, :value},
      self()
    ]

    Enum.each(invalid_replies, fn reply ->
      operation =
        Operation.new(:condition,
          into: :context,
          from: {SpectreSmallModuleBranchTest.PromptProviders, :zero},
          when: fn -> reply end
        )

      assert {:error,
              {:prompt_operation_failed, :condition, {:invalid_prompt_condition_reply, _}}} =
               Prompt.build(agent, :base, ctx, runtime_inject: operation)
    end)

    operation =
      Operation.new(:condition_error,
        into: :context,
        from: {SpectreSmallModuleBranchTest.PromptProviders, :zero},
        when: fn -> {:error, :denied} end
      )

    assert {:error, {:prompt_operation_failed, :condition_error, :denied}} =
             Prompt.build(agent, :base, ctx, runtime_inject: operation)
  end

  test "small compatibility boundaries cover defaults and malformed vector data" do
    assert :ok = Spectre.Telemetry.emit([:default])
    assert [] == Spectre.Classifier.Math.centroid([])
    assert 0.0 == Spectre.Classifier.Math.raw_cosine_score({:error, :bad})
    assert 0.0 == Spectre.Classifier.Math.raw_cosine_score(:bad)
    assert [0.0, 0.0] == Spectre.Classifier.Math.normalize([0.0, 0.0])

    context = %Spectre.Router.Context{}
    assert {:cont, ^context} = Spectre.Router.Plugs.Terminalize.call(context, [])

    assert {:ok, %{events: [%{type: :effect_missing}]}} =
             Spectre.ActionExecutor.execute_pending(
               %Spectre.State{},
               %{agent: SpectreSmallModuleBranchTest.SessionAgent}
             )

    record = Spectre.Journal.Record.new(phase: :coverage)
    assert {:ok, ^record} = Spectre.Journal.Record.restore(record)
    assert {:error, {:invalid_journal_record, :bad}} = Spectre.Journal.Record.restore(:bad)

    skill = SpectreSmallModuleBranchTest.MountSkill.definition()

    assert %Spectre.Skill.Mount{bindings: %{logical_read: :physical_read}} =
             Spectre.Skill.Mount.new(
               SpectreSmallModuleBranchTest.MountSkill,
               skill,
               bind: %{logical_read: :physical_read}
             )

    assert_raise ArgumentError, fn ->
      Spectre.Skill.Mount.new(SpectreSmallModuleBranchTest.MountSkill, skill, bind: :invalid)
    end
  end

  test "session defaults reject stale execution references and replay resolved effects" do
    agent = SpectreSmallModuleBranchTest.SessionAgent

    session =
      start_supervised!({Spectre.Session, agent: agent, state: %Spectre.State{}, idle: false})

    assert {:ok, %Spectre.Result{reply_text: "hello"}} = Spectre.Session.ask(session, "hello")
    assert {:ok, %Spectre.Turn{}} = Spectre.Session.turn(session, "hello")
    assert :ok = Spectre.Session.reset(session)

    empty = %Spectre.Result{state: %Spectre.State{}}
    assert {:error, :no_pending_effect} = Spectre.Session.execute(session, empty)

    current = Effect.stage(%{id: "current", name: :perform})
    assert :ok = Spectre.Session.reset(session, %Spectre.State{pending_effects: [current]})

    assert {:error, {:stale_execution_result, :missing_effect}} =
             Spectre.Session.execute(session, empty)

    submitted = Effect.stage(%{id: "submitted", name: :perform})
    supplied = %Spectre.Result{state: %Spectre.State{pending_effects: [submitted]}}

    assert :ok = Spectre.Session.reset(session, %Spectre.State{})

    assert {:error, {:stale_execution_result, "submitted"}} =
             Spectre.Session.execute(session, supplied)

    assert :ok = Spectre.Session.reset(session, %Spectre.State{pending_effects: [current]})

    assert {:error, {:stale_execution_result, "submitted", "current"}} =
             Spectre.Session.execute(session, supplied)

    for terminal <- [
          Effect.complete(submitted, "done"),
          Effect.complete(submitted, %{done: true}),
          Effect.fail(submitted, :failed)
        ] do
      assert :ok =
               Spectre.Session.reset(session, %Spectre.State{planned_effects: [terminal]})

      assert {:ok, %Spectre.Result{events: [%{type: :effect_already_resolved}]}} =
               Spectre.Session.execute(session, supplied)
    end

    send(session, {:idle_shutdown, -1})
    send(session, :idle_shutdown)
    assert %Spectre.State{} = Spectre.Session.state(session)
  end

  test "dynamic supervisor default APIs summon and dismiss an isolated session" do
    name = SpectreSmallModuleBranchTest.DynamicSupervisor
    start_supervised!({Spectre.Supervisor, name: name})

    assert {:ok, session} =
             Spectre.Supervisor.summon(
               name,
               SpectreSmallModuleBranchTest.SessionAgent,
               state: %Spectre.State{}
             )

    assert Process.alive?(session)
    assert :ok = Spectre.Supervisor.dismiss(name, session)
    refute Process.alive?(session)
  end

  test "router candidate defaults retain raw string intents and context errors" do
    candidate =
      Spectre.Router.Candidate.from_result(
        %{"intent" => "ALPHA", accepted?: true, confidence: 0.7},
        nil,
        :classifier
      )

    assert candidate.label == "ALPHA"
    assert candidate.strength == :medium

    assert %Spectre.Route{label: "ALPHA", labels: []} =
             Spectre.Router.Candidate.to_route(candidate)

    context = %Spectre.Router.Context{opts: [], candidates: []}
    assert Spectre.Router.Context.hard_candidate_locked?(context) == false
    assert [%{reason: :bad}] = Spectre.Router.Context.put_error(context, %{reason: :bad}).errors
  end
end
