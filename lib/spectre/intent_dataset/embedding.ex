defmodule Spectre.IntentDataset.Embedding do
  @moduledoc """
  Prepares compatible vectors for a labeled JSONL intent dataset.

  This batch boundary uses the Agent/Stack's configured encoder. It validates
  every source row before calling the encoder, reuses compatible stored vectors
  and enriches text-only rows. It neither trains a classifier nor mutates the
  online dataset. The output replaces its target atomically only after the whole
  batch succeeds; the source is therefore preserved on validation/provider errors.

  Existing vectors must carry the embedding profile metadata produced by the
  dataset service. Vectors with missing or incompatible profiles are rejected
  rather than attributed to the current encoder without evidence.
  """
  alias Spectre.Classifier.Encoder
  alias Spectre.Definition
  alias Spectre.Provider.Call
  alias Spectre.Router.SemanticCache.Learned.{Index, Rows, Snapshot}

  @doc "Prepares a JSONL artifact without recomputing valid compatible vectors."
  @spec prepare(module(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(agent, source, output, opts \\ []) do
    with {:ok, definition} <- Definition.fetch(agent),
         options <- options(agent, definition.config, opts),
         {:ok, entries} <- Snapshot.entries(source),
         {:ok, validated, dimensions} <- validate(entries, options),
         {:ok, prepared, embedded} <- embed(validated, dimensions, options),
         :ok <- write(prepared, output) do
      {:ok,
       %{
         path: output,
         examples: length(prepared),
         embedded: embedded,
         reused: length(prepared) - embedded
       }}
    end
  end

  defp options(agent, config, opts) do
    Application.get_env(:spectre, :classifier, [])
    |> Keyword.merge(config)
    |> Keyword.merge(agent.__spectre_router__())
    |> Keyword.merge(Spectre.IntentDataset.normalize_options(opts))
    |> Keyword.put(:spectre_rules, Definition.rules(agent))
  end

  defp validate(entries, opts) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], nil}, fn {entry, line}, {:ok, rows, dimensions} ->
      with {:ok, entry} <- validate_entry(entry, opts),
           {:ok, dimensions} <- dimensions(entry["embedding"], dimensions) do
        {:cont, {:ok, [entry | rows], dimensions}}
      else
        {:error, reason} -> {:halt, {:error, {:intent_dataset_row, line, reason}}}
      end
    end)
    |> case do
      {:ok, rows, dimensions} -> {:ok, Enum.reverse(rows), dimensions}
      error -> error
    end
  end

  defp validate_entry(%{"__error__" => reason}, _opts), do: {:error, reason}

  defp validate_entry(entry, opts) when is_map(entry) do
    text = Map.get(entry, "text")
    label = Map.get(entry, "label", Map.get(entry, "intent"))
    metadata = Map.get(entry, "metadata", %{})

    with :ok <- valid_text(text),
         {:ok, label} <- Rows.routeable_label(label, opts),
         :ok <- Rows.cacheable_label(label, opts),
         {:ok, vector} <- Rows.normalize_embedding(Map.get(entry, "embedding")),
         :ok <- valid_metadata(metadata),
         :ok <- Index.validate_embedding_profile(metadata, vector, opts) do
      {:ok,
       entry
       |> Map.put("label", Atom.to_string(label))
       |> Map.put("embedding", vector)
       |> Map.put("metadata", metadata)}
    end
  end

  defp validate_entry(_, _opts), do: {:error, :invalid_intent_dataset_row}

  defp valid_text(text) when is_binary(text) do
    if String.valid?(text) and String.trim(text) != "", do: :ok, else: {:error, :invalid_text}
  end

  defp valid_text(_), do: {:error, :invalid_text}
  defp valid_metadata(metadata) when is_map(metadata), do: :ok
  defp valid_metadata(_), do: {:error, :invalid_metadata}

  defp dimensions(nil, expected), do: {:ok, expected}
  defp dimensions(vector, nil), do: {:ok, length(vector)}

  defp dimensions(vector, expected) do
    if length(vector) == expected,
      do: {:ok, expected},
      else: {:error, {:embedding_dimension_mismatch, length(vector), expected}}
  end

  defp embed(entries, dimensions, opts) do
    if Enum.any?(entries, &is_nil(&1["embedding"])) do
      with {:ok, _profile} <- Index.embedding_profile_identity(opts),
           {:ok, loaded_dimensions} <- load_encoder(opts),
           {:ok, dimensions} <- reconcile_dimensions(dimensions, loaded_dimensions) do
        embed_entries(entries, dimensions, opts)
      end
    else
      {:ok, entries, 0}
    end
  end

  defp reconcile_dimensions(nil, dimensions), do: {:ok, dimensions}
  defp reconcile_dimensions(dimensions, nil), do: {:ok, dimensions}
  defp reconcile_dimensions(dimensions, dimensions), do: {:ok, dimensions}

  defp reconcile_dimensions(actual, expected),
    do: {:error, {:embedding_dimension_mismatch, actual, expected}}

  defp load_encoder(opts) do
    binding = Keyword.get(opts, :embedding, Keyword.get(opts, :embedding_adapter))
    {module, adapter_opts} = encoder_binding(binding)

    if loadable_encoder?(module),
      do: load_encoder_model(module, adapter_opts, opts),
      else: {:ok, nil}
  end

  defp encoder_binding({module, options}) when is_atom(module) and is_list(options),
    do: {module, options}

  defp encoder_binding(module) when is_atom(module), do: {module, []}
  defp encoder_binding(_), do: {nil, []}

  defp loadable_encoder?(nil), do: false

  defp loadable_encoder?(module) do
    Code.ensure_loaded?(module) and
      (function_exported?(module, :load, 2) or function_exported?(module, :load, 1))
  end

  defp load_encoder_model(module, adapter_opts, opts) do
    options = adapter_opts |> Keyword.merge(opts) |> Keyword.put(:embedding_adapter, module)

    model =
      Keyword.get(
        opts,
        :embedding_model,
        Keyword.get(
          adapter_opts,
          :model,
          Keyword.get(opts, :encoder_model, Encoder.default_model())
        )
      )

    case Encoder.load(model, options) do
      {:ok, dimensions} when is_integer(dimensions) and dimensions > 0 -> {:ok, dimensions}
      {:ok, _} -> {:error, :invalid_embedding_dimensions}
      error -> error
    end
  end

  defp embed_entries(entries, dimensions, opts) do
    Enum.reduce_while(entries, {:ok, [], dimensions, 0}, &embed_entry(&1, &2, opts))
    |> case do
      {:ok, rows, _dimensions, count} -> {:ok, Enum.reverse(rows), count}
      error -> error
    end
  end

  defp embed_entry(%{"embedding" => vector} = entry, {:ok, rows, dimensions, count}, _opts)
       when not is_nil(vector),
       do: {:cont, {:ok, [entry | rows], dimensions, count}}

  defp embed_entry(entry, {:ok, rows, dimensions, count}, opts) do
    with {:ok, vector} <- Call.run(:embedding, fn -> Index.embed(entry["text"], opts) end, opts),
         {:ok, vector} <- required_vector(vector),
         {:ok, dimensions} <- dimensions(vector, dimensions),
         {:ok, metadata} <- Index.bind_embedding_profile(entry["metadata"], vector, opts) do
      prepared = entry |> Map.put("embedding", vector) |> Map.put("metadata", metadata)
      {:cont, {:ok, [prepared | rows], dimensions, count + 1}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp required_vector(nil), do: {:error, :embedding_vector_required}
  defp required_vector(vector), do: Rows.normalize_embedding(vector)

  defp write(rows, path) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"
    contents = Enum.map_join(rows, "\n", &Spectre.JSON.encode!/1)
    contents = contents <> if(contents == "", do: "", else: "\n")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, contents, [:exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end
end
