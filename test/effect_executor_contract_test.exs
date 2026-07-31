defmodule SpectreEffectExecutorContractTest.Executor do
  @moduledoc false

  @behaviour Spectre.Effect.Executor

  @impl true
  def execute(effect, ctx, opts) do
    if test_pid = Keyword.get(opts, :test_pid) do
      send(test_pid, {:effect_executor_called, effect.id, ctx, opts})
    end

    case effect.name do
      :ok -> {:ok, %{agent: ctx.agent, payload: effect.payload}}
      :raw -> :raw_result
      :error -> {:error, :declined}
      :large -> {:ok, String.duplicate("x", 128)}
      :raise -> raise "executor secret"
      :throw -> throw(:executor_throw)
      :exit -> exit(:executor_exit)
      :timeout -> Process.sleep(100)
    end
  end
end

defmodule SpectreEffectExecutorContractTest.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl true
  def id, do: :effect_executor_contract

  @impl true
  def api_version, do: 1

  @impl true
  def compile(_owner, opts), do: {:ok, opts}

  @impl true
  def effect_executors(opts), do: Keyword.fetch!(opts, :executors)
end

defmodule SpectreEffectExecutorContractTest.EmptyExtension do
  @moduledoc false
  @behaviour Spectre.Extension
  @impl true
  def id, do: :empty_effect_executor_contract
end

defmodule SpectreEffectExecutorContractTest.InvalidExtension do
  @moduledoc false
  @behaviour Spectre.Extension
  @impl true
  def id, do: :invalid_effect_executor_contract
  @impl true
  def effect_executors(_opts), do: [:invalid]
end

defmodule SpectreEffectExecutorContractTest.Agent do
  @moduledoc false

  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreEffectExecutorContractTest.Extension,
    executors: [
      {:observation, SpectreEffectExecutorContractTest.Executor, extension_option: :mounted},
      {:raw_observation, SpectreEffectExecutorContractTest.Executor},
      Spectre.Effect.Executor.Mount.new(
        :missing_executor,
        SpectreEffectExecutorContractTest.MissingExecutor
      )
    ]
  )
end

defmodule SpectreEffectExecutorContractTest.DuplicateExtension do
  @moduledoc false
  @behaviour Spectre.Extension
  @impl true
  def id, do: :duplicate_effect_executor_contract

  @impl true
  def effect_executors(_opts) do
    [
      {:duplicate_kind, SpectreEffectExecutorContractTest.Executor},
      {:duplicate_kind, SpectreEffectExecutorContractTest.Executor}
    ]
  end
end

defmodule SpectreEffectExecutorContractTest.DuplicateAgent do
  @moduledoc false
  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreEffectExecutorContractTest.DuplicateExtension
  )
end

defmodule SpectreEffectExecutorContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Effect.Executor
  alias Spectre.Effect.Executor.Mount
  alias Spectre.EffectConfig
  alias Spectre.Extension
  alias Spectre.Extension.Mount, as: ExtensionMount
  alias Spectre.Input
  alias Spectre.Provider.Failure
  alias Spectre.State

  @agent SpectreEffectExecutorContractTest.Agent
  @executor SpectreEffectExecutorContractTest.Executor

  test "extension executors normalize all supported mount forms" do
    assert [
             %Mount{kind: :observation, module: @executor, opts: [extension_option: :mounted]},
             %Mount{kind: :raw_observation, module: @executor, opts: []},
             %Mount{
               kind: :missing_executor,
               module: SpectreEffectExecutorContractTest.MissingExecutor,
               opts: []
             }
           ] = EffectConfig.executors(@agent)

    assert {:ok, %Mount{module: @executor}} = EffectConfig.executor(@agent, :observation)

    assert {:error, {:unsupported_effect_kind, :unknown}} =
             EffectConfig.executor(@agent, :unknown)

    empty = ExtensionMount.new(SpectreEffectExecutorContractTest.EmptyExtension, [])
    assert Extension.effect_executors(empty) == []

    invalid = ExtensionMount.new(SpectreEffectExecutorContractTest.InvalidExtension, [])

    assert_raise ArgumentError, ~r/invalid effect executor contribution/, fn ->
      Extension.effect_executors(invalid)
    end

    assert_raise ArgumentError, ~r/duplicate effect executor/, fn ->
      EffectConfig.executors(SpectreEffectExecutorContractTest.DuplicateAgent)
    end
  end

  test "dispatch normalizes Context and executor replies without transferring state ownership" do
    effect = effect(:ok)
    context = context(context_option: :kept)

    assert {:ok, %{agent: @agent, payload: %{page: 1}}} =
             Executor.dispatch(effect, context,
               test_pid: self(),
               dispatch_option: :added
             )

    assert_receive {:effect_executor_called, "effect-ok", %Context{} = callback_context, opts}
    assert callback_context.agent == @agent
    assert callback_context.state == context.state
    assert callback_context.opts[:context_option] == :kept
    assert callback_context.opts[:extension_option] == :mounted
    assert callback_context.opts[:dispatch_option] == :added
    assert callback_context.opts[:effect_id] == "effect-ok"
    assert callback_context.opts[:idempotency_key] == effect.idempotency_key
    assert callback_context.opts[:effect_owner] == @agent
    assert callback_context.opts[:effect_scope] == :agent
    assert callback_context.opts[:effect_kind] == :observation
    refute Keyword.has_key?(opts, :context_option)
    assert Keyword.drop(callback_context.opts, [:context_option]) == opts

    assert {:ok, :raw_result} = Executor.dispatch(effect(:raw), %{agent: @agent})
    assert {:error, :declined} = Executor.dispatch(effect(:error), context())
  end

  test "dispatch rejects missing configuration and enforces payload and result bounds" do
    assert {:error, {:effect_agent_missing, "effect-ok"}} =
             Executor.dispatch(effect(:ok), %{})

    assert {:error, {:unsupported_effect_kind, :unknown}} =
             Executor.dispatch(effect(:ok, :unknown), context())

    assert {:error, {:invalid_effect_executor, :missing_executor, _module}} =
             Executor.dispatch(effect(:ok, :missing_executor), context())

    assert {:error, {:effect_payload_too_large, :payload, bytes, 1}} =
             Executor.dispatch(effect(:ok), context(), effect_payload_max_bytes: 1)

    assert bytes > 1

    assert {:error, {:effect_payload_too_large, :result, result_bytes, 1}} =
             Executor.dispatch(effect(:large), context(), effect_result_max_bytes: 1)

    assert result_bytes > 1

    assert {:error, {:effect_payload_too_large, :payload, _bytes, :invalid}} =
             Executor.dispatch(effect(:ok), context(), effect_payload_max_bytes: :invalid)
  end

  test "executor infrastructure failures remain ambiguous while declared errors do not" do
    for {name, expected_kind} <- [
          {:raise, :exception},
          {:throw, :throw},
          {:exit, :exit},
          {:timeout, :timeout}
        ] do
      opts = if name == :timeout, do: [effect_timeout: 5], else: []

      assert {:error,
              {:effect_outcome_ambiguous, :observation,
               %Failure{provider: :effect, kind: ^expected_kind}}} =
               Executor.dispatch(effect(name), context(), opts)
    end

    assert {:error, :declined} = Executor.dispatch(effect(:error), context())
  end

  test "executor mounts reject action ownership and malformed registrations" do
    assert %Mount{kind: :observation, module: @executor, opts: [mode: :read]} =
             Mount.new(:observation, @executor, mode: :read)

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      Mount.new(:observation, @executor, [:not_keyword])
    end

    assert_raise ArgumentError, ~r/:action is owned/, fn ->
      Mount.new(:action, @executor)
    end

    for invalid <- [
          {nil, @executor, []},
          {:observation, nil, []},
          {"observation", @executor, []},
          {:observation, @executor, %{}}
        ] do
      assert_raise ArgumentError, ~r/invalid effect executor/, fn ->
        invalid |> Tuple.to_list() |> then(&apply(Mount, :new, &1))
      end
    end
  end

  defp effect(name, kind \\ :observation) do
    Effect.restore(%{
      id: "effect-#{name}",
      kind: kind,
      name: name,
      owner: @agent,
      scope: :agent,
      payload: %{page: 1}
    })
  end

  defp context(opts \\ []) do
    %Context{
      agent: @agent,
      input: Input.new("observe"),
      state: %State{},
      opts: opts
    }
  end
end
