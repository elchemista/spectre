defmodule SpectreJSONTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.JSON, as: SpectreJSON

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

  property "pretty formatting preserves every generated JSON value" do
    check all(value <- json_value(), max_runs: 500) do
      compact = SpectreJSON.encode!(value)
      pretty = SpectreJSON.encode!(value, pretty: true)

      assert SpectreJSON.decode!(pretty) == SpectreJSON.decode!(compact)
      refute String.ends_with?(pretty, "\n")
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
      {1,
       StreamData.member_of([
         ~S(quote: \"),
         ~S(backslashes: \\),
         ~S(mixed: \\\"),
         ~S(delimiters: { } [ ] , : /),
         "line\nfeed\ttab",
         ""
       ])}
    ])
  end
end
