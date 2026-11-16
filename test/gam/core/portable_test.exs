Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.Core.PortableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  require Spectre.GAM.Portable

  alias Spectre.GAM.Portable

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

  test "content reference convenience functions preserve the same wire and digest contract" do
    value = %{"scope" => "support", "revision" => 1}
    assert Portable.canonical(value) === Portable.canonical_value(value)
    assert Portable.ref(:record, value) === Portable.content_ref("record", value)

    assert {:error, {:invalid_content_ref, :integer}} =
             Portable.resolve_content_ref(:record, 1, value)

    assert {:error, {:invalid_content_ref_prefix, :map}} =
             Portable.validate_content_ref("ref", %{}, :record)

    for invalid <- [self(), make_ref(), fn -> :capability end, <<1::1>>] do
      assert_raise ArgumentError, fn -> Portable.canonical_value!(invalid) end
      assert_raise ArgumentError, fn -> Portable.digest!(invalid) end
      assert_raise ArgumentError, fn -> Portable.content_ref!(:record, invalid) end
    end
  end

  test "invalid containers and callback results cannot masquerade as canonical records" do
    for {invalid, shape} <- [
          {%URI{}, :struct},
          {{:ref, "x"}, :tuple},
          {make_ref(), :reference},
          {<<1::1>>, :bitstring}
        ] do
      assert Portable.shape(invalid) == shape
      assert {:error, {:invalid_canonical_map, ^shape}} = Portable.canonical_map(invalid)
    end

    for invalid <- [nil, %URI{}, {:ok, %{}}] do
      assert {:error, {:invalid_canonical_record, :record}} =
               Portable.restore_canonical(
                 %{},
                 fn _ -> {:ok, %{}} end,
                 fn _ -> invalid end,
                 :record
               )
    end

    assert {:error, {:unknown_attribute, :record, 1}} =
             Portable.normalize_attrs(%{1 => "hidden"}, [:known], :record)
  end

  test "normalizing nested semantic keys rejects collisions at the exact nested path" do
    collision = %{:account => "A", "account" => "B"}

    for {value, path} <- [
          {[collision], [0, "account"]},
          {{:source, collision}, [1, "account"]},
          {%{"parent" => collision}, ["parent", "account"]}
        ] do
      assert {:error, {:equivalent_map_keys, ^path}} = Portable.stringify_atom_keys(value)
    end
  end
end
