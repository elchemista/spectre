defmodule Spectre.CoreTest.LedgerCompressionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Canonical.Value
  alias Spectre.Ledger.Store.Compression

  property "storage compression preserves the exact canonical bytes" do
    check all(value <- binary(max_length: 4_096), max_runs: 60) do
      bytes = Value.encode!(%{"body" => value})

      for compressed <- [true, false] do
        packed = Compression.pack(bytes, compressed)
        assert byte_size(packed) <= byte_size(bytes)
        assert {:ok, ^bytes} = Compression.unpack(packed, byte_size(bytes))
      end
    end
  end

  test "compressible data shrinks while small values remain plain" do
    bytes = Value.encode!(%{"body" => String.duplicate("hello", 10_000)})
    packed = Compression.pack(bytes, true)
    assert byte_size(packed) < div(byte_size(bytes), 10)
    assert <<"SPZB", 1, _rest::binary>> = packed
    assert {:ok, ^bytes} = Compression.unpack(packed, byte_size(bytes))
    assert Compression.pack("small", true) === "small"
  end

  test "declared expansion is rejected before decompression" do
    bytes = String.duplicate("x", 100_000)

    assert {:error, :compressed_ledger_value_too_large} =
             bytes |> Compression.pack(true) |> Compression.unpack(1_000)
  end

  test "a lying expansion length cannot turn a small read budget into a zip bomb" do
    # The forged declared length is below the limit; checking only the header
    # would allocate the entire 8 MiB. The streaming inflater stops at 1 KiB.
    raw = String.duplicate("x", 8 * 1_024 * 1_024)
    body = :zlib.compress(raw)
    envelope = <<"SPZB", 1, 1_024::64, 0::256, body::binary>>

    assert {:error, :compressed_ledger_value_too_large} =
             Compression.unpack(envelope, 64 * 1_024)

    parent = self()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          send(parent, {:limited_inflate, self(), Compression.unpack(envelope, 64 * 1_024)})
        end,
        [:monitor, {:max_heap_size, %{size: 100_000, kill: true, error_logger: false}}]
      )

    assert_receive {:limited_inflate, ^pid, {:error, :compressed_ledger_value_too_large}}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "truncation, mismatched digest and wrong expanded size are rejected" do
    bytes = String.duplicate("x", 10_000)
    <<"SPZB", 1, size::64, digest::binary-size(32), body::binary>> = Compression.pack(bytes, true)

    for corrupt <- [
          <<"SPZB", 2, size::64, digest::binary, body::binary>>,
          <<"SPZB", 1, size::64, 0::256, body::binary>>,
          <<"SPZB", 1, size + 1::64, digest::binary, body::binary>>,
          <<"SPZB", 1, size::64, digest::binary,
            binary_part(body, 0, byte_size(body) - 1)::binary>>,
          "SPZB"
        ] do
      assert {:error, _} = Compression.unpack(corrupt, 20_000)
    end
  end

  test "plain bytes are also bounded and invalid options do not crash" do
    assert {:error, :ledger_storage_value_too_large} = Compression.unpack("1234", 3)
    assert {:error, _} = Compression.unpack("x", 0)
    assert {:error, _} = Compression.unpack(nil, 1)
  end
end
