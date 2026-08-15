defmodule Spectre.Determinism do
  @moduledoc """
  Replayable port for decision-relevant clock, UUID, and random values.

  `capture/2` installs a process-local source while a runtime boundary is
  evaluated and returns the ordered samples beside the boundary result. Those
  samples can be placed in a portable receipt. Passing them back through
  `:determinism_replay` makes every sampled call fail closed on a kind, request,
  or ordering mismatch.

  Monotonic time is intentionally sourceable but not recorded: it measures
  local durations and mailbox liveness rather than canonical decisions.
  """

  alias Spectre.Determinism.Source.Default
  alias Spectre.Run.Value

  @context_key {__MODULE__, :context}
  @default_sample_limit 1_024

  @type sample :: %{
          required(:sequence) => pos_integer(),
          required(:kind) => atom(),
          required(:request) => map(),
          required(:value) => term()
        }

  @type source :: module() | {module(), keyword()} | nil
  @type monotonic_time_unit :: System.time_unit() | :native

  @doc "Runs a boundary with deterministic capture or replay enabled."
  @spec capture(keyword(), (-> result)) :: {result, [sample()]} when result: term()
  def capture(opts, callback) when is_list(opts) and is_function(callback, 0) do
    previous = Process.get(@context_key)
    Process.put(@context_key, context(opts))

    try do
      result = callback.()
      {result, samples()}
    after
      restore(previous)
    end
  end

  @doc "Installs capture for a long-lived OTP process such as a stream session."
  @spec begin_capture(keyword()) :: :ok
  def begin_capture(opts) when is_list(opts) do
    Process.put(@context_key, context(opts))
    :ok
  end

  @doc "Returns samples captured so far without ending the process-local port."
  @spec samples() :: [sample()]
  def samples do
    case Process.get(@context_key) do
      %{replay?: true, replay: [_unused | _remaining]} ->
        # Replaying only a prefix is as unsafe as consuming samples in the
        # wrong order: it means the recovered boundary no longer has the same
        # decision shape as the original execution.
        raise ArgumentError, "determinism replay completed with unused samples"

      %{samples: samples} ->
        Enum.reverse(samples)

      _none ->
        []
    end
  end

  @doc "Returns a sourceable, receipt-recorded wall-clock value."
  @spec system_time(System.time_unit()) :: integer()
  def system_time(unit \\ :millisecond) do
    sample(:system_time, %{unit: unit}, fn {module, opts} ->
      module.system_time(unit, opts)
    end)
  end

  @doc "Returns sourceable monotonic time without adding receipt evidence."
  @spec monotonic_time(monotonic_time_unit()) :: integer()
  def monotonic_time(unit \\ :native) do
    {module, opts} = active_source()
    module.monotonic_time(unit, opts)
  end

  @doc "Returns receipt-recorded cryptographic random bytes."
  @spec random_bytes(non_neg_integer()) :: binary()
  def random_bytes(count) when is_integer(count) and count >= 0 do
    sample(:random_bytes, %{count: count}, fn {module, opts} ->
      module.random_bytes(count, opts)
    end)
  end

  defp sample(kind, request, generator) do
    case Process.get(@context_key) do
      %{replay: [expected | remaining]} = context ->
        sequence = length(context.samples) + 1
        value = replay_value!(expected, sequence, kind, request)
        record_sample(%{context | replay: remaining}, kind, request, value)

      %{replay: [], replay?: true} ->
        raise ArgumentError, "determinism replay exhausted before #{kind}"

      %{} = context ->
        value = generator.(context.source)
        record_sample(context, kind, request, value)

      _none ->
        generator.(default_source())
    end
  end

  defp record_sample(context, kind, request, value) do
    sequence = length(context.samples) + 1

    if sequence > context.limit do
      raise ArgumentError, "determinism sample limit exceeded"
    end

    sample = %{sequence: sequence, kind: kind, request: request, value: value}

    case Value.validate(sample) do
      :ok ->
        Process.put(@context_key, %{context | samples: [sample | context.samples]})

      {:error, reason} ->
        raise ArgumentError, "non-portable determinism sample: #{inspect(reason)}"
    end

    value
  end

  defp replay_value!(expected, sequence, kind, request) when is_map(expected) do
    expected_sequence = Map.get(expected, :sequence, Map.get(expected, "sequence"))

    expected_kind =
      expected
      |> Map.get(:kind, Map.get(expected, "kind"))
      |> known_sample_kind()

    expected_request = Map.get(expected, :request, Map.get(expected, "request"))

    if expected_sequence == sequence and expected_kind == kind and
         normalize_keys(expected_request) == request do
      Map.get(expected, :value, Map.get(expected, "value"))
    else
      raise ArgumentError,
            "determinism replay mismatch: expected " <>
              "#{inspect({expected_sequence, expected_kind, expected_request})}, " <>
              "got #{inspect({sequence, kind, request})}"
    end
  end

  defp replay_value!(_expected, _sequence, kind, _request),
    do: raise(ArgumentError, "invalid determinism replay sample for #{kind}")

  defp context(opts) do
    replay = Keyword.get(opts, :determinism_replay)

    %{
      source: normalize_source(Keyword.get(opts, :determinism_source)),
      replay: List.wrap(replay),
      replay?: not is_nil(replay),
      samples: [],
      limit: positive_limit(Keyword.get(opts, :determinism_sample_limit, @default_sample_limit))
    }
  end

  defp active_source do
    case Process.get(@context_key) do
      %{source: source} -> source
      _none -> default_source()
    end
  end

  defp normalize_source(nil), do: default_source()
  defp normalize_source(module) when is_atom(module) and not is_nil(module), do: {module, []}

  defp normalize_source({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts),
       do: {module, opts}

  defp normalize_source(value),
    do: raise(ArgumentError, "invalid determinism source: #{inspect(value)}")

  defp default_source, do: {Default, []}

  defp positive_limit(value) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value), do: @default_sample_limit

  defp normalize_keys(request) when is_map(request) do
    Map.new(request, fn
      {key, value} when is_binary(key) -> {known_request_key(key), value}
      pair -> pair
    end)
  end

  defp normalize_keys(request), do: request

  defp known_request_key("unit"), do: :unit
  defp known_request_key("count"), do: :count
  defp known_request_key(key), do: key

  # Receipt codecs may expose atom keys as strings. Keep this mapping closed so
  # replay never creates atoms from untrusted persisted input.
  defp known_sample_kind("system_time"), do: :system_time
  defp known_sample_kind("random_bytes"), do: :random_bytes
  defp known_sample_kind(kind), do: kind

  defp restore(nil), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)
end
