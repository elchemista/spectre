defmodule Spectre.Training.Dataset do
  @moduledoc """
  Builds classifier datasets from Spectre agent routing metadata.
  """

  alias Spectre.Rule

  @type row :: %{text: String.t(), label: String.t()}

  @doc """
  Collects classifier rows from an agent's rule and policy `train` metadata.

  Supported training entries:

    * `true` - include examples for the route label from `:source` files.
    * binary text - direct example unless it points to an existing file.
    * `.json` files - list of objects with `text` and optional `label`/`intent`.
    * `.jsonl` files - one JSON object per line.
    * other files - one example per non-empty, non-comment line.
  """
  @spec from_agent(module(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def from_agent(agent, opts \\ []) when is_atom(agent) and is_list(opts) do
    with {:ok, targets} <- training_targets(agent),
         {:ok, rows} <- collect_targets(targets, opts) do
      {:ok, dedupe(rows)}
    end
  end

  @spec training_targets(module()) :: {:ok, [map()]} | {:error, term()}
  defp training_targets(agent) do
    case training_agent?(agent) do
      true -> {:ok, agent |> agent_targets() |> Enum.filter(&(&1.training != []))}
      false -> {:error, {:invalid_agent, agent}}
    end
  end

  @spec training_agent?(module()) :: boolean()
  defp training_agent?(agent) do
    Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_rules__, 0)
  end

  @spec agent_targets(module()) :: [map()]
  defp agent_targets(agent), do: rule_targets(agent) ++ policy_targets(agent)

  @spec rule_targets(module()) :: [map()]
  defp rule_targets(agent) do
    agent.__spectre_rules__()
    |> Enum.map(&Rule.new/1)
    |> Enum.map(fn rule ->
      %{label: rule.label, training: rule.training, source: {:rule, rule.flow}}
    end)
  end

  @spec policy_targets(module()) :: [map()]
  defp policy_targets(agent) do
    if function_exported?(agent, :__spectre_policies__, 0) do
      agent.__spectre_policies__()
      |> Enum.flat_map(fn {policy_name, policy} ->
        policy_targets(policy_name, Map.get(policy, :accepts, []), :accept) ++
          policy_targets(policy_name, Map.get(policy, :rejects, []), :reject)
      end)
    else
      []
    end
  end

  @spec policy_targets(atom(), [map()], atom()) :: [map()]
  defp policy_targets(policy_name, branches, kind) do
    Enum.map(branches, fn branch ->
      %{
        label: Map.fetch!(branch, :label),
        training: List.wrap(Map.get(branch, :training, [])),
        source: {:policy, policy_name, kind}
      }
    end)
  end

  @spec collect_targets([map()], keyword()) :: {:ok, [row()]} | {:error, term()}
  defp collect_targets(targets, opts) do
    sources = opts |> Keyword.get_values(:source) |> List.flatten()

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, rows} ->
      case collect_target(target, sources) do
        {:ok, target_rows} -> {:cont, {:ok, rows ++ target_rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec collect_target(map(), [String.t()]) :: {:ok, [row()]} | {:error, term()}
  defp collect_target(%{training: [true], label: label}, sources) do
    collect_entries(sources, label)
  end

  defp collect_target(%{training: training, label: label}, _sources) do
    collect_entries(training, label)
  end

  @spec collect_entries([term()], atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_entries(entries, label) do
    entries
    |> Enum.reject(&(&1 in [true, false, nil]))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, rows} ->
      case collect_entry(entry, label) do
        {:ok, entry_rows} -> {:cont, {:ok, rows ++ entry_rows}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec collect_entry(term(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_entry(entry, label) when is_binary(entry) do
    if File.exists?(entry) do
      collect_file(entry, label)
    else
      {:ok, [row(entry, label)]}
    end
  end

  defp collect_entry(entry, _label), do: {:error, {:invalid_training_entry, entry}}

  @spec collect_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_file(path, label) do
    case Path.extname(path) do
      ".json" -> collect_json_file(path, label)
      ".jsonl" -> collect_jsonl_file(path, label)
      _other -> collect_lines_file(path, label)
    end
  end

  @spec collect_json_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_json_file(path, label) do
    with {:ok, text} <- File.read(path),
         {:ok, decoded} <- Jason.decode(text),
         true <- is_list(decoded) || {:error, {:invalid_dataset_json, path}} do
      {:ok, decoded |> Enum.flat_map(&normalize_source_row(&1, label))}
    end
  end

  @spec collect_jsonl_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_jsonl_file(path, label) do
    with {:ok, text} <- File.read(path) do
      text
      |> dataset_lines()
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
        collect_jsonl_line(line, rows, path, label)
      end)
    end
  end

  @spec collect_lines_file(String.t(), atom()) :: {:ok, [row()]} | {:error, term()}
  defp collect_lines_file(path, label) do
    with {:ok, text} <- File.read(path) do
      rows =
        text
        |> dataset_lines()
        |> Enum.map(&row(&1, label))

      {:ok, rows}
    end
  end

  @spec dataset_lines(String.t()) :: [String.t()]
  defp dataset_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @spec collect_jsonl_line(String.t(), [row()], String.t(), atom()) ::
          {:cont, {:ok, [row()]}} | {:halt, {:error, term()}}
  defp collect_jsonl_line(line, rows, path, label) do
    case Jason.decode(line) do
      {:ok, decoded} -> {:cont, {:ok, rows ++ normalize_source_row(decoded, label)}}
      {:error, reason} -> {:halt, {:error, {:invalid_jsonl_row, path, reason}}}
    end
  end

  @spec normalize_source_row(term(), atom()) :: [row()]
  defp normalize_source_row(%{"text" => text} = source, label) when is_binary(text) do
    source_label = Map.get(source, "label", Map.get(source, "intent"))

    if blank?(source_label) or same_label?(source_label, label) do
      [row(text, label)]
    else
      []
    end
  end

  defp normalize_source_row(%{text: text} = source, label) when is_binary(text) do
    source_label = Map.get(source, :label, Map.get(source, :intent))

    if blank?(source_label) or same_label?(source_label, label) do
      [row(text, label)]
    else
      []
    end
  end

  defp normalize_source_row(_source, _label), do: []

  @spec row(String.t(), atom()) :: row()
  defp row(text, label), do: %{text: String.trim(text), label: label_id(label)}

  @spec dedupe([row()]) :: [row()]
  defp dedupe(rows) do
    rows
    |> Enum.reject(&(&1.text == ""))
    |> Enum.uniq_by(&{&1.label, String.downcase(&1.text)})
  end

  @spec same_label?(term(), atom()) :: boolean()
  defp same_label?(source_label, label) do
    source_label
    |> to_string()
    |> String.upcase()
    |> Kernel.==(label_id(label))
  end

  @spec label_id(atom()) :: String.t()
  defp label_id(label), do: label |> to_string() |> String.upcase()

  @spec blank?(term()) :: boolean()
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
