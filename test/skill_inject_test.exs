defmodule SpectreSkillInjectTest.LLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:skill_prompt, prompt})
    {:ok, "MODEL_REPLY"}
  end
end

defmodule SpectreSkillInjectTest.ContextProvider do
  @moduledoc false

  def account(ctx, _opts), do: {:ok, "DYNAMIC_CONTEXT #{ctx.input.text}"}
  def unavailable(_ctx), do: {:error, :context_unavailable}
  def disabled?(_ctx), do: false

  def slow(_ctx) do
    receive do
      :never -> "never"
    end
  end

  def explode(_ctx), do: raise("provider exploded")
  def oversized(_ctx), do: String.duplicate("x", 128)
  def invalid(_ctx), do: %{not: :text}
end

defmodule SpectreSkillInjectTest.Actions do
  @moduledoc false

  def publish_report(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:published, args})
    {:ok, args}
  end
end

defmodule SpectreSkillInjectTest.SupportSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :support,
    version: 1,
    prompt_root: "test/fixtures/skill_inject/skill"

  requires_action(:publish, mode: :write)

  inject(:skill_start, into: :instructions, position: :start)
  inject(:skill_end, into: :instructions, position: :end)

  policy :confirm_publish do
    request(:confirm_publish)
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  protect(:publish, with: :confirm_publish)

  flow :support do
    inject(:flow_start, into: :task, position: :start)
    inject(:flow_end, into: :task, position: :end)

    on :SKILL_ASK, regex: ~r/^skill ask$/ do
      ask(:base,
        inject: [
          [prompt: :handler_replace, into: :task, position: :replace]
        ]
      )
    end

    on :SKILL_RUN, regex: ~r/^skill run$/ do
      run(:handle_locally)
    end

    on :SKILL_ACTION, regex: ~r/^skill action$/ do
      action(:publish, args: %{source: :skill})
    end
  end

  def handle_locally(input, ctx) do
    {:ok,
     %Spectre.Result{
       input: input,
       route: ctx.route,
       state: ctx.state,
       reply_text: "SKILL_RUN_REPLY"
     }}
  end
end

defmodule SpectreSkillInjectTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/skill_inject/agent"

  model(SpectreSkillInjectTest.LLM)
  actions(SpectreSkillInjectTest.Actions)

  inject(:agent_start, into: :instructions, position: :start)
  inject(:agent_end, into: :instructions, position: :end)

  inject(:account,
    from: {SpectreSkillInjectTest.ContextProvider, :account},
    into: :context,
    position: :end
  )

  inject(:optional,
    from: {SpectreSkillInjectTest.ContextProvider, :unavailable},
    into: :context,
    position: :end,
    required: false
  )

  inject(:disabled,
    from: {SpectreSkillInjectTest.ContextProvider, :account},
    into: :context,
    position: :end,
    when: {SpectreSkillInjectTest.ContextProvider, :disabled?}
  )

  skill(SpectreSkillInjectTest.SupportSkill,
    as: :support,
    bind: [publish: :publish_report]
  )
end

defmodule SpectreSkillInjectTest.OuterProtectedAgent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/skill_inject/agent"

  model(SpectreSkillInjectTest.LLM)
  actions(SpectreSkillInjectTest.Actions)

  policy :agent_confirm do
    request(:agent_confirm)
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  protect(:publish_report, with: :agent_confirm)

  skill(SpectreSkillInjectTest.SupportSkill,
    as: :support,
    bind: [publish: :publish_report]
  )
end

defmodule SpectreSkillInjectTest.AlternateSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :alternate,
    prompt_root: "test/fixtures/skill_inject/skill"

  flow :support do
    on :SKILL_RUN, regex: ~r/^alternate run$/ do
      run(:handle_locally)
    end
  end

  def handle_locally(input, ctx) do
    {:ok,
     %Spectre.Result{
       input: input,
       route: ctx.route,
       state: ctx.state,
       reply_text: "ALTERNATE_RUN_REPLY"
     }}
  end
end

defmodule SpectreSkillInjectTest.MultiSkillAgent do
  @moduledoc false

  use Spectre.Agent

  skill(SpectreSkillInjectTest.SupportSkill,
    as: :primary,
    bind: [publish: :publish_report]
  )

  skill(SpectreSkillInjectTest.AlternateSkill, as: :alternate)
end

defmodule SpectreSkillInjectTest do
  use ExUnit.Case, async: false

  alias SpectreSkillInjectTest.Agent

  test "a mounted Skill routes and runs its owner callback" do
    assert {:ok, result} = Spectre.ask(Agent, "skill run")
    assert result.reply_text == "SKILL_RUN_REPLY"
    assert result.route.owner == SpectreSkillInjectTest.SupportSkill
    assert result.route.scope == {:skill, :support}
  end

  test "multiple Skills may reuse local flow and label names without losing ownership" do
    assert {:ok, primary} = Spectre.ask(SpectreSkillInjectTest.MultiSkillAgent, "skill run")
    assert primary.reply_text == "SKILL_RUN_REPLY"
    assert primary.route.owner == SpectreSkillInjectTest.SupportSkill
    assert primary.route.scope == {:skill, :primary}

    assert {:ok, alternate} =
             Spectre.ask(SpectreSkillInjectTest.MultiSkillAgent, "alternate run")

    assert alternate.reply_text == "ALTERNATE_RUN_REPLY"
    assert alternate.route.owner == SpectreSkillInjectTest.AlternateSkill
    assert alternate.route.scope == {:skill, :alternate}
  end

  test "inject composes nested scopes and handler replacement deterministically" do
    assert {:ok, result} = Spectre.ask(Agent, "skill ask", test_pid: self())
    assert_receive {:skill_prompt, prompt}
    assert result.reply_text == "MODEL_REPLY"

    ordered = [
      "AGENT_START",
      "SKILL_START",
      "SKILL_END",
      "AGENT_END",
      "DYNAMIC_CONTEXT skill ask",
      "FLOW_START",
      "HANDLER_REPLACE skill ask",
      "FLOW_END"
    ]

    offsets = Enum.map(ordered, fn fragment -> prompt |> :binary.match(fragment) |> elem(0) end)
    assert offsets == Enum.sort(offsets)
    refute prompt =~ "BASE_TASK"
    refute prompt =~ "context_unavailable"

    operations = result.metadata.prompt_plan.operations
    assert Enum.any?(operations, &(&1.id == :optional and &1.status == :skipped))
    assert Enum.any?(operations, &(&1.id == :disabled and &1.status == :skipped))
    assert Enum.any?(operations, &(&1.id == :handler_replace and &1.status == :applied))
    assert is_binary(result.metadata.prompt_plan.hash)
  end

  test "runtime injections remain a distinct outer scope around handler injections" do
    runtime_inject = [
      [prompt: :runtime_start, into: :task, position: :start],
      [prompt: :runtime_end, into: :task, position: :end]
    ]

    assert {:ok, result} =
             Spectre.ask(Agent, "skill ask", test_pid: self(), inject: runtime_inject)

    assert_receive {:skill_prompt, prompt}

    ordered = [
      "RUNTIME_START",
      "FLOW_START",
      "HANDLER_REPLACE skill ask",
      "FLOW_END",
      "RUNTIME_END"
    ]

    offsets = Enum.map(ordered, fn fragment -> prompt |> :binary.match(fragment) |> elem(0) end)
    assert offsets == Enum.sort(offsets)

    assert Enum.any?(result.metadata.prompt_plan.operations, fn operation ->
             operation.id == :runtime_start and operation.scope == :runtime
           end)

    assert Enum.any?(result.metadata.prompt_plan.operations, fn operation ->
             operation.id == :handler_replace and
               operation.scope == {:handler, {:skill, :support}, :SKILL_ASK}
           end)
  end

  test "bound Skill actions retain scoped policies and execute through the Agent adapter" do
    assert {:ok, awaiting} = Spectre.ask(Agent, "skill action", test_pid: self())
    assert_receive {:skill_prompt, prompt}
    assert prompt =~ "CONFIRM_PUBLISH"

    assert [%Spectre.Effect{name: :publish_report, mode: :write, status: :waiting_policy}] =
             awaiting.state.pending_effects

    assert %Spectre.Awaitable{
             name: {{:skill, :support}, :confirm_publish},
             status: :open
           } = Spectre.Result.open_awaitable(awaiting)

    assert {:ok, approved} =
             Spectre.ask(Agent, "yes", state: awaiting.state, test_pid: self())

    assert %Spectre.Effect{name: :publish_report, status: :approved} =
             Spectre.Result.pending_effect(approved)

    assert {:ok, completed} = Spectre.execute(Agent, approved, test_pid: self())
    assert Spectre.Result.action_outcome(completed) == {:ok, %{source: :skill}}
    assert_receive {:published, %{source: :skill}}
  end

  test "an outer Agent protection takes precedence after logical action binding" do
    agent = SpectreSkillInjectTest.OuterProtectedAgent

    assert {:ok, awaiting} = Spectre.ask(agent, "skill action", test_pid: self())
    assert_receive {:skill_prompt, prompt}
    assert prompt =~ "AGENT_CONFIRM"

    assert %Spectre.Awaitable{name: :agent_confirm, status: :open} =
             Spectre.Result.open_awaitable(awaiting)

    refute prompt =~ "CONFIRM_PUBLISH"
  end

  test "prompt paths cannot escape the active definition root" do
    input = Spectre.Input.new("escape")
    ctx = %Spectre.Context{agent: Agent, input: input, state: %Spectre.State{}, opts: []}

    assert {:error, {:prompt_outside_root, _path, _root}} =
             Spectre.Prompt.resolve(Agent, "../skill/base.text.heex", ctx)
  end

  test "missing logical action bindings fail while compiling the Agent" do
    module = Module.concat(__MODULE__, "MissingBinding#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/requires a binding for :publish/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Spectre.Agent
        skill SpectreSkillInjectTest.SupportSkill
      end
      """)
    end
  end

  test "malformed or undeclared Skill bindings fail while compiling the Agent" do
    invalid_target =
      Module.concat(__MODULE__, "InvalidTarget#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/invalid_skill_binding.*publish.*"publish_report"/, fn ->
      Code.compile_string("""
      defmodule #{inspect(invalid_target)} do
        use Spectre.Agent
        skill SpectreSkillInjectTest.SupportSkill,
          bind: [publish: "publish_report"]
      end
      """)
    end

    undeclared =
      Module.concat(__MODULE__, "UndeclaredBinding#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/invalid_skill_binding.*undeclared/, fn ->
      Code.compile_string("""
      defmodule #{inspect(undeclared)} do
        use Spectre.Agent
        skill SpectreSkillInjectTest.SupportSkill,
          bind: [publish: :publish_report, undeclared: :other_action]
      end
      """)
    end
  end

  test "a Skill cannot invoke an action it did not declare as a requirement" do
    module = Module.concat(__MODULE__, "UndeclaredAction#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/must be declared with requires_action/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Spectre.Skill, id: :unsafe_skill

        flow :unsafe do
          on :DANGER, regex: ~r/danger/ do
            action :danger
          end
        end
      end
      """)
    end
  end

  test "duplicate unconditional replacements fail while compiling a definition" do
    module = Module.concat(__MODULE__, "DuplicateReplace#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/multiple unconditional prompt replacements/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Spectre.Agent
        inject :first, into: :task, position: :replace
        inject :second, into: :task, position: :replace
      end
      """)
    end
  end

  test "multiple conditional replacements that become active fail explicitly" do
    input = Spectre.Input.new("skill ask")
    state = %Spectre.State{}
    base_ctx = %Spectre.Context{agent: Agent, input: input, state: state, opts: []}
    assert {:ok, route} = Spectre.Router.route(input, base_ctx)
    ctx = %{base_ctx | route: route}

    inject = [
      [
        prompt: :handler_replace,
        into: :task,
        position: :replace,
        when: fn _ctx -> true end
      ],
      [prompt: :base, into: :task, position: :replace, when: fn _ctx -> true end]
    ]

    assert {:error,
            {:multiple_prompt_replacements, {:handler, {:skill, :support}, :SKILL_ASK}, :task}} =
             Spectre.Prompt.build(Agent, :base, ctx, inject: inject)
  end

  test "dynamic provider content cannot be promoted to instructions" do
    module = Module.concat(__MODULE__, "UnsafeProvider#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/dynamic inject providers may only target :context/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Spectre.Agent
        inject :unsafe,
          from: {SpectreSkillInjectTest.ContextProvider, :account},
          into: :instructions
      end
      """)
    end
  end

  test "required provider timeouts and optional provider failures are normalized" do
    input = Spectre.Input.new("skill ask")
    state = %Spectre.State{}
    base_ctx = %Spectre.Context{agent: Agent, input: input, state: state, opts: []}
    assert {:ok, route} = Spectre.Router.route(input, base_ctx)
    ctx = %{base_ctx | route: route}

    required = [
      prompt: :slow,
      from: {SpectreSkillInjectTest.ContextProvider, :slow},
      into: :context
    ]

    assert {:error,
            {:prompt_operation_failed, :slow,
             %Spectre.Provider.Failure{provider: :prompt, kind: :timeout}}} =
             Spectre.Prompt.build(Agent, :base, ctx,
               inject: required,
               prompt_timeout: 5
             )

    optional = [
      [
        prompt: :explode,
        from: {SpectreSkillInjectTest.ContextProvider, :explode},
        into: :context,
        required: false
      ],
      [
        prompt: :oversized,
        from: {SpectreSkillInjectTest.ContextProvider, :oversized},
        into: :context,
        max_bytes: 8,
        required: false
      ],
      [
        prompt: :invalid,
        from: {SpectreSkillInjectTest.ContextProvider, :invalid},
        into: :context,
        required: false
      ]
    ]

    assert {:ok, plan} = Spectre.Prompt.build(Agent, :base, ctx, inject: optional)

    assert Enum.any?(plan.operations, fn operation ->
             Map.take(operation, [:id, :status, :reason]) ==
               %{id: :explode, status: :skipped, reason: :exception}
           end)

    assert Enum.any?(plan.operations, fn operation ->
             Map.take(operation, [:id, :status, :reason]) ==
               %{id: :oversized, status: :skipped, reason: :prompt_fragment_too_large}
           end)

    assert Enum.any?(plan.operations, fn operation ->
             Map.take(operation, [:id, :status, :reason]) ==
               %{id: :invalid, status: :skipped, reason: :invalid_prompt_provider_reply}
           end)
  end
end
