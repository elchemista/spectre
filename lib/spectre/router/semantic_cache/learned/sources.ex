defmodule Spectre.Router.SemanticCache.Learned.Sources do
  @moduledoc """
  Static row sources for the learned semantic cache.

  Materializes immutable rows from labeled offline classifier datasets
  (JSON/JSONL files resolved from options and application config) and from
  route examples declared on cacheable rules. Static rows are read-only and
  carry deterministic ids so merged row sets stay stable.
  """

  import Spectre.Router.SemanticCache.Learned.Rows

  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Rule

  @doc "Returns offline dataset rows when static rows and mirroring are enabled."
  @spec maybe_offline_dataset_rows(keyword()) :: {:ok, [Learned.row()]} | {:error, term()}
  def maybe_offline_dataset_rows(opts) do
    if static_rows_enabled?(opts) and mirror_training_dataset?(opts) do
      offline_dataset_rows(opts)
    else
      {:ok, []}
    end
  end

  @doc "Returns static route-example rows when static rows are enabled."
  @spec maybe_static_route_rows(keyword()) :: [Learned.row()]
  def maybe_static_route_rows(opts) do
    if static_rows_enabled?(opts), do: static_route_rows(opts), else: []
  end

  @doc "Collects rows from every configured offline dataset source."
  @spec offline_dataset_rows(keyword()) :: {:ok, [Learned.row()]} | {:error, term()}
  def offline_dataset_rows(opts) do
    rules_by_label = opts |> cacheable_rules() |> index_rules_by_label()

    result =
      opts
      |> sources()
      |> Enum.reject(&(&1 in [true, false, nil]))
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case collect_entry(entry, rules_by_label, opts) do
          {:ok, rows} -> {:cont, {:ok, Enum.reverse(rows, acc)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    reverse_rows(result)
  end

  @doc "Builds rows from route examples declared on cacheable rules."
  @spec static_route_rows(keyword()) :: [Learned.row()]
  def static_route_rows(opts) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    opts
    |> cacheable_rules()
    |> Enum.flat_map(fn rule ->
      rule
      |> static_examples()
      |> Enum.map(&static_route_row(agent, rule, &1))
    end)
  end

  defp collect_entry(entry, rules, opts) when is_binary(entry) do
    if File.exists?(entry) do
      collect_file(entry, rules, opts)
    else
      {:error, {:missing_semantic_cache_source, entry}}
    end
  end

  defp collect_entry(entry, _rules, _opts), do: {:error, {:invalid_learning_entry, entry}}

  defp collect_file(path, rules, opts) do
    case Path.extname(path) do
      ".json" -> collect_json_file(path, rules, opts)
      ".jsonl" -> collect_jsonl_file(path, rules, opts)
      _other -> {:error, {:unsupported_semantic_cache_source, path}}
    end
  end

  defp collect_json_file(path, rules, opts) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text),
         true <- is_list(decoded) || {:error, {:invalid_learning_json, path}} do
      {:ok, Enum.flat_map(decoded, &source_rows(&1, rules, opts, path))}
    end
  end

  defp collect_jsonl_file(path, rules, opts) do
    case File.read(path) do
      {:ok, text} -> collect_jsonl_text(text, path, rules, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_jsonl_text(text, path, rules, opts) do
    result =
      text
      |> dataset_lines()
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        collect_jsonl_line(line, acc, path, rules, opts)
      end)

    reverse_rows(result)
  end

  defp collect_jsonl_line(line, acc, path, rules, opts) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        {:cont, {:ok, Enum.reverse(source_rows(decoded, rules, opts, path), acc)}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_learning_jsonl_row, path, reason}}}
    end
  end

  defp source_rows(%{"text" => text} = source, rules, opts, path) when is_binary(text) do
    source_label = Map.get(source, "label", Map.get(source, "intent"))
    rows_for_source_text(text, source_label, source, rules, opts, path)
  end

  defp source_rows(%{text: text} = source, rules, opts, path) when is_binary(text) do
    source_label = Map.get(source, :label, Map.get(source, :intent))
    rows_for_source_text(text, source_label, source, rules, opts, path)
  end

  defp source_rows(_source, _rules, _opts, _path), do: []

  defp rows_for_source_text(text, source_label, source, rules, opts, path) do
    agent = Keyword.get(opts, :spectre_agent, :anonymous)

    case matching_rules(source_label, rules) do
      [] ->
        []

      matched_rules ->
        Enum.map(matched_rules, fn rule ->
          offline_dataset_row(agent, rule, text, path, source)
        end)
    end
  end

  defp matching_rules(label, rules_by_label) do
    case canonical_label(label) do
      nil -> []
      label -> Map.get(rules_by_label, label, [])
    end
  end

  defp index_rules_by_label(rules) do
    rules
    |> Enum.reduce(%{}, fn rule, acc ->
      Map.update(acc, canonical_label(rule.label), [rule], &[rule | &1])
    end)
    |> Map.new(fn {label, matching} -> {label, Enum.reverse(matching)} end)
  end

  defp canonical_label(nil), do: nil

  defp canonical_label(label)
       when is_atom(label) or is_binary(label) or is_integer(label) or is_float(label),
       do: label |> to_string() |> String.upcase()

  defp canonical_label(_label), do: nil

  defp reverse_rows({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp reverse_rows({:error, _reason} = error), do: error

  defp offline_dataset_row(agent, %Rule{} = rule, text, path, source) do
    normalized = normalize_text(text)

    normalize_row(%{
      id: "dataset_#{stable_hash([agent, rule.label, normalized, path])}",
      agent: agent,
      text: String.trim(text),
      normalized_text: normalized,
      label: rule.label,
      source: :offline_dataset,
      source_strategy: nil,
      accepted?: true,
      confidence: 1.0,
      margin: nil,
      verified?: true,
      editable?: false,
      embedding: source_embedding(source),
      metadata: %{
        dataset_path: path,
        source: source_metadata(source),
        rule_label: rule.label
      },
      inserted_at: static_timestamp(),
      updated_at: static_timestamp()
    })
  end

  defp static_route_row(agent, %Rule{} = rule, text) do
    normalized = normalize_text(text)

    normalize_row(%{
      id: "static_#{stable_hash([agent, rule.label, normalized])}",
      agent: agent,
      text: String.trim(text),
      normalized_text: normalized,
      label: rule.label,
      source: :static_route_example,
      source_strategy: nil,
      accepted?: true,
      confidence: 1.0,
      margin: nil,
      verified?: true,
      editable?: false,
      embedding: nil,
      metadata: %{rule_label: rule.label},
      inserted_at: static_timestamp(),
      updated_at: static_timestamp()
    })
  end

  defp static_examples(%Rule{} = rule) do
    (rule.embedding ++ rule.bag ++ rule.jaro)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp sources(opts) do
    opts
    |> Keyword.get_values(:semantic_cache_source)
    |> Kernel.++(Keyword.get_values(opts, :source))
    |> Kernel.++(semantic_artifact_sources(opts))
    |> Kernel.++(configured_sources())
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp semantic_artifact_sources(opts) do
    config = Application.get_env(:spectre, :classifier, [])
    artifact_dir = Keyword.get(opts, :artifact_dir, Keyword.get(config, :artifact_dir))

    case artifact_dir do
      path when is_binary(path) ->
        semantic_path = Path.join(path, "semantic_cache.jsonl")
        if File.regular?(semantic_path), do: [semantic_path], else: []

      _other ->
        []
    end
  end

  defp configured_sources do
    config = Application.get_env(:spectre, :classifier, [])

    []
    |> Kernel.++(List.wrap(Keyword.get(config, :source)))
    |> Kernel.++(List.wrap(Keyword.get(config, :sources)))
    |> Kernel.++(List.wrap(Keyword.get(config, :dataset_path)))
    |> Kernel.++(default_source())
  end

  defp default_source do
    if File.exists?("training/dataset.json"), do: ["training/dataset.json"], else: []
  end

  defp static_rows_enabled?(opts), do: Keyword.get(opts, :semantic_cache_static?, true)

  defp mirror_training_dataset?(opts) do
    opts
    |> Keyword.get(
      :mirror_training_dataset?,
      Application.get_env(:spectre, :semantic_cache, [])
      |> Keyword.get(:mirror_training_dataset?, true)
    )
  end

  defp source_embedding(source) do
    source
    |> Map.get(
      "embedding",
      Map.get(source, :embedding, Map.get(source, "vector", Map.get(source, :vector)))
    )
    |> normalize_embedding()
    |> case do
      {:ok, embedding} -> embedding
      {:error, _reason} -> nil
    end
  end

  defp source_metadata(source) do
    source
    |> Map.drop(["embedding", :embedding, "vector", :vector])
    |> Enum.reject(fn {_key, value} -> is_binary(value) and byte_size(value) > 2_000 end)
    |> Map.new()
  end
end
