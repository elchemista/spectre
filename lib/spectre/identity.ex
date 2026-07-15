defmodule Spectre.Identity do
  @moduledoc """
  Generates durable identifiers shared by runtime entities.

  UUIDv7 keeps identifiers unique across processes, restarts, and BEAM nodes
  while retaining creation-time ordering. It replaces process-local
  `System.unique_integer/1` identifiers at persistence boundaries.
  """

  @typedoc "A canonical lowercase UUID string."
  @type uuid7 :: <<_::288>>

  @doc """
  Generates an RFC 9562 UUIDv7 string.
  """
  @spec uuid7() :: uuid7()
  def uuid7 do
    unix_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _discard::6>> = :crypto.strong_rand_bytes(10)

    <<unix_ms::unsigned-big-48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> encode_uuid()
  end

  @doc """
  Derives a stable idempotency key from an effect identifier.
  """
  @spec idempotency_key(term()) :: String.t()
  def idempotency_key(id) when is_binary(id), do: "effect:" <> id

  def idempotency_key(id) do
    digest =
      id
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "effect:" <> binary_part(digest, 0, 32)
  end

  @spec encode_uuid(binary()) :: uuid7()
  defp encode_uuid(binary) when byte_size(binary) == 16 do
    hex = Base.encode16(binary, case: :lower)

    Enum.map_join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end
end
