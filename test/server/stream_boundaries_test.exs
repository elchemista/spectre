defmodule Spectre.Server.StreamBoundariesTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.ProviderEvent
  alias Spectre.Server.Stream

  defmodule Model do
    def complete(_, _), do: raise("streaming must use the configured transport")
  end

  defmodule Agent do
    use Spectre.Agent
    model(Model)
  end

  defmodule Transport do
    @behaviour Spectre.Inference.StreamAdapter
    def capabilities(_, _), do: MapSet.new([:stream, :pull_transport])
    def open(_, opts), do: {:ok, Keyword.fetch!(opts, :events), %{}}
    def request_transport_item([]), do: {:error, :disconnected}

    def request_transport_item([event | rest]) do
      send(self(), {:next, event})
      {:ok, rest}
    end

    def handle_transport({:next, {:error, reason}}, state), do: {:error, reason, state}
    def handle_transport({:next, :malformed_reply}, _state), do: :malformed_reply
    def handle_transport({:next, event}, state), do: {:ok, [event], state}
    def handle_transport(_message, state), do: {:ignore, state}
    def cancel(_, _), do: :ok
  end

  defp run(events, opts \\ [], request \\ %{planning: false, preview: :off}) do
    prepared = %{
      selection: %{level: :test, model: Transport},
      descriptor: %{id: "boundaries"},
      provider_opts: []
    }

    context = %{consumer: self(), interaction: "boundaries"}

    Stream.run(
      prepared,
      request,
      context,
      Keyword.merge([stream_adapter: Transport, stream_adapter_opts: [events: events]], opts)
    )
  end

  test "provider lifecycle events do not alter the consolidated answer" do
    assert {:ok, %{text: "answer"}} =
             run([
               ProviderEvent.new(:started),
               ProviderEvent.new(:usage, usage: %{input_tokens: 1}),
               ProviderEvent.delta("answer"),
               ProviderEvent.completed("answer")
             ])

    assert_receive {Spectre.Server, nil, {:preview_end, "boundaries", "boundaries", :completed}},
                   2_000
  end

  test "duplicate start and provider failure cannot consolidate a successful answer" do
    assert {:error, :duplicate_provider_started} =
             run([ProviderEvent.new(:started), ProviderEvent.new(:started)])

    assert {:error, :rate_limited} =
             run([
               ProviderEvent.delta("unfinished"),
               ProviderEvent.new(:failed, payload: :rate_limited)
             ])

    assert_receive {Spectre.Server, nil,
                    {:preview_end, "boundaries", "boundaries", {:error, :rate_limited}}},
                   2_000
  end

  test "transport disconnects, declared errors and malformed replies remain failures" do
    assert {:error, :disconnected} = run([])
    assert {:error, :socket_closed} = run([{:error, :socket_closed}])
    assert {:error, {:invalid_stream_transport_reply, :malformed_reply}} = run([:malformed_reply])
  end

  test "invalid preview and adapter bindings fail before opening transport" do
    assert {:error, {:streaming_unsupported, :adapter}} = run([], stream_adapter: nil)
    assert {:error, :invalid_preview_mode} = run([], [], %{planning: false, preview: :raw})
  end

  test "invalid UTF8 at the terminal boundary cannot be presented as a completion" do
    assert {:error, :incomplete_provider_utf8} =
             run([ProviderEvent.delta(<<0xC3>>), ProviderEvent.completed("terminal")])
  end

  @tag :tmp_dir
  test "the default generation service opens a prepared stream and consolidates its terminal answer",
       %{tmp_dir: root} do
    File.write!(Path.join(root, "pricing.text.heex"), "Give the current price")
    input = Spectre.Input.new("pricing")

    context = %{
      agent: Agent,
      options: [prompt_root: root],
      assigns: %{},
      routing: %{},
      input: input,
      memory: nil,
      consumer: self(),
      interaction: "service-stream"
    }

    request = %{
      input: input,
      prompt: :pricing,
      assigns: %{},
      planning: false,
      stream: true,
      preview: :off
    }

    events = [ProviderEvent.delta("Ten euros"), ProviderEvent.completed("Ten euros")]

    assert {:generated, %{text: "Ten euros", proposals: []}} =
             Spectre.Server.Services.generate(request, context,
               stream_adapter: {Transport, events: events}
             )
  end
end
