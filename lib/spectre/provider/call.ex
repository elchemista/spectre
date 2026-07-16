defmodule Spectre.Provider.Call do
  @moduledoc """
  Isolated timeout and crash boundary for external provider calls.

  Calls run outside the requesting process. A small coordinator links the
  adapter worker to both the caller lifecycle and the configured timeout, so a
  timed-out call or dead caller terminates the local adapter worker. Remote work
  already handed to an external service can only be cancelled when that
  adapter supports cancellation itself.
  """

  alias Spectre.Provider.Failure

  @default_timeouts %{
    llm: 60_000,
    local_classifier: 30_000,
    embedding: 30_000,
    semantic_cache: 30_000
  }

  @type result(value) :: {:ok, value} | {:error, term()}

  @doc """
  Runs one provider function under its configured timeout.

  Provider-specific options override `:provider_timeout`:

    * `:llm_timeout`
    * `:local_classifier_timeout` or `:classifier_timeout`
    * `:embedding_timeout`
    * `:semantic_cache_timeout`

  Application defaults may be configured under `config :spectre, :provider`.
  """
  @spec run(atom(), (-> result(term())), keyword()) :: result(term())
  def run(provider, fun, opts \\ [])

  def run(provider, fun, opts) when is_atom(provider) and is_function(fun, 0) and is_list(opts) do
    with {:ok, timeout} <- timeout(provider, opts) do
      execute(provider, fun, timeout)
    end
  end

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
        validate_timeout(provider, Keyword.merge(configured, opts))

      invalid ->
        {:error, Failure.invalid_timeout(provider, invalid)}
    end
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
  defp timeout_keys(_provider), do: [:provider_timeout]

  @spec default_timeout(atom()) :: timeout()
  defp default_timeout(provider), do: Map.get(@default_timeouts, provider, 30_000)
end
