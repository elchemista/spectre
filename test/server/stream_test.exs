defmodule Spectre.Server.StreamTest do
  use ExUnit.Case, async: true
  alias Spectre.Inference.{ProviderEvent, Response}
  alias Spectre.Server.{Context, Plan, Stream}

  defmodule Transport do
    @behaviour Spectre.Inference.StreamAdapter
    def capabilities(_profile, _opts), do: MapSet.new([:stream, :pull_transport])
    def open(_descriptor, opts), do: {:ok, Keyword.fetch!(opts, :events), %{}}

    def request_transport_item([event | rest]) do
      send(self(), {:owned_transport, event})
      {:ok, rest}
    end

    def request_transport_item([]), do: {:error, :missing_terminal}
    def handle_transport({:owned_transport, event}, state), do: {:ok, [event], state}
    def handle_transport(_other, state), do: {:ignore, state}
    def cancel(_state, _reason), do: :ok
  end

  defmodule Projection do
    @behaviour Spectre.Server.PublicProjection
    def init(_opts), do: {:ok, nil}
    def push(public, state), do: {:ok, public, state}
    def finish(_state), do: {:ok, ""}
  end

  defp prepared do
    %{
      selection: %{level: :test, model: Transport},
      descriptor: %{id: "generation"},
      provider_opts: []
    }
  end

  defp stream(chunks, request_opts \\ %{}, opts \\ []) do
    text = Enum.join(chunks)
    events = Enum.map(chunks, &ProviderEvent.delta/1) ++ [ProviderEvent.completed(text)]
    opts = Keyword.merge([stream_adapter: {Transport, events: events}], opts)
    request = Map.merge(%{planning: false, preview: :auto}, request_opts)
    consumer = self()

    Task.async(fn ->
      Stream.run(prepared(), request, %{consumer: consumer, interaction: "interaction"}, opts)
    end)
    |> Task.await()
  end

  test "stream yields safe provisional text and preserves raw output for consolidation" do
    chunks = ["<thi", "nk>private</think>", "Hello\n<", "al>delete account</al>"]
    assert {:ok, %Response{text: text}} = stream(chunks)
    assert text == Enum.join(chunks)
    previews = previews()
    assert String.contains?(previews, "Hello")
    refute String.contains?(previews, "private")
    refute String.contains?(previews, "delete")
    refute String.contains?(previews, "<al")
  end

  test "planning preview requires an explicit public projection" do
    assert {:ok, _} = stream(["hello"], %{planning: true})
    assert previews() == ""

    assert {:error, {:preview_unsupported, :planner_cleaner_not_incremental}} =
             stream(["hello"], %{planning: true, preview: :required})

    assert {:ok, _} =
             stream(["hello"], %{planning: true, preview: :required},
               public_projection: Projection
             )

    assert previews() == "hello"
  end

  test "projection validates callbacks before opening transport" do
    assert {:error, :invalid_public_projection} =
             stream(["hello"], %{planning: true}, public_projection: String)
  end

  test "UTF8 split across transport chunks is reassembled before preview" do
    assert {:ok, _} = stream([<<0xC3>>, <<0xA8>>, " bello"])
    assert previews() == "è bello"
  end

  test "provider sequence, terminal consistency and output bounds are checked" do
    events = [
      ProviderEvent.delta("one", provider_sequence: 1),
      ProviderEvent.completed("one", provider_sequence: 3)
    ]

    assert {:error, :provider_sequence_violation} =
             Stream.run(
               prepared(),
               %{planning: false, preview: :off},
               %{consumer: self(), interaction: "interaction"},
               stream_adapter: {Transport, events: events}
             )

    events = [ProviderEvent.delta("one"), ProviderEvent.completed("different")]

    assert {:error, :provider_terminal_text_mismatch} =
             Stream.run(
               prepared(),
               %{planning: false, preview: :off},
               %{consumer: self(), interaction: "interaction"},
               stream_adapter: {Transport, events: events}
             )

    assert {:error, :provider_stream_overflow} =
             stream(["too much"], %{preview: :off}, max_output_bytes: 2)
  end

  test "plans submit one proposal at a time and withhold generated success claims" do
    first = %{operation: :first, args: %{}}
    second = %{operation: :second, args: %{}}
    ctx = Plan.start(%Context{}, [first, second])
    assert [command] = ctx.commands
    assert command.kind == :propose
    assert command.args == [:first, %{}]
    assert command.opts[:on_result] == {Plan, [second]}
    next = Plan.continue(%Context{}, [second], {:governed, %{outcome: %{status: :succeeded}}})
    assert [command] = next.commands
    assert command.args == [:second, %{}]
    stopped = Plan.continue(%Context{}, [second], {:governed, %{decision: %{outcome: :refused}}})
    assert [command] = stopped.commands
    assert command.kind == :respond
  end

  defp previews(acc \\ "") do
    receive do
      {Spectre.Server, _runtime, {:preview, "interaction", "generation", text}} ->
        previews(acc <> text)
    after
      0 -> acc
    end
  end
end
