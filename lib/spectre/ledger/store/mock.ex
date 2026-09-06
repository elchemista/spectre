defmodule Spectre.Ledger.Store.Mock do
  @moduledoc """
  Deterministic test adapter which wraps a real ledger Store.

  The mock never reimplements ledger semantics. Unscripted calls are delegated
  to the configured Store, while scripted calls can replace a reply before the
  delegate runs or after it has run. The latter is useful for simulating a lost
  acknowledgement after a durable commit.

  Scripts contain `{operation, phase, reply}` tuples. Supported operations are
  `:append`, `:load`, `:lookup_batch`, and `:export`; phases are `:before` and
  `:after`. Append scripts cannot synthesize a successful commit, and an
  after-append reply is used only when the delegate really succeeded. Each
  operation consumes its own script in insertion order.
  """

  use GenServer

  @behaviour Spectre.Ledger.Store

  alias Spectre.Ledger.Store

  @operations [:append, :load, :load_from, :lookup_batch, :export]
  @phases [:before, :after]

  @type action :: {atom(), :before | :after, term()}

  @doc "Starts a mock around the required `:store` adapter configuration."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {server_opts, init_opts} =
      Keyword.split(opts, [:name, :timeout, :debug, :spawn_opt, :hibernate_after])

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def start_link(_opts), do: {:error, :invalid_ledger_mock_options}

  @doc "Appends validated fault actions to the running script."
  @spec push(GenServer.server(), action() | [action()]) :: :ok | {:error, term()}
  def push(server, actions), do: GenServer.call(server, {:push, List.wrap(actions)})

  @doc "Returns delegated calls in execution order."
  @spec calls(GenServer.server()) :: [map()]
  def calls(server), do: GenServer.call(server, :calls)

  @impl Spectre.Ledger.Store
  def append(domain_ref, batch_id, payloads, expected_revision, opts) do
    invoke(opts, :append, [domain_ref, batch_id, payloads, expected_revision])
  end

  @impl Spectre.Ledger.Store
  def load(domain_ref, opts), do: invoke(opts, :load, [domain_ref])

  @impl Spectre.Ledger.Store
  def load_from(domain_ref, revision, opts), do: invoke(opts, :load_from, [domain_ref, revision])

  @impl Spectre.Ledger.Store
  def lookup_batch(domain_ref, batch_id, opts),
    do: invoke(opts, :lookup_batch, [domain_ref, batch_id])

  @impl Spectre.Ledger.Store
  def export(domain_ref, opts), do: invoke(opts, :export, [domain_ref])

  @impl GenServer
  def init(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, store} <- fetch_store(opts),
         {:ok, script} <- normalize_script(Keyword.get(opts, :script, [])) do
      {:ok, %{store: store, script: script, calls_rev: []}}
    else
      false -> {:stop, :invalid_ledger_mock_options}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:push, actions}, _from, state) do
    case normalize_script(actions) do
      {:ok, additions} ->
        script =
          Map.new(@operations, fn operation ->
            {operation, state.script[operation] ++ additions[operation]}
          end)

        {:reply, :ok, %{state | script: script}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:calls, _from, state),
    do: {:reply, Enum.reverse(state.calls_rev), state}

  def handle_call({:invoke, operation, args, runtime_opts}, _from, state) do
    {action, script} = pop_action(state.script, operation)
    call = %{operation: operation, arguments: args}
    next_state = %{state | script: script, calls_rev: [call | state.calls_rev]}

    reply = apply_action(action, state.store, operation, args, runtime_opts)
    {:reply, reply, next_state}
  end

  defp invoke(opts, operation, args) do
    with {:ok, server} <- server(opts) do
      GenServer.call(
        server,
        {:invoke, operation, args, Keyword.delete(opts, :server)},
        timeout(opts)
      )
    end
  end

  defp apply_action({:before, reply}, _store, _operation, _args, _opts), do: reply

  defp apply_action({:after, reply}, store, :append, args, opts) do
    case delegate(store, :append, args, opts) do
      {:ok, _revision} -> reply
      delegated_reply -> delegated_reply
    end
  end

  defp apply_action({:after, reply}, store, operation, args, opts) do
    _delegated_reply = delegate(store, operation, args, opts)
    reply
  end

  defp apply_action(nil, store, operation, args, opts),
    do: delegate(store, operation, args, opts)

  defp delegate(store, :append, [domain_ref, batch_id, payloads, revision], opts),
    do: Store.append(store, domain_ref, batch_id, payloads, revision, opts)

  defp delegate(store, :load, [domain_ref], opts),
    do: Store.load(store, domain_ref, opts)

  defp delegate(store, :load_from, [domain_ref, revision], opts),
    do: Store.load_from(store, domain_ref, revision, opts)

  defp delegate(store, :lookup_batch, [domain_ref, batch_id], opts),
    do: Store.lookup_batch(store, domain_ref, batch_id, opts)

  defp delegate(store, :export, [domain_ref], opts),
    do: Store.export(store, domain_ref, opts)

  defp fetch_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, {__MODULE__, _opts}} -> {:error, :ledger_mock_cannot_wrap_itself}
      {:ok, __MODULE__} -> {:error, :ledger_mock_cannot_wrap_itself}
      {:ok, store} -> Store.normalize(store)
      :error -> {:error, :ledger_mock_store_required}
    end
  end

  defp normalize_script(actions) when is_list(actions) do
    initial = Map.new(@operations, &{&1, []})

    Enum.reduce_while(actions, {:ok, initial}, fn action, {:ok, script} ->
      case action do
        {:append, _phase, {:ok, _revision}} ->
          {:halt, {:error, :synthetic_ledger_append_success}}

        {operation, phase, reply} when operation in @operations and phase in @phases ->
          {:cont, {:ok, Map.update!(script, operation, &(&1 ++ [{phase, reply}]))}}

        invalid ->
          {:halt, {:error, {:invalid_ledger_mock_action, invalid}}}
      end
    end)
  end

  defp normalize_script(_actions), do: {:error, :invalid_ledger_mock_script}

  defp pop_action(script, operation) do
    case Map.fetch!(script, operation) do
      [action | rest] -> {action, Map.put(script, operation, rest)}
      [] -> {nil, script}
    end
  end

  defp server(opts) when is_list(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} -> {:ok, server}
      :error -> {:error, :ledger_mock_server_required}
    end
  end

  defp server(_opts), do: {:error, :invalid_ledger_mock_options}

  defp timeout(opts), do: Keyword.get(opts, :timeout, :infinity)
end
