defmodule SpectreExtensionEdgeContractTest.Provider do
  @moduledoc false
end

defmodule SpectreExtensionEdgeContractTest.NoCallbacks do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def id, do: :no_callbacks

  @impl true
  def api_version, do: 1
end

defmodule SpectreExtensionEdgeContractTest.ApiTwo do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def api_version, do: 2
end

defmodule SpectreExtensionEdgeContractTest.Callbacks do
  @moduledoc false
  @behaviour Spectre.Extension

  alias Spectre.Flow.Constraint

  @impl true
  def id, do: :coverage_callbacks

  @impl true
  def api_version, do: 1

  @impl true
  def setup(_owner, opts) do
    case Keyword.get(opts, :setup, :ok) do
      :ok -> :ok
      :error -> {:error, :setup_failed}
      :invalid -> :unexpected
    end
  end

  @impl true
  def compile(_owner, opts) do
    case Keyword.get(opts, :compile, :ok) do
      :ok -> {:ok, Keyword.get(opts, :compiled, opts)}
      :raw -> :raw_config
      :error -> {:error, :compile_failed}
    end
  end

  @impl true
  def flow_constraints(opts, {:flow, :ok}) do
    constraints = [
      %Constraint{namespace: :channel, values: [:web]},
      [namespace: :tenant, values: [:internal]]
    ]

    {constraints, Keyword.delete(opts, :consumed)}
  end

  def flow_constraints(_opts, {:flow, :error}), do: {:error, :flow_failed}
  def flow_constraints(_opts, {:flow, :invalid}), do: :unexpected

  @impl true
  def agent_config({:agent_config, config}), do: config
  def agent_config(_config), do: []

  @impl true
  def action_providers({:providers, providers}), do: providers
  def action_providers(_config), do: []

  @impl true
  def action_planner({:planner, planner}), do: planner
  def action_planner(_config), do: nil

  @impl true
  def inference_selector({:selector, selector}), do: selector
  def inference_selector(_config), do: nil

  @impl true
  def expand_handler(handler, _caller, opts) do
    case Keyword.get(opts, :expand, :ignore) do
      :ignore -> :ignore
      :ok -> {:ok, quote(do: reply(:expanded))}
      :same -> {:ok, handler}
      :error -> {:error, :expansion_failed}
      :invalid -> :unexpected
    end
  end
end

defmodule SpectreExtensionEdgeContractTest.FirstSelector do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def id, do: :first_selector

  @impl true
  def inference_selector(_config), do: SpectreExtensionEdgeContractTest.Provider
end

defmodule SpectreExtensionEdgeContractTest.SecondSelector do
  @moduledoc false
  @behaviour Spectre.Extension

  @impl true
  def id, do: :second_selector

  @impl true
  def inference_selector(_config), do: {SpectreExtensionEdgeContractTest.Provider, mode: :two}
end

defmodule SpectreExtensionEdgeContractTest.EmptyAgent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreExtensionEdgeContractTest.MultiSelectorAgent do
  @moduledoc false
  use Spectre.Agent

  Spectre.Extension.register!(__MODULE__, SpectreExtensionEdgeContractTest.FirstSelector)
  Spectre.Extension.register!(__MODULE__, SpectreExtensionEdgeContractTest.SecondSelector)
end

defmodule SpectreExtensionEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Action.Provider.Mount, as: ProviderMount
  alias Spectre.Extension
  alias Spectre.Extension.Mount

  alias SpectreExtensionEdgeContractTest.ApiTwo
  alias SpectreExtensionEdgeContractTest.Callbacks
  alias SpectreExtensionEdgeContractTest.EmptyAgent
  alias SpectreExtensionEdgeContractTest.MultiSelectorAgent
  alias SpectreExtensionEdgeContractTest.NoCallbacks
  alias SpectreExtensionEdgeContractTest.Provider

  test "compile callbacks accept wrapped and raw values and contain failures" do
    assert %Mount{compiled: :wrapped} =
             Extension.compile_mount!(__MODULE__, callback_mount(nil, compiled: :wrapped))

    assert %Mount{compiled: :raw_config} =
             Extension.compile_mount!(__MODULE__, callback_mount(nil, compile: :raw))

    assert_raise ArgumentError, ~r/compile failed: :compile_failed/, fn ->
      Extension.compile_mount!(__MODULE__, callback_mount(nil, compile: :error))
    end

    no_callbacks = Mount.new(NoCallbacks, marker: :kept)

    assert [%Mount{compiled: [marker: :kept]}] =
             Extension.compile_all!(__MODULE__, [no_callbacks])
  end

  test "flow and Agent configuration callbacks normalize values and reject bad replies" do
    flow = callback_mount({:flow, :ok})
    empty = %{Mount.new(NoCallbacks, []) | compiled: :unused}

    assert {[first, second], [left: true]} =
             Extension.flow_constraints(
               [consumed: true, left: true],
               [flow, empty]
             )

    assert first == %Spectre.Flow.Constraint{namespace: :channel, values: [:web]}
    assert second.namespace == :tenant

    assert_raise ArgumentError, ~r/flow_constraints failed: :flow_failed/, fn ->
      Extension.flow_constraints(callback_mount({:flow, :error}), [])
    end

    assert_raise ArgumentError, ~r/invalid_reply/, fn ->
      Extension.flow_constraints(callback_mount({:flow, :invalid}), [])
    end

    first = callback_mount({:agent_config, [adapter: :first, timeout: 10]})

    assert Extension.merge_agent_config([timeout: 20], [first]) == [adapter: :first, timeout: 20]
    assert Extension.agent_config(empty) == []

    assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
      Extension.merge_agent_config([:invalid], [])
    end

    assert_raise ArgumentError, ~r/agent_config failed.*invalid_reply/, fn ->
      Extension.agent_config(callback_mount({:agent_config, :invalid}))
    end

    second = callback_mount({:agent_config, [adapter: :second]}, id: :second)

    assert_raise ArgumentError, ~r/both contribute Agent configuration :adapter/, fn ->
      Extension.merge_agent_config([], [first, second])
    end
  end

  test "providers, planners and selectors normalize every supported public form" do
    existing = ProviderMount.new(:existing, Provider)

    assert [
             ^existing,
             %ProviderMount{id: :short, module: Provider, opts: []},
             %ProviderMount{id: :configured, module: Provider, opts: [mode: :safe]}
           ] =
             Extension.action_providers(
               callback_mount(
                 {:providers,
                  [
                    existing,
                    {:short, Provider},
                    {:configured, Provider, mode: :safe}
                  ]}
               )
             )

    assert Extension.action_providers(%{Mount.new(NoCallbacks, []) | compiled: nil}) == []

    assert_raise ArgumentError, ~r/invalid action provider contribution/, fn ->
      Extension.action_providers(callback_mount({:providers, [:invalid]}))
    end

    assert Extension.action_planner(callback_mount({:planner, nil})) == nil
    assert Extension.action_planner(callback_mount({:planner, Provider})) == {Provider, []}

    assert Extension.action_planner(callback_mount({:planner, {Provider, mode: :safe}})) ==
             {Provider, [mode: :safe]}

    assert_raise ArgumentError, ~r/action planner options must be a keyword list/, fn ->
      Extension.action_planner(callback_mount({:planner, {Provider, [:invalid]}}))
    end

    assert_raise ArgumentError, ~r/invalid action planner contribution/, fn ->
      Extension.action_planner(callback_mount({:planner, 123}))
    end

    assert Extension.inference_selector(callback_mount({:selector, Provider})) == {Provider, []}

    assert_raise ArgumentError, ~r/multiple inference selectors configured/, fn ->
      Extension.inference_selector(MultiSelectorAgent)
    end

    assert_raise ArgumentError, ~r/unknown Spectre extension module/, fn ->
      Extension.action_planner(%Mount{id: :missing, module: Missing.Extension, api_version: 1})
    end
  end

  test "registration validates owners, API versions, setup and duplicate mounts" do
    assert_raise ArgumentError, ~r/must be used after `use Spectre.Agent`/, fn ->
      compile_module("NoOwner", """
      Spectre.Extension.register!(__MODULE__, #{inspect(NoCallbacks)})
      """)
    end

    assert_raise ArgumentError, ~r/can only extend a Spectre Agent/, fn ->
      compile_module("WrongOwner", """
      Module.register_attribute(__MODULE__, :spectre_extensions, accumulate: true)
      Module.register_attribute(__MODULE__, :spectre_kind, persist: true)
      @spectre_kind :skill
      Spectre.Extension.register!(__MODULE__, #{inspect(NoCallbacks)})
      """)
    end

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      compile_agent("InvalidOptions", """
      Spectre.Extension.register!(__MODULE__, #{inspect(NoCallbacks)}, [:invalid])
      """)
    end

    assert_raise ArgumentError, ~r/unsupported Spectre extension API 2/, fn ->
      compile_agent("UnsupportedApi", """
      Spectre.Extension.register!(__MODULE__, #{inspect(ApiTwo)})
      """)
    end

    assert_raise ArgumentError, ~r/setup failed: :setup_failed/, fn ->
      compile_agent("SetupError", """
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)}, setup: :error)
      """)
    end

    assert_raise ArgumentError, ~r/setup failed.*invalid_reply/, fn ->
      compile_agent("SetupInvalid", """
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)}, setup: :invalid)
      """)
    end

    assert [_compiled] =
             compile_agent("StackRefIdempotent", """
             Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)}, stack_ref: :stack)
             Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)})
             """)

    assert_raise ArgumentError, ~r/duplicate Spectre extension/, fn ->
      compile_agent("DuplicateDefault", """
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)})
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)})
      """)
    end

    assert_raise ArgumentError, ~r/duplicate Spectre extension/, fn ->
      compile_agent("DuplicateConfigured", """
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)}, marker: :first)
      Spectre.Extension.register!(__MODULE__, #{inspect(Callbacks)}, marker: :second)
      """)
    end

    assert {:error, {:extension_not_mounted, :missing}} = Extension.fetch(EmptyAgent, :missing)
  end

  defp callback_mount(config, opts \\ []) do
    id = Keyword.get(opts, :id, :coverage_callbacks)
    opts = Keyword.delete(opts, :id)

    %Mount{id: id, module: Callbacks, api_version: 1, opts: opts, compiled: config}
  end

  defp compile_agent(suffix, body), do: compile_module(suffix, "use Spectre.Agent\n" <> body)

  defp compile_module(suffix, body) do
    module = Module.concat(__MODULE__, "Dynamic#{suffix}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      @moduledoc false
      #{body}
    end
    """)
  end
end
