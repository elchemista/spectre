defmodule SpectreCanonicalValueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Canonical.Value
  alias Spectre.Subject

  property "portable values round-trip through stable canonical bytes" do
    check all(value <- portable_value(), max_runs: 250) do
      assert {:ok, encoded} = Value.encode(value)
      assert {:ok, ^value} = Value.decode(encoded)
      assert :ok = Value.validate(value)
      assert {:ok, digest} = Value.digest(value)
      assert digest == Value.digest!(value)
      assert byte_size(digest) == 64
    end
  end

  test "map order and process identity do not affect canonical bytes" do
    left = Map.new([{:charlie, 3}, {:alpha, 1}, {{:tuple, 2}, %{nested: true}}])
    right = Map.new(Enum.reverse(Map.to_list(left)))

    assert {:ok, encoded} = Value.encode(left)
    assert Value.encode(right) == {:ok, encoded}

    task = Task.async(fn -> Value.encode(right) end)
    assert Task.await(task) == {:ok, encoded}
  end

  test "structs require an explicit allowlist and retain their type" do
    subject = %Subject{id: "canonical-subject", metadata: %{role: :operator}}

    assert {:error, {:disallowed_canonical_struct, [], Subject}} = Value.encode(subject)

    assert {:ok, encoded} = Value.encode(subject, allowed_structs: [Subject])
    assert {:ok, ^subject} = Value.decode(encoded, allowed_structs: [Subject])

    assert {:error, {:disallowed_canonical_struct, [], "Elixir.Spectre.Subject"}} =
             Value.decode(encoded)
  end

  test "nonportable VM values and improper lists fail with typed reasons" do
    assert {:error, {:unsupported_canonical_value, [], :pid}} = Value.encode(self())
    assert {:error, {:unsupported_canonical_value, [], :reference}} = Value.encode(make_ref())
    assert {:error, {:unsupported_canonical_value, [], :function}} = Value.encode(fn -> :ok end)
    assert {:error, {:unsupported_canonical_value, [], :bitstring}} = Value.encode(<<1::1>>)

    assert {:error, {:improper_canonical_list, [{:tail, 1}]}} =
             Value.encode([:head | :tail])

    assert_raise ArgumentError, ~r/non-canonical Spectre value/, fn ->
      Value.encode!(%{worker: self()})
    end

    assert_raise ArgumentError, ~r/non-canonical Spectre value/, fn ->
      Value.digest!(%{callback: fn -> :ok end})
    end
  end

  test "decoder rejects unknown atoms, tags, versions, malformed values and trailing bytes" do
    unknown = "spectre_canonical_atom_#{System.unique_integer([:positive])}"
    atom_payload = <<0x13, byte_size(unknown)::unsigned-big-32, unknown::binary>>

    assert {:error, {:unknown_canonical_atom, [], ^unknown}} =
             Value.decode("SPCV" <> <<1>> <> atom_payload)

    assert {:error, {:unknown_canonical_tag, [], 0xFF}} = Value.decode("SPCV" <> <<1, 0xFF>>)
    assert {:error, {:unsupported_canonical_version, 2}} = Value.decode("SPCV" <> <<2, 0>>)
    assert {:error, :invalid_canonical_header} = Value.decode("bad")
    assert {:error, {:invalid_canonical_binary, :atom}} = Value.decode(:invalid)
    assert {:error, {:truncated_canonical_value, []}} = Value.decode("SPCV" <> <<1>>)

    assert {:ok, encoded_nil} = Value.encode(nil)

    assert {:error, {:trailing_canonical_bytes, 1}} =
             Value.decode(encoded_nil <> <<0>>)

    assert {:error, {:invalid_canonical_integer, []}} =
             Value.decode("SPCV" <> <<1, 0x10, 1::unsigned-big-32, "x">>)

    for integer <- ["007", "+7", "-0"] do
      assert {:error, {:noncanonical_integer, []}} =
               Value.decode(
                 "SPCV" <> <<1, 0x10, byte_size(integer)::unsigned-big-32, integer::binary>>
               )
    end

    assert {:error, {:truncated_canonical_value, :binary}} =
             Value.decode("SPCV" <> <<1, 0x12, 5::unsigned-big-32, "no">>)
  end

  test "struct decoding requires the exact declared field set" do
    module_name = Atom.to_string(Subject)

    for fields <- [%{id: "subject-without-metadata"}, %{id: "subject", metadata: %{}, extra: 1}] do
      <<"SPCV", 1, encoded_fields::binary>> = Value.encode!(fields)

      encoded =
        "SPCV" <>
          <<1, 0x23, byte_size(module_name)::unsigned-big-32, module_name::binary,
            encoded_fields::binary>>

      assert {:error, {:invalid_canonical_struct_fields, [], Subject, actual, expected}} =
               Value.decode(encoded, allowed_structs: [Subject])

      refute MapSet.new(actual) == MapSet.new(expected)
      assert MapSet.new(expected) == MapSet.new([:id, :metadata])
    end
  end

  test "decoder requires strictly sorted, unique canonical map keys" do
    key_a = payload!(:a)
    key_b = payload!(:b)
    one = payload!(1)
    two = payload!(2)

    reversed =
      "SPCV" <>
        <<1, 0x22, 2::unsigned-big-32>> <>
        key_b <> one <> key_a <> two

    duplicate =
      "SPCV" <>
        <<1, 0x22, 2::unsigned-big-32>> <>
        key_a <> one <> key_a <> two

    assert {:error, {:noncanonical_map_order, []}} = Value.decode(reversed)
    assert {:error, {:noncanonical_map_order, []}} = Value.decode(duplicate)
  end

  test "limits and options are validated on both encode and decode" do
    assert {:error, :invalid_canonical_options} = Value.encode(:ok, [:not_keyword])
    assert {:error, :invalid_canonical_options} = Value.decode("SPCV" <> <<1, 0>>, :bad)

    assert {:error, {:invalid_canonical_option, :max_bytes, 0}} =
             Value.encode(:ok, max_bytes: 0)

    assert {:error, {:invalid_canonical_option, :max_depth, -1}} =
             Value.encode(:ok, max_depth: -1)

    assert {:error, {:invalid_allowed_structs, [:ok, "bad"]}} =
             Value.encode(:ok, allowed_structs: [:ok, "bad"])

    assert {:error, {:canonical_value_too_large, _actual, 5}} =
             Value.encode("too large", max_bytes: 5)

    assert {:error, {:canonical_depth_exceeded, [0], 0}} =
             Value.encode([:nested], max_depth: 0)

    assert {:error, {:canonical_collection_too_large, [], 2, 1}} =
             Value.encode([:one, :two], max_collection_size: 1)

    encoded = Value.encode!([:one, :two])

    assert {:error, {:canonical_collection_too_large, [], 2, 1}} =
             Value.decode(encoded, max_collection_size: 1)
  end

  test "format metadata is explicit" do
    assert Value.version() == 1
    assert Value.digest_algorithm() == :sha256
  end

  defp payload!(value) do
    <<"SPCV", 1, payload::binary>> = Value.encode!(value)
    payload
  end

  defp portable_value do
    scalar =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(-100_000..100_000),
        StreamData.float(min: -10_000.0, max: 10_000.0),
        StreamData.string(:utf8, max_length: 20),
        StreamData.binary(max_length: 12),
        StreamData.member_of([:ok, :error, :queued, Spectre.Input])
      ])

    scalar
    |> StreamData.tree(fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 4),
        StreamData.tuple({child, child}),
        StreamData.map_of(portable_key(), child, max_length: 4)
      ])
    end)
    |> StreamData.resize(8)
  end

  defp portable_key do
    StreamData.one_of([
      StreamData.integer(-8..8),
      StreamData.string(:alphanumeric, max_length: 8),
      StreamData.member_of([:alpha, :beta, nil]),
      StreamData.tuple({StreamData.member_of([:left, :right]), StreamData.integer(0..3)})
    ])
  end
end
