defmodule Spectre.Server.Diagnostics do
  @moduledoc """
  Versioned, payload-free diagnostic projections of durable coordination state.

  A checkpoint is a retained snapshot, not an event log. These reads never claim
  to reconstruct pruned interactions, model reasoning or historical routing.
  Lists are bounded; counts describe the complete retained snapshot. Codec
  validity does not establish that a checkpoint is compatible with an Agent.
  """
  alias Spectre.Server.Checkpoint

  @doc "Projects a checkpoint without exposing assigns, inputs, arguments or results."
  @spec checkpoint(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def checkpoint(encoded, opts \\ []) do
    with {:ok, limit} <- limit(opts), {:ok, saved} <- decode(encoded) do
      {:ok, operational(saved, limit)}
    end
  end

  @doc "Returns retained coordination facts for one interaction, with explicit coverage."
  @spec trace(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace(encoded, interaction, opts \\ []) do
    with {:ok, limit} <- limit(opts),
         true <- is_binary(interaction) and byte_size(interaction) in 1..256,
         {:ok, saved} <- decode(encoded) do
      records =
        [:operations, :outbox, :inbox, :dead_letters]
        |> Enum.flat_map(fn collection ->
          saved
          |> Map.get(collection, %{})
          |> Enum.filter(fn {_id, value} -> Map.get(event(value), :id) == interaction end)
          |> Enum.map(fn {id, entry} -> entry(id, entry) |> Map.put(:collection, collection) end)
        end)
        |> Enum.sort_by(&{&1.command_id, &1.collection})

      {:ok,
       %{
         version: 1,
         interaction_id: interaction,
         records: Enum.take(records, limit),
         total: length(records),
         truncated: length(records) > limit,
         coverage: %{
           source: :retained_checkpoint,
           complete: false,
           missing: [:historical_routing, :pruned_commands, :model_reasoning, :gam_history]
         }
       }}
    else
      false -> {:error, :invalid_interaction_id}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec read(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(state, opts) do
    with {:ok, encoded, revision} <- fetch(state),
         {:ok, result} <- checkpoint(encoded, opts),
         do: {:ok, Map.put(result, :revision, revision)}
  end

  @doc false
  @spec read_trace(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_trace(state, interaction, opts) do
    with {:ok, encoded, revision} <- fetch(state),
         {:ok, result} <- trace(encoded, interaction, opts),
         do: {:ok, Map.put(result, :revision, revision)}
  end

  @doc false
  @spec changed(map(), term()) :: :ok
  def changed(state, revision) do
    if Keyword.get(state.opts, :diagnostics_notifications, false) and is_pid(state.consumer) do
      send(
        state.consumer,
        {Spectre.Server, self(),
         {:diagnostics_changed, %{source: :checkpoint, revision: revision}}}
      )
    end

    :ok
  end

  @doc false
  @spec limit(keyword()) :: {:ok, pos_integer()} | {:error, atom()}
  def limit(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit] == [] do
      case Keyword.get(opts, :limit, 50) do
        limit when is_integer(limit) and limit in 1..100 -> {:ok, limit}
        _ -> {:error, :invalid_diagnostic_limit}
      end
    else
      {:error, :invalid_diagnostic_options}
    end
  end

  def limit(_), do: {:error, :invalid_diagnostic_options}

  @doc false
  @spec label(term()) :: atom() | binary() | nil
  def label(value) when is_atom(value), do: value
  def label(value) when is_binary(value) and byte_size(value) <= 256, do: value
  def label(_), do: nil

  @spec fetch(map()) :: {:ok, binary(), term()} | {:error, term()}
  defp fetch(state) do
    case Checkpoint.tool_reference(state) do
      %{adapter: adapter, store: store, key: key} ->
        case adapter.fetch(store, key) do
          {:ok, %{value: bytes, revision: revision}} -> {:ok, bytes, revision}
          :not_found -> {:error, :checkpoint_not_found}
          {:error, _} = error -> error
        end

      nil ->
        {:error, :server_checkpoint_required}
    end
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  defp decode(encoded) do
    with {:ok, saved} <- Checkpoint.decode_snapshot(encoded),
         true <- is_map(saved) and not is_struct(saved),
         true <- is_integer(saved[:version]) and saved[:version] > 0,
         true <- is_integer(saved[:sequence]) and saved[:sequence] >= 0,
         true <- Enum.all?([:pending, :inbox, :outbox], &plain_map?(saved[&1])),
         true <- Enum.all?([:operations, :dead_letters], &plain_map?(Map.get(saved, &1, %{}))),
         true <- optional_map?(saved, :current),
         true <- optional_map?(Map.get(saved, :current) || %{}, :routing),
         true <-
           Enum.all?([:pending, :inbox, :outbox, :operations, :dead_letters], fn key ->
             Enum.all?(Map.get(saved, key, %{}), fn {_id, value} -> diagnostic_entry?(value) end)
           end) do
      {:ok, saved}
    else
      false -> {:error, :not_a_server_checkpoint}
      {:error, _} = error -> error
    end
  end

  @spec plain_map?(term()) :: boolean()
  defp plain_map?(value), do: is_map(value) and not is_struct(value)

  @spec optional_map?(map(), atom()) :: boolean()
  defp optional_map?(value, key),
    do: is_nil(Map.get(value, key)) or plain_map?(Map.get(value, key))

  @spec diagnostic_entry?(term()) :: boolean()
  defp diagnostic_entry?(value) when is_map(value) and not is_struct(value) do
    command = Map.get(value, :command)
    worker = Map.get(value, :worker)

    optional_map?(value, :event) and optional_map?(value, :worker) and
      optional_map?(value, :source) and
      (is_nil(worker) or diagnostic_entry?(worker)) and diagnostic_command?(command)
  end

  defp diagnostic_entry?(_), do: false

  @spec diagnostic_command?(term()) :: boolean()
  defp diagnostic_command?(nil), do: true

  defp diagnostic_command?(command) when is_map(command) do
    (plain_map?(command) or is_struct(command, Spectre.Server.Command)) and
      Keyword.keyword?(Map.get(command, :opts, []))
  end

  defp diagnostic_command?(_), do: false

  @spec operational(map(), pos_integer()) :: map()
  defp operational(saved, limit) do
    pending = saved.pending |> Enum.sort_by(&elem(&1, 0))
    commands = saved.outbox |> Enum.sort_by(&elem(&1, 0))
    current = if is_map(saved[:current]), do: saved.current, else: %{}
    routing = if is_map(current[:routing]), do: current.routing, else: %{}

    %{
      version: 1,
      server: label(saved[:server]),
      agent: label(saved[:agent]),
      interaction_id: label(current[:id]),
      routing: %{
        route: route(routing[:route_key]),
        strategy: label(routing[:strategy]),
        available: routing != %{}
      },
      current: %{phase: label(current[:phase])},
      pending:
        Enum.take(pending, limit)
        |> Enum.map(fn {id, value} ->
          %{id: label(id), kind: label(value[:kind]), status: label(value[:status])}
        end),
      commands: Enum.take(commands, limit) |> Enum.map(fn {id, value} -> entry(id, value) end),
      truncated: length(pending) > limit or length(commands) > limit,
      checkpoint: %{
        codec_valid: true,
        version: saved.version,
        sequence: saved.sequence,
        pending: map_size(saved.pending),
        outbox: map_size(saved.outbox),
        inbox: map_size(saved.inbox),
        fingerprint_present: Map.has_key?(saved, :definition_fingerprint)
      },
      recovery: %{
        dead_letters: map_size(Map.get(saved, :dead_letters, %{})),
        retained_operations: map_size(Map.get(saved, :operations, %{})),
        uncertain_pending: Enum.count(pending, fn {_, value} -> value[:status] == :uncertain end)
      },
      coverage: %{source: :retained_checkpoint, historical: false}
    }
  end

  @spec entry(term(), map()) :: map()
  defp entry(id, value) do
    worker = Map.get(value, :worker) || %{}
    source = Map.get(value, :source) || %{}
    command = Map.get(value, :command) || Map.get(worker, :command) || %{}
    opts = Map.get(command, :opts, [])
    tag = if is_list(opts) and Keyword.keyword?(opts), do: Keyword.get(opts, :on_result)

    %{
      command_id: label(Map.get(worker, :command_id) || Map.get(source, :command_id) || id),
      interaction_id: label(Map.get(event(value), :id)),
      kind: label(Map.get(command, :kind) || Map.get(worker, :kind)),
      status: label(value[:status]),
      tag:
        label(
          tag || Map.get(value, :tag) || Map.get(worker, :tag) || Map.get(source, :continuation)
        )
    }
  end

  @spec event(map()) :: map()
  defp event(value) do
    worker = Map.get(value, :worker) || %{}
    Map.get(value, :event) || Map.get(worker, :event) || %{id: Map.get(value, :interaction)}
  end

  @spec route(term()) :: list() | nil
  defp route({flow, intent}) when is_atom(flow) and is_atom(intent), do: [flow, intent]
  defp route(_), do: nil
end
