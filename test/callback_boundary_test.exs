defmodule SpectreCallbackBoundaryTest.Callbacks do
  @moduledoc false

  def run_one(input), do: "one:" <> input.text
  def run_two(input, ctx), do: "two:#{input.text}:#{ctx.assigns.marker}"
  def run_error(_input), do: {:error, :declared_run_error}
  def run_raise(_input), do: raise("SENSITIVE run exception")
  def run_exit(_input), do: exit({:run_exit, "SENSITIVE"})
  def run_throw(_input), do: throw({:run_throw, "SENSITIVE"})
  def run_crash(_input), do: Process.exit(self(), :kill)
  def run_malformed(_input), do: %{private: "run callback result"}

  def run_timeout(_input, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:run_worker, self()})
    Process.sleep(250)
    send(Keyword.fetch!(ctx.opts, :test_pid), :late_run_result)
    "late"
  end

  def healthy(_input), do: "healthy"

  def render_one(assigns), do: "one:#{assigns.input.text}"
  def render_two(prompt, assigns), do: "two:#{prompt}:#{assigns.input.text}"
  def render_three(prompt, input, _ctx), do: "three:#{prompt}:#{input.text}"
  def render_error(_assigns), do: {:error, :declared_renderer_error}
  def render_raise(_assigns), do: raise("SENSITIVE renderer exception")
  def render_exit(_assigns), do: exit({:renderer_exit, "SENSITIVE"})
  def render_throw(_assigns), do: throw({:renderer_throw, "SENSITIVE"})
  def render_crash(_assigns), do: Process.exit(self(), :kill)
  def render_malformed(_assigns), do: %{private: "renderer result"}

  def render_timeout(assigns) do
    send(Keyword.fetch!(assigns.ctx.opts, :test_pid), {:renderer_worker, self()})
    Process.sleep(250)
    send(Keyword.fetch!(assigns.ctx.opts, :test_pid), :late_renderer_result)
    "late"
  end

  def hook_zero, do: :ok
  def hook_one(:delivered), do: {:ok, :recorded}
  def hook_two(:delivered, _ctx), do: :ok

  def hook_three(:delivered, _ctx, hook) do
    if hook.on == :delivered, do: :ok, else: {:error, :wrong_hook}
  end

  def hook_error(_result), do: {:error, :declared_hook_error}
  def hook_raise(_result), do: raise("SENSITIVE hook exception")
  def hook_exit(_result), do: exit({:hook_exit, "SENSITIVE"})
  def hook_throw(_result), do: throw({:hook_throw, "SENSITIVE"})
  def hook_crash(_result), do: Process.exit(self(), :kill)
  def hook_malformed(_result), do: %{private: "hook result"}

  def hook_timeout(_result, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:hook_worker, self()})
    Process.sleep(250)
    send(Keyword.fetch!(ctx.opts, :test_pid), :late_hook_result)
    :ok
  end
end

defmodule SpectreCallbackBoundaryTest.InputPlug do
  @moduledoc false

  @behaviour Spectre.Input.Plug

  @impl Spectre.Input.Plug
  def init(opts) do
    case Keyword.get(opts, :init_mode) do
      :raise ->
        raise "SENSITIVE input init exception"

      :exit ->
        exit({:input_init_exit, "SENSITIVE"})

      :throw ->
        throw({:input_init_throw, "SENSITIVE"})

      :crash ->
        Process.exit(self(), :kill)

      :timeout ->
        send(Keyword.fetch!(opts, :test_pid), {:input_init_worker, self()})
        Process.sleep(250)
        opts

      _other ->
        opts
    end
  end

  @impl Spectre.Input.Plug
  def call(input, _context, state) do
    state
    |> Keyword.get(:mode, :cont)
    |> call_mode(input, state)
  end

  defp call_mode(:cont, input, _state),
    do: {:cont, Spectre.Input.put_meta(input, :bounded, true)}

  defp call_mode(:halt, input, _state),
    do: {:halt, Spectre.Input.put_meta(input, :bounded, true)}

  defp call_mode(:error, _input, _state), do: {:error, :declared_input_error}
  defp call_mode(:raise, _input, _state), do: raise("SENSITIVE input callback exception")
  defp call_mode(:exit, _input, _state), do: exit({:input_exit, "SENSITIVE"})
  defp call_mode(:throw, _input, _state), do: throw({:input_throw, "SENSITIVE"})
  defp call_mode(:crash, _input, _state), do: Process.exit(self(), :kill)
  defp call_mode(:malformed, _input, _state), do: %{private: "input callback result"}

  defp call_mode(:timeout, input, state) do
    send(Keyword.fetch!(state, :test_pid), {:input_worker, self()})
    Process.sleep(250)
    send(Keyword.fetch!(state, :test_pid), :late_input_result)
    {:cont, input}
  end
end

defmodule SpectreCallbackBoundaryTest.SlowRouter do
  @moduledoc false

  def call(context) do
    send(Keyword.fetch!(context.opts, :test_pid), {:router_worker, self()})
    Process.sleep(250)
    send(Keyword.fetch!(context.opts, :test_pid), :late_router_result)
    {:ok, context}
  end
end

defmodule SpectreCallbackBoundaryTest.Agent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false)

  flow :callbacks do
    on :RUN_TIMEOUT, regex: ~r/^run-timeout$/ do
      run(:run_timeout)
    end

    on :HEALTHY, regex: ~r/^healthy$/ do
      run(:healthy)
    end
  end

  defdelegate run_timeout(input, ctx), to: SpectreCallbackBoundaryTest.Callbacks
  defdelegate healthy(input), to: SpectreCallbackBoundaryTest.Callbacks
end

defmodule SpectreCallbackBoundaryTest do
  use ExUnit.Case, async: false

  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Input.Pipeline, as: InputPipeline
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias Spectre.State
  alias SpectreCallbackBoundaryTest.SlowRouter

  @callbacks SpectreCallbackBoundaryTest.Callbacks
  @input_plug SpectreCallbackBoundaryTest.InputPlug
  @agent SpectreCallbackBoundaryTest.Agent

  test "run handlers support both arities and preserve declared errors" do
    input = Input.new("hello")
    ctx = context(input, assigns: %{marker: :ctx})

    assert {:ok, %Result{reply_text: "one:hello"}} =
             Spectre.Runner.run_function(:run_one, input, ctx)

    assert {:ok, %Result{reply_text: "two:hello:ctx"}} =
             Spectre.Runner.run_function(:run_two, input, ctx)

    assert {:error, :declared_run_error} =
             Spectre.Runner.run_function(:run_error, input, ctx)
  end

  test "run handlers sanitize every execution failure and malformed replies" do
    input = Input.new("private input")
    ctx = context(input)

    assert_failure(Spectre.Runner.run_function(:run_raise, input, ctx), :run, :exception)
    assert_failure(Spectre.Runner.run_function(:run_exit, input, ctx), :run, :exit)
    assert_failure(Spectre.Runner.run_function(:run_throw, input, ctx), :run, :throw)
    assert_failure(Spectre.Runner.run_function(:run_crash, input, ctx), :run, :crash)
    assert_failure(Spectre.Runner.run_function(:run_malformed, input, ctx), :run, :invalid_reply)
  end

  test "a timed-out run worker is terminated, not retried, and the Session recovers" do
    session = start_supervised!({Spectre.Session, agent: @agent})

    assert {:error, %Failure{provider: :run, kind: :timeout, timeout: 10}} =
             Spectre.ask(session, "run-timeout", run_timeout: 10, test_pid: self())

    assert_receive {:run_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute_receive :late_run_result, 300
    refute_receive {:run_worker, _retried_worker}, 20
    assert Process.alive?(session)

    assert {:ok, %Result{reply_text: "healthy"}} = Spectre.ask(session, "healthy")
  end

  test "reply renderers support arities one through three" do
    input = Input.new("hello")
    ctx = context(input)

    assert_reply("one:hello", input, ctx, {@callbacks, :render_one})
    assert_reply("two:prompt:hello", input, ctx, {@callbacks, :render_two})
    assert_reply("three:prompt:hello", input, ctx, {@callbacks, :render_three})
  end

  test "reply renderers preserve errors and sanitize failures without retaining private data" do
    input = Input.new("private input")
    ctx = context(input)

    assert {:error, :declared_renderer_error} =
             render(input, ctx, {@callbacks, :render_error})

    assert_failure(render(input, ctx, {@callbacks, :render_raise}), :renderer, :exception)
    assert_failure(render(input, ctx, {@callbacks, :render_exit}), :renderer, :exit)
    assert_failure(render(input, ctx, {@callbacks, :render_throw}), :renderer, :throw)
    assert_failure(render(input, ctx, {@callbacks, :render_crash}), :renderer, :crash)

    assert_failure(
      render(input, ctx, {@callbacks, :render_malformed}),
      :renderer,
      :invalid_reply
    )
  end

  test "a timed-out renderer worker is terminated and not retried" do
    input = Input.new("hello")
    ctx = context(input, opts: [test_pid: self()])

    assert {:error, %Failure{provider: :renderer, kind: :timeout}} =
             render(input, ctx, {@callbacks, :render_timeout}, renderer_timeout: 10)

    assert_receive {:renderer_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute_receive :late_renderer_result, 300
    refute_receive {:renderer_worker, _retried_worker}, 20
  end

  test "action hooks support arities zero through three" do
    for function <- [:hook_zero, :hook_one, :hook_two, :hook_three] do
      assert :ok = run_hook({@callbacks, function})
    end
  end

  test "action hooks aggregate declared errors and sanitize all other failures" do
    assert {:error, [:declared_hook_error]} = run_hook({@callbacks, :hook_error})
    assert_hook_failure(:hook_raise, :exception)
    assert_hook_failure(:hook_exit, :exit)
    assert_hook_failure(:hook_throw, :throw)
    assert_hook_failure(:hook_crash, :crash)
    assert_hook_failure(:hook_malformed, :invalid_reply)
  end

  test "a timed-out hook worker is terminated and not retried" do
    assert {:error, [%Failure{provider: :hook, kind: :timeout}]} =
             run_hook({@callbacks, :hook_timeout}, hook_timeout: 10, test_pid: self())

    assert_receive {:hook_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute_receive :late_hook_result, 300
    refute_receive {:hook_worker, _retried_worker}, 20
  end

  test "input plug init and call callbacks use the protected contract" do
    input = Input.new("hello")

    assert {:ok, %Input{meta: %{bounded: true}}} = run_input(input, mode: :cont)
    assert {:ok, %Input{meta: %{bounded: true}}} = run_input(input, mode: :halt)

    assert {:error, {@input_plug, :declared_input_error}} = run_input(input, mode: :error)

    for {mode, kind} <- [
          raise: :exception,
          exit: :exit,
          throw: :throw,
          crash: :crash,
          malformed: :invalid_reply
        ] do
      assert {:error, {@input_plug, %Failure{provider: :input, kind: ^kind} = failure}} =
               run_input(input, mode: mode)

      refute inspect(failure) =~ "SENSITIVE"
    end
  end

  test "input init and call timeouts terminate workers and a Session remains healthy" do
    assert {:error, %Failure{provider: :input, kind: :timeout}} =
             InputPipeline.init_specs(
               [{@input_plug, [init_mode: :timeout, test_pid: self()]}],
               input_timeout: 10
             )

    assert_receive {:input_init_worker, init_worker}
    refute Process.alive?(init_worker)

    session = start_supervised!({Spectre.Session, agent: @agent})

    assert {:error, {@input_plug, %Failure{provider: :input, kind: :timeout}}} =
             Spectre.ask(session, "healthy",
               input_pipeline: [{@input_plug, [mode: :timeout, test_pid: self()]}],
               input_timeout: 10
             )

    assert_receive {:input_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute_receive :late_input_result, 300
    refute_receive {:input_worker, _retried_worker}, 20
    assert Process.alive?(session)
    assert {:ok, %Result{reply_text: "healthy"}} = Spectre.ask(session, "healthy")
  end

  test "a custom router pipeline times out without killing a later healthy turn" do
    session = start_supervised!({Spectre.Session, agent: @agent})

    assert {:error, %Failure{provider: :router, kind: :timeout}} =
             Spectre.ask(session, "healthy",
               pipeline: SlowRouter,
               router_timeout: 10,
               test_pid: self()
             )

    assert_receive {:router_worker, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    refute_receive :late_router_result, 300
    assert Process.alive?(session)
    assert {:ok, %Result{reply_text: "healthy"}} = Spectre.ask(session, "healthy")
  end

  test "monitor callbacks use the same cancellable boundary" do
    test_pid = self()

    run = fn ->
      send(test_pid, {:monitor_worker, self()})
      Process.sleep(250)
      {:ok, %{status: :late}}
    end

    assert {:ok, %{status: :agent_fallback}} =
             Spectre.Monitor.dispatch(@agent, %{conversation_id: "safe"},
               run: run,
               fallback_exists?: fn _context -> :not_found end,
               create_fallback: fn _context, _text, %Failure{kind: :timeout} ->
                 {:ok, %{}}
               end,
               monitor_timeout: 10
             )

    assert_receive {:monitor_worker, worker}
    refute Process.alive?(worker)
    refute_receive {:monitor_worker, _retried_worker}, 20
  end

  defp context(input, opts \\ []) do
    %Context{
      agent: @callbacks,
      input: input,
      state: %State{},
      assigns: Keyword.get(opts, :assigns, %{}),
      opts: Keyword.get(opts, :opts, [])
    }
  end

  defp render(input, ctx, renderer, opts \\ []) do
    Spectre.Runner.reply(:prompt, input, ctx, Keyword.put(opts, :renderer, renderer))
  end

  defp assert_reply(expected, input, ctx, renderer) do
    assert {:ok, %Result{reply_text: ^expected}} = render(input, ctx, renderer)
  end

  defp run_hook(callback, opts \\ []) do
    hook = %{action: :callback, on: :delivered, run: callback, opts: []}

    effect =
      %{name: :callback, payload: %{hooks: [hook]}}
      |> Effect.stage()
      |> Effect.complete(:delivered)

    input = Input.new("")
    result = %Result{input: input, state: %State{}, effects: [effect]}
    ctx = %Context{agent: @agent, input: input, state: %State{}, opts: []}

    Spectre.ActionHooks.run(@agent, :delivered, result, ctx, opts)
  end

  defp assert_hook_failure(function, kind) do
    assert {:error, [%Failure{provider: :hook, kind: ^kind} = failure]} =
             run_hook({@callbacks, function})

    refute inspect(failure) =~ "SENSITIVE"
  end

  defp run_input(input, plug_opts) do
    InputPipeline.run(input, %{agent: @agent, opts: []}, [
      {@input_plug, plug_opts}
    ])
  end

  defp assert_failure({:error, %Failure{} = failure}, provider, kind) do
    assert failure.provider == provider
    assert failure.kind == kind
    refute inspect(failure) =~ "SENSITIVE"
  end
end
