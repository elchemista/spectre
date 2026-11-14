defmodule Spectre.Server.ManagedMaterialTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.GAM.Managed.Material

  test "material exposes exact values with readable field names" do
    assert Material.render(%{"to" => "dev@example.com", "body" => "Hello\nsecond line"}) ==
             "{\n  Body: \"Hello\\nsecond line\"\n  To: \"dev@example.com\"\n}"

    assert Material.render(%{selected_text: "Account contact"}) ==
             "{\n  Selected text: \"Account contact\"\n}"
  end

  test "long and nested material is retained without inspect truncation" do
    body = String.duplicate("a", 10_000)
    rendered = Material.render(%{"body" => body, "attachments" => [%{"name" => "report.csv"}]})
    assert rendered =~ body
    assert rendered =~ "Attachments: [\n    {\n      Name: \"report.csv\"\n    }\n  ]"
    refute rendered =~ "%{"
  end

  test "model strings cannot inject sibling fields or Unicode direction changes" do
    value = %{"body" => "ciao\nTo: friend@example.com\r\u202Eevil\u2066\0", "to" => "evil@x"}
    rendered = Material.render(value)
    assert rendered =~ "Body: \"ciao\\nTo: friend@example.com\\r\\u{202E}evil\\u{2066}\\u{0}\""
    assert length(Regex.scan(~r/^  To:/m, rendered)) == 1
    refute rendered =~ "\u202E"
    refute rendered =~ "\0"
    refute Material.render("\u202E") == Material.render("\\u{202E}")
    assert Material.render(:"atom\u202E") == ":\"atom\\u{202E}\""
  end

  test "nested fields, colliding normalized keys and value types stay distinct" do
    rendered = Material.render(%{"meta" => %{"to" => "nested"}, "to" => "outer"})
    assert rendered =~ "Meta: {\n    To: \"nested\"\n  }"
    assert rendered =~ "\n  To: \"outer\""

    assert Material.render(%{:a_b => 1, "a b" => 2}) =~ ":\"a_b\": 1"
    assert Material.render(%{:a_b => 1, "a b" => 2}) =~ "\"a b\": 2"
    refute Material.render(["x"]) == Material.render({"x"})
    refute Material.render("nil") == Material.render(nil)
    refute Material.render(<<255>>) == Material.render("binary(0xFF)")
  end
end
