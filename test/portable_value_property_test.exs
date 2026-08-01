defmodule SpectrePortableValuePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Run.Value
  alias Spectre.Stack.Value, as: StackValue
  alias Spectre.Subject

  property "portable nested values survive the JSON checkpoint representation" do
    check all(value <- portable_value(), max_runs: 300) do
      assert :ok = Value.validate(value)
      assert StackValue.portable?(value)

      assert {:ok, encoded} = Value.encode(value)
      assert {:ok, json} = Jason.encode(encoded)
      assert {:ok, decoded_json} = Jason.decode(json)
      assert :ok = Value.prepare(decoded_json)
      assert {:ok, restored} = Value.decode(decoded_json)
      assert restored == value

      assert Value.token("portable-property", restored) ==
               Value.token("portable-property", value)

      assert StackValue.digest(restored) == StackValue.digest(value)
    end
  end

  property "a nonportable leaf is rejected at every generated nesting shape" do
    check all({value, expected_kind} <- nonportable_value(), max_runs: 200) do
      assert {:error, {:nonportable_run_value, path, ^expected_kind}} = Value.validate(value)
      assert is_list(path)
      refute StackValue.portable?(value)
      assert {:error, _reason} = Value.encode(value)
    end
  end

  defp portable_value do
    scalar =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(-100_000..100_000),
        StreamData.float(min: -10_000.0, max: 10_000.0),
        StreamData.string(:utf8, max_length: 24),
        StreamData.member_of([:ok, :error, :queued, :waiting, Spectre.Input])
      ])

    scalar
    |> StreamData.tree(fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 5),
        StreamData.tuple({child, child}),
        StreamData.map_of(portable_key(), child, max_length: 5),
        StreamData.map(child, fn payload ->
          %Subject{id: "property-subject", metadata: %{payload: payload}}
        end)
      ])
    end)
    |> StreamData.resize(10)
  end

  defp portable_key do
    StreamData.one_of([
      StreamData.integer(-16..16),
      StreamData.string(:alphanumeric, max_length: 12),
      StreamData.member_of([:alpha, :beta, :gamma, nil]),
      StreamData.tuple({
        StreamData.member_of([:left, :right]),
        StreamData.integer(0..4)
      })
    ])
  end

  defp nonportable_value do
    StreamData.map(
      {
        StreamData.member_of([:pid, :reference, :function, :improper_list]),
        StreamData.member_of([:root, :list, :tuple, :map_key, :map_value, :deep]),
        portable_value()
      },
      fn {kind, location, payload} ->
        leaf = nonportable_leaf(kind, payload)
        {nest_nonportable(location, leaf, payload), kind}
      end
    )
  end

  defp nonportable_leaf(:pid, _payload), do: self()
  defp nonportable_leaf(:reference, _payload), do: make_ref()
  defp nonportable_leaf(:function, payload), do: fn -> payload end
  defp nonportable_leaf(:improper_list, payload), do: [payload | :improper_tail]

  defp nest_nonportable(:root, leaf, _payload), do: leaf
  defp nest_nonportable(:list, leaf, payload), do: [payload, leaf]
  defp nest_nonportable(:tuple, leaf, payload), do: {payload, leaf}
  defp nest_nonportable(:map_key, leaf, payload), do: %{leaf => payload}
  defp nest_nonportable(:map_value, leaf, payload), do: %{payload: payload, invalid: leaf}

  defp nest_nonportable(:deep, leaf, payload) do
    %{outer: [{payload, %Subject{id: "nested-subject", metadata: %{invalid: leaf}}}]}
  end
end
