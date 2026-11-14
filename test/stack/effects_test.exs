defmodule Spectre.Stack.EffectsTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.{Effects, Installation, Package}

  @descriptor %{
    contract: 1,
    adapter: Spectre.Server.GAM.EffectAdapter,
    operation: :send,
    side_effect: :non_idempotent,
    material: :arguments,
    partition: [:subject],
    schema_hash: "schema:v1",
    config: %{}
  }

  test "effect registration is explicit immutable data with a closed descriptor" do
    entries = %{{:mail, :send} => @descriptor}
    assert Effects.validate!(entries) == entries

    for descriptor <- [
          Map.delete(@descriptor, :adapter),
          Map.put(@descriptor, :executor, {Kernel, :apply}),
          Map.put(@descriptor, :contract, 2),
          Map.put(@descriptor, :partition, [:credentials]),
          Map.put(@descriptor, :config, %{callback: fn -> :ok end})
        ] do
      assert_raise ArgumentError, fn -> Effects.validate!(%{send: descriptor}) end
    end
  end

  test "effect registration and schema changes are covered by installation identity" do
    package = Package.new!(__MODULE__, %{id: :mail, version: "0.1.0"})
    first = Installation.build!(:mail, package, %{}, %{effects: %{send: @descriptor}}, false)

    changed =
      Installation.build!(
        :mail,
        package,
        %{},
        %{effects: %{send: %{@descriptor | schema_hash: "schema:v2"}}},
        false
      )

    refute first.digest == changed.digest
    assert Installation.rebuild!(first) == first
    assert Installation.build!(:mail, package, %{}, %{}, false).adapters == %{}
  end
end
