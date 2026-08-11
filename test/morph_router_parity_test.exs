defmodule SpectreMorphRouterParityTest.CustomArbitrator do
  @moduledoc false
  @behaviour Spectre.Router.Arbitrator

  @impl true
  def decide(arbitration, _opts) do
    Spectre.Router.Arbitrators.Default.decide(arbitration, [])
  end
end

defmodule SpectreMorphRouterParityTest.CustomPipelineAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_custom_pipeline_agent

  router(
    pipeline: Spectre.Router.DefaultPipeline,
    semantic_cache?: false,
    classification_log?: false
  )
end

defmodule SpectreMorphRouterParityTest.CustomArbitratorAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_custom_arbitrator_agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  arbitrator(SpectreMorphRouterParityTest.CustomArbitrator)
end

defmodule SpectreMorphRouterParityTest.ContextSensitiveInputPlug do
  @moduledoc false
  @behaviour Spectre.Input.Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(input, _context, _state), do: {:cont, input}
end

defmodule SpectreMorphRouterParityTest.UnrehearsableInputAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_unrehearsable_input_agent

  input_pipeline([SpectreMorphRouterParityTest.ContextSensitiveInputPlug])
  router(via: [:regex], semantic_cache?: false, classification_log?: false)
end

defmodule SpectreMorphRouterParityTest.LLMOverrideAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_llm_override_agent

  router(
    via: [:regex],
    llm_classifier?: true,
    semantic_cache?: false,
    classification_log?: false
  )
end

defmodule SpectreMorphRouterParityTest.ClarifyFallbackAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_clarify_fallback_agent

  router(
    via: [:regex],
    no_decision: :clarify,
    semantic_cache?: false,
    classification_log?: false
  )
end

defmodule SpectreMorphRouterParityTest.NestedLLMOverrideAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_nested_llm_override_agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  arbitrator(Spectre.Router.Arbitrators.Default,
    llm_classifier?: true,
    model: :not_called
  )
end

defmodule SpectreMorphRouterParityTest.MalformedDefaultArbitratorAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_malformed_default_arbitrator_agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  arbitrator(Spectre.Router.Arbitrators.Default, [:not_a_keyword])
end

defmodule SpectreMorphRouterParityTest.MalformedSemanticCacheAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_malformed_semantic_cache_agent

  router(
    via: [:regex],
    semantic_cache?: "not-a-boolean",
    classification_log?: false
  )
end

defmodule SpectreMorphRouterParityTest.InterruptOnlyAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_interrupt_only_agent

  router(
    via: [:regex],
    policy_interrupt_only?: true,
    semantic_cache?: false,
    classification_log?: false
  )

  interrupt :STOP, regex: ~r/^stop$/ do
    reply(:stop)
  end

  flow :normal do
    on :NORMAL, regex: ~r/^normal$/ do
      reply(:normal)
    end
  end
end

defmodule SpectreMorphRouterParityTest.SourceConstraintExtension do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def id, do: :morph_router_source_constraint

  @impl true
  def flow_constraints(opts, _config) do
    case Keyword.pop(opts, :channel) do
      {nil, remaining} ->
        {[], remaining}

      {channel, remaining} ->
        {[%Spectre.Flow.Constraint{namespace: :channel, values: [channel]}], remaining}
    end
  end
end

defmodule SpectreMorphRouterParityTest.ConstraintAgent do
  @moduledoc false

  use Spectre.Agent, id: :morph_router_constraint_agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreMorphRouterParityTest.SourceConstraintExtension
  )

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :generic do
    on :GENERIC, regex: ~r/^status$/ do
      reply(:generic)
    end
  end

  flow :web, channel: :web do
    on :WEB_STATUS, regex: ~r/^status$/ do
      reply(:web_status)
    end

    on :WEB_ONLY, regex: ~r/^restricted$/ do
      reply(:web_only)
    end
  end
end

defmodule SpectreMorphRouterParityTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Input
  alias Spectre.Router
  alias Spectre.Runtime.SkillDispatch
  alias Spectre.State

  alias SpectreMorphRouterParityTest.ConstraintAgent
  alias SpectreMorphRouterParityTest.ClarifyFallbackAgent
  alias SpectreMorphRouterParityTest.CustomArbitratorAgent
  alias SpectreMorphRouterParityTest.CustomPipelineAgent
  alias SpectreMorphRouterParityTest.InterruptOnlyAgent
  alias SpectreMorphRouterParityTest.LLMOverrideAgent
  alias SpectreMorphRouterParityTest.MalformedDefaultArbitratorAgent
  alias SpectreMorphRouterParityTest.MalformedSemanticCacheAgent
  alias SpectreMorphRouterParityTest.NestedLLMOverrideAgent
  alias SpectreMorphRouterParityTest.UnrehearsableInputAgent

  test "declarative checker refuses custom router execution before issuing evidence" do
    candidate = %{governance: struct(CandidateState)}

    assert {:error, :declarative_checker_custom_router_pipeline_not_rehearsable} =
             Declarative.run(:unreachable_store, candidate, [], agent: CustomPipelineAgent)

    assert {:error, :declarative_checker_custom_arbitrator_not_rehearsable} =
             Declarative.run(:unreachable_store, candidate, [], agent: CustomArbitratorAgent)

    assert {:error, {:invalid_declarative_checker_agent, :not_a_module}} =
             Declarative.run(:unreachable_store, candidate, [], agent: :not_a_module)

    assert {:error, {:invalid_declarative_eval_cases, :other}} =
             Declarative.run(:unreachable_store, candidate, [],
               agent: ConstraintAgent,
               protected_cases: :bad
             )
  end

  test "declarative checker refuses undeclared input replay, LLM fallback and timing claims" do
    candidate = %{governance: struct(CandidateState)}

    assert {:error,
            {:declarative_checker_input_plug_not_rehearsable,
             SpectreMorphRouterParityTest.ContextSensitiveInputPlug}} =
             Declarative.run(:unreachable_store, candidate, [], agent: UnrehearsableInputAgent)

    assert {:error, :declarative_checker_llm_router_not_rehearsable} =
             Declarative.run(:unreachable_store, candidate, [], agent: LLMOverrideAgent)

    for agent <- [
          ClarifyFallbackAgent,
          NestedLLMOverrideAgent,
          MalformedDefaultArbitratorAgent
        ] do
      assert {:error, :declarative_checker_custom_arbitrator_not_rehearsable} =
               Declarative.run(:unreachable_store, candidate, [], agent: agent)
    end

    assert {:error, {:declarative_checker_invalid_semantic_cache, "not-a-boolean"}} =
             Declarative.run(:unreachable_store, candidate, [],
               agent: MalformedSemanticCacheAgent
             )

    timed_case = %{
      "id" => "not-a-real-turn-clock",
      "input" => "anything",
      "expected_outcome" => "clarify",
      "max_duration_us" => 1
    }

    assert {:error, {:declarative_checker_duration_not_rehearsable, "not-a-real-turn-clock"}} =
             Declarative.run(:unreachable_store, candidate, [timed_case], agent: ConstraintAgent)

    stateful_case = %{
      "id" => "policy-state-is-not-synthetic",
      "input" => "anything",
      "expected_outcome" => "clarify",
      "state" => %{"current_flow" => "checkout"}
    }

    assert {:error, {:declarative_checker_state_not_rehearsable, "policy-state-is-not-synthetic"}} =
             Declarative.run(:unreachable_store, candidate, [stateful_case],
               agent: ConstraintAgent
             )
  end

  test "compiled conflict detection honors the same policy interrupt filter as live routing" do
    state = State.new(nil)

    assert :not_found =
             SkillDispatch.compiled_deterministic_route(
               InterruptOnlyAgent,
               state,
               Input.new("normal")
             )

    assert {:ok, :STOP} =
             SkillDispatch.compiled_deterministic_route(
               InterruptOnlyAgent,
               state,
               Input.new("stop")
             )
  end

  test "compiled deterministic routing applies the same source constraints and order as live routing" do
    state = State.new(nil)
    web_input = source_input("status", :web)

    assert [:GENERIC, :WEB_STATUS, :WEB_ONLY] =
             ConstraintAgent
             |> Router.candidate_rules(state)
             |> Enum.map(& &1.label)

    assert {:ok, :WEB_STATUS} =
             SkillDispatch.compiled_deterministic_route(ConstraintAgent, state, web_input)

    assert {:ok, %{label: :WEB_STATUS, accepted?: true}} =
             Router.route(web_input, context(state, web_input))

    app_input = source_input("restricted", :app)

    assert :not_found =
             SkillDispatch.compiled_deterministic_route(ConstraintAgent, state, app_input)

    assert {:ok, %{label: :unknown, accepted?: false}} =
             Router.route(app_input, context(state, app_input))
  end

  defp source_input(text, mount) do
    Input.new(%{text: text, source: %{kind: :channel, mount: mount}})
  end

  defp context(state, input) do
    %Context{agent: ConstraintAgent, state: state, input: input, opts: []}
  end
end
