defmodule SpectreApiBranchCoverageTest.MapDefinition do
  @moduledoc false

  def __spectre_definition__ do
    %{id: :map_definition, kind: :agent, prompt_root: "test/prompts"}
  end
end

defmodule SpectreApiBranchCoverageTest.OwnerlessDefinition do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{id: :ownerless, owner: nil}
  end
end

defmodule SpectreApiBranchCoverageTest.InvalidDefinition do
  @moduledoc false
  def __spectre_definition__, do: [:not, :a, :definition]
end

defmodule SpectreApiBranchCoverageTest.RaisingDefinition do
  @moduledoc false
  def __spectre_definition__, do: raise("definition failed")
end

defmodule SpectreApiBranchCoverageTest.ThrowingDefinition do
  @moduledoc false
  def __spectre_definition__, do: throw(:definition_failed)
end

defmodule SpectreApiBranchCoverageTest.LegacyDefinition do
  @moduledoc false
  def __spectre_config__, do: [prompt_root: "legacy/prompts"]
  def __spectre_router__, do: [via: [:regex]]
  def __spectre_rules__, do: []
  def __spectre_policies__, do: %{safe: %{name: :safe}}
  def __spectre_protections__, do: [%{action: :read, policy: :safe}]
  def __spectre_after_actions__, do: [%{action: :read, run: :after_read}]
end

defmodule SpectreApiBranchCoverageTest.UnknownDefinition do
  @moduledoc false
end

defmodule SpectreApiBranchCoverageTest.SkillDefinition do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      kind: :skill,
      id: :skill,
      owner: __MODULE__,
      prompt_root: "skill/prompts",
      requirements: [%{name: :logical_read, mode: :read}],
      rules: [
        %Spectre.Rule{
          label: :SKILL,
          flow: :skill,
          handler:
            {:action, :logical_read,
             [policy: :safe, hooks: [%{action: :logical_read, run: :after_read}]]}
        }
      ],
      policies: %{safe: %{name: :safe}},
      protections: [%{action: :logical_read, policy: :safe}],
      after_actions: [%{action: :logical_read, run: :after_read}],
      injections: [
        %Spectre.Prompt.Operation{
          id: :skill_context,
          source: {:prompt, :skill_context},
          target: :context
        }
      ]
    }
  end

  def after_read(_value), do: :ok
end

defmodule SpectreApiBranchCoverageTest.ComposedDefinition do
  @moduledoc false

  def __spectre_definition__ do
    skill = SpectreApiBranchCoverageTest.SkillDefinition.__spectre_definition__()

    mount = %Spectre.Skill.Mount{
      id: :mounted,
      module: SpectreApiBranchCoverageTest.SkillDefinition,
      definition_id: skill.id,
      definition_version: skill.version,
      bindings: %{logical_read: :physical_read}
    }

    %Spectre.Definition{
      id: :composed,
      owner: __MODULE__,
      prompt_root: "agent/prompts",
      rules: [
        %Spectre.Rule{
          label: :AGENT,
          flow: :agent,
          handler: {:action, :physical_read, [hooks: [%{run: :after_read}]]}
        }
      ],
      policies: %{safe: %{name: :safe}},
      protections: [%{action: :physical_read, policy: :safe}],
      after_actions: [%{action: :physical_read, run: :after_read}],
      injections: [
        %Spectre.Prompt.Operation{
          id: :agent_context,
          source: {:prompt, :agent_context},
          target: :context
        }
      ],
      skills: [mount]
    }
  end

  def after_read(_value), do: :ok
end

defmodule SpectreApiBranchCoverageTest.MonitorAgent do
  @moduledoc false
  use Spectre.Agent, prompt_root: "test/fixtures/does-not-exist"
  fail(:agent_failure_reply)
end

defmodule SpectreApiBranchCoverageTest.NoFailAgent do
  @moduledoc false
  def __spectre_config__, do: []
end

defmodule SpectreApiBranchCoverageTest do
  use ExUnit.Case, async: true

  alias Spectre.Definition
  alias Spectre.Definition.Validator
  alias Spectre.Input
  alias Spectre.Prompt.Operation
  alias Spectre.Route
  alias Spectre.Router.Support
  alias Spectre.Rule

  defp base_definition do
    Definition.new(
      kind: :agent,
      id: :valid,
      owner: __MODULE__,
      prompt_root: "test/prompts",
      config: [],
      router: [],
      rules: [],
      policies: %{},
      protections: [],
      after_actions: [],
      injections: [],
      requirements: [],
      skills: []
    )
  end

  defp assert_invalid(definitions) do
    Enum.each(definitions, fn definition ->
      assert_raise ArgumentError, fn -> Validator.validate!(definition) end
    end)
  end

  test "prompt operations reject malformed declarations at every public boundary" do
    operation = Operation.new(:context, into: :context)
    provider = Operation.new(:dynamic, [into: :context, from: {__MODULE__, :provide}], :flow)

    assert [] == Operation.normalize(nil, :agent)
    assert [] == Operation.normalize([], :agent)
    assert [%Operation{scope: :handler}] = Operation.normalize(operation, :handler)
    assert [%Operation{id: "prompt"}] = Operation.normalize("prompt", :agent)

    assert [%Operation{id: :prompt}] =
             Operation.normalize([prompt: :prompt, into: :task], :agent)

    assert [_, _] = Operation.normalize([:one, [prompt: :two, into: :context]], :agent)
    assert %Operation{scope: :changed, trust: :data} = Operation.put_scope(provider, :changed)

    assert_raise ArgumentError, fn -> Operation.normalize(123, :agent) end
    assert_raise ArgumentError, fn -> Operation.new(:bad, into: :context, from: :bad) end

    assert_raise ArgumentError, fn ->
      Operation.new(:bad, into: :task, from: {__MODULE__, :provide})
    end

    invalid = [
      %{operation | id: nil},
      %{operation | target: :invalid},
      %{operation | position: :middle},
      %{operation | required?: :yes},
      %{operation | source: {:prompt, 12}},
      %{operation | source: {:provider, "module", :fun}},
      %{operation | source: {:prompt}},
      %{operation | source: {:provider, __MODULE__}},
      %{operation | source: :prompt},
      %{operation | source: {:unknown, :value}},
      %{operation | opts: %{not: :keyword}},
      %{operation | condition: :invalid}
    ]

    Enum.each(invalid, fn item ->
      assert_raise ArgumentError, fn -> Operation.put_scope(item, :agent) end
    end)
  end

  test "definition validator rejects structurally different invalid definitions" do
    base = base_definition()
    rule = %{label: :OK, flow: nil, handler: {:reply, "ok", []}, injections: []}
    duplicate = Operation.new(:same, into: :context)
    replacement_a = Operation.new(:a, into: :task, position: :replace)
    replacement_b = Operation.new(:b, into: :task, position: :replace)

    assert base == Validator.validate!(base)

    assert_invalid([
      %{base | kind: :other},
      %{base | id: nil},
      %{base | version: 0},
      %{base | owner: "owner"},
      %{base | prompt_root: nil},
      %{base | router: :invalid},
      %{base | router: [via: [:regex, :unknown]]},
      %{base | rules: :invalid},
      %{base | rules: [%{rule | label: "OK"}]},
      %{base | rules: [rule, rule]},
      %{base | rules: [%{rule | handler: {:run, "bad", []}}]},
      %{base | policies: []},
      %{base | policies: %{"safe" => %{name: :safe}}},
      %{base | injections: :invalid},
      %{base | injections: [123]},
      %{base | injections: [duplicate, duplicate]},
      %{base | injections: [replacement_a, replacement_b]},
      %{base | rules: [%{rule | handler: {:reply, "ok", [inject: :bad]}}]},
      %{base | rules: [%{rule | handler: {:ask, :prompt, [inject: 123]}}]},
      %{base | skills: [%{id: :not_a_mount}]},
      %{base | requirements: [%{name: :read, mode: :read}]},
      %{base | protections: :invalid},
      %{base | protections: [%{action: :read}]}
    ])
  end

  test "skill validator covers version, infrastructure, requirements and protections" do
    base = %{base_definition() | kind: :skill}
    requirement = %{name: :read, mode: :read}
    action_rule = %{label: :READ, flow: nil, handler: {:action, :read, []}, injections: []}

    assert_invalid([
      %{base | version: 2},
      %{base | config: [actions: __MODULE__]},
      %{base | router: [via: [:regex]]},
      %{base | skills: [%Spectre.Skill.Mount{id: :nested}]},
      %{base | requirements: :invalid},
      %{base | requirements: [%{name: "read", mode: :read}]},
      %{base | requirements: [requirement, requirement]},
      %{base | rules: [action_rule]},
      %{
        base
        | policies: %{safe: %{name: :safe}},
          protections: [%{action: :read, policy: :missing}]
      },
      %{base | protections: [%{}]}
    ])
  end

  test "definition fetch normalizes modern, map, ownerless, legacy and failure replies" do
    assert {:ok, %Definition{owner: SpectreApiBranchCoverageTest.MapDefinition}} =
             Definition.fetch(SpectreApiBranchCoverageTest.MapDefinition)

    assert {:ok, %Definition{owner: SpectreApiBranchCoverageTest.OwnerlessDefinition}} =
             Definition.fetch(SpectreApiBranchCoverageTest.OwnerlessDefinition)

    assert {:ok, %Definition{prompt_root: "legacy/prompts", policies: %{safe: _}}} =
             Definition.fetch(SpectreApiBranchCoverageTest.LegacyDefinition)

    assert {:error, {:invalid_definition_reply, _, :list}} =
             Definition.fetch(SpectreApiBranchCoverageTest.InvalidDefinition)

    assert {:error, {:definition_exception, _, RuntimeError}} =
             Definition.fetch(SpectreApiBranchCoverageTest.RaisingDefinition)

    assert {:error, {:definition_failure, _, :throw, :definition_failed}} =
             Definition.fetch(SpectreApiBranchCoverageTest.ThrowingDefinition)

    assert {:error, {:unknown_spectre_definition, _}} =
             Definition.fetch(SpectreApiBranchCoverageTest.UnknownDefinition)

    assert_raise ArgumentError, fn ->
      Definition.fetch!(SpectreApiBranchCoverageTest.InvalidDefinition)
    end

    assert %Definition{prompt_root: "configured"} =
             Definition.new(id: :x, config: [prompt_root: "configured"], prompt_root: nil)
  end

  test "definition materialization preserves ownership, scopes, bindings and policies" do
    agent = SpectreApiBranchCoverageTest.ComposedDefinition

    assert {:ok, %Definition{kind: :agent}} = Definition.for_scope(agent, :agent)
    assert {:ok, %Definition{kind: :skill}} = Definition.for_scope(agent, {:skill, :mounted})

    assert {:error, {:unknown_skill_mount, _, :missing}} =
             Definition.for_scope(agent, {:skill, :missing})

    assert_raise ArgumentError, fn -> Definition.for_scope!(agent, {:skill, :missing}) end
    assert {:ok, "skill/prompts"} = Definition.prompt_root(agent, {:skill, :mounted})

    [own, mounted] = Definition.rules(agent)
    assert own.scope == :agent
    assert mounted.scope == {:skill, :mounted}
    assert {:action, :physical_read, mounted_opts} = mounted.handler
    assert mounted_opts[:mode] == :read
    assert mounted_opts[:policy] == {{:skill, :mounted}, :safe}

    assert [_, _] = Definition.injections(agent, {:skill, :mounted})
    assert [%{scope: :agent}, %{scope: {:skill, :mounted}}] = Definition.protections(agent)

    assert [
             %{run: {agent, :after_read}},
             %{run: {SpectreApiBranchCoverageTest.SkillDefinition, :after_read}}
           ] =
             Definition.after_actions(agent)

    assert {:ok, %{name: :safe}, :agent} = Definition.policy(agent, :safe)

    assert {:ok, %{name: :safe}, {:skill, :mounted}} =
             Definition.policy(agent, {{:skill, :mounted}, :safe})

    assert {:error, {:unknown_policy, :missing}} = Definition.policy(agent, :missing)
    assert {:error, {:invalid_policy_reference, "bad"}} = Definition.policy(agent, "bad")
    assert :safe == Definition.policy_ref(:agent, :safe)
    assert {{:skill, :mounted}, :safe} == Definition.policy_ref({:skill, :mounted}, :safe)
    assert :safe == Definition.policy_name({{:skill, :mounted}, :safe})
    assert nil == Definition.policy_name("bad")
    assert {:skill, :mounted} == Definition.policy_scope({{:skill, :mounted}, :safe})
    assert :agent == Definition.policy_scope(:safe)
    assert nil == Definition.mount(agent, :agent)
    assert %Spectre.Skill.Mount{id: :mounted} = Definition.mount(agent, {:skill, :mounted})
  end

  test "router support handles scoped ambiguity, checks, raw labels and fallbacks" do
    alpha = %Rule{label: :ALPHA, handler: {:reply, "a", []}, scope: :agent, via: []}
    alpha_skill = %{alpha | scope: {:skill, :one}}

    checked = %Rule{
      label: :CHECKED,
      handler: {:reply, "c", []},
      checks: [text: "yes"]
    }

    classifier_only = %Rule{label: :CLASSIFIER, handler: {:reply, "c", []}, via: [:classifier]}
    input = Input.new("yes")

    assert [:ALPHA, :CHECKED, :CLASSIFIER] ==
             Support.labels_for([alpha, checked, classifier_only])

    assert [^checked] = Support.rules_for([checked], :regex, input)
    assert [] = Support.rules_for([checked], :regex, nil)
    assert [] = Support.rules_for([classifier_only], :regex, input)
    assert [^classifier_only] = Support.rules_for([classifier_only], :classifier, input)
    assert [:ALPHA] = Support.ambiguous_labels([alpha, alpha_skill], :classifier)
    assert [] = Support.rules_for([alpha, alpha_skill], :classifier)
    assert [^alpha, ^alpha_skill] = Support.rules_for([alpha, alpha_skill], :regex)
    assert nil == Support.ambiguity_reason(:classifier, [])

    assert {:ambiguous_scoped_labels, :classifier, [:ALPHA]} =
             Support.ambiguity_reason(:classifier, [:ALPHA])

    assert %Route{rule: ^alpha, labels: [:ALPHA]} =
             Support.route_from_rule(alpha, :regex, "raw", [:ALPHA])

    assert %Route{rule: ^alpha, label: :ALPHA} =
             Support.route_from_result(
               %{"label" => "alpha", "scope" => :agent, "confidence" => 0.9},
               [alpha],
               [:ALPHA],
               :classifier
             )

    assert %Route{rule: nil, label: "MISSING", scope: nil} =
             Support.route_from_result(%{intent: "MISSING"}, [alpha], [:ALPHA], :classifier)

    assert ^alpha = Support.route_rule(%Route{rule: alpha}, [])
    assert ^alpha = Support.route_rule(%Route{label: :ALPHA, scope: :agent}, [alpha])
    assert %Route{labels: [:ALPHA]} = Support.with_labels(%{label: :ALPHA}, [:ALPHA])

    assert %Route{accepted?: true, strategy: :local_classifier_degraded} =
             Support.fallback_route([:ALPHA], %{label: :ALPHA, confidence: 0.75}, :offline)

    assert %Route{accepted?: false, label: :unknown} =
             Support.fallback_route([:ALPHA], %{}, :offline)
  end

  test "terminalization and logging exercise every meaningful score shape" do
    opts = [terminal_labels: [:DONE], high_confidence_threshold: 0.9]

    assert %Route{terminal?: true, escalation_reason: nil} =
             Support.terminalize(%{accepted?: true, label: :DONE, confidence: 0.9}, opts)

    assert %Route{escalation_reason: "not_accepted"} =
             Support.terminalize(%{accepted?: false}, opts)

    assert %Route{escalation_reason: "non_terminal_label"} =
             Support.terminalize(%{accepted?: true, label: :OTHER, confidence: 1.0}, opts)

    assert %Route{escalation_reason: "unscored"} =
             Support.terminalize(%{accepted?: true, label: :DONE, confidence: nil}, opts)

    assert %Route{escalation_reason: "below_high_confidence"} =
             Support.terminalize(%{accepted?: true, label: :DONE, confidence: 0.2}, opts)

    assert nil == Support.log(:debug, "disabled", classification_log?: false)

    assert nil ==
             Support.log_route(
               :debug,
               "route",
               %{
                 label: :A,
                 strategy: :regex,
                 accepted?: true,
                 confidence: 1,
                 margin: nil,
                 scores: %{A: 1.0, B: 0.5, C: 0.1, D: 0.0}
               },
               classification_log?: false
             )

    assert nil ==
             Support.log_route(:debug, "route", %{confidence: :unknown, scores: :invalid},
               classification_log?: false
             )

    assert "regex:ALPHA:confidence=0.9000:margin=0.1000" =
             Support.summarize_local(%{
               label: :ALPHA,
               strategy: :regex,
               confidence: 0.9,
               margin: 0.1
             })

    assert "regex:error=:bad" = Support.summarize_local(%{strategy: :regex, error: :bad})
    assert "123" = Support.summarize_local(123)
    assert ":bad" = Support.format_reason(:bad)
  end

  test "monitor validates run callbacks and normalizes success envelopes" do
    monitor = Spectre.Monitor
    agent = SpectreApiBranchCoverageTest.MonitorAgent
    context = %{conversation_id: "conversation", message_id: "message"}

    assert {:error, {:missing_spectre_monitor_callback, :run}} =
             monitor.dispatch(agent, context, [])

    assert {:error, {:invalid_spectre_monitor_callback, :run, :invalid}} =
             monitor.dispatch(agent, context, run: :invalid)

    # A malformed run callback enters recovery; without a creator the recovery
    # contract reports its own actionable configuration error.
    assert {:error, {:missing_spectre_monitor_callback, :create_fallback}} =
             monitor.dispatch(agent, context, run: fn _arg -> %{} end)

    assert {:ok, %{status: :direct}} =
             monitor.dispatch(agent, context, run: fn -> %{status: :direct} end)

    assert {:ok, %{status: :wrapped}} =
             monitor.dispatch(agent, context, run: fn -> {:ok, %{status: :wrapped}} end)
  end

  test "monitor reuses existing fallbacks for both supported callback arities" do
    monitor = Spectre.Monitor
    agent = SpectreApiBranchCoverageTest.MonitorAgent
    context = %{conversation_id: "conversation"}

    assert {:ok, %{id: 1, status: :agent_fallback}} =
             monitor.dispatch(agent, context,
               run: fn -> {:error, :boom} end,
               fallback_exists?: fn ^context -> %{id: 1} end
             )

    assert {:ok, %{id: 2, status: :preserved}} =
             monitor.dispatch(agent, context,
               run: fn -> {:error, {:failure, :tuple}} end,
               fallback_exists?: fn ^context, {:failure, :tuple} ->
                 {:ok, %{id: 2, status: :preserved}}
               end
             )
  end

  test "monitor continues recovery after misses, invalid replies and callback failures" do
    monitor = Spectre.Monitor
    agent = SpectreApiBranchCoverageTest.MonitorAgent
    context = %{user_id: 10, channel: :test, external_chat_id: "chat"}

    create = fn received_context, text, reason ->
      assert received_context == context
      assert text =~ "couldn't complete"
      %{reason: reason}
    end

    misses = [
      nil,
      fn _context -> false end,
      fn _context -> :not_found end,
      fn _context -> {:error, :lookup_failed} end,
      fn _context -> :invalid_reply end,
      fn _context -> raise "lookup failed" end,
      :invalid_callback
    ]

    Enum.each(misses, fn fallback_exists? ->
      assert {:ok, %{status: :agent_fallback, reason: :boom}} =
               monitor.dispatch(agent, context,
                 run: fn -> {:error, :boom} end,
                 fallback_exists?: fallback_exists?,
                 create_fallback: create
               )
    end)
  end

  test "monitor reports missing, malformed and wrong-arity fallback creators" do
    monitor = Spectre.Monitor
    agent = SpectreApiBranchCoverageTest.MonitorAgent
    context = %{}
    common = [run: fn -> {:error, "string reason"} end]

    assert {:error, {:missing_spectre_monitor_callback, :create_fallback}} =
             monitor.dispatch(agent, context, common)

    assert {:error, {:invalid_spectre_monitor_callback, :create_fallback, :invalid}} =
             monitor.dispatch(agent, context, common ++ [create_fallback: :invalid])

    assert {:error, {:invalid_spectre_monitor_callback_arity, :create_fallback}} =
             monitor.dispatch(agent, context, common ++ [create_fallback: fn _context -> %{} end])

    assert {:error, %Spectre.Provider.Failure{kind: :invalid_reply}} =
             monitor.dispatch(
               agent,
               context,
               common ++ [create_fallback: fn _, _, _ -> :invalid end]
             )

    assert {:error, :creation_denied} =
             monitor.dispatch(
               agent,
               context,
               common ++ [create_fallback: fn _, _, _ -> {:error, :creation_denied} end]
             )
  end

  test "monitor fallback text covers missing configuration and context without a message" do
    assert {:error, {:missing_fail_prompt, SpectreApiBranchCoverageTest.NoFailAgent}} =
             Spectre.Monitor.fallback_text(
               SpectreApiBranchCoverageTest.NoFailAgent,
               %{},
               :boom
             )

    assert {:ok, text} =
             Spectre.Monitor.fallback_text(
               SpectreApiBranchCoverageTest.MonitorAgent,
               %{conversation_id: 1, message_id: nil},
               :boom,
               assigns: %{extra: true}
             )

    assert text =~ "couldn't complete"
  end
end
