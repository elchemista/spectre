defmodule Spectre.Id do
  @moduledoc """
  Generates opaque identifiers for operational ledger records.

  Operational identifiers answer *which occurrence?* and use UUIDv7. Semantic
  records answer *which value?* and therefore use their canonical content
  digest instead; those references are created by the record modules, not here.

  The source is explicit so callers at a boundary can substitute a deterministic
  implementation in tests without making UUID generation part of the kernel.
  """

  @typedoc "A canonical lowercase RFC 9562 UUIDv7 string."
  @type t :: <<_::288>>

  @typedoc "A module which supplies UUIDv7 values."
  @type source :: module()

  @doc "Generates and validates a UUIDv7 using `source`."
  @spec generate(source()) :: t()
  def generate(source \\ Spectre.Id.UUIDv7) when is_atom(source) do
    id = source.generate()

    if valid?(id) do
      id
    else
      raise ArgumentError,
            "#{inspect(source)} returned an invalid UUIDv7: #{inspect(id)}"
    end
  end

  @doc "Returns whether `value` is a canonical lowercase RFC 9562 UUIDv7."
  @spec valid?(term()) :: boolean()
  def valid?(
        <<_time_low::binary-size(8), ?-, _time_mid::binary-size(4), ?-, ?7,
          _version_tail::binary-size(3), ?-, variant, _variant_tail::binary-size(3), ?-,
          _node::binary-size(12)>> = value
      )
      when variant in [?8, ?9, ?a, ?b] do
    lowercase_hex?(value)
  end

  def valid?(_value), do: false

  defp lowercase_hex?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte == ?- or byte in ?0..?9 or byte in ?a..?f end)
  end
end
