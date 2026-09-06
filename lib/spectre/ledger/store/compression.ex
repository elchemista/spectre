defmodule Spectre.Ledger.Store.Compression do
  @moduledoc """
  Optional physical compression of canonical storage bytes.

  Compression is below the ledger format: decompression returns the exact
  original bytes, so Entry digests, exports and idempotency do not change.
  Small/incompressible values stay unwrapped. Readers accept both forms,
  allowing a host to change its write policy without rewriting old records.

  The envelope declares the decoded size and its SHA-256 checksum. Neither is
  trusted: inflation proceeds in small chunks under the caller's byte limit,
  and the actual size/checksum are checked before canonical decoding. This
  checksum detects damage; it is not an authenticity signature.
  """

  @magic "SPZB"
  @version 1
  @header_bytes 45

  @spec pack(binary(), boolean()) :: binary()
  def pack(bytes, false) when is_binary(bytes), do: bytes

  def pack(bytes, true) when is_binary(bytes) do
    compressed = :zlib.compress(bytes)

    if byte_size(compressed) + @header_bytes < byte_size(bytes) do
      digest = :crypto.hash(:sha256, bytes)

      <<@magic, @version, byte_size(bytes)::unsigned-big-64, digest::binary-size(32),
        compressed::binary>>
    else
      bytes
    end
  end

  @spec unpack(binary(), pos_integer()) :: {:ok, binary()} | {:error, term()}
  def unpack(bytes, max_bytes)
      when is_binary(bytes) and is_integer(max_bytes) and max_bytes > 0 do
    case bytes do
      <<@magic, @version, size::unsigned-big-64, digest::binary-size(32), body::binary>> ->
        if size <= max_bytes and byte_size(bytes) <= max_bytes + @header_bytes,
          do: inflate(body, size, digest),
          else: {:error, :compressed_ledger_value_too_large}

      <<@magic, _rest::binary>> ->
        {:error, :invalid_ledger_compression_envelope}

      _plain when byte_size(bytes) <= max_bytes ->
        {:ok, bytes}

      _too_large ->
        {:error, :ledger_storage_value_too_large}
    end
  end

  def unpack(_bytes, _max_bytes), do: {:error, :invalid_ledger_storage_value}

  defp inflate(body, size, digest) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream)

      with {:ok, chunks} <- collect(stream, :zlib.safeInflate(stream, body), size, []),
           :ok <- :zlib.inflateEnd(stream),
           decoded = chunks |> Enum.reverse() |> IO.iodata_to_binary(),
           true <- byte_size(decoded) === size,
           true <- :crypto.hash(:sha256, decoded) === digest do
        {:ok, decoded}
      else
        false -> {:error, :ledger_compression_integrity_mismatch}
        {:error, _} = error -> error
      end
    rescue
      ErlangError -> {:error, :invalid_compressed_ledger_value}
    after
      :zlib.close(stream)
    end
  end

  defp collect(stream, {status, output}, remaining, chunks)
       when status in [:continue, :finished] do
    remaining = remaining - IO.iodata_length(output)

    cond do
      remaining < 0 -> {:error, :compressed_ledger_value_too_large}
      status == :finished -> {:ok, [output | chunks]}
      true -> collect(stream, :zlib.safeInflate(stream, []), remaining, [output | chunks])
    end
  end

  defp collect(_stream, _dictionary_required, _remaining, _chunks),
    do: {:error, :invalid_compressed_ledger_value}
end
