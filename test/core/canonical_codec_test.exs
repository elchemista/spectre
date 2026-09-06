defmodule Spectre.Core.CanonicalCodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Canonical.Value

  # Ported from main@9fad62e:test/canonical_value_test.exs. The wire contract
  # survives the runtime replacement; the allowlisted struct is now test-local.
  defmodule Record do
    defstruct [:id, metadata: %{}]
  end

  property "portable trees round-trip without changing canonical bytes or digests" do
    check all(value <- portable_value(), max_runs: 250) do
      assert {:ok, encoded} = Value.encode(value)
      assert {:ok, restored} = Value.decode(encoded)
      assert restored === value
      assert :ok = Value.validate(value)
      assert Value.encode!(restored) == encoded

      assert Value.digest!(restored) ==
               Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
    end
  end

  test "map insertion order and encoding process do not change identity" do
    left = Map.new([{:charlie, 3}, {:alpha, 1}, {{:tuple, 2}, %{nested: true}}])
    right = Map.new(Enum.reverse(Map.to_list(left)))
    assert {:ok, encoded} = Value.encode(left)
    assert Value.encode(right) == {:ok, encoded}
    assert Task.await(Task.async(fn -> Value.encode(right) end)) == {:ok, encoded}
  end

  test "dedicated scalar tags cannot be aliased through the atom tag, even in a collection" do
    for atom <- ["nil", "true", "false"] do
      payload = <<0x13, byte_size(atom)::32, atom::binary>>
      assert {:error, :noncanonical_value_encoding} = Value.decode(<<"SPCV", 1, payload::binary>>)

      assert {:error, :noncanonical_value_encoding} =
               Value.decode(<<"SPCV", 1, 0x20, 1::32, payload::binary>>)
    end
  end

  test "an allowlisted struct cannot masquerade as a canonical map" do
    fields = [{:__struct__, Record}, {:id, "x"}, {:metadata, %{}}]

    body =
      fields
      |> Enum.map(fn {k, v} -> {payload!(k), payload!(v)} end)
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [k, v] end)

    encoded = IO.iodata_to_binary([<<"SPCV", 1, 0x22, 3::32>>, body])

    assert {:error, :noncanonical_value_encoding} =
             Value.decode(encoded, allowed_structs: [Record])

    assert {:error, :noncanonical_value_encoding} = Value.decode(encoded)
  end

  property "accepted mutated encodings still have exactly one canonical representation" do
    check all(
            value <- portable_value(),
            offset <- non_negative_integer(),
            byte <- integer(0..255),
            max_runs: 350
          ) do
      encoded = Value.encode!(value)
      position = rem(offset, byte_size(encoded))
      <<before::binary-size(^position), _old, after_bytes::binary>> = encoded
      mutated = <<before::binary, byte, after_bytes::binary>>

      case Value.decode(mutated) do
        {:ok, decoded} -> assert Value.encode!(decoded) === mutated
        {:error, _} -> :ok
      end
    end
  end

  test "a struct allowlist is required independently at encode and decode" do
    record = %Record{id: "portable", metadata: %{role: :operator}}
    assert {:error, {:disallowed_canonical_struct, [], Record}} = Value.encode(record)
    assert {:ok, encoded} = Value.encode(record, allowed_structs: [Record])
    assert {:ok, ^record} = Value.decode(encoded, allowed_structs: [Record])
    name = Atom.to_string(Record)
    assert {:error, {:disallowed_canonical_struct, [], ^name}} = Value.decode(encoded)
  end

  test "VM-local values and improper lists fail with typed reasons" do
    for {value, type} <- [
          {self(), :pid},
          {make_ref(), :reference},
          {fn -> :ok end, :function},
          {<<1::1>>, :bitstring}
        ] do
      assert {:error, {:unsupported_canonical_value, [], ^type}} = Value.encode(value)
    end

    assert {:error, {:improper_canonical_list, [{:tail, 1}]}} = Value.encode([:head | :tail])
    assert_raise ArgumentError, fn -> Value.encode!(%{worker: self()}) end
    assert_raise ArgumentError, fn -> Value.digest!(%{callback: fn -> :ok end}) end
  end

  test "unknown atoms are rejected without interning their names" do
    unknown = "spectre_canonical_atom_#{System.unique_integer([:positive])}"
    encoded = <<"SPCV", 1, 0x13, byte_size(unknown)::32, unknown::binary>>
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, {:unknown_canonical_atom, [], ^unknown}} = Value.decode(encoded)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "unknown tags, versions, headers and trailing bytes are not silently accepted" do
    assert {:error, {:unknown_canonical_tag, [], 0xFF}} = Value.decode(<<"SPCV", 1, 0xFF>>)
    assert {:error, {:unsupported_canonical_version, 2}} = Value.decode(<<"SPCV", 2, 0>>)
    assert {:error, :invalid_canonical_header} = Value.decode("bad")
    assert {:error, {:invalid_canonical_binary, :atom}} = Value.decode(:invalid)
    assert {:error, {:truncated_canonical_value, []}} = Value.decode(<<"SPCV", 1>>)
    assert {:error, {:trailing_canonical_bytes, 1}} = Value.decode(Value.encode!(nil) <> <<0>>)
  end

  test "integers have one spelling and declared binary lengths are enforced" do
    assert {:error, {:invalid_canonical_integer, []}} =
             Value.decode(<<"SPCV", 1, 0x10, 1::32, "x">>)

    for integer <- ["007", "+7", "-0"] do
      assert {:error, {:noncanonical_integer, []}} =
               Value.decode(<<"SPCV", 1, 0x10, byte_size(integer)::32, integer::binary>>)
    end

    assert {:error, {:truncated_canonical_value, :binary}} =
             Value.decode(<<"SPCV", 1, 0x12, 5::32, "no">>)
  end

  test "allowed struct payloads must contain the exact declared fields" do
    module_name = Atom.to_string(Record)

    for fields <- [%{id: "missing-metadata"}, %{id: "extra", metadata: %{}, extra: 1}] do
      encoded =
        <<"SPCV", 1, 0x23, byte_size(module_name)::32, module_name::binary,
          payload!(fields)::binary>>

      assert {:error, {:invalid_canonical_struct_fields, [], Record, actual, expected}} =
               Value.decode(encoded, allowed_structs: [Record])

      refute MapSet.new(actual) == MapSet.new(expected)
      assert MapSet.new(expected) == MapSet.new([:id, :metadata])
    end
  end

  test "map decoding rejects duplicate and out-of-order keys" do
    for keys <- [[:b, :a], [:a, :a]] do
      [first, second] = Enum.map(keys, &payload!/1)

      encoded =
        <<"SPCV", 1, 0x22, 2::32, first::binary, payload!(1)::binary, second::binary,
          payload!(2)::binary>>

      assert {:error, {:noncanonical_map_order, []}} = Value.decode(encoded)
    end
  end

  test "every truncation of a nested valid value is rejected" do
    encoded = Value.encode!(%{"data" => [{:ok, [1, 2, 3]}, %{"binary" => <<0, 255>>}]})

    for size <- 0..(byte_size(encoded) - 1) do
      assert {:error, _} = Value.decode(binary_part(encoded, 0, size))
    end
  end

  test "collection and depth limits apply to decoding as well as encoding" do
    for value <- [[1, 2], {1, 2}, %{"a" => 1, "b" => 2}] do
      encoded = Value.encode!(value)
      assert {:error, _} = Value.encode(value, max_collection_size: 1)
      assert {:error, _} = Value.decode(encoded, max_collection_size: 1)
    end

    encoded = Value.encode!([[:nested]])
    assert {:error, _} = Value.encode([[:nested]], max_depth: 1)
    assert {:error, _} = Value.decode(encoded, max_depth: 1)
    assert {:ok, [[:nested]]} = Value.decode(encoded, max_depth: 2)
  end

  defp payload!(value) do
    <<"SPCV", 1, payload::binary>> = Value.encode!(value)
    payload
  end

  defp portable_value do
    scalar =
      one_of([
        constant(nil),
        boolean(),
        integer(-100_000..100_000),
        float(min: -10_000.0, max: 10_000.0),
        string(:utf8, max_length: 20),
        binary(max_length: 12),
        member_of([:ok, :error, :queued, __MODULE__])
      ])

    scalar
    |> tree(fn child ->
      one_of([
        list_of(child, max_length: 4),
        tuple({child, child}),
        map_of(one_of([integer(-8..8), string(:alphanumeric, max_length: 8)]), child,
          max_length: 4
        )
      ])
    end)
    |> resize(8)
  end
end
