defmodule SpectreRunnerLifecycleContractTest.Model do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:runner_model, prompt})
    end

    {:ok, Keyword.get(opts, :model_reply, "model reply")}
  end
end

defmodule SpectreRunnerLifecycleContractTest.Actions do
  @moduledoc false
  def one(args), do: {:ok, args}
  def protected(args), do: {:ok, args}
end

defmodule SpectreRunnerLifecycleContractTest.Renderers do
  @moduledoc false

  def three(prompt, input, ctx), do: "#{prompt}:#{input.text}:#{ctx.assigns.source}"
  def two(prompt, assigns), do: "#{prompt}:#{assigns.input.text}:#{assigns.source}"
  def one(assigns), do: "#{assigns.key}:#{assigns.input.text}:#{assigns.extra}"
end

defmodule SpectreRunnerLifecycleContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"

  actions(SpectreRunnerLifecycleContractTest.Actions)

  policy :confirm do
    request(:base)
    accept(:yes, regex: ~r/^yes$/)
    reject(:no, regex: ~r/^no$/)
  end

  protect(:protected, with: :confirm)

  def bare_result(_input), do: %Spectre.Result{reply_text: "bare"}

  def contextual_result(input, ctx) do
    %Spectre.Result{
      input: input,
      state: ctx.state,
      reply_text: "contextual",
      metadata: %{route_label: ctx.route && ctx.route.label}
    }
  end

  def scalar(_input, _ctx), do: 42
  def invalid(_input, _ctx), do: %{not: :stringable}
end

defmodule SpectreRunnerLifecycleContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Route
  alias Spectre.Runner
  alias Spectre.State

  @agent SpectreRunnerLifecycleContractTest.Agent
  @model SpectreRunnerLifecycleContractTest.Model
  @renderers SpectreRunnerLifecycleContractTest.Renderers

  test "ask and reply defaults traverse the real prompt plan and preserve route state" do
    input = Input.new("hello")
    state = %State{revision: 4}
    route = %Route{label: :ASK, owner: @agent, scope: :agent}

    ctx = %Context{
      agent: @agent,
      input: input,
      state: state,
      route: route,
      opts: [model: @model, test_pid: self()]
    }

    assert {:ok, %Result{} = asked} = Runner.ask(:base, input, ctx)
    assert asked.reply_text == "model reply"
    assert asked.route == route
    assert asked.state == state
    assert asked.metadata.prompt_plan.bytes > 0
    assert_receive {:runner_model, rendered_prompt}
    assert rendered_prompt =~ "BASE_MATRIX_TASK hello"

    assert {:ok, %Result{reply_text: asset}} = Runner.reply(:base, input, ctx)
    assert asset =~ "BASE_MATRIX_TASK hello"
  end

  test "renderer contracts support all callback arities and reject every invalid adapter shape" do
    input = Input.new("hello")

    ctx = %{
      agent: @agent,
      state: %State{},
      assigns: %{source: "context"},
      opts: []
    }

    assert {:ok, %Result{reply_text: "prompt:hello:context"}} =
             Runner.reply(:prompt, input, ctx, renderer: &@renderers.three/3)

    assert {:ok, %Result{reply_text: "prompt:hello:context"}} =
             Runner.reply(:prompt, input, ctx, renderer: &@renderers.two/2)

    assert {:ok, %Result{reply_text: "reply-key:hello:value"}} =
             Runner.reply(:prompt, input, ctx,
               renderer: &@renderers.one/1,
               key: "reply-key",
               assigns: [extra: "value"]
             )

    assert {:ok, %Result{reply_text: "prompt:hello:context"}} =
             Runner.reply(:prompt, input, ctx, renderer: {@renderers, :three})

    assert {:ok, %Result{reply_text: "prompt:hello:context"}} =
             Runner.reply(:prompt, input, ctx, renderer: {@renderers, :two})

    assert {:ok, %Result{reply_text: "reply-key:hello:value"}} =
             Runner.reply(:prompt, input, ctx,
               renderer: {@renderers, :one},
               key: "reply-key",
               assigns: [extra: "value"]
             )

    assert {:error, {:undefined_reply_renderer, @renderers, :missing}} =
             Runner.reply(:prompt, input, ctx, renderer: {@renderers, :missing})

    invalid_renderers = [
      {:atom, :atom},
      {"binary", :binary},
      {[], :list},
      {%{}, :map},
      {{:bad, :tuple, :shape}, {:tuple, 3}},
      {fn -> :bad end, :function},
      {self(), :other}
    ]

    Enum.each(invalid_renderers, fn {renderer, shape} ->
      assert {:error, {:invalid_reply_renderer, ^shape}} =
               Runner.reply(:prompt, input, ctx, renderer: renderer)
    end)

    assert {:error, %Spectre.Provider.Failure{provider: :renderer, kind: :invalid_reply}} =
             Runner.reply(:prompt, input, ctx, renderer: fn _assigns -> %{bad: :reply} end)
  end

  test "run callbacks receive defaults, preserve bare results, and contain invalid replies" do
    input = Input.new("run")
    state = %State{revision: 7}
    route = %Route{label: :RUN, owner: @agent, scope: :agent}
    ctx = %{agent: @agent, state: state, route: route, opts: []}

    assert {:ok, %Result{} = bare} = Runner.run_function(:bare_result, input, ctx)
    assert bare.input == input
    assert bare.route == route
    assert bare.state == state
    assert bare.reply_text == "bare"

    assert {:ok, %Result{} = contextual} =
             Runner.run_function(:contextual_result, input, ctx)

    assert contextual.metadata.route_label == :RUN

    assert {:ok, %Result{reply_text: "42"}} = Runner.run_function(:scalar, input, ctx)

    assert {:error, %Spectre.Provider.Failure{provider: :run, kind: :invalid_reply}} =
             Runner.run_function(:invalid, input, ctx)

    assert {:error, {:undefined_run_function, @agent, :missing}} =
             Runner.run_function(:missing, input, ctx)
  end

  test "action staging is durable, rejects overlap, and reports unknown policy references" do
    input = Input.new("action")
    route = %Route{label: :ACTION, owner: @agent, scope: nil}
    ctx = %{agent: @agent, state: %State{}, route: route, opts: []}

    assert {:ok, %Result{} = staged} = Runner.action(:one, input, ctx)
    assert [%Effect{name: :one, owner: @agent, scope: :agent, status: :pending}] = staged.effects
    assert [%{type: :effect_staged, name: :one, owner: @agent, scope: :agent}] = staged.events
    assert staged.route == route

    assert {:error, {:pending_effect_not_resolved, effect_id, :pending}} =
             Runner.action(:one, input, %{ctx | state: staged.state})

    assert effect_id == hd(staged.effects).id

    no_route_ctx = %{agent: @agent, state: %State{}, opts: []}

    assert {:ok, %Result{effects: [%Effect{owner: @agent, scope: :agent}]}} =
             Runner.action(:one, input, no_route_ctx)

    assert {:error, {:unknown_policy, :does_not_exist}} =
             Runner.action(:one, input, ctx, policy: :does_not_exist)
  end
end
