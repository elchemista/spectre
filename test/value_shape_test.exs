defmodule Spectre.ValueShapeTest do
  use ExUnit.Case, async: true

  test "each boundary retains its supported error vocabulary" do
    for {value, kinds, expected} <- [
          {nil, [:atom], :atom},
          {false, [:atom], :atom},
          {%URI{}, [:map], :map},
          {<<1::1>>, [:binary], :other},
          {42, [:integer], :integer},
          {2.5, [:map, :list, :tuple], :other},
          {42, [:map, :list, :tuple], :other}
        ] do
      assert Spectre.ValueShape.of(value, kinds) == expected
    end
  end
end
