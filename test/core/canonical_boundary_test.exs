defmodule Spectre.Core.CanonicalBoundaryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Canonical.Value

  test "the byte budget includes the header and every sibling, including map keys" do
    for value <- [
          nil,
          true,
          false,
          -123,
          1.5,
          "text",
          :ok,
          [],
          {},
          %{},
          ["ab", "cd"],
          {"ab", "cd"},
          %{"ab" => "cd"},
          [%{"a" => {"b", [1, 2, 3]}}]
        ] do
      assert {:ok, encoded} = Value.encode(value)
      size = byte_size(encoded)
      assert {:ok, ^encoded} = Value.encode(value, max_bytes: size)
      assert {:ok, ^value} = Value.decode(encoded, max_bytes: size)

      assert {:error, {:canonical_value_too_large, used, limit}} =
               Value.encode(value, max_bytes: size - 1)

      assert used > limit
      assert limit == size - 1
    end
  end

  test "known wire vectors do not change with the budgeted encoder" do
    for {value, payload} <- [
          {nil, <<0>>},
          {false, <<1>>},
          {true, <<2>>},
          {-12, <<0x10, 3::32, "-12">>},
          {1.5, <<0x11, 1.5::float-64>>},
          {"ab", <<0x12, 2::32, "ab">>},
          {:ok, <<0x13, 2::32, "ok">>},
          {[nil, true], <<0x20, 2::32, 0, 2>>},
          {{false, nil}, <<0x21, 2::32, 1, 0>>},
          {%{"b" => true, "a" => nil}, <<0x22, 2::32, 0x12, 1::32, "a", 0, 0x12, 1::32, "b", 2>>}
        ] do
      expected = <<"SPCV", 1, payload::binary>>
      assert {:ok, ^expected} = Value.encode(value)
      assert {:ok, ^value} = Value.decode(expected)
      assert {:ok, digest} = Value.digest(value)
      assert digest == Base.encode16(:crypto.hash(:sha256, expected), case: :lower)
    end
  end

  test "malformed options and improper allowlists return errors, never exceptions" do
    for opts <- [
          [allowed_structs: [URI | :broken]],
          [allowed_structs: [URI, 42]],
          [max_bytes: 0],
          [max_depth: -1],
          [max_collection_size: -1],
          [{:max_bytes, 10} | :broken]
        ] do
      assert {:error, _reason} = Value.encode(nil, opts)
      assert {:error, _reason} = Value.decode(<<"SPCV", 1, 0>>, opts)
    end
  end

  test "an allowed struct still needs its exact declared fields to be encodable" do
    uri = %URI{scheme: "https", host: "example.test"}
    assert {:ok, encoded} = Value.encode(uri, allowed_structs: [URI])
    assert {:ok, ^uri} = Value.decode(encoded, allowed_structs: [URI])

    for malformed <- [Map.put(uri, :extra, 1), Map.delete(uri, :host)] do
      assert {:error, _reason} = Value.encode(malformed, allowed_structs: [URI])
    end
  end

  property "bounded arbitrary bytes cannot crash or smuggle an alternative canonical encoding" do
    check all(payload <- binary(max_length: 256), max_runs: 300) do
      encoded = <<"SPCV", 1, payload::binary>>

      case Value.decode(encoded) do
        {:ok, value} -> assert {:ok, ^encoded} = Value.encode(value)
        {:error, _reason} -> :ok
      end
    end
  end
end
