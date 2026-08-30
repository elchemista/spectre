defmodule SpectreJSONTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.JSON, as: SpectreJSON

  @hostile_strings [
    "{",
    "}",
    "[",
    "]",
    ",",
    ":",
    "\"",
    "\\",
    "\\\"",
    "\\\\",
    "a\"b",
    "x\\",
    ~S({"object":[1,2],"nested":{"ok":true}}),
    <<0, 8, 12, 10, 13, 9>>,
    "héllø λ 世界 👻"
  ]

  test "compact and pretty encoders keep the internal JSON contract" do
    value = %{"items" => [1, "two", []]}

    assert SpectreJSON.encode!(value) == ~s({"items":[1,"two",[]]})

    assert SpectreJSON.encode!(value, pretty: true) ==
             """
             {
               "items": [
                 1,
                 "two",
                 []
               ]
             }
             """
             |> String.trim_trailing()

    assert SpectreJSON.encode!(value, pretty: false) == SpectreJSON.encode!(value)
  end

  test "tagged and bang APIs expose standard JSON errors" do
    assert {:ok, ~s({"ok":true})} = SpectreJSON.encode(%{"ok" => true})
    assert {:error, %Protocol.UndefinedError{}} = SpectreJSON.encode(self())

    assert {:error, %JSON.DecodeError{}} = SpectreJSON.decode("{invalid")
    assert_raise JSON.DecodeError, fn -> SpectreJSON.decode!("{invalid") end
  end

  test "malformed bytes and unsupported values fail without a backend fallback" do
    for input <- ["", ~s({"key":), "true false", <<255>>] do
      assert {:error, %JSON.DecodeError{}} = SpectreJSON.decode(input)
    end

    assert {:error, %Protocol.UndefinedError{}} = SpectreJSON.encode({:tuple})
    assert {:error, %ErlangError{original: {:invalid_byte, 255}}} = SpectreJSON.encode(<<255>>)
    assert_raise Protocol.UndefinedError, fn -> SpectreJSON.encode!({:tuple}) end
  end

  test "pretty options reject ambiguous or unsupported input" do
    assert_raise ArgumentError, ~r/keyword list/, fn -> SpectreJSON.encode!(%{}, [:pretty]) end

    for opts <- [%{}, nil, :pretty, {:pretty, true}] do
      assert_raise ArgumentError, ~r/keyword list/, fn -> SpectreJSON.encode!(%{}, opts) end
    end

    assert_raise ArgumentError, ~r/unknown JSON options/, fn ->
      SpectreJSON.encode!(%{}, indentation: 4)
    end

    assert_raise ArgumentError, ~r/duplicate JSON option/, fn ->
      SpectreJSON.encode!(%{}, pretty: true, pretty: false)
    end

    assert_raise ArgumentError, ~r/expected :pretty to be a boolean/, fn ->
      SpectreJSON.encode!(%{}, pretty: :yes)
    end
  end

  test "pretty formatting treats structural and escaped bytes inside strings as data" do
    for hostile <- @hostile_strings do
      value = %{
        "outer" => [
          %{hostile => hostile},
          %{"suffix" => hostile <> "\\"},
          ["prefix:" <> hostile, %{"literal" => "{[,:]}"}]
        ]
      }

      compact = SpectreJSON.encode!(value)
      pretty = SpectreJSON.encode!(value, pretty: true)

      assert SpectreJSON.decode!(pretty) == SpectreJSON.decode!(compact)
      assert String.valid?(pretty)
      refute String.ends_with?(pretty, "\n")
      assert_two_space_indentation(pretty)
    end
  end

  test "pretty formatting keeps nested empty containers inline" do
    value = %{"root" => [%{}, [], %{"nested" => [%{}, []]}]}

    assert SpectreJSON.encode!(value, pretty: true) ==
             """
             {
               "root": [
                 {},
                 [],
                 {
                   "nested": [
                     {},
                     []
                   ]
                 }
               ]
             }
             """
             |> String.trim_trailing()
  end

  test "pretty formatting leaves top-level scalars semantically and bytewise stable" do
    for scalar <- [nil, true, false, 0, -42, 1.25, "", "plain", "x\\", "a\"b"] do
      assert SpectreJSON.encode!(scalar, pretty: true) == SpectreJSON.encode!(scalar)
    end
  end

  property "pretty formatting preserves every generated JSON value" do
    check all(value <- json_value(), max_runs: 800) do
      compact = SpectreJSON.encode!(value)
      pretty = SpectreJSON.encode!(value, pretty: true)

      assert SpectreJSON.decode!(pretty) == SpectreJSON.decode!(compact)
      assert String.valid?(pretty)
      refute String.ends_with?(pretty, "\n")
      assert_two_space_indentation(pretty)
    end
  end

  defp json_value do
    scalar =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(-1_000_000..1_000_000),
        StreamData.float(min: -1_000_000.0, max: 1_000_000.0),
        json_string()
      ])

    scalar
    |> StreamData.tree(fn child ->
      StreamData.one_of([
        StreamData.list_of(child, max_length: 8),
        StreamData.map_of(json_string(), child, max_length: 8)
      ])
    end)
    |> StreamData.resize(12)
  end

  defp json_string do
    StreamData.frequency([
      {4, StreamData.string(:utf8, max_length: 32)},
      {2, StreamData.member_of(@hostile_strings)},
      {1, StreamData.constant("")}
    ])
  end

  defp assert_two_space_indentation(json) do
    Enum.each(String.split(json, "\n"), fn line ->
      leading_bytes = byte_size(line) - byte_size(String.trim_leading(line))
      assert rem(leading_bytes, 2) == 0
    end)
  end
end
