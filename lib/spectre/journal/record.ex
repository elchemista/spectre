defmodule Spectre.Journal.Record do
  @moduledoc """
  Versioned, privacy-aware explanation record for one runtime decision.

  Input and reply content are absent by default. Applications must opt in to
  content recording through their journal configuration.
  """

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            agent: nil,
            agent_version: nil,
            conversation_id: nil,
            turn_id: nil,
            sequence: 1,
            trace_id: nil,
            state_revision: nil,
            phase: nil,
            decision: %{},
            reason: %{},
            evidence: [],
            transition: nil,
            policy: nil,
            effect: nil,
            input: nil,
            reply: nil,
            duration_native: nil,
            metadata: %{},
            occurred_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          agent: module() | nil,
          agent_version: term(),
          conversation_id: term(),
          turn_id: term(),
          sequence: non_neg_integer(),
          trace_id: term(),
          state_revision: non_neg_integer() | nil,
          phase: atom(),
          decision: map(),
          reason: map(),
          evidence: [map()],
          transition: map() | nil,
          policy: map() | nil,
          effect: map() | nil,
          input: map() | nil,
          reply: String.t() | nil,
          duration_native: integer() | nil,
          metadata: map(),
          occurred_at: DateTime.t()
        }

  @doc """
  Builds a journal record and derives a stable record identifier from its turn,
  phase, sequence, and agent.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    turn_id = Map.get(attrs, :turn_id) || Spectre.Identity.uuid7()
    phase = Map.get(attrs, :phase, :unknown)
    sequence = Map.get(attrs, :sequence, 1)
    agent = Map.get(attrs, :agent)
    trace_id = Map.get(attrs, :trace_id) || turn_id
    occurred_at = Map.get(attrs, :occurred_at) || DateTime.utc_now()
    id = Map.get(attrs, :id) || stable_id(turn_id, phase, sequence, agent)

    attrs =
      attrs
      |> Map.put(:turn_id, turn_id)
      |> Map.put(:trace_id, trace_id)
      |> Map.put(:occurred_at, occurred_at)
      |> Map.put(:id, id)

    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @doc """
  Converts a record into a JSON-safe, string-keyed map for persistence.

  Record fields carry arbitrary runtime terms — atoms, tuples, structs,
  DateTimes — that JSON columns cannot store. This conversion is lossy but
  total: atoms become strings, tuples become lists, structs lose their module,
  calendar types render ISO-8601, and anything else falls back to `inspect/2`.
  Journal store adapters can persist the result directly:

      def append(record, _opts) do
        record |> Record.to_json_map() |> MyRepo.insert_journal_row()
      end
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_safe(value)} end)
  end

  @spec json_safe(term()) :: term()
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value) or is_binary(value) or is_number(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe(%{__struct__: _module} = value), do: value |> Map.from_struct() |> json_safe()
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key(key), json_safe(item)} end)
  end

  defp json_safe(value), do: inspect(value, limit: 20, printable_limit: 500)

  @spec json_key(term()) :: String.t()
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key, limit: 10, printable_limit: 100)

  @doc """
  Restores a persisted schema-v1 record while tolerating unknown additive
  fields. Legacy maps without a schema version are migrated to version 1.
  """
  @spec restore(t() | map()) :: {:ok, t()} | {:error, term()}
  def restore(%__MODULE__{} = record), do: {:ok, record}

  def restore(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)
    version = Map.get(attrs, :schema_version, 1)

    if version == @schema_version do
      {:ok, attrs |> Map.put(:schema_version, version) |> new()}
    else
      {:error, {:unsupported_journal_schema, version}}
    end
  end

  def restore(other), do: {:error, {:invalid_journal_record, other}}

  defp normalize_keys(attrs) do
    known = Map.new(fields(), &{Atom.to_string(&1), &1})

    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {Map.get(known, key, key), value}
      pair -> pair
    end)
  end

  @spec stable_id(term(), atom(), non_neg_integer(), module() | nil) :: String.t()
  defp stable_id(turn_id, phase, sequence, agent) do
    digest =
      {turn_id, phase, sequence, agent}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "journal:" <> binary_part(digest, 0, 32)
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
