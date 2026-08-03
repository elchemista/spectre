defmodule Spectre.Training.Dataset do
  @moduledoc """
  Builds classifier datasets from Spectre agent routing metadata.

  Training examples live in configured dataset sources. Rows must carry a
  `label` or `intent`, and this module exports only labels that exist on the
  agent's routes or policy branches.

      {:ok, rows} =
        Spectre.Training.Dataset.from_agent(MyApp.Agent,
          source: "training/raw_intents.jsonl"
        )
  """

  alias Spectre.Rule

  @type row :: %{text: String.t(), label: String.t()}

  @doc """
  Collects classifier rows from labeled dataset sources for the agent's known
  route and policy labels.

  Supported dataset files:

    * `.json` files - list of objects with `text` and `label`/`intent`.
    * `.jsonl` files - one JSON object per line with `text` and `label`/`intent`.

  ```elixir
  {:ok, rows} = Spectre.Training.Dataset.from_agent(MyApp.Agent)
  ```
  """
  @spec from_agent(module(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def from_agent(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    with {:ok, labels} <- training_labels(agent),
         {:ok, rows} <- collect_sources(labels, opts) do
      {:ok, dedupe(rows)}
    end
  end

  @spec training_labels(module()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  defp training_labels(agent) do
    case training_agent?(agent) do
      true -> {:ok, agent |> agent_labels() |> MapSet.new(&label_id/1)}
      false -> {:error, {:invalid_agent, agent}}
    end
  end

  @spec training_agent?(module()) :: boolean()
  defp training_agent?(agent) do
    Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_rules__, 0)
  end

  @spec agent_labels(module()) :: [atom()]
  defp agent_labels(agent), do: rule_labels(agent) ++ policy_labels(agent)

  @spec rule_labels(module()) :: [atom()]
  defp rule_labels(agent) do
    agent
    |> Spectre.Definition.rules()
    |> Enum.map(&Rule.new/1)
    |> Enum.map(& &1.label)
  end

  @spec policy_labels(module()) :: [atom()]
  defp policy_labels(agent) do
    if function_exported?(agent, :__spectre_policies__, 0) do
      agent.__spectre_policies__()
      |> Enum.flat_map(fn {policy_name, policy} ->
        policy_labels(policy_name, Map.get(policy, :accepts, []), :accept) ++
          policy_labels(policy_name, Map.get(policy, :rejects, []), :reject)
      end)
    else
      []
    end
  end

  @spec policy_labels(atom(), [map()], atom()) :: [atom()]
  defp policy_labels(_policy_name, branches, _kind) do
    Enum.map(branches, &Map.fetch!(&1, :label))
  end

  @spec collect_sources(MapSet.t(String.t()), keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_sources(labels, opts) do
    sources = sources(opts)

    result =
      Enum.reduce_while(sources, {:ok, []}, fn target, {:ok, rows} ->
        case collect_entry(target, labels) do
          {:ok, target_rows} -> {:cont, {:ok, Enum.reverse(target_rows, rows)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    reverse_rows(result)
  end

  defp sources(opts) do
    opts
    |> Keyword.get_values(:source)
    |> Kernel.++(configured_sources())
    |> List.flatten()
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
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

  @spec collect_entry(term(), MapSet.t(String.t())) :: {:ok, [row()]} | {:error, term()}
  defp collect_entry(entry, labels) when is_binary(entry) do
    if File.exists?(entry) do
      collect_file(entry, labels)
    else
      {:error, {:missing_dataset_source, entry}}
    end
  end

  defp collect_entry(entry, _labels), do: {:error, {:invalid_training_source, entry}}

  @spec collect_file(String.t(), MapSet.t(String.t())) :: {:ok, [row()]} | {:error, term()}
  defp collect_file(path, labels) do
    case Path.extname(path) do
      ".json" -> collect_json_file(path, labels)
      ".jsonl" -> collect_jsonl_file(path, labels)
      _other -> {:error, {:unsupported_dataset_source, path}}
    end
  end

  @spec collect_json_file(String.t(), MapSet.t(String.t())) :: {:ok, [row()]} | {:error, term()}
  defp collect_json_file(path, labels) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text),
         true <- is_list(decoded) || {:error, {:invalid_dataset_json, path}} do
      {:ok, decoded |> Enum.flat_map(&normalize_source_row(&1, labels))}
    end
  end

  @spec collect_jsonl_file(String.t(), MapSet.t(String.t())) :: {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_file(path, labels) do
    with {:ok, text} <- File.read(path) do
      result =
        text
        |> String.splitter("\n")
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
          collect_jsonl_line(String.trim(line), rows, path, labels)
        end)

      reverse_rows(result)
    end
  end

  @spec collect_jsonl_line(String.t(), [row()], String.t(), MapSet.t(String.t())) ::
          {:cont, {:ok, [row()]}} | {:halt, {:error, term()}}
  defp collect_jsonl_line("", rows, _path, _labels), do: {:cont, {:ok, rows}}
  defp collect_jsonl_line("#" <> _comment, rows, _path, _labels), do: {:cont, {:ok, rows}}

  defp collect_jsonl_line(line, rows, path, labels) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        {:cont, {:ok, Enum.reverse(normalize_source_row(decoded, labels), rows)}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_jsonl_row, path, reason}}}
    end
  end

  @spec reverse_rows({:ok, [row()]} | {:error, term()}) ::
          {:ok, [row()]} | {:error, term()}
  defp reverse_rows({:ok, rows}), do: {:ok, Enum.reverse(rows)}
  defp reverse_rows({:error, _reason} = error), do: error

  @spec normalize_source_row(term(), MapSet.t(String.t())) :: [row()]
  defp normalize_source_row(%{"text" => text} = source, labels) when is_binary(text) do
    source
    |> Map.get("label", Map.get(source, "intent"))
    |> row_for_label(text, labels)
  end

  defp normalize_source_row(%{text: text} = source, labels) when is_binary(text) do
    source
    |> Map.get(:label, Map.get(source, :intent))
    |> row_for_label(text, labels)
  end

  defp normalize_source_row(_source, _labels), do: []

  @spec row_for_label(term(), String.t(), MapSet.t(String.t())) :: [row()]
  defp row_for_label(source_label, text, labels) do
    label = label_id(source_label)

    if label != "" and MapSet.member?(labels, label) do
      [row(text, label)]
    else
      []
    end
  end

  @spec row(String.t(), atom() | String.t()) :: row()
  defp row(text, label), do: %{text: String.trim(text), label: label_id(label)}

  @spec dedupe([row()]) :: [row()]
  defp dedupe(rows) do
    rows
    |> Enum.reject(&(&1.text == ""))
    |> Enum.uniq_by(&{&1.label, String.downcase(&1.text)})
  end

  @spec label_id(term()) :: String.t()
  defp label_id(nil), do: ""

  defp label_id(label)
       when is_atom(label) or is_binary(label) or is_integer(label) or is_float(label),
       do: label |> to_string() |> String.upcase()

  defp label_id(_label), do: ""

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
