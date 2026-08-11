defmodule Spectre.Router.SemanticCache.Learned.Snapshot do
  @moduledoc """
  Portable snapshot export and import for the learned semantic cache.

  Encodes review rows and their stored embeddings as JSON-compatible maps or
  an atomically written JSONL file, and restores online rows from snapshot
  maps or paths while re-validating labels against the agent's current
  cacheable routes.
  """

  import Spectre.Router.SemanticCache.Learned.Rows

  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Learned.Index
  alias Spectre.Router.SemanticCache.Learned.Online

  @default_learn_confidence 0.86

  @doc "Encodes rows as snapshot maps, or writes them to a JSONL path."
  @spec write([Learned.row()], String.t() | nil | term()) ::
          {:ok, String.t() | [map()]} | {:error, term()}
  def write(rows, nil), do: {:ok, Enum.map(rows, &encode_snapshot_row/1)}

  def write(rows, path) when is_binary(path) do
    rows
    |> Enum.map(&encode_snapshot_row/1)
    |> Enum.map_join("\n", &Jason.encode!/1)
    |> write_snapshot_file(path)
  end

  def write(_rows, path), do: {:error, {:invalid_snapshot_path, path}}

  @doc "Resolves snapshot input (path, rows, or keyword) into entry maps."
  @spec entries(term()) :: {:ok, [map()]} | {:error, term()}
  def entries(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      entries_from_opts(opts)
    else
      {:ok, opts}
    end
  end

  def entries(path) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, snapshot_lines(text)}
      {:error, reason} -> {:error, reason}
    end
  end

  def entries(other), do: {:error, {:invalid_snapshot, other}}

  @doc "Loads snapshot entries as online rows, summarizing skips and errors."
  @spec load(module(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def load(agent, entries, opts) do
    {loaded, skipped, errors} =
      Enum.reduce(entries, {0, 0, []}, fn entry, {loaded, skipped, errors} ->
        case load_entry(agent, entry, opts) do
          {:ok, row} ->
            Online.put_row(row, opts)
            {loaded + 1, skipped, errors}

          {:skip, reason} ->
            {loaded, skipped + 1, [reason | errors]}
        end
      end)

    if loaded > 0 do
      Online.bump_revision(agent)
    end

    _index_status = warm_index(opts)
    summary = %{loaded: loaded, skipped: skipped, errors: Enum.reverse(errors)}

    if Keyword.get(opts, :strict?, false) and errors != [] do
      {:error, {:invalid_snapshot, summary}}
    else
      {:ok, summary}
    end
  end

  defp warm_index(opts) do
    case Learned.rows(opts) do
      {:ok, rows} -> Index.warm(rows, opts)
      {:error, _reason} = error -> error
    end
  end

  defp write_snapshot_file(encoded, path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_snapshot_file_contents(path, encoded)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_snapshot_file_contents(path, encoded) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    contents = encoded <> if(encoded == "", do: "", else: "\n")

    with :ok <- File.write(temporary, contents),
         :ok <- File.rename(temporary, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp encode_snapshot_row(row) do
    %{
      id: row.id,
      text: row.text,
      label: to_string(row.label),
      source: to_string(row.source),
      source_strategy: source_strategy_string(row.source_strategy),
      confidence: row.confidence,
      verified: row.verified?,
      embedding: row.embedding,
      inserted_at: DateTime.to_iso8601(row.inserted_at),
      updated_at: DateTime.to_iso8601(row.updated_at),
      metadata: encode_metadata(row.metadata)
    }
  end

  defp source_strategy_string(nil), do: nil
  defp source_strategy_string(strategy), do: to_string(strategy)

  defp entries_from_opts(opts) do
    cond do
      path = Keyword.get(opts, :path) -> entries(path)
      rows = Keyword.get(opts, :rows) -> entries(rows)
      true -> {:error, :missing_snapshot}
    end
  end

  defp snapshot_lines(text) do
    text
    |> dataset_lines()
    |> Enum.map(&decode_snapshot_line/1)
  end

  defp decode_snapshot_line(line) do
    case Jason.decode(line) do
      {:ok, row} -> row
      {:error, reason} -> %{"__error__" => {:invalid_json, reason}}
    end
  end

  defp load_entry(_agent, %{"__error__" => reason}, _opts), do: {:skip, reason}

  defp load_entry(agent, entry, opts) when is_map(entry) do
    with {:ok, text} <- snapshot_text(entry),
         {:ok, label} <- routeable_label(snapshot_label(entry), opts),
         :ok <- cacheable_label(label, opts),
         {:ok, embedding} <- snapshot_embedding(entry),
         {:ok, metadata} <- snapshot_metadata(entry, embedding, opts) do
      {:ok, snapshot_row(agent, entry, text, label, embedding, metadata)}
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp load_entry(_agent, entry, _opts), do: {:skip, {:invalid_snapshot_row, entry}}

  defp snapshot_text(entry) do
    case Map.get(entry, "text") || Map.get(entry, :text) do
      text when is_binary(text) ->
        if String.trim(text) == "", do: {:skip, :blank_text}, else: {:ok, text}

      _other ->
        {:skip, :blank_text}
    end
  end

  defp snapshot_label(entry), do: Map.get(entry, "label") || Map.get(entry, :label)

  defp snapshot_row(agent, entry, text, label, embedding, metadata) do
    now = DateTime.utc_now()
    id = Map.get(entry, "id") || Map.get(entry, :id) || online_id()

    normalize_row(%{
      id: id,
      agent: agent,
      text: text,
      normalized_text: normalize_text(text),
      label: label,
      source: :online_learned,
      source_strategy:
        snapshot_atom(Map.get(entry, "source_strategy") || Map.get(entry, :source_strategy)),
      accepted?: true,
      confidence: snapshot_confidence(entry),
      margin: nil,
      verified?:
        Map.get(entry, "verified", Map.get(entry, :verified, Map.get(entry, :verified?, false))),
      editable?: true,
      embedding: embedding || existing_snapshot_embedding(agent, id, text),
      metadata: metadata,
      inserted_at:
        snapshot_time(Map.get(entry, "inserted_at") || Map.get(entry, :inserted_at), now),
      updated_at: snapshot_time(Map.get(entry, "updated_at") || Map.get(entry, :updated_at), now)
    })
  end

  defp snapshot_confidence(entry) do
    case Map.get(entry, "confidence") || Map.get(entry, :confidence) do
      value when is_number(value) and value > 0 -> value
      _other -> @default_learn_confidence
    end
  end

  defp snapshot_embedding(entry) do
    entry
    |> Map.get("embedding", Map.get(entry, :embedding))
    |> normalize_embedding()
  end

  defp existing_snapshot_embedding(agent, id, text) do
    case Online.fetch(agent, id) do
      %{text: existing_text, embedding: embedding}
      when is_list(embedding) and embedding != [] ->
        if normalize_text(existing_text) == normalize_text(text), do: embedding

      _other ->
        nil
    end
  end

  defp snapshot_metadata(entry) do
    case Map.get(entry, "metadata") || Map.get(entry, :metadata) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp snapshot_metadata(entry, embedding, opts) do
    metadata = snapshot_metadata(entry)

    case {Map.get(metadata, :embedding_profile_ref, Map.get(metadata, "embedding_profile_ref")),
          Map.get(
            metadata,
            :embedding_profile_digest,
            Map.get(metadata, "embedding_profile_digest")
          )} do
      {nil, nil} ->
        Index.bind_embedding_profile(metadata, embedding, opts)

      _present ->
        with :ok <- Index.validate_embedding_profile(metadata, embedding, opts),
             do: {:ok, metadata}
    end
  end

  defp snapshot_atom(nil), do: nil

  defp snapshot_atom(value) when is_atom(value), do: value

  defp snapshot_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> existing_snapshot_atom(text)
    end
  end

  defp existing_snapshot_atom(text) do
    String.to_existing_atom(text)
  rescue
    ArgumentError -> nil
  end

  defp snapshot_time(%DateTime{} = time, _default), do: time

  defp snapshot_time(value, default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> time
      _other -> default
    end
  end

  defp snapshot_time(_value, default), do: default

  defp encode_metadata(metadata) do
    Map.new(metadata, fn {key, value} ->
      {to_string(key), encode_metadata_value(value)}
    end)
  end

  defp encode_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_metadata_value(value) when is_atom(value), do: to_string(value)
  defp encode_metadata_value(value) when is_map(value), do: encode_metadata(value)

  defp encode_metadata_value(value) when is_list(value),
    do: Enum.map(value, &encode_metadata_value/1)

  defp encode_metadata_value(value), do: value
end
