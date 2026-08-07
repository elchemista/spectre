defmodule SpectreReplySanitizerTest do
  use ExUnit.Case, async: true

  alias Spectre.Reply.Sanitizer

  doctest Spectre.Reply.Sanitizer

  test "strips Spectre control tokens and reasoning wrappers" do
    text = """
    <think>let me reason</think><!-- routing note -->
    <REPLY>Ciao! Posso aiutarti.</REPLY>
    INTENT: PRICING
    al: create_project
    <al kind="plan">create_project(budget: 100)</al>
    <intent>PRICING</intent>
    """

    assert Sanitizer.sanitize(text) == "Ciao! Posso aiutarti."
  end

  test "repeated blocks are all removed" do
    assert Sanitizer.sanitize("a<al>1</al>b<al>2</al>c") == "abc"
  end

  test "Unicode case folding never shifts block offsets and wrapper tags ignore case" do
    assert Sanitizer.sanitize("İstanbul <THINK>gizli</tHiNk> cevap") == "İstanbul  cevap"
    assert Sanitizer.sanitize("<RePlY>Città già pronta</rEpLy>") == "Città già pronta"
  end

  test "unterminated blocks are left alone" do
    assert Sanitizer.sanitize("hello <al>dangling") == "hello <al>dangling"
  end

  test "plain replies pass through trimmed" do
    assert Sanitizer.sanitize("  just a reply  ") == "just a reply"
  end

  test "sanitize_reply: false only trims" do
    assert Sanitizer.sanitize("<al>x</al> hi", sanitize_reply: false) == "<al>x</al> hi"
  end

  test "the runner's default clean path strips control tokens" do
    assert Spectre.ActionPlanner.clean_reply("<intent>HELP</intent>hello") == "hello"

    assert {:ok, %{reply_text: "hello", effects: []}} =
             Spectre.ActionPlanner.plan_response("<al>a</al>hello")
  end
end
