defmodule Spectre.Server.StoreBindingTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.Store.Binding
  alias Spectre.Server.GAM.Managed.Store, as: Memory

  defmodule Agent do
    use Spectre.Agent
  end

  defmodule Package do
    use Spectre.Stack.Installable,
      id: :store_binding,
      version: "0.1.0",
      spectre: "~> 0.4.0",
      provides: [{:contract, {:spectre, :server_store, 1}}],
      resources: [:journal],
      metadata: %{server_store: %{adapter: Spectre.Server.GAM.Managed.Store, resource: :journal}}

    def child_specs(_, opts) do
      if opts[:enabled], do: [{:journal, {Spectre.Server.GAM.Managed.Store, []}}], else: []
    end
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule StoredAgent do
    use Spectre.Agent, stack: Stack
  end

  test "only configured Stack resources are selected; absence preserves the fallback" do
    empty = start_supervised!({Spectre.Stack.Runtime, stack: Stack}, id: :empty)

    assert {:ok, {Memory, :fallback}} =
             Binding.resolve([agent: StoredAgent, stack_runtime: empty], {Memory, :fallback})

    runtime =
      start_supervised!(
        {Spectre.Stack.Runtime, stack: Stack, packages: [store_binding: [enabled: true]]}
      )

    {:ok, resource} = Spectre.Stack.resolve(Stack, :resource, :journal)
    {:ok, store} = Spectre.Stack.Runtime.resolve(runtime, resource)

    assert {:ok, {Memory, ^store}} =
             Binding.configured(agent: StoredAgent, stack_runtime: runtime)
  end

  test "explicit coordination store takes precedence over checkpoint and fallback" do
    selected = {Memory, :selected}

    assert {:ok, ^selected} =
             Binding.resolve(
               [
                 store: selected,
                 options: [checkpoint: {Memory, :checkpoint, :key}]
               ],
               {Memory, :fallback}
             )

    assert {:ok, {Memory, :checkpoint}} =
             Binding.resolve(
               [
                 options: [checkpoint: {Memory, :checkpoint, :key}]
               ],
               {Memory, :fallback}
             )

    assert {:ok, {Memory, :checkpoint}} =
             Binding.configured(
               options: [
                 checkpoint: {Memory, :checkpoint, :key},
                 payload_store: {__MODULE__, []}
               ]
             )

    assert {:ok, {Memory, :fallback}} = Binding.resolve([agent: Agent], {Memory, :fallback})
    assert {:ok, nil} = Binding.configured(agent: Agent)
    assert {:ok, nil} = Binding.configured(store: nil)
  end

  test "invalid tagged adapter fails closed" do
    assert {:error, :invalid_managed_coordination_store} =
             Binding.configured(store: {:store, __MODULE__, :missing})
  end
end
