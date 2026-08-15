defmodule SpectreReplySanitizerTest.DropToken do
  @moduledoc false

  @behaviour Spectre.Reply.Sanitizer

  @impl true
  def sanitize(text, opts), do: String.replace(text, Keyword.fetch!(opts, :token), "")

  @impl true
  def init_stream(opts), do: {:ok, Keyword.fetch!(opts, :token)}

  @impl true
  def sanitize_chunk(text, token), do: {:ok, String.replace(text, token, ""), token}

  @impl true
  def finish_stream(_token), do: {:ok, ""}
end

defmodule SpectreReplySanitizerTest.Failing do
  @moduledoc false

  @behaviour Spectre.Reply.Sanitizer

  @impl true
  def sanitize(_text, _opts), do: raise("extension failure")

  @impl true
  def init_stream(_opts), do: {:error, :unavailable}

  @impl true
  def sanitize_chunk(_text, _state), do: {:error, :unavailable}

  @impl true
  def finish_stream(_state), do: {:error, :unavailable}
end

defmodule SpectreReplySanitizerTest.PassthroughPlanner do
  @moduledoc false

  @behaviour Spectre.Action.Planner

  @impl true
  def plan_response(text, _ctx, _opts), do: %{reply_text: text, actions: []}

  @impl true
  def clean_reply(text, _ctx, _opts), do: text
end

defmodule SpectreReplySanitizerTest.TrailingBuffer do
  @moduledoc false

  @behaviour Spectre.Reply.Sanitizer

  @impl true
  def sanitize(text, _opts), do: text

  @impl true
  def init_stream(_opts), do: {:ok, ""}

  @impl true
  def sanitize_chunk(text, pending) do
    graphemes = String.graphemes(pending <> text)

    case Enum.split(graphemes, -1) do
      {[], trailing} -> {:ok, "", Enum.join(trailing)}
      {visible, trailing} -> {:ok, Enum.join(visible), Enum.join(trailing)}
    end
  end

  @impl true
  def finish_stream(pending), do: {:ok, pending}
end

defmodule SpectreReplySanitizerTest.ContractProbe do
  @moduledoc false

  @behaviour Spectre.Reply.Sanitizer

  @impl true
  def sanitize(text, opts) do
    case Keyword.get(opts, :terminal, :ok) do
      :invalid_utf8 -> <<255>>
      :invalid_reply -> :invalid
      :throw -> throw(:terminal_failure)
      :ok -> text
    end
  end

  @impl true
  def init_stream(opts) do
    case Keyword.get(opts, :init, :ok) do
      {:error, reason} -> {:error, reason}
      :invalid_reply -> :invalid
      :throw -> throw(:initialization_failure)
      :ok -> {:ok, opts}
    end
  end

  @impl true
  def sanitize_chunk(text, opts) do
    case Keyword.get(opts, :chunk, :ok) do
      :invalid_utf8 -> {:ok, <<255>>, opts}
      {:error, reason} -> {:error, reason}
      :invalid_reply -> :invalid
      :throw -> throw(:chunk_failure)
      :ok -> {:ok, text, opts}
    end
  end

  @impl true
  def finish_stream(opts) do
    case Keyword.get(opts, :finish, :ok) do
      :invalid_utf8 -> {:ok, <<255>>}
      {:error, reason} -> {:error, reason}
      :invalid_reply -> :invalid
      :throw -> throw(:finish_failure)
      :ok -> {:ok, ""}
    end
  end
end

defmodule SpectreReplySanitizerTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.StreamSanitizer
  alias Spectre.Reply.Sanitizer
  alias Spectre.Reply.Sanitizer.Runtime, as: SanitizerRuntime

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

  test "an optional sanitizer extends the core pass without replacing it" do
    opts = [reply_sanitizer: {SpectreReplySanitizerTest.DropToken, token: "~"}]

    assert Sanitizer.sanitize("<think>hidden</think>a~b", opts) == "ab"

    assert Sanitizer.sanitize("<al>core</al> a~b", Keyword.put(opts, :sanitize_reply, false)) ==
             "<al>core</al> a~b"
  end

  test "a failing optional sanitizer falls back to the safe core result" do
    assert Sanitizer.sanitize("<intent>hidden</intent>visible",
             reply_sanitizer: SpectreReplySanitizerTest.Failing
           ) == "visible"
  end

  test "planner output still crosses the core and configured sanitizer layers" do
    opts = [
      action_planner: SpectreReplySanitizerTest.PassthroughPlanner,
      reply_sanitizer: {SpectreReplySanitizerTest.DropToken, token: "~"}
    ]

    assert Spectre.ActionPlanner.clean_reply("<al>hidden</al>a~b", opts) == "ab"

    assert {:ok, %{reply_text: "ab", effects: []}} =
             Spectre.ActionPlanner.plan_response("<al>hidden</al>a~b", %{}, opts)
  end

  test "the streaming port carries extension state through finish" do
    assert {:ok, state} =
             StreamSanitizer.new(reply_sanitizer: SpectreReplySanitizerTest.TrailingBuffer)

    assert {:ok, "a", state} = StreamSanitizer.push(state, "ab")
    assert {:ok, "bc", state} = StreamSanitizer.push(state, "cd")
    assert {:ok, "d", _state} = StreamSanitizer.finish(state)
  end

  test "the streaming port reports extension initialization failures" do
    assert {:error,
            {:reply_sanitizer_failed, SpectreReplySanitizerTest.Failing, :init_stream,
             :unavailable}} =
             StreamSanitizer.new(reply_sanitizer: SpectreReplySanitizerTest.Failing)
  end

  test "the runtime validates terminal and malformed extension specifications" do
    assert :ok =
             SanitizerRuntime.validate(
               [reply_sanitizer: SpectreReplySanitizerTest.DropToken],
               :terminal
             )

    assert {:error, :invalid_reply_sanitizer_configuration} =
             SanitizerRuntime.validate([reply_sanitizer: 42], :terminal)

    assert {:error, :invalid_reply_sanitizer_configuration} =
             SanitizerRuntime.validate(
               [reply_sanitizer: {SpectreReplySanitizerTest.DropToken, [:not_keyword]}],
               :terminal
             )

    # Terminal rendering is deliberately fail-safe after the core sanitizer ran.
    assert SanitizerRuntime.sanitize("safe", reply_sanitizer: 42) == "safe"
  end

  test "the stream runtime rejects malformed callback replies and invalid UTF-8" do
    module = SpectreReplySanitizerTest.ContractProbe

    assert {:ok, invalid_utf8_chunk} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, chunk: :invalid_utf8})

    assert {:error, {:reply_sanitizer_failed, ^module, :sanitize_chunk, :invalid_utf8}} =
             SanitizerRuntime.sanitize_chunk(invalid_utf8_chunk, "visible")

    assert {:ok, invalid_chunk_reply} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, chunk: :invalid_reply})

    assert {:error, {:reply_sanitizer_failed, ^module, :sanitize_chunk, :invalid_reply}} =
             SanitizerRuntime.sanitize_chunk(invalid_chunk_reply, "visible")

    assert {:ok, invalid_utf8_finish} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, finish: :invalid_utf8})

    assert {:error, {:reply_sanitizer_failed, ^module, :finish_stream, :invalid_utf8}} =
             SanitizerRuntime.finish_stream(invalid_utf8_finish)

    assert {:ok, invalid_finish_reply} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, finish: :invalid_reply})

    assert {:error, {:reply_sanitizer_failed, ^module, :finish_stream, :invalid_reply}} =
             SanitizerRuntime.finish_stream(invalid_finish_reply)

    assert {:error, {:reply_sanitizer_failed, ^module, :init_stream, :invalid_reply}} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, init: :invalid_reply})
  end

  test "the stream runtime converts callback exits into stable typed failures" do
    module = SpectreReplySanitizerTest.ContractProbe

    assert {:error, {:reply_sanitizer_failed, ^module, :init_stream, :throw}} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, init: :throw})

    assert {:ok, chunk_state} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, chunk: :throw})

    assert {:error, {:reply_sanitizer_failed, ^module, :sanitize_chunk, :throw}} =
             SanitizerRuntime.sanitize_chunk(chunk_state, "visible")

    assert {:ok, finish_state} =
             SanitizerRuntime.init_stream(reply_sanitizer: {module, finish: :throw})

    assert {:error, {:reply_sanitizer_failed, ^module, :finish_stream, :throw}} =
             SanitizerRuntime.finish_stream(finish_state)

    # Terminal extensions cannot invalidate an already safe, core-sanitized reply.
    assert SanitizerRuntime.sanitize("safe", reply_sanitizer: {module, terminal: :throw}) ==
             "safe"
  end

  test "callback failure details are reduced to bounded public classes" do
    module = SpectreReplySanitizerTest.ContractProbe

    classifications = [
      {%URI{}, URI},
      {{:transport, :closed}, :transport},
      {%{private: :detail}, :map},
      {[:private, :detail], :list},
      {"private detail", :binary},
      {42, :other}
    ]

    for {reason, expected_class} <- classifications do
      assert {:ok, state} =
               SanitizerRuntime.init_stream(reply_sanitizer: {module, chunk: {:error, reason}})

      assert {:error, {:reply_sanitizer_failed, ^module, :sanitize_chunk, ^expected_class}} =
               SanitizerRuntime.sanitize_chunk(state, "visible")
    end

    assert {:ok, state} =
             SanitizerRuntime.init_stream(
               reply_sanitizer: {module, finish: {:error, :unavailable}}
             )

    assert {:error, {:reply_sanitizer_failed, ^module, :finish_stream, :unavailable}} =
             SanitizerRuntime.finish_stream(state)
  end

  test "the runner's default clean path strips control tokens" do
    assert Spectre.ActionPlanner.clean_reply("<intent>HELP</intent>hello") == "hello"

    assert {:ok, %{reply_text: "hello", effects: []}} =
             Spectre.ActionPlanner.plan_response("<al>a</al>hello")
  end
end
