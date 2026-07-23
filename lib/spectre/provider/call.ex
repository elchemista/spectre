defmodule Spectre.Provider.Call do
  @moduledoc """
  Isolated timeout and crash boundary for external provider calls.

  Calls run outside the requesting process. A small coordinator links the
  adapter worker to both the caller lifecycle and the configured timeout, so a
  timed-out call or dead caller terminates the local adapter worker. Remote work
  already handed to an external service can only be cancelled when that
  adapter supports cancellation itself. Route evaluation also uses this
  boundary as the canonical source of sanitized provider outcome and duration
  facts.

  The same boundary is used for application callbacks executed by a turn. The
  callback contracts are:

  | Kind | Supported arities | Normalized success | Timeout | Failure policy |
  | --- | --- | --- | --- | --- |
  | `:run` | 1, 2 | a `Spectre.Result` or visible reply value | `:run_timeout`, 30s | abort the handler turn |
  | `:renderer` | 1, 2, 3 | a binary reply | `:renderer_timeout`, 10s | abort the handler turn |
  | `:hook` | 0, 1, 2, 3 | `:ok` or `{:ok, value}` | `:hook_timeout`, 10s | aggregate and report |
  | `:prompt` | 0, 1, 2 | a boolean condition or binary context | `:prompt_timeout`, 10s | abort required operations, skip optional ones |
  | `:input` | `init/1`, `call/3` | a valid pipeline transition | `:input_timeout`, 10s | abort the turn |
  | `:turn_handler` | `handle_turn/2` | `:cont` or a typed reply | `:turn_handler_timeout`, 30s | abort the turn (fail closed) |
  | `:router` | `init/1`, `call/2` | a valid pipeline transition | `:router_timeout`, 120s | abort the routing pipeline |
  | `:monitor` | 0, 1, 2, 3 | callback-specific host data | `:monitor_timeout`, 60s | enter or continue recovery |

  Model, classifier, embedding, semantic-cache, action, state, memory, and
  journal adapters use their existing provider-specific timeout keys. Every
  timeout accepts `:infinity` only when explicitly configured. Declared
  `{:error, reason}` replies are returned unchanged; exceptions, exits, throws,
  hard crashes, timeouts, and malformed envelopes become privacy-safe
  `Spectre.Provider.Failure` values. Calls are attempted exactly once.
  """

  alias Spectre.Provider.Failure

  @default_timeouts %{
    llm: 60_000,
    local_classifier: 30_000,
    embedding: 30_000,
    semantic_cache: 30_000,
    prompt: 10_000,
    action: 60_000,
    state: 10_000,
    memory: 10_000,
    journal: 10_000,
    turn_handler: 30_000,
    run: 30_000,
    renderer: 10_000,
    hook: 10_000,
    input: 10_000,
    router: 120_000,
    monitor: 60_000
  }

  @observer_key :spectre_provider_observer

  @type result(value) :: {:ok, value} | {:error, term()}
  @type event :: %{
          required(:provider) => atom(),
          required(:outcome) => atom(),
          required(:duration_us) => non_neg_integer(),
          required(:invoked?) => boolean(),
          optional(:purpose) => atom()
        }

  @doc """
  Runs one provider function under its configured timeout.

  Provider-specific options override `:provider_timeout`:

    * `:llm_timeout`
    * `:local_classifier_timeout` or `:classifier_timeout`
    * `:embedding_timeout`
    * `:semantic_cache_timeout`
    * `:run_timeout`
    * `:renderer_timeout`
    * `:hook_timeout`
    * `:input_timeout`
    * `:router_timeout`
    * `:monitor_timeout`
    * `:turn_handler_timeout`

  Application defaults may be configured under `config :spectre, :provider`.
  """
  @spec run(atom(), (-> result(term())), keyword()) :: result(term())
  def run(provider, fun, opts \\ [])

  def run(provider, fun, opts) when is_atom(provider) and is_function(fun, 0) and is_list(opts) do
    if Keyword.keyword?(opts) do
      started_at = System.monotonic_time()

      {result, invoked?} =
        case timeout(provider, opts) do
          {:ok, timeout} -> {execute(provider, fun, timeout), true}
          {:error, %Failure{} = failure} -> {{:error, failure}, false}
        end

      event = event(provider, result, invoked?, started_at)
      notify_observer(opts, event)

      Spectre.Telemetry.emit(
        [:provider, :stop],
        %{duration_us: event.duration_us},
        Map.take(event, [:provider, :outcome, :invoked?, :purpose]),
        opts
      )

      result
    else
      {:error, Failure.invalid_options(provider)}
    end
  end

  @doc false
  @spec adapter_opts(keyword()) :: keyword()
  def adapter_opts(opts) when is_list(opts), do: Keyword.delete(opts, @observer_key)

  @spec execute(atom(), (-> result(term())), timeout()) :: result(term())
  defp execute(provider, fun, timeout) do
    caller = self()
    reference = make_ref()
    callers = [caller | List.wrap(Process.get(:"$callers"))]
    logger_metadata = Logger.metadata()

    {coordinator, monitor} =
      spawn_monitor(fn ->
        coordinate(caller, reference, provider, fun, callers, logger_metadata)
      end)

    await(provider, reference, coordinator, monitor, timeout)
  end

  @spec coordinate(pid(), reference(), atom(), function(), [pid()], keyword()) :: :ok
  defp coordinate(caller, reference, provider, fun, callers, logger_metadata) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    coordinator = self()

    worker =
      spawn_link(fn ->
        Process.put(:"$callers", callers)
        Logger.metadata(logger_metadata)
        send(coordinator, {:provider_result, safe_call(provider, fun)})
      end)

    receive do
      {:provider_result, result} ->
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reference, normalize_reply(provider, result)})
        :ok

      {:EXIT, ^worker, reason} ->
        Process.demonitor(caller_monitor, [:flush])
        send(caller, {reference, {:error, Failure.crash(provider, reason)}})
        :ok

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        Process.exit(worker, :kill)
        :ok
    end
  end

  @spec safe_call(atom(), function()) :: result(term()) | term()
  defp safe_call(provider, fun) do
    fun.()
  rescue
    exception -> {:error, Failure.exception(provider, exception)}
  catch
    kind, reason -> {:error, Failure.caught(provider, kind, reason)}
  end

  @spec normalize_reply(atom(), term()) :: result(term())
  defp normalize_reply(_provider, {:ok, _value} = result), do: result
  defp normalize_reply(_provider, {:error, _reason} = result), do: result
  defp normalize_reply(provider, other), do: {:error, Failure.invalid_reply(provider, other)}

  @spec await(atom(), reference(), pid(), reference(), timeout()) :: result(term())
  defp await(provider, reference, coordinator, monitor, :infinity) do
    receive_result(provider, reference, coordinator, monitor)
  end

  defp await(provider, reference, coordinator, monitor, timeout) do
    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^coordinator, reason} ->
        {:error, Failure.crash(provider, reason)}
    after
      timeout ->
        cancel(reference, coordinator, monitor)
        {:error, Failure.timeout(provider, timeout)}
    end
  end

  @spec receive_result(atom(), reference(), pid(), reference()) :: result(term())
  defp receive_result(provider, reference, coordinator, monitor) do
    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^coordinator, reason} ->
        {:error, Failure.crash(provider, reason)}
    end
  end

  @spec cancel(reference(), pid(), reference()) :: :ok
  defp cancel(reference, coordinator, monitor) do
    Process.exit(coordinator, :kill)
    drain_cancel(reference, monitor)
  end

  @spec drain_cancel(reference(), reference()) :: :ok
  defp drain_cancel(reference, monitor) do
    receive do
      {^reference, _late_result} -> drain_cancel(reference, monitor)
      {:DOWN, ^monitor, :process, _pid, _reason} -> flush_result(reference)
    end
  end

  @spec flush_result(reference()) :: :ok
  defp flush_result(reference) do
    receive do
      {^reference, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  @spec timeout(atom(), keyword()) :: {:ok, timeout()} | {:error, Failure.t()}
  defp timeout(provider, opts) do
    case Application.get_env(:spectre, :provider, []) do
      configured when is_list(configured) ->
        if Keyword.keyword?(configured) do
          validate_timeout(provider, Keyword.merge(configured, opts))
        else
          {:error, Failure.invalid_timeout(provider, configured)}
        end

      invalid ->
        {:error, Failure.invalid_timeout(provider, invalid)}
    end
  end

  @spec event(atom(), result(term()), boolean(), integer()) :: event()
  defp event(provider, result, invoked?, started_at) do
    %{
      provider: provider,
      outcome: outcome(result),
      duration_us: elapsed_us(started_at),
      invoked?: invoked?
    }
  end

  @spec outcome(result(term())) :: atom()
  defp outcome({:ok, _value}), do: :ok
  defp outcome({:error, %Failure{kind: kind}}), do: kind
  defp outcome({:error, _reason}), do: :error

  @spec notify_observer(keyword(), event()) :: :ok
  defp notify_observer(opts, event) do
    case Keyword.get(opts, @observer_key) do
      {observer, reference} when is_pid(observer) and is_reference(reference) ->
        purpose = Keyword.get(opts, :purpose)

        event =
          if is_atom(purpose) and not is_nil(purpose),
            do: Map.put(event, :purpose, purpose),
            else: event

        send(observer, {:spectre_provider_call, reference, event})
        :ok

      _other ->
        :ok
    end
  end

  @spec elapsed_us(integer()) :: non_neg_integer()
  defp elapsed_us(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :microsecond)
  end

  @spec validate_timeout(atom(), keyword()) :: {:ok, timeout()} | {:error, Failure.t()}
  defp validate_timeout(provider, configured) do
    timeout = configured_timeout(provider, configured)

    if timeout == :infinity or (is_integer(timeout) and timeout > 0),
      do: {:ok, timeout},
      else: {:error, Failure.invalid_timeout(provider, timeout)}
  end

  @spec configured_timeout(atom(), keyword()) :: term()
  defp configured_timeout(provider, configured) do
    case Enum.find(timeout_keys(provider), &Keyword.has_key?(configured, &1)) do
      nil -> default_timeout(provider)
      key -> Keyword.get(configured, key)
    end
  end

  @spec timeout_keys(atom()) :: [atom()]
  defp timeout_keys(:llm), do: [:llm_timeout, :provider_timeout]

  defp timeout_keys(:local_classifier),
    do: [:local_classifier_timeout, :classifier_timeout, :provider_timeout]

  defp timeout_keys(:embedding), do: [:embedding_timeout, :provider_timeout]
  defp timeout_keys(:semantic_cache), do: [:semantic_cache_timeout, :provider_timeout]
  defp timeout_keys(:prompt), do: [:prompt_timeout, :provider_timeout]
  defp timeout_keys(:action), do: [:action_timeout, :tool_timeout, :provider_timeout]
  defp timeout_keys(:state), do: [:state_timeout, :provider_timeout]
  defp timeout_keys(:memory), do: [:memory_timeout, :provider_timeout]
  defp timeout_keys(:journal), do: [:journal_timeout, :provider_timeout]

  defp timeout_keys(:turn_handler),
    do: [:turn_handler_timeout, :callback_timeout, :provider_timeout]

  defp timeout_keys(:run), do: [:run_timeout, :callback_timeout, :provider_timeout]

  defp timeout_keys(:renderer),
    do: [:renderer_timeout, :callback_timeout, :provider_timeout]

  defp timeout_keys(:hook), do: [:hook_timeout, :callback_timeout, :provider_timeout]
  defp timeout_keys(:input), do: [:input_timeout, :callback_timeout, :provider_timeout]
  defp timeout_keys(:router), do: [:router_timeout, :callback_timeout, :provider_timeout]
  defp timeout_keys(:monitor), do: [:monitor_timeout, :callback_timeout, :provider_timeout]
  defp timeout_keys(_provider), do: [:provider_timeout]

  @spec default_timeout(atom()) :: timeout()
  defp default_timeout(provider), do: Map.get(@default_timeouts, provider, 30_000)
end
