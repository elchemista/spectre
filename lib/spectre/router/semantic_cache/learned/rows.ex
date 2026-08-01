defmodule Spectre.Router.SemanticCache.Learned.Rows do
  @moduledoc """
  Row and label vocabulary for the built-in learned semantic cache.

  Normalizes row shapes and text, deduplicates merged row sets with a stable
  source ranking, validates embeddings, and resolves route labels against the
  agent's cacheable rules. Intended to be `import`ed by the Learned cache
  modules.
  """

  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Rule

  @doc "Fills defaults and normalizes text fields of a row."
  @spec normalize_row(map()) :: Learned.row()
  def normalize_row(row) do
    row
    |> Map.update!(:text, &String.trim/1)
    |> Map.update(:normalized_text, normalize_text(row.text), &normalize_text/1)
    |> Map.put_new(:accepted?, true)
    |> Map.put_new(:confidence, nil)
    |> Map.put_new(:margin, nil)
    |> Map.put_new(:source_strategy, nil)
    |> Map.put_new(:embedding, nil)
    |> Map.put_new(:metadata, %{})
  end

  @doc "Normalizes lookup text to its trimmed, lowercase key."
  @spec normalize_text(String.t()) :: String.t()
  def normalize_text(text), do: text |> String.trim() |> String.downcase()

  @doc "Requires non-blank text."
  @spec valid_text(String.t()) :: {:ok, String.t()} | {:error, term()}
  def valid_text(text) do
    text = String.trim(text)
    if text == "", do: {:error, :blank_text}, else: {:ok, text}
  end

  @doc "Puts one metadata key on a row."
  @spec put_metadata(Learned.row(), atom(), term()) :: Learned.row()
  def put_metadata(row, key, value) do
    Map.update!(row, :metadata, &Map.put(&1, key, value))
  end

  @doc "Deduplicates merged rows by normalized text with a stable source rank."
  @spec dedupe([Learned.row()]) :: [Learned.row()]
  def dedupe(rows) do
    rows
    |> Enum.reject(&(&1.text == ""))
    |> Enum.sort_by(&dedupe_rank/1)
    |> Enum.uniq_by(&{&1.agent, &1.normalized_text})
  end

  @doc "Splits dataset text into trimmed, non-comment lines."
  @spec dataset_lines(String.t()) :: [String.t()]
  def dataset_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc "Returns true for nil or empty strings."
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_value), do: false

  @doc "Compares a source label with a rule label case-insensitively."
  @spec same_label?(term(), atom()) :: boolean()
  def same_label?(source_label, label) do
    source_label
    |> to_string()
    |> String.upcase()
    |> Kernel.==(label |> to_string() |> String.upcase())
  end

  @doc "Fixed timestamp used for immutable static rows."
  @spec static_timestamp() :: DateTime.t()
  def static_timestamp, do: ~U[1970-01-01 00:00:00Z]

  @doc "Builds a short stable hash for deterministic static row ids."
  @spec stable_hash(term()) :: String.t()
  def stable_hash(term), do: term |> :erlang.phash2() |> Integer.to_string(36)

  @doc "Builds a unique online row id."
  @spec online_id() :: String.t()
  def online_id do
    "scx_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  @doc "Validates and coerces an embedding to a list of finite floats."
  @spec normalize_embedding(term()) :: {:ok, [float()] | nil} | {:error, term()}
  def normalize_embedding(nil), do: {:ok, nil}

  def normalize_embedding(embedding) when is_list(embedding) and embedding != [] do
    if Enum.all?(embedding, &finite_number?/1) do
      {:ok, Enum.map(embedding, &(&1 * 1.0))}
    else
      {:error, :invalid_semantic_cache_embedding}
    end
  end

  def normalize_embedding(_embedding), do: {:error, :invalid_semantic_cache_embedding}

  @doc "Returns the rules that allow semantic caching."
  @spec cacheable_rules(keyword()) :: [Rule.t()]
  def cacheable_rules(opts) do
    opts
    |> Keyword.get(:spectre_rules, [])
    |> Enum.map(&Rule.new(rule_to_map(&1)))
    |> Enum.filter(&cacheable_rule?/1)
  end

  @doc "Coerces a rule struct or map to a plain map."
  @spec rule_to_map(Rule.t() | map()) :: map()
  def rule_to_map(%Rule{} = rule), do: Map.from_struct(rule)
  def rule_to_map(rule) when is_map(rule), do: rule

  @doc "Resolves a label against declared route rules, or nil."
  @spec route_label(term(), [Rule.t() | map()]) :: atom() | nil
  def route_label(label, rules) when is_atom(label) do
    Enum.find_value(rules, fn rule ->
      rule = Rule.new(rule_to_map(rule))
      if rule.label == label, do: rule.label
    end)
  end

  def route_label(label, rules) when is_binary(label) do
    Enum.find_value(rules, fn rule ->
      rule = Rule.new(rule_to_map(rule))
      if same_label?(label, rule.label), do: rule.label
    end)
  end

  def route_label(_label, _rules), do: nil

  @doc "Resolves a label against the agent routes, tagging unknown labels."
  @spec routeable_label(term(), keyword()) :: {:ok, atom()} | {:error, term()}
  def routeable_label(label, opts) do
    case route_label(label, Keyword.get(opts, :spectre_rules, [])) do
      nil -> {:error, {:unknown_label, label}}
      label -> {:ok, label}
    end
  end

  @doc "Requires the label's route to allow semantic caching."
  @spec cacheable_label(atom(), keyword()) :: :ok | {:error, term()}
  def cacheable_label(label, opts) do
    if cacheable_label?(label, opts), do: :ok, else: {:error, {:uncacheable_label, label}}
  end

  @doc "Returns true when the label's route allows semantic caching."
  @spec cacheable_label?(atom(), keyword()) :: boolean()
  def cacheable_label?(label, opts), do: Enum.any?(cacheable_rules(opts), &(&1.label == label))

  defp dedupe_rank(%{source: :online_learned, verified?: true, updated_at: updated_at}) do
    {0, -DateTime.to_unix(updated_at, :microsecond)}
  end

  defp dedupe_rank(%{source: :offline_dataset, embedding: embedding})
       when is_list(embedding) and embedding != [],
       do: {1, 0}

  defp dedupe_rank(%{source: :offline_dataset}), do: {1, 1}
  defp dedupe_rank(%{source: :static_route_example}), do: {2, 0}

  defp dedupe_rank(%{source: :online_learned, updated_at: updated_at}) do
    {3, -DateTime.to_unix(updated_at, :microsecond)}
  end

  defp cacheable_rule?(%Rule{cache: false}), do: false
  defp cacheable_rule?(%Rule{via: []}), do: true
  defp cacheable_rule?(%Rule{via: via}), do: :semantic_cache in via

  defp finite_number?(number) when is_integer(number), do: true

  defp finite_number?(number) when is_float(number) do
    _encoded = :erlang.float_to_binary(number, [:compact])
    true
  rescue
    ArithmeticError -> false
  end

  defp finite_number?(_number), do: false
end
