defmodule Spectre.Core.PortableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Spectre.Portable

  alias Spectre.Portable

  property "shared scalar guards preserve the exact primitive predicates" do
    check all(value <- term()) do
      assert Portable.is_plain_map(value) == (is_map(value) and not is_struct(value))
      assert Portable.is_non_negative_integer(value) == (is_integer(value) and value >= 0)
      assert Portable.is_positive_integer(value) == (is_integer(value) and value > 0)
      assert Portable.is_non_empty_binary(value) == (is_binary(value) and value != "")
      assert Portable.keyword?(value) == (is_list(value) and Keyword.keyword?(value))
    end
  end

  test "container guards exclude structs and keyword detection rejects improper lists" do
    refute Portable.is_plain_map(%URI{})
    assert Portable.is_plain_map(%{})
    refute Portable.keyword?([{:key, :value} | :improper])
    refute Portable.keyword?(%{})
    assert Portable.keyword?([])
    assert Portable.keyword?(key: :value)
  end

  test "strict restoration does not confuse integer and float canonical representations" do
    builder = fn data -> {:ok, %{"quantity" => trunc(data["quantity"])}} end
    canonicalizer = fn record -> record end

    assert {:ok, %{"quantity" => 1}} =
             Portable.restore_canonical(%{"quantity" => 1}, builder, canonicalizer, :example)

    assert {:error, {:noncanonical_record, :example}} =
             Portable.restore_canonical(%{"quantity" => 1.0}, builder, canonicalizer, :example)
  end
end
