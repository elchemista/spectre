defmodule Spectre.Instance.Configuration do
  @moduledoc false

  # Normalizes the independent option sources used to start an Instance. The
  # owner process receives one validated snapshot and can keep `init/1`
  # focused on restore, ownership acquisition, and runtime recovery.

  alias Spectre.AgentRef
  alias Spectre.Definition.Store, as: DefinitionStore
  alias Spectre.Inference.StreamCapacity
  alias Spectre.Instance.Checkpoint
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Operation.RunnerSupervisor
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Run.Value
  alias Spectre.Subject

  @default_max_runs 256
  @default_max_tombstones 256
  @default_max_operation_runners 8
  @default_max_stream_sessions 4
  @default_max_receipt_outbox 256
  @default_terminal_loop_retention 256
  @default_correlation_retention 1_024

  @enforce_keys [
    :base_opts,
    :checkpoint_mode,
    :idle_timeout,
    :max_operation_runners,
    :max_receipt_outbox,
    :max_runs,
    :max_stream_sessions,
    :max_tombstones,
    :receipt_mode,
    :runner_supervisor,
    :stream_capacity,
    :stream_registry
  ]
  defstruct @enforce_keys ++ [:checkpoint_store, :definition_store, :owner, :receipt_sink]

  @type t :: %__MODULE__{
          base_opts: keyword(),
          checkpoint_mode: :async | :manual,
          checkpoint_store: Spectre.Instance.CheckpointStore.config() | nil,
          definition_store: DefinitionStore.config() | nil,
          idle_timeout: timeout() | false | nil,
          max_operation_runners: pos_integer(),
          max_receipt_outbox: pos_integer(),
          max_runs: pos_integer(),
          max_stream_sessions: pos_integer(),
          max_tombstones: non_neg_integer(),
          owner: Spectre.Instance.Owner.config(),
          receipt_mode: :disabled | :observational | :required,
          receipt_sink: Spectre.Receipt.Sink.normalized(),
          runner_supervisor: GenServer.server(),
          stream_capacity: GenServer.server(),
          stream_registry: atom()
        }

  @doc false
  @spec load(module(), InstanceRef.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(agent, %InstanceRef{} = instance_ref, opts) when is_atom(agent) and is_list(opts) do
    with {:ok, max_runs} <-
           positive_integer(Keyword.get(opts, :max_runs, @default_max_runs), :max_runs),
         {:ok, max_tombstones} <-
           non_negative_integer(Keyword.get(opts, :max_tombstones, @default_max_tombstones)),
         {:ok, max_operation_runners} <-
           positive_integer(
             Keyword.get(opts, :max_operation_runners, @default_max_operation_runners),
             :max_operation_runners
           ),
         {:ok, max_stream_sessions} <-
           positive_integer(
             Keyword.get(opts, :max_stream_sessions, @default_max_stream_sessions),
             :max_stream_sessions
           ),
         base_opts <- base_opts(opts, instance_ref),
         {:ok, terminal_loop_retention} <-
           retention(
             first_configured([
               {opts, :operation_terminal_loop_retention},
               {base_opts, :operation_terminal_loop_retention}
             ]),
             :operation_terminal_loop_retention,
             @default_terminal_loop_retention
           ),
         {:ok, correlation_retention} <-
           retention(
             first_configured([
               {opts, :operation_correlation_retention},
               {base_opts, :operation_correlation_retention}
             ]),
             :operation_correlation_retention,
             @default_correlation_retention
           ),
         base_opts <-
           base_opts
           |> Keyword.put(:operation_terminal_loop_retention, terminal_loop_retention)
           |> Keyword.put(:operation_correlation_retention, correlation_retention),
         {:ok, base_opts} <- normalize_inference_observer(opts, base_opts),
         {:ok, checkpoint_store} <- Checkpoint.store_config(agent, opts, base_opts),
         {:ok, checkpoint_mode} <- Checkpoint.mode(opts, checkpoint_store),
         {:ok, receipt_mode} <- receipt_mode(opts, base_opts),
         {:ok, receipt_sink} <- receipt_sink(opts, base_opts),
         {:ok, max_receipt_outbox} <- receipt_outbox_limit(opts, base_opts),
         base_opts <- Keyword.put(base_opts, :receipt_outbox_limit, max_receipt_outbox),
         :ok <- validate_receipts(receipt_mode, receipt_sink, checkpoint_store),
         {:ok, definition_store} <- definition_store(agent, opts, base_opts),
         :ok <- validate_store_pair(checkpoint_store, definition_store) do
      {:ok,
       %__MODULE__{
         base_opts: base_opts,
         checkpoint_mode: checkpoint_mode,
         checkpoint_store: checkpoint_store,
         definition_store: definition_store,
         idle_timeout: idle_timeout(agent, opts, base_opts),
         max_operation_runners: max_operation_runners,
         max_receipt_outbox: max_receipt_outbox,
         max_runs: max_runs,
         max_stream_sessions: max_stream_sessions,
         max_tombstones: max_tombstones,
         owner: owner_config(agent, opts, base_opts),
         receipt_mode: receipt_mode,
         receipt_sink: receipt_sink,
         runner_supervisor: Keyword.get(opts, :runner_supervisor, RunnerSupervisor),
         stream_capacity: Keyword.get(opts, :stream_capacity, StreamCapacity),
         stream_registry: Keyword.get(opts, :stream_registry, Spectre.Inference.StreamRegistry)
       }}
    end
  end

  @doc false
  @spec instance_ref!(keyword()) :: InstanceRef.t()
  def instance_ref!(opts) when is_list(opts) do
    agent_ref =
      case Keyword.get(opts, :agent_ref) do
        %AgentRef{} = ref ->
          AgentRef.new(ref)

        nil ->
          agent = Keyword.fetch!(opts, :agent)

          case Keyword.get(opts, :agent_id) do
            nil -> AgentRef.new(agent)
            id -> AgentRef.new(agent, id: id)
          end
      end

    subject =
      case Keyword.fetch(opts, :subject) do
        {:ok, %Subject{} = subject} -> Subject.new(subject)
        {:ok, subject} -> Subject.new(subject)
        :error -> raise ArgumentError, "Spectre.Instance requires an explicit :subject"
      end

    InstanceRef.new(agent_ref, subject)
  end

  @doc false
  @spec timeout(keyword()) :: timeout()
  def timeout(opts) when is_list(opts), do: Keyword.get(opts, :timeout, :timer.minutes(5))

  defp base_opts(opts, instance_ref) do
    state_conversation_id =
      opts
      |> Keyword.get(:state_conversation_id, instance_ref.key)
      |> validate_state_conversation_id!()

    opts
    |> Keyword.get(:opts, [])
    |> maybe_put(:event_schema_registry, Keyword.get(opts, :event_schema_registry))
    |> Keyword.put(:conversation_id, state_conversation_id)
    |> Keyword.put(:subject, instance_ref.subject)
    |> Keyword.put(:subject_id, instance_ref.subject.id)
  end

  defp validate_state_conversation_id!(value) do
    case Value.validate(value, [:instance, :state_conversation_id]) do
      :ok ->
        value

      {:error, reason} ->
        raise ArgumentError,
              "invalid Instance state_conversation_id: #{inspect(reason)}"
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp definition_store(agent, opts, base_opts) do
    value =
      first_configured([
        {opts, :definition_store},
        {base_opts, :definition_store},
        {agent.__spectre_config__(), :definition_store}
      ])

    case value do
      value when value in [nil, false] -> {:ok, nil}
      value -> DefinitionStore.normalize(value)
    end
  end

  defp validate_store_pair(_checkpoint_store, nil), do: :ok

  defp validate_store_pair(checkpoint_store, definition_store),
    do: DefinitionStore.validate_durability_pair(checkpoint_store, definition_store)

  defp owner_config(agent, opts, base_opts) do
    first_configured([
      {opts, :owner},
      {base_opts, :owner},
      {agent.__spectre_config__(), :owner}
    ])
  end

  defp idle_timeout(agent, opts, base_opts) do
    config = agent.__spectre_config__()

    first_configured([
      {opts, :idle},
      {opts, :shutdown},
      {base_opts, :idle},
      {base_opts, :shutdown},
      {config, :idle},
      {config, :shutdown}
    ])
  end

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp positive_integer(value, _key) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(value, :max_runs), do: {:error, {:invalid_instance_max_runs, value}}

  # Preserve the established public error for the existing runner limit.
  defp positive_integer(value, :max_operation_runners),
    do: {:error, {:invalid_instance_max_runs, value}}

  defp positive_integer(value, key), do: {:error, {:invalid_instance_option, key, value}}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value),
    do: {:error, {:invalid_instance_max_tombstones, value}}

  defp retention(nil, _key, default), do: {:ok, default}
  defp retention(:unlimited, _key, _default), do: {:ok, :unlimited}

  defp retention(value, _key, _default) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp retention(value, key, _default),
    do: {:error, {:invalid_instance_retention, key, value}}

  defp normalize_inference_observer(opts, base_opts) do
    enabled =
      first_configured([
        {opts, :inference_observer_lane},
        {base_opts, :inference_observer_lane}
      ]) || false

    interval =
      first_configured([
        {opts, :inference_progress_commit_interval},
        {base_opts, :inference_progress_commit_interval}
      ]) || 5_000

    limit =
      first_configured([
        {opts, :inference_progress_limit},
        {base_opts, :inference_progress_limit}
      ]) || 256

    checkpoint_interval =
      first_configured([
        {opts, :inference_stream_checkpoint_interval},
        {base_opts, :inference_stream_checkpoint_interval}
      ]) || 5_000

    cond do
      not is_boolean(enabled) ->
        {:error, {:invalid_inference_observer_lane, enabled}}

      not is_integer(interval) or interval <= 0 ->
        {:error, {:invalid_inference_progress_commit_interval, interval}}

      not is_integer(limit) or limit <= 0 ->
        {:error, {:invalid_inference_progress_limit, limit}}

      not is_integer(checkpoint_interval) or checkpoint_interval <= 0 ->
        {:error, {:invalid_inference_stream_checkpoint_interval, checkpoint_interval}}

      true ->
        {:ok,
         base_opts
         |> Keyword.put(:inference_observer_lane, enabled)
         |> Keyword.put(:inference_progress_commit_interval, interval)
         |> Keyword.put(:inference_progress_limit, limit)
         |> Keyword.put(:inference_stream_checkpoint_interval, checkpoint_interval)}
    end
  end

  defp receipt_mode(opts, base_opts) do
    mode =
      first_configured([
        {opts, :receipt_mode},
        {base_opts, :receipt_mode}
      ]) || :disabled

    if mode in [:disabled, :observational, :required],
      do: {:ok, mode},
      else: {:error, {:invalid_receipt_mode, mode}}
  end

  defp receipt_sink(opts, base_opts) do
    first_configured([
      {opts, :receipt_sink},
      {base_opts, :receipt_sink}
    ])
    |> ReceiptSink.normalize()
  end

  defp receipt_outbox_limit(opts, base_opts) do
    positive_integer(
      first_configured([
        {opts, :receipt_outbox_limit},
        {base_opts, :receipt_outbox_limit}
      ]) || @default_max_receipt_outbox,
      :receipt_outbox_limit
    )
  end

  defp validate_receipts(:disabled, _sink, _checkpoint_store), do: :ok

  defp validate_receipts(:observational, nil, _checkpoint_store),
    do: {:error, :receipt_sink_required}

  defp validate_receipts(:observational, _sink, _checkpoint_store), do: :ok

  defp validate_receipts(:required, nil, _checkpoint_store),
    do: {:error, :receipt_sink_required}

  defp validate_receipts(:required, _sink, nil),
    do: {:error, :required_receipts_need_checkpoint_store}

  defp validate_receipts(:required, sink, _checkpoint_store) do
    if ReceiptSink.payload_capable?(sink),
      do: :ok,
      else: {:error, :required_receipt_sink_lacks_payload_store}
  end
end
