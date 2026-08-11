defmodule SpectreAgentDSLContractTest.Arbitrator do
  @moduledoc false
end

defmodule SpectreAgentDSLContractTest.Actions do
  @moduledoc false
end

defmodule SpectreAgentDSLContractTest.ToolSkill do
  @moduledoc false
  use Spectre.Skill, id: :tool_skill

  requires_tool(:search, mode: :write, timeout: 250)

  flow :tools do
    on :SEARCH, regex: ~r/^search$/ do
      reply(:search)
    end
  end
end

defmodule SpectreAgentDSLContractTest.ConfigAgent do
  @moduledoc false

  use Spectre.Agent,
    fail: {:localized_failure, locale: :it},
    arbitrator: SpectreAgentDSLContractTest.Arbitrator
end

defmodule SpectreAgentDSLContractTest.RichAgent do
  @moduledoc false
  use Spectre.Agent

  actions SpectreAgentDSLContractTest.Actions do
    protect(function: :danger, with: :gate)
    protect(custom: :opaque_boundary, with: :gate)
  end

  input_pipeline do
    plug(Spectre.Input.Plugs.NormalizeText)
  end

  policy :gate do
    request(:confirm)
    accept(:confirmed, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
  end

  flow :rich do
    inject(:flow_context, into: :context)

    on :DANGER, regex: ~r/^danger$/ do
      action :danger do
        reply(:completed)
      end
    end
  end
end

defmodule SpectreAgentDSLContractTest.HandlerMacros do
  @moduledoc false
  require Spectre.Agent

  def values do
    [
      Spectre.Agent.ask(:question, temperature: 0.0),
      Spectre.Agent.run(:work, timeout: 20),
      Spectre.Agent.reply(:done, locale: :it),
      Spectre.Agent.action(:deliver, idempotency_key: "stable")
    ]
  end
end

defmodule SpectreAgentDSLContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition
  alias Spectre.Prompt.Operation

  test "tool requirements and handler macros preserve their complete declarations" do
    skill = Definition.fetch!(SpectreAgentDSLContractTest.ToolSkill)

    assert skill.requirements == [
             %{name: :search, mode: :write, opts: [timeout: 250]}
           ]

    assert SpectreAgentDSLContractTest.HandlerMacros.values() == [
             {:__spectre_handler__, :ask, :question, [temperature: 0.0]},
             {:__spectre_handler__, :run, :work, [timeout: 20]},
             {:__spectre_handler__, :reply, :done, [locale: :it]},
             {:__spectre_handler__, :action, :deliver, [idempotency_key: "stable"]}
           ]
  end

  test "agent startup normalizes tuple failure and atom arbitrator settings" do
    config = SpectreAgentDSLContractTest.ConfigAgent.__spectre_config__()
    router = SpectreAgentDSLContractTest.ConfigAgent.__spectre_router__()

    assert config[:fail] == {:localized_failure, locale: :it}
    assert router[:arbitrator] == {SpectreAgentDSLContractTest.Arbitrator, []}
  end

  test "nested action, protection, pipeline, and flow injection declarations compile faithfully" do
    definition = Definition.fetch!(SpectreAgentDSLContractTest.RichAgent)

    assert definition.config[:actions] == {SpectreAgentDSLContractTest.Actions, []}
    assert definition.config[:input_pipeline] == [Spectre.Input.Plugs.NormalizeText]

    assert MapSet.new(Enum.map(definition.protections, & &1.action)) ==
             MapSet.new([
               {:function, :danger},
               [custom: :opaque_boundary]
             ])

    assert [%Operation{id: :flow_context, source_line: line}] =
             hd(definition.rules).injections

    assert is_integer(line)

    assert hd(definition.rules).handler ==
             {:action, :danger, [reply: :completed]}
  end

  test "a Skill rejects Agent-only router ownership at compile time" do
    module = unique_module("SkillWithArbitrator")

    assert_raise ArgumentError, ~r/Skills inherit the Agent router/, fn ->
      compile_module("""
      defmodule #{inspect(module)} do
        use Spectre.Skill, arbitrator: SpectreAgentDSLContractTest.Arbitrator
      end
      """)
    end
  end

  test "mounting a normal Agent as a Skill fails before runtime startup" do
    module = unique_module("InvalidSkillMount")

    assert_raise ArgumentError, ~r/skill expects a module using Spectre.Skill/, fn ->
      compile_module("""
      defmodule #{inspect(module)} do
        use Spectre.Agent
        skill SpectreAgentDSLContractTest.ConfigAgent
      end
      """)
    end
  end

  test "duplicate policies and invalid cache values fail during definition compilation" do
    duplicate = unique_module("DuplicatePolicy")

    assert_raise ArgumentError, ~r/duplicate policy :same/, fn ->
      compile_module("""
      defmodule #{inspect(duplicate)} do
        use Spectre.Agent

        policy :same do
          request :one
        end

        policy :same do
          request :two
        end
      end
      """)
    end

    invalid_cache = unique_module("InvalidCache")

    assert_raise ArgumentError, ~r/cache: accepts only true or false/, fn ->
      compile_module("""
      defmodule #{inspect(invalid_cache)} do
        use Spectre.Agent

        flow :invalid do
          on :ROUTE, cache: :sometimes do
            reply :route
          end
        end
      end
      """)
    end
  end

  test "compact declarations reject a non-keyword do block explicitly" do
    module = unique_module("InvalidInterrupt")

    assert_raise ArgumentError, ~r/expected keyword options with do block/, fn ->
      compile_module("""
      defmodule #{inspect(module)} do
        use Spectre.Agent
        interrupt :STOP, :not_a_keyword
      end
      """)
    end
  end

  test "a flow injection without a target fails at startup instead of producing an invalid plan" do
    module = unique_module("MissingInjectionTarget")

    assert_raise ArgumentError, ~r/inject into: must be one of/, fn ->
      compile_module("""
      defmodule #{inspect(module)} do
        use Spectre.Agent

        flow :invalid do
          inject :context_without_target

          on :ROUTE do
            reply :route
          end
        end
      end
      """)
    end
  end

  test "a one-expression block AST is normalized to the same handler contract" do
    module = unique_module("OneExpressionBlock")

    handler = {:__block__, [], [{:reply, [], [:wrapped]}]}
    regex = Macro.escape(~r/^wrapped$/)

    flow =
      {:flow, [],
       [
         :wrapped,
         [
           do:
             {:on, [],
              [
                :WRAPPED,
                [regex: regex],
                [do: handler]
              ]}
         ]
       ]}

    body =
      quote do
        use Spectre.Agent
        unquote(flow)
      end

    assert {:module, ^module, _binary, _value} =
             Module.create(module, body, Macro.Env.location(__ENV__))

    assert [rule] = module.__spectre_rules__()
    assert rule.handler == {:reply, :wrapped, []}
  end

  test "runtime compilation preserves every closed handler and infrastructure mount" do
    module = unique_module("RuntimeCompiledSurface")

    assert [{^module, _binary}] =
             compile_module("""
             defmodule #{inspect(module)} do
               use Spectre.Agent, id: :runtime_compiled_surface

               action_provider :local, Spectre.Action.Provider.Local, mode: :strict
               checkpoint_store Spectre.Instance.CheckpointStore, namespace: "contract"
               action_planner Spectre.ActionPlanner, strict?: true
               route_operation_events [:completed, :failed]

               def handlers do
                 [
                   ask(:question),
                   reason(:analysis),
                   act(:plan),
                   run(:local),
                   reply(:done),
                   work(Spectre.Execution.Work),
                   action(:deliver),
                   call_operation(:lookup)
                 ]
               end
             end
             """)

    config = module.__spectre_config__()

    assert [%Spectre.Action.Provider.Mount{id: :local, module: Spectre.Action.Provider.Local}] =
             config[:action_providers]

    assert config[:checkpoint_store] ==
             {Spectre.Instance.CheckpointStore, namespace: "contract"}

    assert config[:action_planner] == {Spectre.ActionPlanner, strict?: true}
    assert config[:route_operation_events] == [:completed, :failed]

    assert module.handlers() == [
             {:__spectre_handler__, :ask, :question, []},
             {:__spectre_handler__, :reason, :analysis, []},
             {:__spectre_handler__, :act, :plan, []},
             {:__spectre_handler__, :run, :local, []},
             {:__spectre_handler__, :reply, :done, []},
             {:__spectre_handler__, :work, Spectre.Execution.Work, []},
             {:__spectre_handler__, :action, :deliver, []},
             {:__spectre_handler__, :operation, :lookup, []}
           ]

    invalid_events = unique_module("InvalidOperationEvents")

    assert_raise ArgumentError, ~r/route_operation_events expects/, fn ->
      compile_module("""
      defmodule #{inspect(invalid_events)} do
        use Spectre.Agent
        route_operation_events [:completed, nil]
      end
      """)
    end

    invalid_planner = unique_module("InvalidActionPlanner")

    assert_raise ArgumentError, ~r/action planner must be a module/, fn ->
      compile_module("""
      defmodule #{inspect(invalid_planner)} do
        use Spectre.Agent
        action_planner nil
      end
      """)
    end

    invalid_planner_opts = unique_module("InvalidActionPlannerOptions")

    assert_raise ArgumentError, ~r/action planner options must be a keyword list/, fn ->
      compile_module("""
      defmodule #{inspect(invalid_planner_opts)} do
        use Spectre.Agent
        action_planner Spectre.ActionPlanner, %{bad: true}
      end
      """)
    end
  end

  defp compile_module(source), do: Code.compile_string(source)

  defp unique_module(suffix) do
    Module.concat([
      SpectreAgentDSLContractTest,
      "#{suffix}#{System.unique_integer([:positive, :monotonic])}"
    ])
  end
end
