defmodule SpectreStackRuntimeInstanceOptionTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :stack_runtime_instance_option_agent
end

defmodule SpectreStackRuntimeInstanceOptionTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Configuration
  alias Spectre.Instance.Ref
  alias Spectre.Instance.RuntimeOptions
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Subject

  alias SpectreStackRuntimeInstanceOptionTest.Agent

  test "top-level stack_runtime is explicit runtime-only configuration" do
    ref = Ref.new(Agent, "top-level-runtime")

    assert {:ok, config} =
             Configuration.load(Agent, ref,
               stack_runtime: __MODULE__.Runtime,
               opts: [model: :configured]
             )

    assert config.stack_runtime == __MODULE__.Runtime
    refute Keyword.has_key?(config.base_opts, :stack_runtime)

    runtime_opts = RuntimeOptions.build(instance_state(ref, config), [], %Spectre.Input{})
    assert runtime_opts[:stack_runtime] == __MODULE__.Runtime
    refute Map.has_key?(runtime_opts[:run_metadata], :stack_runtime)
  end

  test "nested stack_runtime remains compatible but is removed from base options" do
    ref = Ref.new(Agent, "nested-runtime")
    via = {:via, Registry, {__MODULE__.Registry, :memory}}

    assert {:ok, config} =
             Configuration.load(Agent, ref, opts: [stack_runtime: via, model: :configured])

    assert config.stack_runtime == via
    assert config.base_opts[:model] == :configured
    refute Keyword.has_key?(config.base_opts, :stack_runtime)
  end

  test "runtime process handles are rejected at Instance configuration" do
    ref = Ref.new(Agent, "invalid-runtime")

    assert {:error, {:invalid_instance_option, :stack_runtime, pid}} =
             Configuration.load(Agent, ref, stack_runtime: self())

    assert pid == self()

    assert {:error, {:invalid_instance_option, :stack_runtime, reference}} =
             Configuration.load(Agent, ref, stack_runtime: make_ref())

    assert is_reference(reference)
  end

  defp instance_state(ref, config) do
    %InstanceState{
      agent: Agent,
      agent_ref: ref.agent_ref,
      ref: ref,
      subject: Subject.new(ref.subject),
      state: %Spectre.State{},
      base_opts: config.base_opts,
      stack_runtime: config.stack_runtime
    }
  end
end
