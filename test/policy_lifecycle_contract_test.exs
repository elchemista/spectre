defmodule SpectrePolicyLifecycleContractTest.Actions do
  @moduledoc false

  def publish(args, _ctx), do: {:ok, {:published, args}}
end

defmodule SpectrePolicyLifecycleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/skill_inject/agent"

  router(semantic_cache?: false, classification_log?: false)

  actions SpectrePolicyLifecycleContractTest.Actions do
    protect(:publish, with: :agent_confirm)
  end

  policy :agent_confirm do
    request(:agent_confirm)
    accept(:approved, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
    otherwise(ask: :agent_confirm)
    attempts(2, then: :attempts_exhausted)
  end

  policy :unlimited_confirm do
    accept(:approved, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
  end

  policy :default_exhaustion do
    accept(:approved, regex: ~r/^yes$/)
    reject(:rejected, regex: ~r/^no$/)
    attempts(1, then: nil)
  end

  flow :publishing do
    on :PUBLISH, regex: ~r/^publish$/ do
      action(:publish, args: %{document: 42})
    end
  end

  def attempts_exhausted(input, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid) do
      send(pid, {:policy_attempts_exhausted, input.text, ctx.state})
    end

    "manual review required"
  end
end

defmodule SpectrePolicyLifecycleContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Policy
  alias Spectre.Result
  alias Spectre.State

  @agent SpectrePolicyLifecycleContractTest.Agent

  test "a full protected turn retries through the policy prompt and invokes its terminal handler" do
    model = fn prompt, _opts ->
      assert prompt =~ "AGENT_CONFIRM"
      {:ok, "please confirm"}
    end

    assert {:ok, opened} =
             Spectre.ask(@agent, "publish",
               model: model,
               test_pid: self()
             )

    assert %Awaitable{name: :agent_confirm, status: :open, attempts: 0} =
             Result.open_awaitable(opened)

    assert [%Effect{name: :publish, status: :waiting_policy}] = opened.state.pending_effects
    assert opened.reply_text == "please confirm"

    assert {:ok, retried} =
             Spectre.ask(@agent, "maybe",
               state: opened.state,
               model: model,
               test_pid: self()
             )

    assert retried.reply_text == "please confirm"

    assert %Awaitable{name: :agent_confirm, status: :open, attempts: 1} =
             Result.open_awaitable(retried)

    assert Enum.any?(
             retried.events,
             &match?(%{type: :awaitable_pending, name: :agent_confirm}, &1)
           )

    assert {:ok, exhausted} =
             Spectre.ask(@agent, "still maybe",
               state: retried.state,
               model: model,
               test_pid: self()
             )

    assert exhausted.reply_text == "manual review required"

    assert_receive {:policy_attempts_exhausted, "still maybe",
                    %State{awaitables: [%Awaitable{attempts: 2, status: :open}]}}

    assert [%Effect{status: :waiting_policy}] = exhausted.state.pending_effects
  end

  test "an unlimited policy remains open across unmatched turns without calling a model" do
    state = policy_state(:unlimited_confirm)
    input = Input.new("not a decision")
    ctx = context(input, state)

    assert {:ok, %Result{} = result} = Policy.resume(input, ctx)
    assert result.reply_text == ""

    assert %Awaitable{name: :unlimited_confirm, attempts: 1, status: :open} =
             Result.open_awaitable(result)

    assert [%Effect{status: :waiting_policy}] = result.state.pending_effects
    assert [%{type: :awaitable_pending, name: :unlimited_confirm}] = result.events
  end

  test "attempt exhaustion defaults to cancelling pending effects when no handler is configured" do
    state = policy_state(:default_exhaustion)
    input = Input.new("unknown")

    assert {:ok, %Result{} = result} = Policy.resume(input, context(input, state))
    assert result.state.pending_effects == []

    assert %Awaitable{name: :default_exhaustion, attempts: 1, status: :cancelled} =
             List.first(result.awaitables)

    assert [%Effect{status: :cancelled} = cancelled] = result.effects
    assert Effect.outcome(cancelled) == {:cancelled, :policy_attempts_exceeded}

    assert Enum.any?(
             result.events,
             &match?(%{type: :effect_cancelled, reason: :policy_attempts_exceeded}, &1)
           )
  end

  test "public policy boundaries report missing, unknown, malformed, and unmatched decisions" do
    input = Input.new("maybe")
    empty = context(input, %State{})

    assert {:error, :no_open_policy} = Policy.resume(input, empty)
    assert {:error, :no_open_policy} = Policy.resolve({:accept, :approved}, input, empty)

    unknown_state = policy_state(:policy_that_is_not_defined)
    unknown = context(input, unknown_state)

    assert {:error, {:unknown_policy, :policy_that_is_not_defined}} =
             Policy.resume(input, unknown)

    assert {:error, {:unknown_policy, :policy_that_is_not_defined}} =
             Policy.resolve({:accept, :approved}, input, unknown)

    assert {:error, {:invalid_policy_resolution, :malformed}} =
             Policy.resolve(:malformed, input, empty)

    assert :no_match = Policy.decide(%Policy{}, "nothing matches")
  end

  test "trusted resolution validates branch labels before mutating policy state" do
    state = policy_state(:unlimited_confirm)
    input = Input.new("durable host proof")
    ctx = context(input, state)

    assert {:error, {:unknown_policy_resolution_label, :unlimited_confirm, :accept, :missing}} =
             Policy.resolve({:accept, :missing}, input, ctx)

    assert State.open_policy_awaitable(state).status == :open
    assert State.pending_effect(state).status == :waiting_policy
  end

  defp policy_state(policy) do
    effect =
      Effect.stage_action(
        %{name: :publish, args: %{document: 42}},
        @agent,
        :agent
      )

    State.put_pending_effect(%State{}, effect, policy)
  end

  defp context(input, state) do
    %Context{
      agent: @agent,
      input: input,
      state: state,
      opts: [test_pid: self()]
    }
  end
end
