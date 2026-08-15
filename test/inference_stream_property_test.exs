defmodule SpectreInferenceStreamPropertyTest.Agent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreInferenceStreamPropertyTest.Session do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)
    key = Keyword.fetch!(opts, :key)
    {:ok, _owner} = Registry.register(registry, key, %{})
    {:ok, Keyword.fetch!(opts, :replies)}
  end

  @impl GenServer
  def handle_call({:next, _token, _consumer, _claim, _demand}, _from, [reply]) do
    {:stop, :normal, reply, []}
  end

  def handle_call({:next, _token, _consumer, _claim, _demand}, _from, [reply | rest]) do
    {:reply, reply, rest}
  end
end

defmodule SpectreInferenceStreamPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Spectre.Inference.Stream
  alias Spectre.Inference.StreamEvent
  alias Spectre.Instance.Ref
  alias Spectre.Subject

  @registry SpectreInferenceStreamPropertyTest.Registry
  @agent SpectreInferenceStreamPropertyTest.Agent
  @fence_fields [
    :inference_id,
    :invocation_id,
    :attempt_id,
    :run_revision,
    :generation,
    :dispatch_id,
    :control_revision,
    :stream_epoch
  ]

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  property "arbitrary batch boundaries preserve one exact global stream sequence" do
    check all(
            delta_count <- integer(1..48),
            widths <- list_of(integer(1..8), min_length: 1, max_length: 12),
            max_runs: 100
          ) do
      stream = stream()

      events =
        Enum.map(1..delta_count, &event(stream, :delta, &1)) ++
          [event(stream, :failed, delta_count + 1)]

      replies = events |> split_batches(widths) |> Enum.map(&{:ok, &1})
      start_session(stream, replies)

      observed = Enum.to_list(stream)

      assert Enum.map(observed, & &1.sequence) == Enum.to_list(1..(delta_count + 1))
      assert Enum.map(observed, & &1.kind) == List.duplicate(:delta, delta_count) ++ [:failed]
    end
  end

  property "a duplicate or gap at any generated position rejects the complete batch" do
    check all(
            {event_count, index, violation} <- sequence_violation(),
            max_runs: 120
          ) do
      stream = stream()
      events = sequential_events(stream, event_count)
      original = Enum.fetch!(events, index)

      invalid_sequence =
        case violation do
          :duplicate -> index
          :gap -> original.sequence + 1
        end

      invalid = List.replace_at(events, index, %{original | sequence: invalid_sequence})
      start_session(stream, [{:ok, invalid}])

      assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(stream)
    end
  end

  property "changing any generated stream fence rejects an otherwise valid terminal" do
    check all(field <- member_of(@fence_fields), max_runs: 120) do
      stream = stream()
      terminal = event(stream, :failed, 1)
      stale = Map.put(terminal, field, stale_fence(field, Map.fetch!(terminal, field)))
      start_session(stream, [{:ok, [stale]}])

      assert [%StreamEvent{kind: :interrupted, sequence: 1}] = Enum.to_list(stream)
    end
  end

  defp sequence_violation do
    bind(integer(2..40), fn event_count ->
      tuple({
        constant(event_count),
        integer(0..(event_count - 1)),
        member_of([:duplicate, :gap])
      })
    end)
  end

  defp sequential_events(stream, event_count) do
    Enum.map(1..event_count, fn sequence ->
      kind = if sequence == event_count, do: :failed, else: :delta
      event(stream, kind, sequence)
    end)
  end

  defp split_batches(events, widths), do: do_split_batches(events, widths, widths, [])

  defp do_split_batches([], _remaining_widths, _all_widths, acc), do: Enum.reverse(acc)

  defp do_split_batches(events, [], all_widths, acc),
    do: do_split_batches(events, all_widths, all_widths, acc)

  defp do_split_batches(events, [width | rest], all_widths, acc) do
    {batch, remaining} = Enum.split(events, width)
    do_split_batches(remaining, rest, all_widths, [batch | acc])
  end

  defp start_session(stream, replies) do
    {:ok, session} =
      SpectreInferenceStreamPropertyTest.Session.start_link(
        registry: @registry,
        key: Stream.session_key(stream),
        replies: replies
      )

    session
  end

  defp stream do
    unique = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    Stream.new(
      inference_id: "inference-#{unique}",
      invocation_id: "invocation-#{unique}",
      attempt_id: "attempt-#{unique}",
      run_id: "run-#{unique}",
      run_revision: rem(String.to_integer(unique), 100),
      generation: "generation-#{unique}",
      dispatch_id: "dispatch-#{unique}",
      control_revision: rem(String.to_integer(unique), 50),
      stream_epoch: "epoch-#{unique}",
      consumer_token: "consumer-#{unique}",
      instance_ref: Ref.new(@agent, Subject.new("subject-#{unique}")),
      registry: @registry,
      demand: 8,
      next_timeout: 100
    )
  end

  defp event(stream, :delta, sequence) do
    event_opts(stream, sequence)
    |> Keyword.put(:payload, "delta-#{sequence}")
    |> then(&StreamEvent.new(:delta, &1))
  end

  defp event(stream, :failed, sequence) do
    event_opts(stream, sequence)
    |> Keyword.put(:payload, :generated_failure)
    |> then(&StreamEvent.new(:failed, &1))
  end

  defp event_opts(stream, sequence) do
    [
      inference_id: stream.inference_id,
      invocation_id: stream.invocation_id,
      attempt_id: stream.attempt_id,
      run_revision: stream.run_revision,
      generation: stream.generation,
      dispatch_id: stream.dispatch_id,
      control_revision: stream.control_revision,
      stream_epoch: stream.stream_epoch,
      sequence: sequence,
      at: sequence
    ]
  end

  defp stale_fence(field, current) when field in [:run_revision, :control_revision],
    do: current + 1

  defp stale_fence(field, current), do: "stale-#{field}-#{current}"
end
